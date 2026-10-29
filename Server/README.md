# TableLog 맥스튜디오 서버 0.3.0

TableLog Android의 녹음을 Whisper large-v3-turbo로 전사합니다. 맥의 API는 `127.0.0.1:7870`에서만 듣고 Caddy의 HTTPS 경로 `/tablelog-api/`를 통해 접근합니다. 음성 모델은 요청마다 별도 프로세스로 실행하고 완료·취소·시간 초과 시 프로세스를 종료합니다. 상시 모델 메모리는 없습니다. 회의록 자동 요약과 화자 분리는 제공하지 않습니다.

## 태블릿 연결

맥의 저장소 루트에서 실행합니다.

```sh
Server/tablelog-server issue-code --name '내 태블릿'
```

TableLog 앱의 **설정 → 맥스튜디오 선택 → 일회용 연결 코드 → 코드로 연결·저장**에 표시된 코드를 입력합니다. 코드는 10분간 한 번 사용할 수 있습니다. 별도의 웹 승인 화면은 없습니다. 새 기기 토큰은 30일간 유효하며 만료 후 새 코드로 연결합니다. 자동 갱신은 없습니다.

```sh
Server/tablelog-server devices
Server/tablelog-server revoke 기기ID
```

연결 해제는 해당 기기 토큰만 무효화합니다. 앱의 **연결 지우기**는 앱 안의 설정만 삭제하므로 분실 기기는 반드시 위 명령으로 해제합니다. 이미 진행 중인 전사는 끝날 수 있지만 이후 요청은 거부됩니다.

## 설치와 실행

Apple Silicon Mac, Python 3.12와 `requirements.txt`의 패키지가 필요합니다. 이 맥에서는 기존 `~/Library/Application Support/CoworkPython/envs/fish-audio-s2/` 환경을 재사용합니다. 다른 환경은 `TABLELOG_PYTHON`으로 지정합니다. 환경·모델·인증 DB는 Git과 iCloud 밖에 둡니다.

워커는 다음 Hugging Face 스냅샷을 로컬 캐시에서 읽습니다. 다운로드는 운영 요청 중 수행하지 않습니다.

- `mlx-community/whisper-large-v3-turbo`, revision `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb`
- `openai/whisper-large-v3-turbo`, revision `41f01f3fe87f28c78e2fbf8b568835947dd65ed9` (processor와 generation config)

```sh
# 직접 실행
Server/tablelog-server serve
# 같은 Python 환경으로 로그인 시 자동 실행 등록/업데이트
"$HOME/Library/Application Support/CoworkPython/envs/fish-audio-s2/bin/python" Server/install_service.py
```

설치기는 코드 두 파일을 `~/Library/Application Support/TableLogServer/app/`에 복사하고 `com.yunju.tablelog-server` LaunchAgent를 등록합니다. 기존 기기 DB는 보존합니다. `Server/85-tablelog.caddy`는 기존 HTTPS 프록시 사이트 안에 넣을 경로 예시이며 설치기가 프록시 설정을 자동 수정하지 않습니다. 외부 기본 주소는 `https://yunju.work/tablelog-api/v1`입니다.

## 접근·부하 제한

- 공개 경로는 상태 확인 `GET /health`, 코드 교환 `POST /v1/devices/connect`입니다. 코드 발급·기기 목록·임의 기기 폐기는 맥 CLI에서만 가능합니다.
- 모델 목록·전사는 기기 Bearer 토큰을 검증한 후 본문을 읽습니다. DB에는 코드·토큰의 SHA-256만 보관합니다. 토큰은 256비트 난수이며 기기마다 다릅니다.
- 코드 교환은 서버 전체 분당 20회 제한입니다. 반복 시도로 본인의 연결도 잠시 막힐 수 있습니다. 사용자별 공정한 작업 큐는 없습니다.
- 최대 요청 12MiB, 16kHz mono PCM16 WAV 5분 이하, 동시 전사 1개, 워커 실행 210초 제한입니다. 다른 작업 중에는 429를 반환합니다. 앱이 긴 녹음을 5분씩 순서대로 보냅니다.
- 업로드는 임시 폴더에만 두고 작업 후 삭제합니다. 서버에는 회의 기록·전사 결과를 영구 보관하지 않습니다. 모델이 실패하면 원본은 태블릿에 남습니다.
- 앱에 서버 관리자 키나 공용 인증 토큰을 넣지 않습니다. APK에서 서버 주소와 통신 규약은 확인할 수 있습니다. 루팅된 기기나 탈취된 토큰까지 방어한다고 보장하지 않습니다.
- **기존 Fish Audio 공개 웹은 사용자의 요청에 따라 인증 없이 유지합니다.** 이 서버의 인증은 `/tablelog-api/`에 적용됩니다. Fish 웹 주소를 아는 사람은 기존 합성·목소리·학습 기능을 사용할 수 있습니다.

## 검증

```sh
cd Server
"$HOME/Library/Application Support/CoworkPython/envs/fish-audio-s2/bin/python" -m unittest -v test_server
```

단위 검증은 합성 워커로 인증·코드 재사용·만료·기기별 폐기·요청 크기·WAV·속도 제한을 확인합니다. 실제 Whisper·외부 HTTPS·태블릿 검증 범위는 [Android 검증 기록](../Android/VERIFICATION.md)에 별도로 기록합니다.
