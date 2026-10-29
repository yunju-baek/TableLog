# 테이블로그 Android 0.3.0

회의를 녹음하고 발언·회의록·메모를 기기에 보관하는 Kotlin·Jetpack Compose 앱입니다. 주 대상은 **레노버 샤오신패드 프로 13(TB376FC), RAM 8GB**입니다. 전사 방식은 **태블릿 로컬 / 서버** 중 직접 선택하며, 오류가 나도 다른 방식으로 자동 전환하지 않습니다.

## 설치와 첫 사용

GitHub Releases의 `TableLog-0.3.0.apk`는 배포 키로 서명한 release 빌드입니다. Android 8.0(API 26) 이상의 arm64·x86_64 기기를 지원합니다. Play Store 출시는 별도 작업입니다. 기존 debug APK와 서명 키가 달라 바로 덮어 설치할 수 없습니다. 기존 기록의 JSON·WAV를 먼저 내보낸 다음 테스트 앱을 삭제하고 설치하세요. 새 release 버전끼리는 같은 서명으로 업데이트합니다.

Fish Audio 합성 앱은 별도 `FishAudio-0.1.0.apk`이며 [사용 안내](FISH_AUDIO.md)를 참조하세요.

1. `TableLog-0.3.0.apk`를 태블릿에 설치합니다. USB 연결 시 `adb install -r TableLog-0.3.0.apk`를 사용할 수 있습니다.
2. 설정에서 **한국어 모델 설치**를 누릅니다. Hugging Face와 GitHub에서 약 230MiB를 한 번 다운로드합니다. 설치에는 녹음을 전송하지 않습니다. 중단 후 다시 누르면 이어받고, 파일 크기와 SHA-256을 확인한 뒤 설치를 완료합니다.
3. **새 회의 녹음**을 누르고 마이크 권한을 허용합니다. 알림 권한도 허용하면 앱 밖에서 녹음과 로컬 작업을 제어할 수 있습니다.
4. 녹음을 **저장**한 뒤 **태블릿 로컬 → 로컬 전사**를 누릅니다. 설치가 끝난 모델은 인터넷 없이 실행합니다. 결과를 검토하고 적용해야 기존 녹취가 바뀝니다.
5. 맥스튜디오는 **설정 → 맥스튜디오 선택**을 누르고 맥에서 `Server/tablelog-server issue-code`로 발급한 일회용 코드를 입력합니다. **코드로 연결·저장**하면 서버 전사로 전환됩니다. 다른 서버의 HTTPS 주소·기기 토큰·모델을 직접 입력할 수도 있습니다. 실행 전 실제 전송 대상과 보낼 자료를 확인합니다.

로컬 회의록 요약과 자동 화자 분리는 아직 없습니다. **서버 회의록**은 별도 버튼이며, 로컬 전사를 선택했더라도 이 버튼을 누르면 녹취·메모의 서버 전송 확인을 거칩니다. 서버 없이 회의록 양식과 직접 편집을 사용할 수 있습니다.

## 8GB 태블릿에서의 로컬 처리

- sherpa-onnx 2.0.1의 CPU 실행 경로로 SenseVoice Small INT8 한국어 전사를 수행합니다. 음성 인식은 2스레드, Silero VAD는 1스레드로 제한합니다. GPU·NPU 가속은 사용하지 않습니다.
- 녹음 종료 후 한 작업씩 처리합니다. 원본 WAV를 작은 프레임으로 읽고, 발화 구간은 약 20초 안에서 나눕니다. 전체 녹음을 메모리에 올리지 않으며 네이티브 스트림·모델은 처리 종료 시 해제합니다.
- 시각은 VAD가 찾은 발화 구간 기준입니다. 단어별 강제 정렬이나 자동 화자 식별을 수행한 결과가 아니며 화자는 **화자 미지정**으로 표시합니다. 한국어 띄어쓰기·고유명사와 긴 발화 경계는 실제 회의로 품질을 평가해야 합니다.
- 모델 설치와 전사는 알림이 있는 foreground service에서 실행하며 화면을 꺼도 작업을 이어갈 수 있습니다. 취소 시 현재 네이티브 구간 처리를 마친 후 해제하므로 즉시 끝나지 않을 수 있습니다. 녹음과 무거운 로컬 작업은 동시에 시작하지 않습니다.
- 완료 결과는 `local-proposal.json`에 원자적으로 저장해 앱을 다시 열어도 검토할 수 있습니다. 결과 적용 시 회의 revision을 확인하여 그동안 수정한 기록을 덮어쓰지 않습니다.
- 프로세스가 종료되면 진행 중 전사는 중단됩니다. 원본은 보존하며 사용자가 다시 실행합니다. 처리 중간부터 재개하는 기능은 아직 없습니다. 설치 중단은 `.part` 파일을 이용해 이어받습니다.

