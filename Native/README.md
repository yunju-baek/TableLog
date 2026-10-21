# 음성 엔진 빌드

테이블로그 2.6.0은 NeMo-Speech.cpp **v0.2.0** (`6a3ca369370782acee0dd155e34394ba60b920c4`)과 해당 태그의 llama.cpp (`bd4f514db14d87fded667787a7a963bfbaa98e89`)를 사용합니다. C++ 연결부와 동적 라이브러리는 같은 소스 버전으로 빌드합니다.

## 준비와 빌드

CMake, Ninja, Xcode Command Line Tools가 필요합니다. 소스와 빌드 폴더는 로컬 임시 경로에 둡니다.

```bash
git clone --branch v0.2.0 --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/NVIDIA/NeMo-Speech.cpp.git /tmp/tablelog-nemo-v0.2.0
bash Native/build_runtime.sh /tmp/tablelog-nemo-v0.2.0 .runtime/v0.2.0
bash build.sh "$HOME/Applications/테이블로그.app"
```

첫 빌드는 공식 스크립트로 고정된 SentencePiece를 가져옵니다. Metal 셰이더와 SentencePiece를 라이브러리에 포함하고 CPU는 `GGML_NATIVE=OFF`로 빌드합니다. 출력에는 C 연결부, 6개 동적 라이브러리, 라이선스, 버전·SHA256 기록이 함께 들어갑니다. 앱 빌드는 이 기록으로 연결부와 라이브러리의 조합을 확인합니다. 이후에는 같은 버전이 설치된 앱을 빌드 기반으로 사용할 수 있습니다.

## 동작

- 16kHz 모노 Float PCM을 최대 1,600개씩 직렬 큐에서 전달합니다.
- 한국어 `ko-KR`, 단어 시각, 중간 화자 태그, 최대 8개 화자 채널을 사용합니다.
- 800ms 토큰 무음 기준으로 발언을 확정하고, v0.2.0이 다음 발언까지 인식 문맥을 유지합니다.
- 늦게 나온 문장부호를 직전 확정 발언에 반영합니다. 원래 ASR 모델의 문장부호를 사용하며, 별도 ITN 모델 적용은 후속 범위입니다.
- 화자 재판정은 확정·진행 중인 발언에 함께 반영합니다. 20ms 대표 화자 기록에는 무음 구간도 포함됩니다.
- `finish`는 반복 호출 시 결과를 유지하고, `start`와 `reset`은 새 세션 상태를 만듭니다. 잘못된 용어 입력 시 기존 결과를 보존합니다.

`Verification/EngineSmoke.cpp`는 완료·초기화·무음·입력 검증·용어 토크나이저·발언 경계와 두 문맥 설정을 확인합니다. `--right13`, `--official`, `--endpoints`로 실제 설정과 경계 검증을 선택합니다.

공식 [릴리스](https://github.com/NVIDIA/NeMo-Speech.cpp/releases/tag/v0.2.0)와 [비교 기록](../docs/ENGINE_UPDATE_2.6.0.md)을 참고하세요.
