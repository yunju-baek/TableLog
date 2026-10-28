# 테이블로그 Android 0.2.0

회의를 녹음하고 발언·회의록·메모를 기기에 보관하는 Kotlin·Jetpack Compose 앱입니다. 주 대상은 **레노버 샤오신패드 프로 13(TB376FC), RAM 8GB**입니다. 전사 방식은 **태블릿 로컬 / 서버** 중 직접 선택하며, 오류가 나도 다른 방식으로 자동 전환하지 않습니다.

## 설치와 첫 사용

현재 APK는 테스트용 debug 빌드이며 Android 8.0(API 26) 이상의 arm64·x86_64 기기를 지원합니다. Play Store 출시는 별도 작업입니다.

1. `app/build/outputs/apk/debug/app-debug.apk`를 태블릿에 설치합니다. USB 연결 시 `adb install -r app/build/outputs/apk/debug/app-debug.apk`를 사용할 수 있습니다.
2. 설정에서 **한국어 모델 설치**를 누릅니다. Hugging Face와 GitHub에서 약 230MiB를 한 번 다운로드합니다. 설치에는 녹음을 전송하지 않습니다. 중단 후 다시 누르면 이어받고, 파일 크기와 SHA-256을 확인한 뒤 설치를 완료합니다.
3. **새 회의 녹음**을 누르고 마이크 권한을 허용합니다. 알림 권한도 허용하면 앱 밖에서 녹음과 로컬 작업을 제어할 수 있습니다.
4. 녹음을 **저장**한 뒤 **태블릿 로컬 → 로컬 전사**를 누릅니다. 설치가 끝난 모델은 인터넷 없이 실행합니다. 결과를 검토하고 적용해야 기존 녹취가 바뀝니다.
5. 서버를 사용할 때는 **서버**를 선택하고 HTTPS 주소·기기 토큰·모델 이름을 등록합니다. 실행 전 실제 전송 대상과 보낼 자료를 확인합니다.

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

0.2.0은 HTTPS 서버 주소(예: `https://서버주소/v1`)와 **Bearer 기기 토큰**을 수동 등록합니다. 앱은 토큰을 발급하지 않습니다. 인증 없는 서버는 지원하지 않으며, 서버 주소가 바뀌면 새 토큰을 등록해야 합니다.

| 경로 | 요청 | 응답 |
| --- | --- | --- |
| `GET /models` | `Authorization: Bearer <기기 토큰>`만 전송 | `data` 배열. 연결 확인용이며 녹음·녹취를 보내지 않음 |
| `POST /audio/transcriptions` | multipart: `file` WAV, `model`, `language=ko`, `response_format=verbose_json` | `segments: [{start, end, text}]` 또는 `text` |
| `POST /chat/completions` | JSON: `model`, `messages`, `stream=false` | `choices[0].message.content` |

세 경로 모두 설정한 기본 주소 아래에 붙습니다. 서버 전사는 현재 최대 5분 WAV를 순서대로 보내고 응답 시각을 전체 회의의 초 단위로 변환합니다. 단어 `words[]`만 반환하는 NeMo 서버는 API 계층에서 문장 `segments[]`로 변환해야 시각을 활용할 수 있습니다. CLOVA의 밀리초 시각도 변환해야 합니다. 현재 앱은 서버 응답의 화자 필드를 사용하지 않습니다. `text`만 있으면 해당 5분 전체를 한 발언으로 보관합니다. 구간 경계 문맥 연결·업로드 재개·서버 작업 큐는 아직 없습니다.

회의록 요청은 제목·일시·녹취·메모를 보냅니다. 녹취와 메모가 합계 10만 자를 넘으면 중단하고, 임의로 잘라 보내지 않습니다. 일부 구간만 성공한 전사는 적용하지 않습니다. 요청 취소 시 네트워크 호출을 취소하고, 전송 확인 시점의 서버 설정을 해당 요청에 고정합니다.

서버 주소·토큰·모델은 기본 제공하지 않습니다. 실제 운영 서버를 배포하지 않았으며 Mac의 Codex·Claude Code·Gemini CLI 로그인이나 구독이 자동 연결되는 구조가 아닙니다.

## 서버 인증과 등록 방식

