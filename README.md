# 테이블로그 2.9.0

macOS에서 회의를 녹음하고 화자별 녹취·회의록·참고 자료를 정리하는 앱입니다. 자연어 편집 채팅으로 문장과 화자를 수정하고, AI CLI를 선택해 교정·요약·자료 분석에 사용할 수 있습니다.

- [사용법·도움말](docs/USER_GUIDE.md)
- [Codex · Claude Code · Gemini CLI 연결](docs/AI_CLI_SETUP.md)
- [버전 기록](docs/CHANGELOG.md)
- [음성 엔진 업데이트·화자 모델 비교](docs/ENGINE_UPDATE_2.6.0.md)

## 실행 환경

macOS 26, Apple Silicon, Xcode Command Line Tools가 필요합니다. 현재 버전은 2.9.0, 빌드 35입니다.

로컬 음성 인식·화자 분리는 NVIDIA Nemotron, 등록 목소리 비교는 TitaNet을 사용합니다. AI 문맥 처리는 설치된 Codex, Claude Code, Gemini CLI 가운데 하나를 선택합니다. 각 CLI의 로그인 계정과 사용 한도가 적용됩니다.

녹음 중 **일시정지 / 녹음 재개** 또는 `⇧⌘P`로 같은 회의에 이어서 녹음할 수 있습니다. 회의 일시는 휴식 시간을 포함하며, M4A 길이와 발언 시각은 실제 녹음 구간을 기준으로 합니다.

## 빌드

이 저장소는 Swift 소스와 네이티브 연결 모듈을 담습니다. 음성 엔진은 NeMo-Speech.cpp v0.2.0으로 고정합니다. 첫 엔진 빌드는 [네이티브 빌드 안내](Native/README.md)를 따르고, 이후에는 같은 엔진을 포함한 설치본의 라이브러리·리소스를 재사용합니다. 모델은 `~/Library/Application Support/TableLog/Models`에서 읽습니다.

```bash
bash build.sh "$HOME/Applications/테이블로그.app"
```

완성된 앱 경로가 마지막 줄에 표시됩니다. 녹음과 저장을 완료하고 앱을 종료한 다음 해당 앱으로 설치본을 교체합니다. 코드 서명을 유지할 수 있도록 앱 빌드와 압축 해제는 로컬 임시 폴더에서 수행합니다.

필요한 모델 파일:

- `nemotron-3.5-asr-streaming-0.6b.q8_0.gguf`
- `Nemotron-3-Diarization.q8_0.gguf`
- `nemo_en_titanet_large.onnx`

## 회의록

회의 전체를 안건별로 종합해 회의 개요·핵심 요약·논의 내용·결정 사항·후속 조치·확인할 사항을 Markdown으로 저장합니다. 회의 일시는 시작 시각을 10분 단위로 절삭하고 종료 시각을 10분 단위로 올림하여 표시합니다. 발언별 시각·전사·도우미 기록은 앱의 각 화면에서 확인합니다. 긴 회의는 구간별 추출 후 전체 종합을 거쳐 반복을 정리합니다.

## 검증

격리된 임시 저장소와 예시 발언으로 편집·복원·설정 호환·CLI 응답 검증을 실행합니다.

```bash
bash Verification/run-editing-checks.sh
bash Verification/run-minutes-checks.sh
# 세 CLI의 연결과 예시 발언 화자 수정까지 확인합니다. 각 계정의 사용량이 발생합니다.
bash Verification/run-editing-checks.sh --live-all
```

실행 기반 앱이 다른 경로에 있으면 `TABLELOG_BASE_APP` 환경 변수를 지정합니다. 실제 녹음 환경의 음성·화자 인식 품질은 마이크와 등록 음성 조건에 따라 달라집니다.

## 코드 구성

| 파일 | 역할 |
|---|---|
| `AITextRunner.swift` | CLI별 실행·응답 변환·연결 확인 |
| `ContextEditorView.swift` | AI 선택·모델·실행 경로·교정 설정 |
| `MeetingEditingChat.swift` | 자연어 수정안·원문 검증·적용·되돌리기 |
| `EditingConversationView.swift` | 채팅과 변경 전후 비교 |
| `AppModel.swift` | 전사·화자·회의 상태 연결 |
| `MeetingWorkspace.swift` | 회의록 생성·편집본 보관 |
| `MeetingMaterials.swift` | 자료 수집·선택·버전 보관 |
| `VoiceIdentity.swift` | 등록 목소리 연결·학습 자료 관리 |
| `AppHelp.swift` | GitHub 사용법 링크 |

기록·음성·계정 정보·모델 파일은 사용자의 로컬 저장소에서 관리합니다. GitHub에는 앱 코드와 문서, 합성 자료 기반 검증 코드를 보관합니다.
