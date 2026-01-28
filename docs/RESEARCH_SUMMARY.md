# Gemini Live API 동시통역 구현 연구 요약

## 📊 분석한 프로젝트 목록 (40+ 프로젝트)

### 공식 Google 저장소
| 저장소 | 설명 | 핵심 패턴 |
|--------|------|----------|
| [google-gemini/cookbook](https://github.com/google-gemini/cookbook) | 공식 예제 및 가이드 | proactive_audio 설정, Native Audio |
| [google-gemini/live-api-web-console](https://github.com/google-gemini/live-api-web-console) | React 기반 Live API 데모 | WebSocket 스트리밍, 모듈화 |
| [googleapis/python-genai](https://github.com/googleapis/python-genai) | 공식 Python SDK | send_realtime_input, LiveConnectConfig |
| [GoogleCloudPlatform/generative-ai](https://github.com/GoogleCloudPlatform/generative-ai) | Vertex AI 노트북 | 엔터프라이즈 배포 패턴 |

### 동시통역/번역 관련 프로젝트
| 저장소 | 접근방식 | 우리 프로젝트에 적용 가능성 |
|--------|---------|---------------------------|
| [tristan-mcinnis/Simultaneous-Interpretation](https://github.com/tristan-mcinnis/Simultaneous-Interpretation) | 멀티스레드 파이프라인 (Whisper + OpenAI) | ⭐⭐⭐ context deque 패턴 |
| [folubebe/gemini_realtime_speech_to_text](https://github.com/folubebe/gemini_realtime_speech_to_text) | **5초 청크 버퍼링** | ⭐⭐⭐⭐⭐ 우리와 동일한 전략! |
| [byteresearchcla/RealSI](https://github.com/byteresearchcla/RealSI) | SI 벤치마크 (연구) | ⭐⭐ 평가 지표 참고 |
| [ZackAkil/immersive-language-learning-with-live-api](https://github.com/ZackAkil/immersive-language-learning-with-live-api) | 언어학습 앱 (Immergo) | ⭐⭐⭐ WebSocket 아키텍처 |

### 실시간 음성 스트리밍 프로젝트
| 저장소 | 핵심 기술 | 참고할 패턴 |
|--------|----------|------------|
| [ScaleVoice/gemini-voice-to-voice](https://github.com/ScaleVoice/gemini-voice-to-voice) | asyncio.TaskGroup, 3개 병렬 태스크 | model_speaking 플래그 |
| [pipecat-ai/pipecat](https://github.com/pipecat-ai/pipecat) | 프레임워크 | 우선순위 큐, VAD 설정 |
| [sa-kanean/gemini-live-voice-ai-agent-with-telephony](https://github.com/sa-kanean/gemini-live-voice-ai-agent-with-telephony) | Pipecat + 전화 통합 | 다국어 전환 |
| [heiko-hotz/gemini-multimodal-live-dev-guide](https://github.com/heiko-hotz/gemini-multimodal-live-dev-guide) | 개발자 가이드 | 베스트 프랙티스 |

---

## 🔑 핵심 발견사항

### 1. Gemini Live API의 근본적 한계

```
┌─────────────────────────────────────────────────────────────────┐
│  Gemini Live API = Turn-Based (Half-Duplex)                     │
│                                                                 │
│  [사용자 발화] → [모델 응답] → [사용자 발화] → [모델 응답]       │
│                                                                 │
│  ❌ 동시 처리 불가: 모델 응답 중 새 입력 처리 안됨              │
│  ❌ 인터럽트 발생: 입력 들어오면 응답 중단                       │
└─────────────────────────────────────────────────────────────────┘
```

**결론**: Gemini Live API로는 **진정한 동시통역 불가능**. 순차통역 또는 버퍼링 기반 접근만 가능.

### 2. 업계에서 사용하는 접근방식 비교

| 접근방식 | 지연시간 | 품질 | 복잡도 | 사용 프로젝트 |
|---------|---------|-----|-------|-------------|
| **5초 버퍼링** | 5-10초 | 높음 | 낮음 | folubebe, **우리 프로젝트** |
| 멀티스레드 파이프라인 | 2-5초 | 중간 | 높음 | Simultaneous-Interpretation |
| proactive_audio | 1-3초 | 가변 | 중간 | Google 공식 예제 |
| 듀얼 세션 | 이론적 | 불명 | 매우 높음 | 구현체 없음 |
| S2ST 전용 모델 | <1초 | 높음 | - | CLASI (ByteDance) |

### 3. proactive_audio의 실제 상태

```python
# 공식 설정 방법
CONFIG = {
    "response_modalities": ["AUDIO"],
    "proactivity": {'proactive_audio': True}
}
```

**알려진 문제점** (GitHub Issues에서 발견):
- 할당량 빠르게 소진 (#1275)
- 오디오 응답 끝부분 잘림
- gsans/gemini-2-live-angular: "proactive와 affective 플래그 **비활성화 권장**"

### 4. interrupted 신호 처리 패턴

```python
# 올바른 처리 방법 (cookbook issue #680에서 권장)
if server_content.interrupted:
    # turn_complete이 아닌 interrupted로 오디오 버퍼 클리어!
    while not self.audio_in_queue.empty():
        self.audio_in_queue.get_nowait()
```

### 5. 오디오 설정 표준

```python
# 모든 프로젝트에서 일관됨
INPUT_SAMPLE_RATE = 16000   # 16kHz (음성 인식 표준)
OUTPUT_SAMPLE_RATE = 24000  # 24kHz (고품질 재생)
FORMAT = pyaudio.paInt16    # 16-bit PCM
CHANNELS = 1                # 모노
CHUNK_SIZE = 512            # 32ms 청크 (또는 1024)
```

---

## 🏆 RealSI 벤치마크에서 배운 것

ByteDance 연구팀의 동시통역 벤치마크 결과:

| 시스템 | VIP 점수 (%) | 비고 |
|--------|-------------|------|
| SeamlessStreaming (Meta) | 2-13% | 오픈소스 최고 |
| 상용 시스템 1-4 | 10-42% | 익명 |
| **CLASI (ByteDance)** | **78-81%** | 사람 수준 |
| 전문 통역사 | ~80% | 기준선 |

**핵심 인사이트**:
- 기존 캐스케이드 시스템(ASR→번역→TTS)은 오류 누적
- LLM 기반 에이전트가 돌파구
- 허용 가능한 지연: **2-4초**
- Gemini Live API는 이 벤치마크에서 테스트되지 않음 (턴 기반이라 SI에 부적합)

---

## 📐 우리 프로젝트에 적용할 아키텍처 패턴

### 패턴 1: 5초 버퍼링 (현재 구현 중) ✅

```
[마이크] → [버퍼 (5초)] → [Gemini API] → [응답] → [스피커]
              ↓
         [다음 버퍼 수집 시작]
```

**장점**: 단순, 안정적, 오디오 손실 없음
**단점**: 5-10초 지연

### 패턴 2: 멀티스레드 파이프라인 (Simultaneous-Interpretation 스타일)

```
[마이크] → [STT Thread] → [번역 Thread] → [TTS Thread] → [스피커]
              ↓               ↓               ↓
         [Queue]         [Queue]         [Queue]
              ↓
      [Context Deque (최근 10개 청크)]
```

**장점**: 더 낮은 지연, 컨텍스트 유지
**단점**: 복잡함, Gemini Live API 미사용

### 패턴 3: model_speaking 플래그 (gemini-voice-to-voice 스타일)

```python
model_speaking = False

async def capture_audio():
    while True:
        if not model_speaking:  # 모델 응답 중이 아닐 때만 전송
            data = await mic.read()
            await session.send_realtime_input(audio=data)

async def receive_audio():
    async for response in session.receive():
        if response.audio:
            model_speaking = True
            play(response.audio)
        if response.turn_complete:
            model_speaking = False
```

**장점**: 에코/피드백 방지
**단점**: 모델 응답 중 입력 버림

### 패턴 4: 우선순위 큐 (Pipecat 스타일)

```python
class PriorityQueue:
    HIGH_PRIORITY = 1  # InterruptionFrame, SystemFrame
    LOW_PRIORITY = 2   # AudioFrame, TextFrame

    async def put(self, frame):
        if isinstance(frame, SystemFrame):
            await super().put((HIGH_PRIORITY, frame))
        else:
            await super().put((LOW_PRIORITY, frame))
```

**장점**: 인터럽션 즉시 처리
**단점**: 구현 복잡

---

## 🛠 권장 구현 전략

### 단기 (현재): 5초 버퍼링 완성
- `buffer_manager.py` 테스트 및 안정화
- 오버플로우 방지 검증
- UI에 지연 표시기 추가

### 중기: VAD 최적화
```python
config = LiveConnectConfig(
    realtime_input_config=RealtimeInputConfig(
        automatic_activity_detection=AutomaticActivityDetection(
            disabled=False,
            start_of_speech_sensitivity=StartSensitivity.START_SENSITIVITY_HIGH,
            end_of_speech_sensitivity=EndSensitivity.END_SENSITIVITY_LOW,
            silence_duration_ms=1000  # 1초 침묵 후 턴 종료
        )
    )
)
```

### 장기: S2ST 모델 대기
- `gemini-2.5-flash-s2st-*` 모델 승인 대기
- Vertex AI 통합 준비
- 진정한 동시통역은 S2ST로만 가능

---

## 📚 참고 자료

### 공식 문서
- [Gemini Live API Guide](https://ai.google.dev/gemini-api/docs/live-guide)
- [Vertex AI Live API](https://cloud.google.com/vertex-ai/generative-ai/docs/live-api)

### 핵심 GitHub Issues
- [#680: interrupted로 버퍼 클리어](https://github.com/google-gemini/cookbook/issues/680)
- [#1224: turn_complete 후 세션 멈춤](https://github.com/googleapis/python-genai/issues/1224)
- [#1275: proactive_audio 할당량 문제](https://github.com/googleapis/python-genai/issues/1275)
- [#1279: transcription 필드 누락](https://github.com/googleapis/python-genai/issues/1279)

### 연구 논문
- [RealSI: Benchmark for Simultaneous Interpretation](https://arxiv.org/abs/2407.21646)
- [Simul-LLM: Simultaneous Translation Framework](https://openreview.net/forum?id=UqR2dFmfRB)

---

*Generated: 2026-01-27*
*Project: LiveNote - Real-time English to Korean Translation*