### 현재 앱에 구현한 범위

- 토큰을 Android Keystore의 AES-GCM 키로 암호화하고, 정규화한 서버 기본 주소를 인증 데이터(AAD)로 사용합니다. 다른 주소로 암호문을 옮겨 재사용할 수 없습니다. 이는 기기 내 보관 보호이며 서버가 기기 신원을 검증했다는 뜻은 아닙니다.
- 토큰은 요청의 Authorization 헤더로만 보내며 URL·로그·내보내기·화면 복원 상태에 넣지 않습니다. 서버 주소를 편집하면 입력 중인 기존 토큰을 지웁니다.
- 일반 TLS 인증서 검증을 유지합니다. HTTP, URL 내 아이디·비밀번호·쿼리 키, 요청 리디렉션은 거부합니다. 인증서 검증을 끄거나 자체 서명 인증서를 무조건 신뢰하는 우회는 제공하지 않습니다.
- HTTP 401은 인증 만료/오류, 403은 권한 부족으로 구분해 안내합니다. 자동 재로그인·토큰 갱신은 아직 없습니다.
- **연결 지우기**는 이 기기에 저장된 서버 설정만 삭제합니다. 서버의 토큰 폐기는 서버 기기 관리에서 해야 합니다. 모델·회의 기록·전사 방식은 그대로 유지합니다.

### 권장 서버 구성과 수동 토큰 발급

개인용 첫 서버는 Mac의 API 계층을 loopback에 바인딩하고, Tailscale Serve의 HTTPS 주소로 연결하는 구성을 권장합니다. Tailscale 접근 제어와 앱 토큰 검증을 함께 적용합니다. 여러 사람에게 공개할 때는 정상 인증서가 있는 HTTPS 도메인과 계정 로그인을 갖춘 API 서버로 확장합니다. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve).

서버는 사용자·기기별로 서로 다른 256비트 이상 난수 토큰을 발급하고, 토큰 자체 대신 해시와 기기 ID·소유자·만료일·권한·폐기 상태를 보관하도록 설계합니다. `/models`, 전사, 회의록 권한을 구분하고, 모든 작업·결과 조회에서 소유자를 검증합니다. 유출·분실 시 해당 기기의 토큰만 폐기할 수 있어야 합니다. 외부 AI 서비스의 장기 API 키는 서버에 보관합니다. 앱에 등록한 Bearer 토큰은 소지자가 사용할 수 있으므로 기기 고유 하드웨어 인증과 동일하게 취급하지 않습니다.

이 발급·권한·폐기 기능은 **서버 구현 요구사항**입니다. 현재 앱에 토큰을 입력한다고 서버에 자동으로 기기가 등록되거나 폐기 목록이 생기지는 않습니다. NeMo 내장 서버의 단일 API 키만 사용하면 여러 기기를 개별 폐기할 수 없으므로 기기별 인증 계층이 필요합니다.

### 후속 등록 절차: 짧은 코드로 승인

