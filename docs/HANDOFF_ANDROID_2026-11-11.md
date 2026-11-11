# TableLog Android·Mac 서버 인계 자료

확인 기준: **2026-11-11 16:00 KST 전후**. 저장소·GitHub PR/릴리스/CI·로컬 배포 파일·서버 상태 응답을 직접 확인했다. 10월의 기능 테스트와 11월 11일의 상태 확인을 구분한다. 이 문서는 당시 상태를 보존하는 인계 기록이며 이후 변경은 각 브랜치와 최신 운영 문서에서 확인한다.

## 1. 무엇을 만들었는가

기존 Mac TableLog에 **안드로이드 태블릿용 회의 기록 앱**을 추가했다. 대상은 **레노버 샤오신패드 프로 13, TB376FC, RAM 8GB**다. 회의를 녹음하고 글로 옮기는 전사는 태블릿 자체 또는 Mac 서버에서 실행하도록 선택한다. 요약·질문·교정·회의록 생성은 서버 AI를 사용한다.

| 영역 | 현재 구현 |
| --- | --- |
| TableLog Android 0.4.0 | 녹음·일시정지·재개·복구, 녹음 중 자동 전사와 저장, 종료 후 마지막 구간 처리 |
| 태블릿 로컬 전사 | SenseVoice Small 및 Whisper Tiny/Base/Small/Medium INT8, 총 5종 선택·설치·삭제. 한국어·영어·자동 언어 |
| 회의 편집 | 발언 편집·분리·삭제·되돌리기, 화자 이름 일괄 변경, 메모·시각별 재생·검색, 휴지통 복원 |
| 회의 AI | 요약·질문·검토 후 교정·회의록. 선택하면 약 2분마다 요약하고 종료 후 회의록 생성 |
| 자료·파일 | TXT/Markdown 참고자료, M4A/AAC·MP3·WAV 가져오기, JSON·Markdown·WAV·M4A 내보내기 |
| Mac 서버 0.4.0 | Whisper large-v3-turbo 음성 전사, Qwen3.5 4B 4bit 회의 AI, 일회용 코드와 기기별 인증 |
| 별도 Fish Audio 0.1.0 | 기존 Fish Audio 웹을 여는 Android 앱. 음성 합성 모델은 서버에서 실행 |

**오프라인으로 가능한 범위는 녹음과 로컬 음성 전사다.** 회의 AI를 켜면 전사 방식이 로컬이어도 녹취·메모·선택한 자료가 설정한 서버로 전송된다. 자동 회의 AI는 기본값이 꺼짐이다. 전사 오류가 나도 다른 방식으로 자동 전환하지 않는다.

## 2. 이어서 작업할 위치와 GitHub 상태

