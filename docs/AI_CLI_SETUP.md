# AI CLI 연결 안내

테이블로그 2.5.0은 **Codex · Claude Code · Gemini CLI**를 지원합니다. 상단 **AI 설정** 또는 메뉴 **AI → AI CLI 설정…**에서 선택합니다. CLI별 모델·추론 강도·실행 파일 경로를 따로 보관합니다.

## 공통 설정

1. 사용할 CLI를 설치하고 터미널에서 로그인합니다.
2. 앱의 **AI 설정**에서 CLI를 선택합니다.
3. **실행 파일 경로**를 비우면 기본 설치 위치를 탐색합니다. 사용자 지정 설치는 실행 파일의 절대 경로를 입력합니다.
4. **설치 확인**으로 실행 파일을 확인합니다.
5. **모델 ID**를 비우면 CLI 기본 모델을 사용합니다. 특정 모델은 해당 계정에서 제공하는 ID를 입력합니다.
6. **연결 테스트**로 예시 JSON 요청을 실행한 뒤 **적용**을 누릅니다.

연결 테스트에는 예시 문장만 사용하며, 선택한 계정의 사용량이 발생합니다. 설정 변경은 적용 후 새 요청부터 반영됩니다.

| CLI | 터미널 로그인 | 자동 탐색 경로 |
|---|---|---|
| Codex | `codex login` | ChatGPT·Codex 앱 내 CLI, Homebrew·로컬 설치 경로 |
| Claude Code | `claude auth login` | `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` |
| Gemini CLI | `gemini` 실행 후 인증 선택 | `~/.local/bin/gemini`, `/opt/homebrew/bin/gemini`, `/usr/local/bin/gemini` |

## Codex

기존 ChatGPT 로그인을 사용합니다. 앱 안의 **ChatGPT 로그인** 버튼으로도 로그인할 수 있습니다. 설치된 ChatGPT 앱의 최신 CLI를 우선 탐색합니다. 이전 경로가 설정되어 있으면 실행 파일 경로를 비우고 설치 확인을 실행하거나 현재 CLI 경로로 갱신합니다.

모델 목록은 로컬 Codex 모델 캐시에서 읽습니다. 목록에 필요한 모델이 있으면 선택하고, 직접 지정할 때는 모델 ID를 입력합니다. 추론 강도는 해당 모델에서 지원하는 값을 선택합니다.

## Claude Code

설치 후 `claude auth login`으로 인증합니다. 기본 모델로 연결 테스트를 먼저 실행하고 필요하면 모델 ID와 추론 강도를 지정합니다.

앱은 Claude의 비대화형 실행과 구조화 JSON 출력을 사용합니다. 요청별로 도구·MCP·개인 명령을 제한하고 제공된 발언과 자료를 텍스트로 처리합니다.

## Gemini CLI

설치 후 터미널에서 `gemini`를 실행하여 로그인합니다. 모델 ID를 비우면 CLI에서 선택하는 기본 모델을 사용합니다. 앱에서 시작하는 CLI가 기존 인증 설정을 사용할 수 있어야 합니다.

앱은 Gemini의 비대화형 JSON 출력을 사용합니다. 요청 전용 임시 설정과 정책으로 도구·확장·훅을 제한합니다. 기존 시스템 설정은 요청 설정에 병합해 유지합니다.

## 적용 범위와 데이터

선택한 CLI는 편집 채팅, 실시간 문맥 교정, 회의 요약·제안, 회의록, 자료 분석, LLM 화자 검토에 적용됩니다. 요청에 필요한 텍스트는 Codex 선택 시 OpenAI, Claude Code 선택 시 Anthropic, Gemini CLI 선택 시 Google로 전달됩니다. 각 계정의 모델 접근 권한·이용 조건·사용 한도가 적용됩니다.

앱이 입력을 구성하고 응답의 대상 ID·원문·형식을 검사합니다. 편집 채팅은 수정안 확인 후 **변경 적용**으로 반영합니다. 자료 원본과 음성 파일은 로컬 저장소에서 유지합니다.

**인식 엔진 설정의 Gemini 음성 인식**은 별도 기능입니다. 이 기능은 음성을 Gemini API로 보내 전사하며 해당 화면에서 API 키를 설정합니다. **AI 설정의 Gemini CLI**는 추출된 텍스트의 교정·요약·편집에 사용합니다.

## 오류 해결

| 표시·상황 | 확인할 내용 |
|---|---|
| 실행 파일 경로 확인 | 터미널에서 `command -v codex`, `command -v claude`, `command -v gemini`로 경로 확인 후 앱에 입력 |
| Vertex AI 인증 오류 401 | Gemini CLI의 인증 방식과 Google Cloud 인증을 확인합니다. 개인 Google 로그인을 쓰려면 터미널 `gemini`의 `/auth`에서 해당 방식을 선택합니다. |
| 로그인 필요 | 선택한 CLI의 로그인 명령 실행 후 연결 테스트 |
| 모델·추론 강도 오류 | 모델 ID와 추론 강도를 기본값으로 두고 재시도 |
| 사용 한도 도달 | 해당 계정의 한도·갱신 시각을 확인하거나 다른 CLI 선택 |
| 응답 대기 시간 초과 | 네트워크와 CLI 터미널 실행 상태를 확인하고 재시도 |
| 응답 형식 확인 | 최신 CLI로 업데이트하고 현재 내용으로 다시 요청 |
| 설치 확인 성공, 연결 테스트 실패 | 설치 확인은 실행 가능 여부, 연결 테스트는 인증과 실제 모델 응답을 각각 점검 |

현재 어댑터는 각 CLI의 JSON 출력과 실행 옵션을 사용합니다. 설치한 버전의 옵션이 바뀐 경우 최신 연결 코드와 함께 검증합니다.

## 공식 참고 문서

- [Claude Code 비대화형 실행](https://code.claude.com/docs/en/headless)
- [Gemini CLI 설정](https://geminicli.com/docs/reference/configuration/)
- [Gemini CLI 정책 엔진](https://geminicli.com/docs/reference/policy-engine/)
