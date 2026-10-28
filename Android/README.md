# 테이블로그 Android 0.1.0

회의를 녹음하고 발언·회의록·메모를 기기에 보관하는 네이티브 Android 앱입니다. macOS TableLog와 같은 저장소에서 개발하며, 모바일 화면과 녹음 처리는 Kotlin·Jetpack Compose로 구현했습니다.

## 설치와 사용

Android 8.0(API 26) 이상을 대상으로 합니다. 현재 제공하는 APK는 테스트용 debug 빌드입니다. Play Store 배포용 서명·출시는 별도 작업입니다.

1. `app/build/outputs/apk/debug/app-debug.apk`를 휴대폰으로 옮겨 설치합니다. 또는 USB 디버깅 연결 후 `adb install -r app/build/outputs/apk/debug/app-debug.apk`를 실행합니다.
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

## AI 서버 연결

설정에서 HTTPS 기본 주소(예: `https://서버주소/v1`), 음성 모델 이름, 회의록 모델 이름, 필요한 경우 API 키를 입력합니다. 서버는 다음 계약을 지원해야 합니다.

| 경로 | 요청 | 응답 |
| --- | --- | --- |
| `POST /audio/transcriptions` | multipart: `file` WAV, `model`, `language=ko`, `response_format=verbose_json` | `segments: [{start, end, text}]` 또는 `text` |
| `POST /chat/completions` | JSON: `model`, `messages`, `stream=false` | `choices[0].message.content` |

음성은 최대 5분씩 나눠 순차 전송하고, 구간 시각을 전체 녹음의 시각으로 변환합니다. 서버가 문장별 시각을 반환하지 않으면 각 5분 구간 전체를 한 발언으로 보관합니다. 구간 경계 문맥 연결과 자동 화자 식별은 제공하지 않습니다. 전사 결과의 화자는 **화자 미지정**으로 표시합니다.

회의록 요청은 제목·일시·녹취·메모를 보냅니다. 녹취와 메모 합계 10만 자를 넘으면 명시적으로 중단하며 조용히 잘라 보내지 않습니다. 요청 취소 시 네트워크 호출도 취소합니다. 일부 구간만 성공한 전사 결과는 적용하지 않습니다. 적용 전 회의가 수정되면 오래된 결과의 적용을 거부합니다.

서버 주소·모델·키는 기본으로 제공하지 않습니다. 연결 테스트는 합성 입력을 사용하는 로컬 HTTPS 모의 서버에서 수행했습니다. 실제 운영 서버의 모델 지원·음성 품질·요금은 검증하지 않았습니다. Mac의 Codex·Claude Code·Gemini CLI 로그인이나 구독은 자동으로 연결되지 않습니다.

## 저장·호환 범위

앱의 `files/meetings/<UUID>/` 아래에 `meeting.json`, `recording.wav`, 수정 전 `revisions/`, 가져온 `import-original.json`을 보관합니다. 파일 가져오기는 새 UUID를 만들고 외부 파일 경로를 따라가지 않습니다. 음성 파일과 수정 이력은 JSON 내보내기에 포함되지 않으므로 필요한 WAV는 별도로 공유해야 합니다. 변경 이력의 앱 내 탐색·되돌리기 UI는 아직 없습니다.

Mac용 JSON은 제목·일시·발언·화자·시각을 교환합니다. Mac 자료 첨부·음성 프로필·AI 대화·회의록 내부 상태를 완전히 왕복하는 형식은 아닙니다. Android의 회의록과 메모까지 백업하려면 Android 기록 JSON 또는 Markdown을 선택합니다. Mac에 가져온 녹음 경로가 자동으로 연결되지는 않습니다.

휴지통은 논리적 삭제이며 파일을 지우지 않습니다. 앱 삭제 시 앱 전용 저장소도 삭제됩니다. OS 클라우드 백업과 기기 이전은 비활성화되어 있으며, 새 기기로 옮기기 전 직접 내보내야 합니다. API 키는 Keystore 키로 암호화해 저장하고 로그·내보내기·Git에 포함하지 않습니다. 네트워크 리디렉션과 평문 HTTP 연결은 허용하지 않습니다.

현재 제외: 휴대폰 내 NeMo/TitaNet 실행, 자동 화자 분리·등록 목소리 비교, 실시간 전사, 자연어 편집 채팅, 참고 자료 분석, Mac 자동 동기화, 외부 오디오 파일 가져오기, Play Store 출시.

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
