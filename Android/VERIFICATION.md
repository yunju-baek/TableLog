# Android 0.2.0 검증 기록

검증일: 2026-10-28. 목표 기기는 **레노버 샤오신패드 프로 13(TB376FC), RAM 8GB**입니다. 실제 기기는 연결하지 않았습니다. Android 16/API 36 arm64의 Pixel Tablet 프로필(2560×1600, 실행 RAM 4GB) 에뮬레이터에서 확인했습니다.

## 확인한 결과

| 항목 | 결과 | 확인 범위 |
| --- | --- | --- |
| Debug APK | 통과 | JDK 17, Gradle 8.13, AGP 8.13.2, SDK 36, arm64·x86_64 |
| 서명·패키징 | 통과 | APK v2 서명, ZIP 16KB 정렬, 포함된 모든 native ELF LOAD 정렬 16KB 이상. 16KB 기기 실행 자체는 미검증 |
| Android lint | 오류 0 | API·manifest·리소스 분석. 의존성 갱신·스타일 경고는 남아 있음 |
| JVM 단위 테스트 | 11개 통과 | 기존 JSON·WAV·서버 요청 검사, 모델 이어받기·해시 실패·취소, 인증 실패·리디렉션 차단, native 입력 WAV 형식 검사 |
| 일반 기기 테스트 | 4개 통과, 다운로드 선택 테스트 1개 건너뜀 | 편집·복원·녹음 수명주기, Keystore와 전사 방식 저장, 실제 로컬 음성 엔진·결과 보관 |
| 선택한 다운로드 테스트 | 별도 1개 통과 | 앱의 다운로드 코드로 공개 HTTPS 모델 파일을 실제 내려받고 고정 크기·SHA-256 확인 |
| 오프라인 추론 | 통과 | 비행기 모드, Wi-Fi·셀룰러 비활성화, `Active default network: none` 상태에서 한국어 샘플 전사 |
| 제한된 음성 구간 처리 | 통과 | 48초로 반복한 공개 한국어 음성에서 여러 구간 생성, 각 구간 25초 이내, 전체 시각 범위·순서 확인 |
| 결과 검토·보존 | 통과 | foreground service 전사 완료 후 검토 파일 저장, 기존 발언 미변경, Activity 재생성 후 검토 파일 재읽기 |
| 인증 정보 보호 | 통과 | AES-GCM 저장·복호화, URL 변경 시 동일 토큰 거부, 암호문에 연결된 URL을 바꾸면 복호화 실패, 로컬 모드는 손상된 서버 토큰 없이도 읽힘 |
| 서버 연결 확인 | 모의 HTTPS에서 통과 | GET 모델 목록, Bearer 헤더, 빈 요청 본문, 401·403 구분, 302를 따라 토큰을 전달하지 않음 |
| 녹음 복구 | 통과 | 홈으로 이동해 무음 녹음, 강제 종료 후 PCM 보존·WAV 헤더 복구. 5.0초 checkpoint에서 5.6초 복구 |
| 태블릿 화면 | 확인 | 회의 목록·상세 동시 표시, 로컬/서버 선택, 설정 화면. 화면 압축 변경 후 편집·녹음 테스트 2개 재통과 |

기기 테스트의 `OK (5 tests)`에는 기본적으로 실행하지 않는 다운로드 테스트 1개의 assumption skip이 포함됩니다. 이를 실제 추론이나 다운로드 성공으로 세지 않았습니다. 다운로드는 `downloadModel=true`를 지정한 별도 실행에서 성공했습니다.

## 실제 모델 입력과 결과

사용한 입력은 사용자의 회의가 아닌 [sherpa-onnx 공개 한국어 샘플](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/blob/2365baeacb507f821a0c8120fcee3d484dba7a07/test_wavs/ko.wav)입니다. SHA-256은 `0dc797a5c81ed30fc339d91f3da718ab02854e17ffa37cb93c4c039ac5c6bb9c`이며 4.608초, 16kHz mono PCM16입니다. 반복 입력도 이 공개 샘플에서 만들었습니다.

실제 모델은 `조 금만 생각 을 하 면서 살 면 훨씬 편할 거야.`를 반환했습니다. 한국어 출력·시각 범위·저장 흐름을 확인했지만 띄어쓰기 문제도 관찰되었습니다. 정답 회의 자료로 CER·WER를 측정한 결과가 아니며, 장시간 한국어 회의의 정확도를 보장하지 않습니다. 에뮬레이터 실행 시간은 TB376FC 성능으로 제시하지 않습니다.

## 화면

![태블릿 로컬·서버 선택](screenshots/tablet-local.png)

![태블릿 설정](screenshots/tablet-settings.png)

화면에는 합성 회의와 공개 샘플 검증용 기록만 표시했습니다. 녹취의 ‘보존할 기존 발언’은 결과를 자동으로 덮어쓰지 않는지 확인하는 테스트 입력입니다.

## 실행 명령

```bash
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:lintDebug
adb -s emulator-5554 shell am instrument -w work.yunju.tablelog.test/androidx.test.runner.AndroidJUnitRunner
adb -s emulator-5554 shell am instrument -w \
  -e class 'work.yunju.tablelog.LocalAiTest#installFromPublicSourcesWhenExplicitlyRequested' \
  -e downloadModel true work.yunju.tablelog.test/androidx.test.runner.AndroidJUnitRunner
python3 scripts/smoke-recovery.py --serial emulator-5554 --output verification-local/0.2.0-recovery.json
```

실제 추론 테스트는 모델과 샘플을 앱 저장소에 준비해야 합니다. 설치 방법과 경로는 [README](README.md#빌드와-검증)를 참조하세요. Gradle 보고서는 `app/build/reports/`, 복구 결과는 `verification-local/0.2.0-recovery.json`, 에뮬레이터 추론 기록은 앱의 `files/verification/local-smoke.json`입니다. 실행 산출물은 Git에 포함하지 않습니다.

## 아직 확인하지 않은 범위

TB376FC 실기기에서의 장시간 녹음·전사, 최대 메모리, 발열·배터리, 제조사 절전 정책, 실제 마이크·블루투스·오디오 포커스, 세로·분할 창 전환의 전체 사용 흐름은 미검증입니다. Android 8~15와 x86_64 실기기 실행도 확인하지 않았습니다.

운영 서버를 배포하거나 실제 서버의 토큰 발급·폐기·갱신을 검증하지 않았습니다. 코드 승인/OAuth 등록은 설계안입니다. 자동 화자 분리, 로컬 회의록 요약, 실시간 자막과 Play Store 배포도 이번 구현 범위에 포함하지 않습니다.