수동 토큰 전달을 줄이기 위한 제안이며 아직 앱·서버에 구현하지 않았습니다. [OAuth Device Authorization Grant(RFC 8628)](https://www.rfc-editor.org/rfc/rfc8628)을 기준으로 다음 절차를 권장합니다.

1. 태블릿에서 서버 주소를 입력하거나 서버 주소 QR을 읽고 표시된 도메인을 확인합니다. QR에는 장기 토큰을 넣지 않습니다.
2. 태블릿이 등록 요청을 보내면 서버가 10분 이내 만료되는 `device_code`, 짧은 `user_code`, 승인 URL과 폴링 간격을 반환합니다. 이 수치는 초기 운영 정책 제안입니다.
3. 사용자가 Mac의 서버 관리 화면에 로그인해 태블릿에 표시된 코드와 기기 이름을 확인하고 승인합니다. 코드만 아는 사람이 승인할 수 없도록 관리자 인증·시도 제한·일회 사용을 적용합니다.
4. 앱은 지정 간격을 지키며 토큰을 요청하고 `authorization_pending`, `slow_down`, 거부·만료를 처리합니다. 서버는 승인된 요청에만 짧은 access token과 기기별 refresh token을 반환합니다. 앱에 공용 client secret을 넣지 않습니다.
5. access token 15분·refresh token 30일을 초기 정책으로 검토합니다. refresh token은 사용 시 교체하고 재사용을 탐지해 폐기합니다. 토큰은 서버 주소에 묶어 Keystore로 보호합니다.
6. 서버의 **기기 연결 해제**는 해당 기기의 세션·토큰을 폐기합니다. 앱의 로그아웃은 서버 폐기를 요청한 뒤 로컬 토큰을 삭제하고, 오프라인이면 서버 폐기를 완료하지 못했음을 알려야 합니다.

등록용 경로 예시는 `POST /oauth/device_authorization`, `POST /oauth/token`, `POST /oauth/revoke`입니다. 현재 앱의 서버 연결 확인은 `/v1/models` 계약만 사용하며 이 등록 API를 호출하지 않습니다. [Android Keystore](https://developer.android.com/privacy-and-security/keystore).

## 저장·호환 범위

녹음은 16kHz mono PCM16 WAV이며 분당 약 1.92MB입니다. 녹음 서비스는 실제 PCM 샘플 수로 시간을 계산하고 WAV 헤더를 주기적으로 저장합니다. 중단 후 남은 PCM으로 길이를 복구합니다.

`files/meetings/<UUID>/`에 `meeting.json`, `recording.wav`, 수정 전 `revisions/`, 가져온 `import-original.json`, 완료된 로컬 전사의 `local-proposal.json`을 보관합니다. 가져오기는 새 UUID를 만들며 외부 파일 경로를 따라가지 않습니다. 휴지통은 논리적 삭제입니다.

Mac용 녹취 JSON과 Android 기록 JSON, Markdown, WAV 내보내기를 지원합니다. Mac의 확정된 `corrected_text`를 가져오며 원본 JSON도 보존합니다. Mac 자료 첨부·음성 프로필·AI 대화·회의록 내부 상태·녹음 경로가 완전히 왕복하는 형식은 아닙니다. Android 회의록과 메모까지 보관하려면 Android 기록 JSON 또는 Markdown을 사용하고 WAV는 별도로 내보내야 합니다. 변경 이력과 미적용 로컬 결과는 내보내기에 포함되지 않습니다.

앱 삭제 시 앱 전용 저장소도 삭제됩니다. OS 클라우드 백업과 기기 이전은 비활성화했으므로 필요한 자료를 먼저 내보내세요. 모델·인증 토큰은 내보내기에 포함하지 않습니다. 예시 회의는 가상 자료임을 명시합니다.

## 빌드와 검증

필요 도구는 JDK 17, Python 3, Android SDK Platform 36, Build Tools 35.0.0입니다. SDK 경로는 `local.properties`의 `sdk.dir` 또는 `ANDROID_HOME`으로 지정합니다.

```bash
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

Gradle이 `scripts/fetch-sherpa.py`로 고정 버전 AAR을 내려받고 SHA-256을 검증합니다. AAR은 `app/build/dependencies/`에만 보관합니다. APK에는 추론 런타임이 포함되며 모델은 별도 설치합니다.

일반 기기 테스트는 모델이 없으면 실제 추론 테스트를 건너뜁니다. 실제 추론 테스트를 실행하려면 모델 목록의 파일과 공개 `test_wavs/ko.wav`를 앱 전용 저장소의 `ai-models/sensevoice-int8-v1/`, `verification/ko.wav`에 준비해야 합니다. `LocalAiTest.installFromPublicSourcesWhenExplicitlyRequested`는 `downloadModel=true`를 명시해야 실제 모델을 다운로드합니다. 테스트 입력의 출처는 [공개 한국어 샘플](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/blob/2365baeacb507f821a0c8120fcee3d484dba7a07/test_wavs/ko.wav)이며 사용자 녹음을 쓰지 않습니다.

GitHub Actions는 단위 테스트·lint·APK 빌드와 artifact 생성을 수행합니다. [검증 기록](VERIFICATION.md)에 에뮬레이터 확인과 실기기 미검증 범위를 구분했습니다. TB376FC의 2시간 녹음, 장시간 전사·발열·배터리·절전 정책과 실제 한국어 회의 정확도는 실기기에서 확인해야 합니다.
