# Deep Research 요청: 실시간 번역 품질 향상 방안

> LiveNote V2의 번역 품질을 높이기 위한 세그멘테이션 및 프롬프트 전략 연구

## 1. 현재 시스템 상태

### 1.1 아키텍처 개요

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   PyAudio   │───▶│ Silero VAD  │───▶│   Queue     │───▶│ Gemini API  │
│   Capture   │    │ Segmenter   │    │ (Producer)  │    │ (Consumer)  │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
     16kHz              음성 감지          세그먼트           번역
     Mono               경계 판단          버퍼링            JSON 출력
```

### 1.2 현재 VAD 세그멘테이션 파라미터

| 파라미터 | 현재값 | 설명 |
|---------|--------|------|
| MIN_CHUNK | 1.5초 (47 frames) | 최소 세그먼트 길이 |
| MAX_CHUNK | 6.0초 (187 frames) | 최대 세그먼트 길이 |
| SILENCE_THRESHOLD | 800ms (25 frames) | 문장 종료 판단 무음 길이 |
| FORCE_FLUSH | 7.0초 (218 frames) | 강제 전송 타임아웃 |
| VAD_THRESHOLD | 0.5 | 음성 감지 확률 임계값 |

### 1.3 현재 프롬프트 (System Instruction)

```
You are an expert simultaneous interpreter translating English audio to Korean in real-time.

CORE RULES:

1. **Latency Priority:** Translate concisely. Do not add explanations.

2. **Incomplete Sentences:**
   - If the audio cuts off mid-sentence, DO NOT guess the ending.
   - Use Korean connecting endings (Ghost Suffixes):
     - '~하고' (and, listing)
     - '~인데' (but, contrast)
     - '~해서' (so, because)
     - '~며' (while, and)
     - '~는데' (but, however)

3. **Context Awareness:**
   - Use provided previous transcripts to maintain context
   - Resolve pronouns based on prior context
   - Maintain terminology consistency

4. **Accuracy:**
   - Transcribe English exactly as heard
   - Do not omit or add words

5. **Natural Korean:**
   - Use natural, spoken Korean
   - Match formality level to source speech
