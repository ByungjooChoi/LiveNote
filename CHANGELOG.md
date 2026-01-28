# LiveNote Changelog

버전별 주요 변경사항을 기록합니다. Rollback 시 참고용.

---

## [NEXT] - 2026-01-28
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
| 안정적인 실시간 텍스트 번역 | **[NEXT]** - Buffered Mode (2.5 Flash) |
| 한국어 음성 출력 필요 | **[b3e469c]** or **[a9ee4b6]** |
| Live API 실험 | **[b3e469c]** |

---

## 향후 계획
- [ ] Gemini Live API + WebSocket Stateful 세션으로 전환
- [ ] `is_sentence_complete` 플래그를 활용한 문장 경계 감지
- [ ] VAD + Semantic Endpointing 하이브리드 적용
