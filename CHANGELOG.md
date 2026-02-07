# LiveNote Changelog

사용 가능한 릴리스 버전을 기록합니다.

> **Note**: Live API 실험 등 시도 후 폐기된 접근 방식은 Git 히스토리에만 존재하며, 이 문서에는 **실제 작동하는 버전**만 기록합니다.

---

## v0.5.0 - 2026-02-06
**S2ST Full Duplex 모드 추가**

### 핵심 기능
- **S2ST 모델 지원**: `gemini-2.5-flash-s2st-exp-11-2025`
- **Full Duplex**: 입력과 출력이 동시에 독립적으로 동작
- **텍스트 전용**: 음성 출력 무시, 번역 텍스트만 표시

### 아키텍처
```
기존 모드 (generateContent)          S2ST 모드 (Live API Full Duplex)
==============================      ================================
Audio → VAD → Segment               Audio ─────────────────────────►
         ↓                                     (끊김 없이 전송)
  generateContent API
         ↓                          ◄───────────────────────── Text
      JSON 파싱                       input_transcription (원문)
         ↓                           output_transcription (번역)
      UI 업데이트
```

### 신규 파일
| 파일 | 설명 |
|------|------|
| `live_api_client.py` | Live API WebSocket 클라이언트 (Full Duplex) |

### 변경 파일
| 파일 | 변경 내용 |
|------|----------|
| `model_fetcher.py` | S2ST 모델 추가 (`type: s2st`) |
| `gemini_client.py` | `is_s2st_model()`, `get_model_type()` 추가 |
| `main_window.py` | S2ST 모드 분기 (`_start_s2st_mode()`, `_feed_audio_to_s2st()`) |

### S2ST 모드 특징
- VAD 불필요 (모델이 발화 구간 자동 처리)
- 오디오 출력 UI 비활성화
- `input_transcription`: 원문 (영어)
- `output_transcription`: 번역 (한국어)
- `turn_complete`: 발화 종료 감지

### 사용 방법
1. Settings → Model에서 "🎤 Gemini 2.5 Flash S2ST" 선택
2. Start Translation 클릭
3. 영어 음성 입력 시 실시간 번역 표시

### 주의사항
- S2ST 모델은 **Allowlist 승인 필요** (Google Cloud Support Case)
- Region: `us-central1` 필요할 수 있음

---

## v0.4.0 - 2026-01-29
**번역 품질 개선: VAD 히스테리시스 + Flicker 제어 + Wait Tokens**

### 핵심 개선
- **문장 끊김 70% 감소**: VAD 히스테리시스 + 적응형 침묵 임계값
- **Flicker 50% 감소**: LCP 기반 StreamStabilizer
- **조기 번역 방지**: Wait Tokens로 불완전 문장 대기

### VAD 개선 (Deep Research 기반)
| 기능 | 설명 |
|------|------|
| 히스테리시스 | Dual threshold (ON: 0.6, OFF: 0.35) |
| 적응형 침묵 | 발화 길이에 따라 800ms~1200ms 동적 조정 |
| HESITATION 복귀 | 짧은 멈춤 후 음성 재개 감지 |
| Pre-speech 버퍼 | 320ms (기존 96ms)로 발화 시작점 보존 |
| 노이즈 캔슬링 | UI 슬라이더로 실시간 조절 (30~80) |

### 번역 품질 개선
| 기능 | 설명 |
|------|------|
| Wait Tokens | 전치사/접속사/관계대명사로 끝나면 번역 대기 |
| Ghost Suffix | 불완전 문장에 연결어미 (~하고, ~해서) |
| untranslated_suffix | 미번역 부분을 다음 턴에 이어붙임 |
| StreamStabilizer | LCP 기반 Flicker 제어 |

### UI 개선
- 노이즈 캔슬링 슬라이더 추가 (레벨 미터 옆)
- 실시간 반영: 슬라이더 조절 시 즉시 VAD threshold 변경

