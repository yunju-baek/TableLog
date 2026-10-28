# 테이블로그 Android 0.1.0

회의를 녹음하고 발언·회의록·메모를 기기에 보관하는 네이티브 Android 앱입니다. macOS TableLog와 같은 저장소에서 개발하며, 화면과 녹음 처리는 Kotlin·Jetpack Compose로 구현했습니다.

## 목표 기기와 태블릿 화면

주 개발 대상은 **레노버 샤오신패드 프로 13, TB376FC**입니다. Lenovo 공식 사양은 Snapdragon 8s Gen 4, 13인치 3504×2190 화면이며 8 GB와 12 GB RAM 구성이 있습니다. 사용자가 보유한 기기의 RAM·설치된 OS 버전은 아직 확인하지 않았습니다. [8 GB 모델 사양](https://item.lenovovip.com.cn/pd/1053160.html), [12 GB 모델 사양](https://item.lenovo.com.cn/product/1053089.html).

태블릿 화면은 다음과 같이 개편할 계획입니다. **현재 0.1.0은 단일 열 화면이며 아래 배치는 아직 구현하지 않았습니다.**

- 넓은 가로 창: 왼쪽 회의 목록, 가운데 녹취·화자, 오른쪽 회의록·메모를 함께 표시하고 녹음 제어를 계속 노출합니다.
- 세로·분할 창: 사용 가능한 창 너비에 따라 2개 또는 1개 영역으로 줄입니다. 3504픽셀에 고정하거나 가로 방향을 강제하지 않습니다.
- 키보드가 열리거나 창 크기가 바뀌어도 선택한 회의·편집 초안·녹음 상태를 유지합니다.

구현 기준은 Android의 [적응형 목록·상세 레이아웃](https://developer.android.com/develop/ui/compose/layouts/adaptive/list-detail)입니다. 기존 Pixel 7 에뮬레이터 검증은 TB376FC 화면·마이크·절전 동작을 검증한 결과가 아닙니다.

## 설치와 사용

Android 8.0(API 26) 이상을 대상으로 합니다. 현재 제공하는 APK는 테스트용 debug 빌드입니다. Play Store 배포용 서명·출시는 별도 작업입니다.

1. `app/build/outputs/apk/debug/app-debug.apk`를 태블릿으로 옮겨 설치합니다. 또는 USB 디버깅 연결 후 `adb install -r app/build/outputs/apk/debug/app-debug.apk`를 실행합니다.
2. **새 회의 녹음**을 누르고 이름을 정합니다. 마이크 권한을 허용합니다. 알림 권한도 허용하면 앱 밖에서 일시정지·재개·저장을 조작할 수 있습니다.
3. **저장**을 누르면 녹음을 마무리합니다. 녹음은 16 kHz, mono, 16-bit PCM WAV이며 분당 약 1.92 MB입니다. 휴식 시간은 녹음 길이에서 제외됩니다.
4. **발언 추가**에서 시각·이름·내용을 입력합니다. 녹음 후 AI 전사를 선택할 수도 있습니다. 발언 시각을 누르면 해당 위치로 재생 지점을 옮깁니다.
5. **회의록**에서 양식을 열거나 직접 작성하고, **메모**에 안건과 참고할 내용을 적습니다. AI가 생성한 내용은 검토 후 적용합니다.
6. 오른쪽 위 내보내기로 Markdown, Mac용 녹취 JSON, Android 기록 JSON, 녹음 WAV를 저장하거나 공유합니다.

**예시 회의 둘러보기**는 가상 발언을 명시적으로 추가합니다. 사용자의 실제 회의처럼 자동으로 채워 넣지 않습니다.

## 포함된 기능

- 화면을 벗어나거나 화면을 꺼도 이어지는 마이크 foreground service, 알림 제어, 일시정지·재개
- 실제 기록한 PCM 샘플 기준 녹음 시간, 녹음 레벨 표시, 재생·구간 이동
- 앱 전용 저장소와 원자적 JSON 저장, 중단된 WAV 헤더 복구
- 회의·발언 검색, 발언과 화자 이름 편집, 회의록 양식과 자유 편집, 메모
- 휴지통 이동·복원, 변경 전 JSON 이력 보존
- Mac `segments`·`speakers` JSON 가져오기, 확정된 `corrected_text` 적용, 가져온 원본 JSON 보존
- 선택적으로 연결하는 HTTPS AI 서버, API 키의 Android Keystore 암호화, 전송 전 확인, 결과 검토·적용

## 현재 0.1.0의 AI 서버 연결

설정에서 HTTPS 기본 주소(예: `https://서버주소/v1`), 음성 모델 이름, 회의록 모델 이름, 필요한 경우 API 키를 입력합니다. 서버는 다음 계약을 지원해야 합니다.

| 경로 | 요청 | 응답 |
| --- | --- | --- |
| `POST /audio/transcriptions` | multipart: `file` WAV, `model`, `language=ko`, `response_format=verbose_json` | `segments: [{start, end, text}]` 또는 `text` |
| `POST /chat/completions` | JSON: `model`, `messages`, `stream=false` | `choices[0].message.content` |

음성은 최대 5분씩 나눠 순차 전송하고, 구간 시각을 전체 녹음의 시각으로 변환합니다. 서버가 문장별 시각을 반환하지 않으면 각 5분 구간 전체를 한 발언으로 보관합니다. 구간 경계 문맥 연결과 자동 화자 식별은 제공하지 않습니다. 전사 결과의 화자는 **화자 미지정**으로 표시합니다.

회의록 요청은 제목·일시·녹취·메모를 보냅니다. 녹취와 메모 합계 10만 자를 넘으면 명시적으로 중단하며 조용히 잘라 보내지 않습니다. 요청 취소 시 네트워크 호출도 취소합니다. 일부 구간만 성공한 전사 결과는 적용하지 않습니다. 적용 전 회의가 수정되면 오래된 결과의 적용을 거부합니다.

서버 주소·모델·키는 기본으로 제공하지 않습니다. 연결 테스트는 합성 입력을 사용하는 로컬 HTTPS 모의 서버에서 수행했습니다. 실제 운영 서버의 모델 지원·음성 품질·요금은 검증하지 않았습니다. Mac의 Codex·Claude Code·Gemini CLI 로그인이나 구독은 자동으로 연결되지 않습니다.

## 제안하는 서버·전사 구조

2026-10-28 기준 설계안입니다. 서버 배포, 업로드 재개, 작업 큐, 실시간 전사, 기기 내 모델 실행은 아직 구현하지 않았습니다. 상시 켜둘 Mac 또는 GPU 서버의 사용 가능 여부도 확인 전입니다.

권장 기본 경로는 **태블릿 원본 녹음 → 개인 서버 전사·화자 분리 → 검토한 녹취로 회의록 생성**입니다. 네트워크가 끊기거나 서버가 꺼져도 녹음을 보존하고 전송 대기 상태를 표시합니다. 서버가 다시 연결되면 이미 받은 구간 다음부터 전송합니다. 녹취·회의록 결과를 받았다는 이유로 태블릿의 원본 WAV를 자동 삭제하지 않습니다.

### 연결과 실행 환경

- 개인용 첫 서버는 기존 TableLog의 음성 엔진을 실행할 수 있는 Mac으로 구성합니다. 태블릿과 Mac을 Tailscale에 연결하고, **Tailscale Serve의 HTTPS 주소**로 접근합니다. Serve는 같은 tailnet 안에서 서비스를 공유합니다. 서버 프로세스는 loopback에 바인딩하고 접근 가능한 기기를 제한합니다. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve).
- 앱에서는 서버 주소와 모델 이름을 매번 입력하는 대신 일회용 QR 페어링으로 서버를 등록하고, 이후 연결·처리 상태를 보여주는 구성을 목표로 합니다. 기기별 취소 가능한 인증 토큰은 Keystore로 보호합니다. 외부 AI 서비스의 장기 API 키는 서버가 보관합니다.
- 얇은 API 계층이 업로드, 작업 상태, 취소, 결과 버전을 관리하고 음성 엔진과 회의록 모델로 요청을 나눕니다. 초기에는 모델을 메모리에 유지하고 전사 작업을 하나씩 처리합니다. 대기열은 디스크에 보존하고, 서버 재시작 후 원본에서 작업을 재시도할 수 있게 합니다. 회의 간 화자 상태를 공유하지 않습니다.
- 서버는 음성·녹취 내용을 기본 로그에 남기지 않습니다. 작업 취소와 원본 삭제는 별도 동작으로 두고, 서버 사본의 보관 기간과 삭제 상태를 사용자가 확인할 수 있게 합니다.

### 전사 엔진 선택

| 역할 | 우선 검토할 방식 | 선택 근거와 남은 검증 |
| --- | --- | --- |
| 기본 전사·화자 분리 | Mac의 NeMo-Speech.cpp v0.2.0 + Nemotron 3.5 ASR 0.6B + 화자 분리 모델 | 기존 Mac 코드·모델을 활용할 수 있음. 실제 한국어 회의 정확도와 서버 통합 검증 필요 |
| 서버 운영이 어려울 때 | API 계층 뒤에 CLOVA Speech 연결 | 한국어와 화자 분리 지원. 실제 회의 자료로 품질·비용을 비교하고 사용자가 선택한 경우에만 전송 |
| 네트워크 없는 현장 | whisper.cpp의 다국어 base/small 양자화 모델을 TB376FC에서 시험 | Android 예제가 있음. 처리 속도·메모리·발열·배터리 실측 후 도입 판단. 영어 전용 `.en` 모델은 제외 |

Nemotron 3.5 모델 카드는 한국어 `ko-KR`를 transcription-ready 언어로 명시합니다. 이것만으로 특정 회의에서의 정확도나 TB376FC 실시간 처리를 보장할 수는 없습니다. NPU를 자동으로 활용한다고 가정하지 않으며, 기기 내 전사는 녹음을 동시에 수행하면서 30분 이상 부하를 걸어 판단합니다. [모델 카드](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b), [CLOVA Speech API](https://api.ncloud-docs.com/docs/ai-application-service-clovaspeech-longsentence-externalurl), [whisper.cpp Android 예제](https://github.com/ggml-org/whisper.cpp/tree/master/examples/whisper.android).

NeMo-Speech.cpp v0.2.0에는 HTTP 전사와 실시간 WebSocket 서버가 이미 있습니다. 다만 현재 앱에서 서버 URL만 바꾸는 것으로 통합이 완료되지는 않습니다. 해당 서버의 `verbose_json`은 `words[]`에 단어 시각과 화자를 반환하고, 앱은 현재 `segments[]`만 읽어 시각을 처리합니다. API 계층에서 단어를 문장·화자 구간으로 묶고 시각 단위를 초로 통일해야 합니다. 화자 분리 요청과 모델 설정도 필요합니다. CLOVA의 밀리초 시각도 같은 형식으로 변환합니다. [v0.2.0 서버](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/v0.2.0/docs/server.md), [API 형식](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/v0.2.0/docs/api.md).

현재 Mac의 TitaNet 프로필 비교와 서버의 익명 화자 분리는 별도로 검증합니다. `화자 1`은 특정 인물의 이름이 아니며, 사용자가 연결한 이름을 회의별로 보관합니다. 원래 인식 결과와 사용자 수정본도 구분합니다. 회의록 모델은 검토된 녹취와 메모를 사용하고 원본 녹취를 덮어쓰지 않습니다.

### 구현 순서와 API 초안

첫 단계는 **녹음 종료 후 전사를 안정적으로 완료하는 것**입니다. 전송 조각과 추론 단위를 분리해, 조각마다 독립된 5분 회의로 처리하지 않고 전체 회의의 문맥·화자 상태를 유지합니다. 아래 경로는 구현 예정인 TableLog API이며 NeMo의 기본 제공 경로가 아닙니다.

| 경로 | 동작 |
| --- | --- |
| `POST /v1/meetings` | 기기에서 만든 회의 UUID를 받아 중복 생성 없이 업로드 세션을 만듦 |
| `PUT /v1/meetings/{id}/chunks/{sequence}` | 시작 샘플·샘플 수·해시와 음성을 저장한 뒤 수신 확인. 같은 내용 재전송은 성공, 같은 번호의 다른 내용은 충돌로 응답 |
| `GET /v1/meetings/{id}/upload` | 디스크에 저장된 연속 수신 위치를 알려 재전송 시작점을 결정 |
| `POST /v1/meetings/{id}/transcription-jobs` | 전체 샘플 수와 누락 여부를 확인하고 작업 생성. 동일 멱등성 키의 재요청은 기존 작업을 반환 |
| `GET /v1/transcription-jobs/{id}` | 대기·처리·완료·실패·취소 상태와 결과 버전, `segments[{start,end,text,speaker_id}]`를 반환 |
| `DELETE /v1/transcription-jobs/{id}` | 진행 중 처리를 취소. 녹음 원본은 별도로 보존 |

세션과 작업은 인증된 기기의 권한을 확인합니다. 폴링으로 결과를 받아 앱이 종료되었다 다시 열려도 상태를 복구합니다. 진행률·실패 원인을 표시하고, 사용자가 녹취를 수정한 동안 도착한 오래된 결과는 자동 적용하지 않습니다. 긴 녹음은 샘플 위치를 기준으로 순차 처리해 전체 PCM을 메모리에 복사하지 않습니다.

두 번째 단계에서 녹음 중 임시 자막을 추가합니다. API 계층이 NeMo의 `/v1/audio/transcriptions/realtime`에 연결하고, 회의별로 순서가 있는 PCM16 프레임을 전달합니다. 앱의 로컬 저장과 서버의 영속 수신 확인을 기준으로 재연결하며, 엔진 연결이 끊기면 필요한 음성을 다시 처리합니다. 엔진의 WebSocket 자체에 영속 재개 기능이 있다고 가정하지 않습니다. 느린 연결에서는 제한된 전송 대기열을 사용하고 원본은 계속 기기에 저장합니다. 임시 자막과 최종 녹취를 구별하고, 회의 종료 후 화자·시각을 정리한 결과를 검토합니다.

완료 기준은 TB376FC 실기기에서 가로·세로·분할 창 전환, 화면을 끈 상태의 2시간 녹음, Wi-Fi 단절·서버 재시작 후 재전송, 중복 없는 결과 적용을 확인하는 것입니다. 별도로 정답을 작성한 한국어 회의 구간에서 문자 오류율과 화자 배정 오류를 측정하고, 기기 내 전사 후보는 처리 시간·최대 메모리·온도·배터리 사용량을 기록합니다. 아직 이 실기기 검증을 수행하지 않았습니다.

## 저장·호환 범위

앱의 `files/meetings/<UUID>/` 아래에 `meeting.json`, `recording.wav`, 수정 전 `revisions/`, 가져온 `import-original.json`을 보관합니다. 파일 가져오기는 새 UUID를 만들고 외부 파일 경로를 따라가지 않습니다. 음성 파일과 수정 이력은 JSON 내보내기에 포함되지 않으므로 필요한 WAV는 별도로 공유해야 합니다. 변경 이력의 앱 내 탐색·되돌리기 UI는 아직 없습니다.

Mac용 JSON은 제목·일시·발언·화자·시각을 교환합니다. Mac 자료 첨부·음성 프로필·AI 대화·회의록 내부 상태를 완전히 왕복하는 형식은 아닙니다. Android의 회의록과 메모까지 백업하려면 Android 기록 JSON 또는 Markdown을 선택합니다. Mac에 가져온 녹음 경로가 자동으로 연결되지는 않습니다.

휴지통은 논리적 삭제이며 파일을 지우지 않습니다. 앱 삭제 시 앱 전용 저장소도 삭제됩니다. OS 클라우드 백업과 기기 이전은 비활성화되어 있으며, 새 기기로 옮기기 전 직접 내보내야 합니다. API 키는 Keystore 키로 암호화해 저장하고 로그·내보내기·Git에 포함하지 않습니다. 네트워크 리디렉션과 평문 HTTP 연결은 허용하지 않습니다.

현재 제외: 기기 내 NeMo/TitaNet 실행, 자동 화자 분리·등록 목소리 비교, 실시간 전사, 자연어 편집 채팅, 참고 자료 분석, Mac 자동 동기화, 외부 오디오 파일 가져오기, Play Store 출시.

## 빌드와 검증

필요 도구는 JDK 17, Android SDK Platform 36, Build Tools 35.0.0입니다. Android Studio에서 이 디렉터리를 열거나 명령줄에서 실행합니다. SDK 위치는 `local.properties`의 `sdk.dir` 또는 `ANDROID_HOME`으로 지정합니다. `local.properties`와 빌드 출력은 Git에 포함하지 않습니다.

```bash
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

테스트 기기/에뮬레이터 연결 후:

```bash
./gradlew :app:connectedDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
python3 scripts/smoke-recovery.py --serial emulator-5554
```

`smoke-recovery.py`는 에뮬레이터에만 실행되며, 테스트 녹음을 새로 만들어 백그라운드 녹음 중 프로세스를 강제 종료한 후 PCM 보존과 WAV 복구를 확인합니다. 실제 마이크 음질 검증이 아닙니다.

- 단위 테스트: Mac 가져오기와 교정본 선택, 왕복 저장, 시각·경로 검증, WAV 복구, HTTPS 설정, 청크 시각, HTTPS 모의 서버 전사·회의록
- 기기 테스트: 제목·발언 편집, 휴지통 복원, 디스크 재읽기, 녹음 일시정지·재개, Activity 재생성, WAV 헤더·녹음 길이와 동시 메모 보존
- GitHub Actions: 단위 테스트·lint·APK 빌드와 APK artifact 제공. 기기 테스트는 별도 실행

[검증 기록](VERIFICATION.md)에 실제 수행한 범위를 정리했습니다.

구현 시 참조한 공식 문서: [AGP 8.13 호환성](https://developer.android.com/build/releases/agp-8-13-0-release-notes), [마이크 foreground service](https://developer.android.com/develop/background-work/services/fgs/service-types#microphone), [Compose BOM](https://developer.android.com/develop/ui/compose/bom).