| 용도 | 위치 |
| --- | --- |
| 실제 Android 작업 체크아웃 | `/Users/yunju/orca/workspaces/tablelog-android` |
| GitHub 저장소 | [yunju-baek/TableLog](https://github.com/yunju-baek/TableLog) |
| Android 최신 기능 브랜치 | [`feat/local-models-live-transcription`](https://github.com/yunju-baek/TableLog/tree/feat/local-models-live-transcription), 커밋 `02256c2fcc702ebb6dfb8b0da4ab0625225a1eb1` |
| Android 공개 설치본 | [android-v0.4.0 사전 릴리스](https://github.com/yunju-baek/TableLog/releases/tag/android-v0.4.0) |
| 이 인계 문서 브랜치 | [`docs/tablelog-handoff-2026-11-11`](https://github.com/yunju-baek/TableLog/tree/docs/tablelog-handoff-2026-11-11), 위 기능 브랜치에서 분기 |
| 원격 `main` | 확인 당시 `a204515de615438928bb7d76e7aa494a055687fe`, **Mac 2.9.0** |

**`main`만 내려받으면 이번 Android 작업을 이어갈 수 없다.** Android 변경은 아래 3개 PR에 누적되어 있고 모두 미병합이다. GitHub에 APK가 공개된 것과 `main` 병합 여부는 별개다.

| PR | 작업 브랜치 → 대상 브랜치 | 확인 당시 상태 |
| --- | --- | --- |
| [#1: Android 0.2.0](https://github.com/yunju-baek/TableLog/pull/1) | `feat/android-app` → `main` | Draft, 미병합, GitHub `mergeable=false` |
| [#2: Mac 서버 연결·Fish Audio](https://github.com/yunju-baek/TableLog/pull/2) | `feat/mac-studio-connection` → `feat/android-app` | Draft, 미병합 |
| [#3: Android 0.4.0](https://github.com/yunju-baek/TableLog/pull/3) | `feat/local-models-live-transcription` → `feat/mac-studio-connection` | Open, 미병합 |

Android 브랜치의 공통 기반은 `d0bd884`이며 그 안의 Mac 코드는 2.8.0이다. 원격 `main`에는 이후 Mac 2.9.0 변경이 있다. [Mac/Android 비교표](../Android/PARITY.md)는 **Mac 2.8.0 기준**이므로 Mac 최신판과의 완전한 비교표로 사용하지 않는다. 병합 시 Mac 변경을 보존하고 PR 간 의존 관계와 충돌을 검토해야 한다. 이번 인계 작업에서는 병합하거나 앱·서버를 재배포하지 않았다.

## 3. 작업 이력

시간은 KST다. 세부 근거는 각 커밋과 PR에 있다.

| 일시 | 커밋 | 작업 결과 |
| --- | --- | --- |
| 10/28 11:38 | [`baf9ab0`](https://github.com/yunju-baek/TableLog/commit/baf9ab03cb1084efed52c4b98457675697c2bc29) | Kotlin·Compose Android 앱 첫 구현. 회의 녹음·편집·복원·파일 교환·선택적 서버 AI |
| 10/28 11:41 | [`2d21918`](https://github.com/yunju-baek/TableLog/commit/2d21918f8d9410e905bf0199503c8b346c753691) | CI에서 고정 해시로 Android SDK를 준비하도록 수정 |
| 10/28 13:59 | [`b4abc24`](https://github.com/yunju-baek/TableLog/commit/b4abc248b0e0e4151799e45b682a985de5334c1f) | TB376FC 대상과 서버 전사 구조 문서화 |
| 10/28 15:49 | [`b6162d9`](https://github.com/yunju-baek/TableLog/commit/b6162d95b243e8f4bb9386caa48262cf07debc8c) | 0.2.0: 오프라인 한국어 전사, 로컬/서버 선택, 암호화한 수동 토큰 등록, 태블릿 화면 |
| 10/29 13:01 | [`f21ead5`](https://github.com/yunju-baek/TableLog/commit/f21ead5626b5639f8379488c9ba1b89307c5c0f4) | 0.3.0: Mac 서버·일회용 연결 코드·기기별 폐기 구현. Fish Audio 별도 앱과 서명 APK 공개 |
| 10/30 08:51 | [`02256c2`](https://github.com/yunju-baek/TableLog/commit/02256c2fcc702ebb6dfb8b0da4ab0625225a1eb1) | 0.4.0: 녹음 중 자동 전사, 5종 모델, 회의 AI, 편집·자료·M4A 기능 확장 |
| 10/30 08:57 | `android-v0.4.0` | 같은 배포 키로 서명한 0.4.0 APK 사전 릴리스 공개 |
| 11/11 | 이 문서 | 코드·릴리스·해시·CI·서버 상태 재확인, 작업 위치와 후속 과제 정리 |

0.2.0 당시 답변의 “서버 인증은 설계만 있음”, “녹음 종료 후 전사만 가능”은 과거 상태다. 현재는 코드 연결과 녹음 중 자동 전사가 구현되어 있다. 초기의 Tailscale 제안과 달리 **현재 확인한 기본 연결 경로는 `yunju.work`의 공개 HTTPS + 기기 인증**이다. Tailscale 사용을 필수 전제로 삼지 않는다.

## 4. 설치 파일과 로컬 산출물

아래 상대 경로는 모두 실제 체크아웃 `/Users/yunju/orca/workspaces/tablelog-android` 기준이다. `Builds/`와 기기 검증 로그는 Git 추적에서 제외된다. 다른 Mac에서는 GitHub Releases의 APK를 받는다.

| 산출물 | 로컬 상대 경로 | GitHub |
| --- | --- | --- |
| **최신 TableLog 0.4.0** | `Builds/android-v0.4.0/TableLog-0.4.0.apk` | [APK 다운로드](https://github.com/yunju-baek/TableLog/releases/download/android-v0.4.0/TableLog-0.4.0.apk) |
| 0.4.0 해시·릴리스 설명 | `Builds/android-v0.4.0/SHA256SUMS.txt`, `release-notes.md` | [릴리스](https://github.com/yunju-baek/TableLog/releases/tag/android-v0.4.0) |
| 이전 TableLog 0.3.0 | `Builds/Android-0.3.0/TableLog-0.3.0.apk` | [0.3.0 릴리스](https://github.com/yunju-baek/TableLog/releases/tag/android-v0.3.0) |
| Fish Audio 0.1.0 | `Builds/Android-0.3.0/FishAudio-0.1.0.apk` | [APK 다운로드](https://github.com/yunju-baek/TableLog/releases/download/android-v0.3.0/FishAudio-0.1.0.apk) |
| 초기 debug 앱·소스 ZIP·로그 | `Builds/Android-0.1.0/`, `Builds/Android-0.2.0/` | 현재 설치본은 위 0.4.0 사용 |
| 0.4.0 기기 검증 원본 | `Android/verification-local/0.4.0/` | 요약은 [검증 기록](../Android/VERIFICATION.md) |
| 태블릿 화면 캡처 | `Android/screenshots/` | 0.2.0 당시 화면이며 0.4.0 전체 화면을 대표하지 않음 |

0.4.0 APK는 **79,770,111 bytes**이며 다음 SHA-256이 로컬 파일과 GitHub asset digest에서 일치했다.

```text
6f449f81f795ec62f2af55c1f20d4294028e010874c010422fff7be00e0f86b0  TableLog-0.4.0.apk
```

Fish Audio APK의 SHA-256:

```text
44ca5156db041f8aa8e9b884dad92f8ef48495921b6d9b6b4116d690c48f6052  FishAudio-0.1.0.apk
```

**0.3.0은 삭제하지 않고 0.4.0을 덮어 설치한다.** 두 버전은 같은 배포 서명이며 기록·설정·기존 모델 보존을 에뮬레이터에서 검증했다. 초기 0.1/0.2 debug APK는 서명이 달라 직접 업데이트할 수 없으므로 기록과 음성을 먼저 내보내고 이전해야 한다. 앱 삭제 시 앱 전용 기록도 삭제된다. Android 전체 기록 JSON에도 오디오는 포함되지 않아 별도로 내보내야 한다.

## 5. 코드와 문서 지도

| 위치 | 맡는 역할 |
| --- | --- |
| [`Android/README.md`](../Android/README.md) | 설치·사용·모델·연결·빌드 안내 |
| [`Android/VERIFICATION.md`](../Android/VERIFICATION.md) | 버전별 테스트 결과와 미검증 범위 |
| [`Android/PARITY.md`](../Android/PARITY.md) | Mac 2.8.0과 Android 0.4.0 기능 비교 |
| [`Android/FISH_AUDIO.md`](../Android/FISH_AUDIO.md) | 별도 Fish Audio 앱 사용·보안 범위 |
| `Android/app/src/main/java/work/yunju/tablelog/` | TableLog Android 코드. `ui/` 화면, `audio/` 녹음·변환, `ai/` 추론·서버, `data/` 기록 저장 |
| `Android/app/src/main/assets/local-models.json` | 다운로드 URL·revision·크기·SHA-256 모델 목록 |
| `Android/app/src/main/assets/licenses/` | 음성 엔진·모델 라이선스 고지 |
| `Android/app/src/test/`, `Android/app/src/androidTest/` | JVM 테스트와 Android 기기 테스트 |
| `Android/fishapp/` | 별도 Fish Audio 앱 |
| [`Server/README.md`](../Server/README.md) | 서버 설치·연결 코드·기기 폐기·모델·운영 제한 |
| `Server/server.py` | 인증, 코드 교환, 요청 제한, 음성/텍스트 API |
| `Server/transcribe_worker.py`, `Server/text_worker.py` | 요청별 음성/텍스트 모델 실행 |
| `Server/tablelog-server`, `Server/install_service.py` | 관리 CLI와 Mac 자동 실행 설치 |
| `Server/85-tablelog.caddy` | HTTPS 프록시 설정 예시. 운영 설정 파일 자체는 아님 |
| [`.github/workflows/android.yml`](../.github/workflows/android.yml) | Android/Fish 단위 테스트·lint·debug 빌드와 Python 서버 테스트 |

## 6. 서버·인증 운영 인계

### 연결 구조

```text
태블릿 로컬 전사: 마이크 → 기기 WAV → 설치한 음성 모델 → 기기 녹취
태블릿 서버 전사: 마이크 → 기기 WAV → HTTPS + 기기 토큰 → Mac Whisper → 기기 녹취
회의 AI:         기기 녹취·메모·자료 → HTTPS + 기기 토큰 → Mac Qwen → 검토/저장
```

- 기본 API 주소: `https://yunju.work/tablelog-api/v1`
- 외부 상태 조회: `https://yunju.work/tablelog-api/health`
- Mac API 수신: `127.0.0.1:7870`만 사용. HTTPS 프록시가 `/tablelog-api/` 경로를 전달한다.
- 일회용 코드는 **10분·1회** 유효하며 Mac에서 발급한다. 태블릿에서 교환하면 **기기별 30일 토큰**을 받는다. 자동 갱신·별도 웹 승인 화면은 없다. 만료 후 새 코드로 연결한다.
- 서버는 코드·토큰의 해시를 저장하고, Android는 토큰을 Keystore AES-GCM으로 암호화하여 서버 주소에 묶는다. 주소 변경 시 기존 토큰을 재사용하지 않는다.
- 앱의 “연결 지우기”는 로컬 설정 삭제다. 분실 기기를 차단하려면 서버에서 해당 기기를 폐기한다.
- 음성/텍스트 모델은 각각 요청별 프로세스로 실행하고 종료한다. 서버는 업로드·결과를 임시 처리하며 회의 기록의 주 저장소는 태블릿이다.
- 로컬 전사 선택과 회의 AI 선택은 독립적이다. 완전 오프라인 사용 시 서버 회의 AI·자동 요약을 켜지 않는다.

### 운영 파일 위치

`~`는 현재 운영 계정의 `/Users/yunju`다. 아래 파일의 **위치만** 기록하며 DB·키·암호·토큰·운영 로그 내용은 GitHub에 올리지 않는다.

| 용도 | 경로 |
| --- | --- |
| 실제 배포된 서버 코드 | `~/Library/Application Support/TableLogServer/app/` |
| 기기 등록 DB | `~/Library/Application Support/TableLogServer/devices.sqlite3` |
| 텍스트 모델 | `~/Library/Application Support/TableLogServer/models/qwen3.5-4b-4bit/` |
| 서버 로그·백업 | `~/Library/Application Support/TableLogServer/server.log`, `backups/` |
| 자동 실행 설정 | `~/Library/LaunchAgents/com.yunju.tablelog-server.plist` |
| API·음성 Python 환경 | `~/Library/Application Support/CoworkPython/envs/fish-audio-s2/` |
| 텍스트 Python 환경 | `~/Library/Application Support/CoworkPython/envs/tablelog-text/` |
| APK 배포 키 | `~/Library/Application Support/TableLogAndroidSigning/release.jks` |
| 배포 키 자격 정보 | `~/Library/Application Support/TableLogAndroidSigning/credentials.json` |

11월 11일 배포된 `server.py`·음성 워커·텍스트 워커는 기능 커밋 `02256c2`의 작업 파일과 바이트가 일치했다. 키와 자격 정보는 파일명·존재만 확인했고 내용을 열지 않았다. 배포 키를 바꾸면 기존 설치본에 덮어 설치할 수 없으므로 유지해야 한다.

### 담당자가 사용할 명령

저장소 루트에서 실행한다. 아래 발급·폐기·설치 명령은 운영 상태를 바꾸므로 필요할 때만 실행한다. 이번 문서 작성에서는 실행하지 않았다.

```sh
# Mac에서 연결 코드 발급 → 태블릿 설정의 “맥스튜디오 선택”에 입력
Server/tablelog-server issue-code --name '내 태블릿'

# 등록 기기 조회 / 특정 기기 토큰 폐기
Server/tablelog-server devices
Server/tablelog-server revoke 기기ID

# 서버 소스 변경 후 배포: 처리 중인 작업이 있으면 설치기가 중단함
"$HOME/Library/Application Support/CoworkPython/envs/fish-audio-s2/bin/python" Server/install_service.py
```

API·음성 환경은 기존 Fish Audio 환경을 사용하므로 패키지를 임의로 갱신하지 않는다. 텍스트 환경은 별도다. **Fish Audio 공개 웹은 TableLog 기기 인증으로 보호되지 않는다.** 기존 운영 범위이며, 인계 중 변경하지 않았다.

## 7. 검증 결과와 현재 관찰을 구분할 것

### 과거 기능 검증: 2026-10-30, 0.4.0

- JVM 18개, Python 서버 6개, API 36 arm64 태블릿 에뮬레이터 통합 검사 11개 통과. 선택적 전체 재다운로드 검사 1개는 건너뛰었으며 성공 개수에 넣지 않았다.
- 5개 실제 음성 모델의 공개 한국어·영어 샘플 추론, 녹음 도중 결과 반영·종료 후 마지막 구간·기존 편집 보존 확인.
- 실제 Mac HTTPS 음성 전사·회의 AI, M4A 왕복, 0.3.0 → 0.4.0 업데이트 보존 확인. 마지막 녹음 마무리 변경 후 서비스 검사 3개 재통과.
- debug/test/release 빌드, lint 오류 0, 서명·ZIP/native ELF 16KB 정렬 확인. 실제 16KB 페이지 기기 실행 검증은 아님.
- [GitHub Android·서버 CI #7](https://github.com/yunju-baek/TableLog/actions/runs/40975964741)는 기능 커밋 `02256c2`에서 성공했다. 11월 11일에도 해당 run의 완료·성공 상태를 조회했다.

상세 근거와 제약은 [VERIFICATION.md의 0.4.0 항목](../Android/VERIFICATION.md#040--2026-10-30)에 있다. 하단의 0.2.0 “서버 미구현” 등은 해당 버전의 과거 기록이다.

### 이번 인계 시 재확인: 2026-11-11

| 관찰 | 결과 | 의미와 한계 |
| --- | --- | --- |
| GitHub 브랜치·PR | Android 3개 PR 미병합, `main`은 별도 Mac 2.9.0 | 최종 통합 전 확인 필요 |
| 공개 릴리스 | 0.4.0·0.3.0 사전 릴리스와 APK asset 존재 | Play Store 출시를 의미하지 않음 |
| APK 해시 | 로컬 0.4.0·0.3.0·Fish APK가 GitHub digest와 일치 | 이번에 재빌드한 결과는 아님 |
| 로컬 `/health` | HTTP 200, version 0.4.0, `text_available=true` | 상태와 모델 준비 표시 확인, 실제 AI 생성은 재실행하지 않음 |
| 외부 `/health` (`curl`) | HTTP 200, version 0.4.0 | HTTPS 상태 조회 가능 |
| 외부 `/v1/models` 무인증 (`curl`) | HTTP 401, 기기 연결 필요 | 무인증 조회 차단 확인. 새 토큰 발급·인증 전사는 재검사하지 않음 |
| Python 기본 HTTP 클라이언트 | 외부 두 경로에서 HTTP 403 / `error code: 1010` | 클라이언트에 따라 응답이 달랐음. 원인은 확정하지 않음 |
| 배포 코드 | 서버 3개 파일과 기능 브랜치 소스 일치 | 배포 코드와 기록의 연결 확인 |

`/health`의 준비 상태만으로 모델 품질·처리 속도·태블릿 연결 성공을 주장하지 않는다. 외부 접속 문제가 생기면 위 클라이언트별 차이도 조사한다.

## 8. 개발 재개와 빌드

새 체크아웃은 Android 기능 브랜치에서 시작한다. 기존 폴더에서는 먼저 미커밋 변경과 현재 브랜치를 확인한다. 이번 인계 문서는 별도 문서 브랜치에 있다.

```sh
git clone --branch feat/local-models-live-transcription https://github.com/yunju-baek/TableLog.git
cd TableLog/Android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleDebugAndroidTest
```

- JDK 17, Python 3, Android SDK Platform 36, Build Tools 35.0.0 사용. SDK 경로는 `Android/local.properties` 또는 `ANDROID_HOME`으로 지정한다.
- 현재 Mac의 JDK: `~/.cache/tablelog-android-tools/jdk17/Contents/Home`
- 현재 Mac의 SDK: `~/Library/Android/sdk`
- 로컬 모델·도구 캐시: `~/.cache/tablelog-android-tools/`의 `local-models/`, `model-catalog/`, `sherpa-2.0.1/` 등.
- sherpa-onnx 2.0.1 AAR은 `Android/scripts/fetch-sherpa.py`가 고정 해시로 준비한다. 모델과 런타임의 라이선스는 별도이며 모델을 코드와 같은 라이선스로 단정하지 않는다.
- release 빌드는 기존 키를 `TABLELOG_SIGNING_STORE`, `TABLELOG_SIGNING_PASSWORD` 환경 변수로 주입하고 `./gradlew :app:assembleRelease`를 실행한다. 키 alias는 `tablelog`다. 변수 미설정 결과는 서명되지 않는다. 비밀값을 명령 기록·문서·Git에 남기지 않는다.
- `connectedDebugAndroidTest`는 시험 앱을 재설치·제거할 수 있다. 모델·시험 자료를 유지해야 하면 [기기 테스트 안내](../Android/README.md#빌드와-검증)에 따라 APK 설치 후 instrumentation을 실행한다. 실사용 기록이 있는 태블릿에 시험 설치를 바로 실행하지 않는다.
- 이 인계 변경은 문서뿐이므로 앱 빌드·AI 추론을 반복하지 않았다. 문서 링크·파일 위치·원격 상태·해시를 확인했다.

## 9. 다음 담당자가 할 일

1. **TB376FC 8GB 실기기에서 0.4.0 사용 검증.** 기존 설치 버전·서명을 확인하고 기록을 보존해 설치한다. 로컬 모델을 설치한 뒤 녹음 중 전사, 종료 후 마무리, 화면 꺼짐·일시정지·재개를 확인한다. 짧은 시험 후 30분·2시간 회의로 늘려 지연·발열·배터리·음성 누락을 기록한다.
2. **실제 태블릿의 서버 연결 검증.** Mac에서 코드를 발급해 연결하고 짧은 공개/시험 음성 전사와 회의 AI를 확인한다. 이번 상태 조회로 기기 연결까지 확인된 것은 아니다.
3. **GitHub 통합 정리.** `main`의 Mac 2.9.0 변경과 Android PR #1 → #2 → #3을 비교해 병합 순서와 충돌을 정리한다. 현재 PR #1은 바로 병합할 수 없는 상태다. 사용자의 “항상 GitHub에 올려줘”는 코드·검증 후 브랜치/PR 게시 기준으로 이어간다. 이번 인계에서 자동 병합은 하지 않았다.
4. **품질과 기능의 남은 범위 결정.** 자동 화자 구분·목소리 등록/학습, 실시간 AI 문맥 교정, 태블릿 단독 요약 LLM, PDF/OCR·URL·폴더 동기화는 미구현이다. Mac과 완전 동등한 앱으로 설명하지 않는다.

현재 가장 필요한 증거는 **대상 실기기의 실제 회의 녹음 결과**다. 에뮬레이터·짧은 공개 샘플 테스트만으로 TB376FC의 실시간 속도나 한국어 장시간 회의 정확도를 보장할 수 없다.

## 10. 다음 작업자에게 전달할 짧은 문장

> TableLog Android 0.4.0과 Mac 서버 0.4.0을 이어서 작업한다. 저장소는 yunju-baek/TableLog, 로컬 체크아웃은 /Users/yunju/orca/workspaces/tablelog-android, 기능 브랜치는 feat/local-models-live-transcription, 기능 커밋은 02256c2다. main은 Mac 2.9.0이며 Android PR #1~#3은 미병합이다. docs/HANDOFF_ANDROID_2026-11-11.md와 Android/README.md·VERIFICATION.md, Server/README.md를 먼저 읽고 현 상태를 재확인한다. 목표 기기는 TB376FC 8GB다. 로컬/서버 전사는 선택 가능하고 회의 AI는 서버에서 실행한다. 기존 회의·모델·배포 키·기기 DB를 보존하고, 검증한 변경은 GitHub 브랜치와 PR에 올린다. 다음 우선 과제는 대상 태블릿의 실제 사용 검증이다.
