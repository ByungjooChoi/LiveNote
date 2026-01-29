# LiveNote Changelog

버전별 주요 변경사항을 기록합니다. Rollback 시 참고용.

---

## [ed765e3] - 2026-01-29
**feat: VAD-based segmentation with thinking disabled**

### 방식
- **VAD + generateContent API** - Silero VAD로 지능적 세그멘테이션
- 음성 감지 기반 1.5s~6s 동적 청크 → generateContent API 호출
- Gemini 2.5 Flash **Thinking 비활성화** (`thinking_budget=0`)

### 모델
- `gemini-2.5-flash` (Thinking OFF)

### 주요 변경
- **Silero VAD 세그멘터** 추가 (`vad_segmenter.py`)
  - 상태 머신: IDLE → PRE_SPEECH → SPEECH_ACTIVE → HESITATION → 세그먼트 emit
  - MIN_CHUNK: 1.5s, MAX_CHUNK: 6s, SILENCE: 800ms
- **Ghost Suffix 프롬프트** (`prompts.py`)
  - 불완전 문장에 연결어미 (~하고, ~인데, ~해서) 적용
  - JSON 스키마 출력 (transcript, translation, is_complete)
- **컨텍스트 관리** (`context_manager.py`)
  - 최근 5턴 히스토리 유지
  - 불완전 문장 자동 병합
  - 오디오 오버랩 0.5초 (단어 잘림 방지)
- **API 로깅** 추가 (`logs/api/`)
  - 요청별 레이턴시, 토큰 사용량, thinking_tokens 기록
- **파이프라인 타이밍 분석**
  - Producer-Consumer 시간 추적
  - 세그먼트별 대기시간, API 시간 출력

### 성능 개선
| 항목 | 이전 (Thinking ON) | 현재 (Thinking OFF) |
|------|-------------------|---------------------|
| 평균 레이턴시 | 8.65s | **2.4s** |
| 최악 레이턴시 | 33.2s | **4.6s** |
| 큐 밀림 | 발생 (7개 backlog) | **해결** |
| 실시간성 | ❌ | ✅ |

### 알려진 이슈
- 문장이 불완전하게 잘리는 경우 있음 (VAD가 800ms 무음에서 자름)
- 번역 품질 개선 여지 있음 (Deep Research 예정)

### Rollback 명령
```bash
git checkout 7f62895  # 이전 버전 (Buffered Mode)
```

---

## [7f62895] - 2026-01-28
**feat: buffered mode with generateContent API (folubebe style)**

### 방식
- **Buffered Mode (generateContent API)** - folubebe 스타일
- 5초 고정 버퍼로 오디오 수집 → generateContent API 호출 → STT+번역 동시 수행
- Live API의 턴 기반 한계 우회

### 모델
- `gemini-2.5-flash` (속도와 품질의 균형)

### 주요 변경
- `stream_audio_buffered()` 메서드 추가
- `BufferedAudioManager` 클래스로 버퍼 관리 (5초 단위, 최대 20개 큐)
- UI에서 `--buffered` 모드 선택 가능

### 성능 테스트 결과
| 모델 | 큐 안정성 | 실시간 가능 | 번역 품질 |
|------|----------|------------|----------|
| 2.0 Flash | 1/20 (완벽) | ✅ | 보통 (외래어 많음) |
| 2.5 Flash | 1-3/20 (가끔 스파이크) | ✅ | 좋음 |
| 3.0 Flash | 1→9/20 (계속 증가) | ❌ | 최고 (but 느림) |

### Rollback 명령
```bash
git checkout b3e469c
```

---

## [b3e469c] - 2026-01-27
**feat: add transcription support for sequential interpretation**

### 방식
- **Live API (WebSocket)** - Proactive Audio 모드
- 실시간 스트리밍, 모델이 자동으로 응답 타이밍 결정

### 모델
- `gemini-2.5-flash-native-audio-preview-12-2025`

### 주요 기능
- 순차 통역 모드 지원
- 영어 전사(transcription) 텍스트 출력 추가
- 한국어 번역 + 영어 원문 동시 표시

### 한계
- Live API 턴 기반 → 연속 발화 시 오디오 손실
- 문장 경계 인식 불안정

### Rollback 명령
```bash
git checkout b3e469c
```

---

## [a9ee4b6] - 2026-01-26
**feat: add proactive audio for near real-time translation**

### 방식
- **Live API (WebSocket)** - Proactive Audio 활성화
- `proactive_audio=True`로 모델이 먼저 발화 시작

### 모델
- `gemini-2.5-flash-native-audio-preview-12-2025`

### 주요 기능
- 거의 실시간에 가까운 번역 응답
- 한국어 음성 출력 (TTS)

### 한계
- 여전히 턴 기반 문제 존재
- 긴 발화에서 중간 내용 누락

### Rollback 명령
```bash
git checkout a9ee4b6
```

---

## 버전 선택 가이드

| 상황 | 추천 버전 |
|------|----------|
| 실시간 텍스트 번역 (최신) | **[ed765e3]** - VAD + Thinking OFF |
| 고정 5초 버퍼 방식 | **[7f62895]** - Buffered Mode |
| 한국어 음성 출력 필요 | **[b3e469c]** or **[a9ee4b6]** |
| Live API 실험 | **[b3e469c]** |

---

## 향후 계획
- [x] VAD 기반 세그멘테이션
- [x] Thinking 비활성화로 레이턴시 개선
- [ ] 번역 품질 개선 (문장 경계, 프롬프트 최적화)
- [ ] Semantic Endpointing (의미 단위 세그멘테이션)