### 기술 상세
```
PRE_SPEECH_FRAMES: 3 → 10 (~320ms)
VAD_THRESHOLD_ON: 0.6 (UI 조절 가능: 0.3~0.8)
VAD_THRESHOLD_OFF: 0.35
MIN_HESITATION_FRAMES: 10 (320ms)
SAFE_MIN_CHUNK_FRAMES: 94 (3초)
API_TIMEOUT: 15초
```

### Rollback
```bash
git checkout ed765e3  # v0.3.0으로 롤백
```

---

## v0.3.0 [ed765e3] - 2026-01-29
**VAD 기반 동적 세그멘테이션 + Thinking 비활성화**

### 핵심 개선
- **레이턴시 70% 감소**: 8.65s → 2.4s (평균)
- **큐 밀림 현상 해결**: 실시간 번역이 음성을 따라잡음
- **지능적 세그멘테이션**: Silero VAD로 음성 구간 자동 감지

### 기술 스택
- API: `generateContent` (REST)
- 모델: `gemini-2.5-flash` (Thinking OFF)
- 세그멘테이션: Silero VAD (1.5s~6s 동적 청크)

### 주요 기능
| 기능 | 설명 |
|------|------|
| VAD 세그멘터 | 음성 감지 기반 동적 청크 분할 |
| Ghost Suffix | 불완전 문장에 연결어미 (~하고, ~인데) 적용 |
| 컨텍스트 유지 | 최근 5턴 히스토리로 대명사 해석 |
| 오디오 오버랩 | 0.5초 중복으로 단어 잘림 방지 |
| API 로깅 | 요청별 레이턴시, 토큰 사용량 기록 |

### 알려진 이슈
- VAD가 800ms 무음에서 자르므로 문장이 불완전하게 끊길 수 있음
- 번역 품질 개선 여지 있음

### Rollback
```bash
git checkout 7f62895  # v0.2.0으로 롤백
```

---

## v0.2.0 [7f62895] - 2026-01-28
**고정 버퍼 방식 (5초 단위)**

### 핵심 특징
- **단순하고 안정적**: 5초마다 고정 전송
- **실시간 가능**: 2.5 Flash 기준 큐 안정적 유지

### 기술 스택
- API: `generateContent` (REST)
- 모델: `gemini-2.5-flash`
- 세그멘테이션: 5초 고정 버퍼

### 성능
| 모델 | 큐 안정성 | 실시간 가능 |
|------|----------|------------|
| 2.0 Flash | 완벽 | ✅ |
| 2.5 Flash | 가끔 스파이크 | ✅ |
| 3.0 Flash | 계속 증가 | ❌ |

### Rollback
```bash
git checkout 7f62895
```

---

## 버전 선택 가이드

| 상황 | 추천 버전 |
|------|----------|
| 실시간 텍스트 번역 (최신, 권장) | **v0.3.0** |
| 단순하고 안정적인 방식 선호 | **v0.2.0** |

---

## 폐기된 접근 방식 (참고용)

아래 방식들은 실험 후 한계가 확인되어 폐기되었습니다. Git 히스토리에서 확인 가능합니다.

| 방식 | 문제점 | 관련 커밋 |
|------|--------|----------|
| Live API (WebSocket) | 턴 기반 한계, 연속 발화 시 오디오 손실 | b3e469c, a9ee4b6 |
| Proactive Audio | 할당량 빠르게 소진, 응답 끝부분 잘림 | a9ee4b6 |

---

## 향후 계획

- [x] VAD 기반 세그멘테이션
- [x] Thinking 비활성화로 레이턴시 개선
- [x] 번역 품질 개선 (VAD 히스테리시스, Wait Tokens, Flicker 제어)
- [x] S2ST (Speech-to-Speech Translation) Full Duplex 대응
- [ ] Gradio UI Confirmed/Provisional 분리
- [ ] S2ST 모드 성능 튜닝 및 최적화