```

### 1.4 JSON 출력 스키마

```json
{
  "transcript": "영어 원문 (STT)",
  "translation": "한국어 번역",
  "is_complete": true/false  // 문장 완성 여부
}
```

### 1.5 컨텍스트 관리

- 최근 5턴 히스토리 유지
- 불완전 문장(is_complete=false) 자동 병합
- 오디오 오버랩 0.5초 적용 (단어 잘림 방지)

---

## 2. 현재 관찰된 문제점

### 2.1 세그먼트 경계 문제

실제 로그에서 관찰된 불완전 문장 예시:

```
Seg#4: "it and uh the feedback they gave me, which uh" (is_complete: false)
Seg#9: "break anything in the future. And we we we can" (is_complete: false)
Seg#17: "um, you know, then that that works for me, honestly. Um, you know, I I have I have" (is_complete: false)
```

**문제**: VAD는 800ms 무음이면 자르지만, 이는 화자가 잠시 쉬는 것일 뿐 문장이 끝난 것이 아닐 수 있음.

### 2.2 번역 품질 영향

- 불완전 세그먼트 → 문맥 부족 → 부정확한 번역
- Ghost Suffix로 연결하지만, 다음 세그먼트와 자연스럽게 이어지지 않는 경우 있음
- 대명사 해석 오류 (컨텍스트 전달이 완벽하지 않음)

### 2.3 API 응답 특성

최근 테스트 결과 (Thinking OFF 상태):
- 평균 레이턴시: 2.4초
- 최대 레이턴시: 4.6초 (간헐적 스파이크)
- 오디오 6~7초당 2~3초 처리 → Consumer가 Producer를 따라잡음

---

## 3. 연구 요청 사항

### 3.1 세그멘테이션 전략 연구

**질문 1**: 동시통역 시스템에서 오디오를 어떤 단위로 자르는 것이 최적인가?

조사 필요 사항:
- **Wait-k 정책**: k개 단어/토큰을 기다렸다가 번역 시작하는 전략
  - 최적의 k값은?
  - 시간 기반 vs 단어 기반 vs 의미 단위 기반?
- **Sentence Boundary Detection**: 문장 경계를 감지하는 방법
  - 음성만으로 문장 끝을 판단하는 방법?
  - 억양, 포즈 패턴 분석?
- **Adaptive Chunking**: 상황에 따라 청크 크기를 동적으로 조절
  - 빠른 발화 vs 느린 발화
  - 단순 문장 vs 복잡한 문장

**질문 2**: VAD 파라미터 최적화

- SILENCE_THRESHOLD를 800ms에서 늘리면 품질이 올라가는가?
- 1000ms, 1200ms, 1500ms 비교 연구가 있는가?
- MIN_CHUNK를 1.5초에서 2초, 2.5초로 늘리면?

### 3.2 프롬프트 엔지니어링 연구

**질문 3**: 실시간 번역을 위한 최적의 프롬프트 전략은?

조사 필요 사항:
- 동시통역사가 실제로 사용하는 기법
  - Salami Technique (작은 단위로 쪼개서 번역)
  - Anticipation (예측하여 미리 번역 시작)
  - Compression (압축하여 번역)
- LLM 기반 동시통역 연구에서 사용하는 프롬프트
- Ghost Suffix 외에 불완전 문장을 처리하는 다른 방법

**질문 4**: 컨텍스트 전달 최적화

- 5턴이 최적인가? 더 많이/적게?
- 컨텍스트를 어떤 형식으로 전달하는 것이 효과적인가?
- 요약 vs 전체 텍스트 vs 키워드

### 3.3 품질 평가 지표

**질문 5**: 실시간 번역 품질을 어떻게 측정하는가?

- BLEU, COMET 등 기존 지표가 동시통역에 적합한가?
- 레이턴시 vs 품질 트레이드오프를 어떻게 정량화하는가?
- 사용자 체감 품질 (QoE) 측정 방법

---

## 4. 참고할 연구 및 프로젝트

### 4.1 학술 연구

1. **Wait-k Policy**
   - "STACL: Simultaneous Translation with Implicit Anticipation" (ACL 2019)
   - "Efficient Wait-k Models for Simultaneous Machine Translation" (2020)

2. **Simultaneous Speech Translation (SimulST)**
   - RealSI Benchmark (ByteDance)
   - CLASI (Consecutive and Simultaneous AI Interpretation)

3. **Streaming ASR + NMT**
   - Google's Translatotron
   - Meta's SeamlessM4T

### 4.2 오픈소스 프로젝트

- pipecat-ai/pipecat - 음성 AI 프레임워크
- Simultaneous-Interpretation (GitHub) - 멀티스레드 파이프라인

### 4.3 산업 사례

- Google Translate 실시간 번역
- Microsoft Translator Live
- KUDO, Interprefy 등 전문 통역 플랫폼

---

## 5. 기대 결과물

### 5.1 세그멘테이션 개선안

- VAD 파라미터 최적값 제안 (근거 포함)
- 또는 VAD 외에 추가로 사용할 수 있는 세그멘테이션 기법

### 5.2 프롬프트 개선안

- 번역 품질을 높이는 프롬프트 수정 제안
- 컨텍스트 전달 방식 개선안

### 5.3 구현 가이드

- 코드 수정이 필요한 부분 명시
- 예상 효과 및 트레이드오프

---

## 6. 제약 조건

### 6.1 기술적 제약

- **모델**: Gemini 2.5 Flash (Thinking OFF)
- **레이턴시 목표**: 세그먼트당 3초 이내 응답
- **API 비용**: 최소화 필요 (토큰 수 고려)

### 6.2 사용 환경

- **입력**: 영어 음성 (회의, 강연, 대화)
- **출력**: 한국어 자막 (실시간)
- **사용자**: 영어 청취에 어려움이 있는 한국어 사용자

---

## 7. 현재 코드 위치 참고

| 파일 | 역할 |
|------|------|
| `src/audio/vad_segmenter.py` | VAD 기반 세그멘테이션 |
| `src/translator/prompts.py` | 시스템 프롬프트 및 JSON 스키마 |
| `src/translator/context_manager.py` | 컨텍스트 히스토리 관리 |
| `src/translator/gemini_client.py` | Gemini API 호출 |
| `docs/IMPLEMENTATION_PLAN_V2.md` | 기존 설계 문서 |