모델 파일은 APK·Git에 넣지 않습니다. [고정 다운로드 목록과 해시](app/src/main/assets/local-models.json), [SenseVoice 모델 안내](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html), [모델 원 출처·이용 조건](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)을 참조하세요. 런타임·모델 고지는 `app/src/main/assets/licenses/`에 포함합니다.

## 태블릿 화면

사용 가능한 창 너비가 1000dp 이상이면 왼쪽 회의 목록과 오른쪽 회의 상세를 함께 표시합니다. 세로·분할 창에서 너비가 줄면 목록과 상세를 한 영역씩 보여줍니다. 물리 해상도에 고정하거나 가로 방향을 강제하지 않습니다. 녹취·회의록·메모는 상세 영역의 탭으로 전환합니다. 세 영역 동시 배치는 후속 작업입니다.

Lenovo 공식 사양은 Snapdragon 8s Gen 4, 13인치 3504×2190입니다. 사용자의 RAM 8GB는 확인했으며 설치된 OS와 제조사 절전 동작은 실기기 확인 전입니다. [Lenovo 사양](https://item.lenovovip.com.cn/pd/1053160.html), [Android 적응형 레이아웃](https://developer.android.com/develop/ui/compose/layouts/adaptive/list-detail).

## 현재 서버 연결 계약

0.3.0은 맥스튜디오 기본 주소 `https://yunju.work/tablelog-api/v1`와 일회용 코드 연결을 제공합니다. 코드는 맥에서 발급하며 10분간 한 번 유효합니다. 교환한 기기 토큰은 30일 후 만료되고 맥 CLI에서 개별 해제할 수 있습니다. [서버 실행·연결 안내](../Server/README.md). 다른 HTTPS 서버의 토큰 수동 등록도 유지합니다.

| 경로 | 요청 | 응답 |
| --- | --- | --- |
| `GET /models` | `Authorization: Bearer <기기 토큰>`만 전송 | `data` 배열. 연결 확인용이며 녹음·녹취를 보내지 않음 |
| `POST /audio/transcriptions` | multipart: `file` WAV, `model`, `language=ko`, `response_format=verbose_json` | `segments: [{start, end, text}]` 또는 `text` |
| `POST /chat/completions` | JSON: `model`, `messages`, `stream=false` | `choices[0].message.content` |

세 경로 모두 설정한 기본 주소 아래에 붙습니다. 서버 전사는 현재 최대 5분 WAV를 순서대로 보내고 응답 시각을 전체 회의의 초 단위로 변환합니다. 단어 `words[]`만 반환하는 NeMo 서버는 API 계층에서 문장 `segments[]`로 변환해야 시각을 활용할 수 있습니다. CLOVA의 밀리초 시각도 변환해야 합니다. 현재 앱은 서버 응답의 화자 필드를 사용하지 않습니다. `text`만 있으면 해당 5분 전체를 한 발언으로 보관합니다. 구간 경계 문맥 연결·업로드 재개·서버 작업 큐는 아직 없습니다.

회의록 요청은 제목·일시·녹취·메모를 보냅니다. 녹취와 메모가 합계 10만 자를 넘으면 중단하고, 임의로 잘라 보내지 않습니다. 일부 구간만 성공한 전사는 적용하지 않습니다. 요청 취소 시 네트워크 호출을 취소하고, 전송 확인 시점의 서버 설정을 해당 요청에 고정합니다.

맥스튜디오 기본값은 Whisper 음성 전사만 제공합니다. 회의록 모델은 비워 두며 자동 요약은 별도 `/chat/completions` 서버가 필요합니다. Mac의 Codex·Claude Code·Gemini CLI 로그인이나 구독을 자동 연결하지 않습니다.

## 서버 인증과 등록 방식

### 현재 앱에 구현한 범위

- 토큰을 Android Keystore의 AES-GCM 키로 암호화하고, 정규화한 서버 기본 주소를 인증 데이터(AAD)로 사용합니다. 다른 주소로 암호문을 옮겨 재사용할 수 없습니다. 이는 기기 내 보관 보호이며 서버가 기기 신원을 검증했다는 뜻은 아닙니다.
- 토큰은 요청의 Authorization 헤더로만 보내며 URL·로그·내보내기·화면 복원 상태에 넣지 않습니다. 서버 주소를 편집하면 입력 중인 기존 토큰을 지웁니다.
- 일반 TLS 인증서 검증을 유지합니다. HTTP, URL 내 아이디·비밀번호·쿼리 키, 요청 리디렉션은 거부합니다. 인증서 검증을 끄거나 자체 서명 인증서를 무조건 신뢰하는 우회는 제공하지 않습니다.
- HTTP 401은 인증 만료/오류, 403은 권한 부족으로 구분해 안내합니다. 자동 재로그인·토큰 갱신은 아직 없습니다.
- **연결 지우기**는 이 기기에 저장된 서버 설정만 삭제합니다. 서버의 토큰 폐기는 서버 기기 관리에서 해야 합니다. 모델·회의 기록·전사 방식은 그대로 유지합니다.

### 맥스튜디오 기기 연결

코드 교환 `POST /devices/connect`에는 일회용 코드만 전송합니다. 서버가 반환한 개별 토큰을 위 방식으로 저장합니다. 서버는 코드·토큰의 해시만 보관하고 `/models`와 전사 요청을 인증합니다. 기기 목록과 코드 발급은 로컬 CLI에서만 가능합니다. 별도의 웹 승인 화면이나 OAuth 폴링 절차는 사용하지 않습니다.

공개 APK에 공용 관리자 키나 장기 API 키를 포함하지 않습니다. 코드 교환은 HTTPS이며 리디렉션을 따라가지 않습니다. 서버의 요청 크기·동시 실행 제한과 기기별 폐기는 [서버 안내](../Server/README.md)에 정리했습니다. 연결 코드와 토큰을 다른 사람에게 전달하면 그 사람이 해당 기기로 접근할 수 있습니다.

## 저장·호환 범위

녹음은 16kHz mono PCM16 WAV이며 분당 약 1.92MB입니다. 녹음 서비스는 실제 PCM 샘플 수로 시간을 계산하고 WAV 헤더를 주기적으로 저장합니다. 중단 후 남은 PCM으로 길이를 복구합니다.

`files/meetings/<UUID>/`에 `meeting.json`, `recording.wav`, 수정 전 `revisions/`, 가져온 `import-original.json`, 완료된 로컬 전사의 `local-proposal.json`을 보관합니다. 가져오기는 새 UUID를 만들며 외부 파일 경로를 따라가지 않습니다. 휴지통은 논리적 삭제입니다.

Mac용 녹취 JSON과 Android 기록 JSON, Markdown, WAV 내보내기를 지원합니다. Mac의 확정된 `corrected_text`를 가져오며 원본 JSON도 보존합니다. Mac 자료 첨부·음성 프로필·AI 대화·회의록 내부 상태·녹음 경로가 완전히 왕복하는 형식은 아닙니다. Android 회의록과 메모까지 보관하려면 Android 기록 JSON 또는 Markdown을 사용하고 WAV는 별도로 내보내야 합니다. 변경 이력과 미적용 로컬 결과는 내보내기에 포함되지 않습니다.

앱 삭제 시 앱 전용 저장소도 삭제됩니다. OS 클라우드 백업과 기기 이전은 비활성화했으므로 필요한 자료를 먼저 내보내세요. 모델·인증 토큰은 내보내기에 포함하지 않습니다. 예시 회의는 가상 자료임을 명시합니다.

## 빌드와 검증

필요 도구는 JDK 17, Python 3, Android SDK Platform 36, Build Tools 35.0.0입니다. SDK 경로는 `local.properties`의 `sdk.dir` 또는 `ANDROID_HOME`으로 지정합니다.

```bash
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug \
  :fishapp:testDebugUnitTest :fishapp:lintDebug :fishapp:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

Gradle이 `scripts/fetch-sherpa.py`로 고정 버전 AAR을 내려받고 SHA-256을 검증합니다. AAR은 `app/build/dependencies/`에만 보관합니다. APK에는 추론 런타임이 포함되며 모델은 별도 설치합니다.

일반 기기 테스트는 모델이 없으면 실제 추론 테스트를 건너뜁니다. 실제 추론 테스트를 실행하려면 모델 목록의 파일과 공개 `test_wavs/ko.wav`를 앱 전용 저장소의 `ai-models/sensevoice-int8-v1/`, `verification/ko.wav`에 준비해야 합니다. `LocalAiTest.installFromPublicSourcesWhenExplicitlyRequested`는 `downloadModel=true`를 명시해야 실제 모델을 다운로드합니다. 테스트 입력의 출처는 [공개 한국어 샘플](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/blob/2365baeacb507f821a0c8120fcee3d484dba7a07/test_wavs/ko.wav)이며 사용자 녹음을 쓰지 않습니다.

GitHub Actions는 단위 테스트·lint·APK 빌드와 artifact 생성을 수행합니다. [검증 기록](VERIFICATION.md)에 에뮬레이터 확인과 실기기 미검증 범위를 구분했습니다. TB376FC의 2시간 녹음, 장시간 전사·발열·배터리·절전 정책과 실제 한국어 회의 정확도는 실기기에서 확인해야 합니다.

배포 빌드에는 로컬에서만 관리하는 키 저장소와 비밀번호를 환경 변수 `TABLELOG_SIGNING_STORE`, `TABLELOG_SIGNING_PASSWORD`로 주입합니다. alias는 `tablelog`입니다. 키를 소스·APK·릴리스에 넣지 마세요. 변수 없이 release를 빌드하면 서명하지 않은 APK가 생성됩니다.

```sh
./gradlew :app:assembleRelease :fishapp:assembleRelease
```

현재 배포 키는 이 맥의 `~/Library/Application Support/TableLogAndroidSigning/`에서 관리합니다. 이 키를 잃으면 기존 설치본에 업데이트할 수 없으므로 별도 안전한 백업이 필요합니다.
