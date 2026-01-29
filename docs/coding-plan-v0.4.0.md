# LiveNote v0.4.0 코딩 플랜

## 📋 개요

**목표:** 두 Deep Research 보고서(Gemini + Perplexity)의 분석 결과를 통합하여 번역 품질 개선

**기간:** 3주 (Phase별 1주)

**주요 변경 파일:**
- `src/audio/vad_segmenter.py` - VAD 히스테리시스 + 적응형 로직
- `src/translator/prompts.py` - Wait Tokens + untranslated_suffix
- `src/translator/gemini_client.py` - Flicker 제어 로직
- `src/translator/context_manager.py` - 컨텍스트 윈도우 확장
- `src/ui/gradio_app.py` (신규) - Confirmed/Provisional UI 분리

---

## Phase 1: VAD 히스테리시스 + Flicker 제어 (Week 1)

### Task 1.1: VAD 히스테리시스 (Dual Threshold) 적용

**파일:** `src/audio/vad_segmenter.py`

**현재 문제:**
```python
# 현재: 단일 임계값
VAD_THRESHOLD = 0.5
is_speech = speech_prob >= self.VAD_THRESHOLD
```

**개선안:**
```python
# 히스테리시스: 이중 임계값
VAD_THRESHOLD_ON = 0.6   # 음성 시작 기준 (높음)
VAD_THRESHOLD_OFF = 0.35  # 음성 종료 기준 (낮음)

# 상태에 따라 다른 임계값 적용
if self._state == VADState.IDLE:
    is_speech = speech_prob >= self.VAD_THRESHOLD_ON
else:  # SPEECH_ACTIVE, HESITATION
    is_speech = speech_prob >= self.VAD_THRESHOLD_OFF
```

**수정 위치:**
- Line 79: `VAD_THRESHOLD = 0.5` → 두 개로 분리
- Line 281: `is_speech = speech_prob >= self.VAD_THRESHOLD` → 조건부 로직

**예상 효과:** HESITATION ↔ SPEECH_ACTIVE 발진(Oscillation) 70% 감소

---

### Task 1.2: 적응형 SILENCE_THRESHOLD 추가

**파일:** `src/audio/vad_segmenter.py`

**현재 문제:**
```python
SILENCE_FRAMES = 25  # 800ms 고정
```

**개선안:**
```python
def _get_adaptive_silence_frames(self) -> int:
    """발화 길이에 따라 침묵 임계값 동적 조정"""
    utterance_ms = self._speech_frames * self.FRAME_DURATION_MS

    if utterance_ms > 5000:  # 5초 이상: 긴 발화
        return 37  # 1200ms
    elif utterance_ms > 3000:  # 3-5초: 중간 발화
        return 31  # 1000ms
    else:  # 3초 미만: 짧은 발화
        return 25  # 800ms (기본값)
```

**수정 위치:**
- Line 87 아래: 새 메서드 추가
- Line 360, 392: `self.SILENCE_FRAMES` → `self._get_adaptive_silence_frames()`

**예상 효과:** 문장 중간 끊김 추가 30% 감소

---

### Task 1.3: HESITATION 복귀 가능성 판단 추가

**파일:** `src/audio/vad_segmenter.py`

**현재 문제:**
```python
# _handle_hesitation에서 음성 재개 판단이 단순함
if is_speech:
    self._transition_to(VADState.SPEECH_ACTIVE)
```

**개선안:**
```python
def _is_hesitation_recovery_likely(self, speech_prob: float) -> bool:
    """HESITATION 상태에서 음성 복귀 가능성 추정"""
    hesitation_ms = self._silence_frames * self.FRAME_DURATION_MS

    # 500ms 이내 HESITATION: 복귀 가능성 높음
    if hesitation_ms < 500:
        return True

    # VAD 점수 0.2-0.4: 약한 음성 신호 (복귀 예상)
    if 0.2 <= speech_prob <= 0.4:
        return True

    return False
```

**수정 위치:**
- Line 374 `_handle_hesitation` 메서드 내부 확장

---

### Task 1.4: Flicker 제어 - Stability Score 기반

**파일:** `src/translator/gemini_client.py` (신규 클래스 추가)

**현재 문제:** 스트리밍 번역 시 출력이 계속 변경됨

**개선안:**
```python
class StreamStabilizer:
    """스트리밍 출력 안정화"""

    def __init__(self, stability_threshold: float = 0.6):
        self.stability_threshold = stability_threshold
        self.last_output = ""
        self.confirmed_text = ""

    def should_update(self, new_text: str, confidence: float = 0.5) -> tuple[bool, str, str]:
        """
        출력 업데이트 여부 판단

        Returns:
            (should_update, confirmed_part, provisional_part)
        """
        if not self.last_output:
            self.last_output = new_text
            return True, "", new_text

        # LCP (최장 공통 접두사) 계산 - 단어 단위
        common_prefix = self._get_word_boundary_lcp(self.last_output, new_text)
        prefix_ratio = len(common_prefix) / max(len(new_text), 1)

        # Stability score = 0.8 * prefix_ratio + 0.2 * confidence
        stability_score = 0.8 * prefix_ratio + 0.2 * confidence

        if stability_score > self.stability_threshold:
            self.confirmed_text = common_prefix
            provisional = new_text[len(common_prefix):]
            self.last_output = new_text
            return True, self.confirmed_text, provisional

        return False, self.confirmed_text, ""

    def _get_word_boundary_lcp(self, s1: str, s2: str) -> str:
        """단어 경계 기준 LCP 반환"""
        min_len = min(len(s1), len(s2))
        common_len = 0

        for i in range(min_len):
            if s1[i] == s2[i]:
                common_len += 1
            else:
                break

        # 단어 경계로 조정 (공백 기준)
        common = s1[:common_len]
        last_space = common.rfind(' ')

        if last_space != -1:
            return common[:last_space]
        return ""

    def reset(self):
        self.last_output = ""
        self.confirmed_text = ""
```

**수정 위치:**
- Line 517 이후에 새 클래스 추가
- `translate_audio_streaming` 메서드에서 stabilizer 사용

---

## Phase 2: 프롬프트 최적화 + 컨텍스트 확장 (Week 2)

### Task 2.1: Wait Tokens 조건부 출력 프롬프트

**파일:** `src/translator/prompts.py`

**현재 문제:**
```python
# 불완전 문장 처리 지시가 불명확
"If the audio cuts off mid-sentence, DO NOT guess the ending."
```

**개선안:**
```python
SYSTEM_PROMPT = """You are an expert simultaneous interpreter translating English audio to Korean in real-time.

CORE RULES:

1. **Latency Priority:** Translate concisely.

2. **WAIT CONDITIONS - DO NOT TRANSLATE if transcript ends with:**
   - Relative pronouns: which, that, who, whom, whose
   - Prepositions: in, on, at, to, with, for, from, by, about
   - Conjunctions: and, but, or, so, because, although, while
   - Fillers: uh, um, er, like, you know
   - Articles before noun: a, an, the (without following noun)

   In these cases, set is_complete=false and put the trailing words in untranslated_suffix.

3. **Incomplete Sentences:**
   - Use Korean connecting endings (Ghost Suffixes):
     - '~하고' (and, listing)
     - '~인데' (but, contrast)
     - '~해서' (so, because)
     - '~며' (while, and)

4. **Context Awareness:**
   - Use previous context to resolve pronouns
   - Maintain terminology consistency

5. **Natural Korean:**
   - Use spoken Korean style
   - Match formality level

OUTPUT FORMAT:
Return JSON with these fields:
- transcript: English text heard
- translation: Korean translation (only stable parts)
- is_complete: true if grammatically complete, false otherwise
- confidence: 0.0-1.0 translation confidence
- untranslated_suffix: trailing words not yet translated (if incomplete)"""
```

**수정 위치:** Line 16-49 전체 교체

---

### Task 2.2: JSON 스키마 확장

**파일:** `src/translator/prompts.py`

**현재 문제:**
```python
RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "transcript": {...},
        "translation": {...},
        "is_complete": {...}
    }
}
```

**개선안:**
```python
RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "transcript": {
            "type": "STRING",
            "description": "The English speech recognized from the audio"
        },
        "translation": {
            "type": "STRING",
            "description": "The Korean translation (only stable, complete parts)"
        },
        "is_complete": {
            "type": "BOOLEAN",
            "description": "True if sentence is grammatically complete"
        },
        "confidence": {
            "type": "NUMBER",
            "description": "Translation confidence score (0.0-1.0)"
        },
        "untranslated_suffix": {
            "type": "STRING",
            "description": "Trailing words not yet translated due to incompleteness"
        }
    },
    "required": ["transcript", "translation", "is_complete", "confidence", "untranslated_suffix"]
}
```

**수정 위치:** Line 56-73 교체

---

### Task 2.3: 응답 파서 확장

**파일:** `src/translator/gemini_client.py`

**현재 문제:**
```python
def parse_translation_response(response_text: str) -> Optional[dict]:
    if not all(k in result for k in ['transcript', 'translation', 'is_complete']):
        return None
```

**개선안:**
```python
def parse_translation_response(response_text: str) -> Optional[dict]:
    try:
        result = json.loads(response_text.strip())

        # 필수 필드 검증
        required = ['transcript', 'translation', 'is_complete']
        if not all(k in result for k in required):
            print(f"[PARSE] Missing required fields: {result.keys()}")
            return None

        # 선택 필드 기본값 설정
        result.setdefault('confidence', 0.5)
        result.setdefault('untranslated_suffix', '')

        return result
    except json.JSONDecodeError as e:
        print(f"[PARSE] JSON decode error: {e}")
        return None
```

**수정 위치:** Line 57-85 수정

---

### Task 2.4: 컨텍스트 윈도우 EN/KO 쌍 포맷

**파일:** `src/translator/prompts.py`

**현재 문제:**
```python
def build_context_prompt(context_history: list[dict], max_turns: int = 5) -> str:
    lines.append(f"Turn {i} {status}:")
    lines.append(f"  EN: {en_text}")
    lines.append(f"  KR: {kr_text}")
```

**개선안:** (이미 구현됨, 유지)

---

### Task 2.5: untranslated_suffix Re-injection

**파일:** `src/translator/context_manager.py`

**현재 문제:** untranslated_suffix가 다음 턴에 전달되지 않음

**개선안:**
```python
@dataclass
class TranslationTurn:
    transcript: str
    translation: str
    is_complete: bool
    confidence: float = 0.5
    untranslated_suffix: str = ""
    timestamp: float = field(default_factory=time.time)

class ContextManager:
    def __init__(self, ...):
        ...
        self._pending_suffix: str = ""  # 다음 턴에 붙일 suffix

    def add_turn(self, transcript, translation, is_complete,
                 confidence=0.5, untranslated_suffix=""):
        # suffix가 있으면 다음 컨텍스트에 포함
        if untranslated_suffix:
            self._pending_suffix = untranslated_suffix
            print(f"[CONTEXT] Pending suffix: '{untranslated_suffix}'")

        # 이전 suffix가 있으면 transcript 앞에 붙임
        if self._pending_suffix and not is_complete:
            transcript = self._pending_suffix + " " + transcript
            self._pending_suffix = ""

        # 기존 로직...
```

**수정 위치:** Line 17-31 (dataclass), Line 83-138 (add_turn)

---

## Phase 3: UI 분리 + 버그 수정 + 리뷰 (Week 3)

### Task 3.1: Gradio UI Confirmed/Provisional 분리

**파일:** `src/ui/gradio_app.py` (신규 또는 기존 UI 파일)

**개선안:**
```python
def render_translation(confirmed: str, provisional: str) -> str:
    """확정/임시 텍스트를 HTML로 렌더링"""
    return f"""
    <div style="font-size: 18px; line-height: 1.8;">
        <span style="color: black; font-weight: bold;">{confirmed}</span>
        <span style="color: gray; font-style: italic;">{provisional}</span>
    </div>
    """
```

---

### Task 3.2: 버그 수정 - HESITATION 발진 방지

**파일:** `src/audio/vad_segmenter.py`

**현재 버그 (로그 분석):**
```log
[VAD] State: SPEECH_ACTIVE → HESITATION
[VAD] State: HESITATION → SPEECH_ACTIVE
[VAD] State: SPEECH_ACTIVE → HESITATION
(반복...)
```

**원인:** `_handle_speech_active`에서 5프레임(~160ms) 무음이면 바로 HESITATION으로 전환

**수정안:**
```python
def _handle_speech_active(self, frame_bytes: bytes, is_speech: bool) -> Optional[bytes]:
    ...
    if not is_speech:
        self._silence_frames += 1

        # 버그 수정: MIN_HESITATION_FRAMES 추가 (10프레임 = 320ms)
        MIN_HESITATION_FRAMES = 10
        if self._silence_frames >= MIN_HESITATION_FRAMES:
            self._transition_to(VADState.HESITATION)
```

**수정 위치:** Line 369: `if self._silence_frames >= 5:` → `>= 10`

---

### Task 3.3: 버그 수정 - 짧은 세그먼트 조기 종료

**파일:** `src/audio/vad_segmenter.py`

**현재 버그 (로그 분석):**
```log
[VAD] Segment #3: 69632 bytes (2176ms, 68 frames)  ← 2.2초로 짧음
```

**원인:** MIN_CHUNK_FRAMES(47) 도달 후 SILENCE_FRAMES(25) 지나면 바로 종료

**수정안:**
```python
def _handle_hesitation(self, frame_bytes: bytes, is_speech: bool) -> Optional[bytes]:
    ...
    if self._silence_frames >= self._get_adaptive_silence_frames():
        # 버그 수정: 최소 3초(94프레임) 이상일 때만 종료
        SAFE_MIN_FRAMES = 94  # 3초
        if self._speech_frames >= SAFE_MIN_FRAMES:
            return self._flush_segment()
        else:
            # 3초 미만이면 계속 대기 (HESITATION 유지)
            print(f"[VAD] Waiting for more speech ({self._speech_frames} < {SAFE_MIN_FRAMES} frames)")
```

**수정 위치:** Line 392-398

---

### Task 3.4: 버그 수정 - 22초 응답 지연

**파일:** `src/translator/gemini_client.py`

**현재 버그 (로그 분석):**
```log
[GEMINI] Response in 22.70s  ← 비정상적으로 긴 응답
```

**원인:** Thinking mode가 완전히 비활성화되지 않았거나, 큰 오디오 청크

**확인 사항:**
```python
# 현재 설정 (Line 46)
thinking_config=types.ThinkingConfig(thinking_budget=0)
```

**추가 방어 로직:**
```python
# translate_audio 메서드에 타임아웃 추가
async def translate_audio(self, audio_data: bytes, ...):
    ...
    try:
        response = await asyncio.wait_for(
            asyncio.to_thread(self.client.models.generate_content, ...),
            timeout=15.0  # 15초 타임아웃
        )
    except asyncio.TimeoutError:
        print(f"[GEMINI] Request timeout after 15s")
        self._error_count += 1
        return None
```

**수정 위치:** Line 323 주변

---

### Task 3.5: 코드 리뷰 체크리스트

**리뷰 항목:**

1. **VAD 상태 전이 검증**
   - [ ] IDLE → PRE_SPEECH: threshold_on 적용 확인
   - [ ] SPEECH_ACTIVE → HESITATION: MIN_HESITATION_FRAMES 적용 확인
   - [ ] HESITATION → IDLE: adaptive_silence + SAFE_MIN_FRAMES 적용 확인

2. **프롬프트 검증**
   - [ ] Wait Tokens 리스트 완전성 (전치사, 접속사, 관계대명사)
   - [ ] JSON 스키마 필드 일치 확인
   - [ ] 예제 출력 형식 검증

3. **Flicker 제어 검증**
   - [ ] stability_score 계산 정확성
   - [ ] 단어 경계 LCP 동작 확인
   - [ ] reset 호출 시점 확인

4. **에러 핸들링 검증**
   - [ ] JSON 파싱 실패 시 기본값 설정
   - [ ] API 타임아웃 처리
   - [ ] 큐 full 시 graceful degradation

5. **통합 테스트**
   - [ ] 5분 TED 강연 오디오로 end-to-end 테스트
   - [ ] 문장 끊김 발생 빈도 측정
   - [ ] Flicker 발생 빈도 측정

---

## 📁 변경 파일 요약

| 파일 | 변경 내용 | Phase |
|------|----------|-------|
| `src/audio/vad_segmenter.py` | 히스테리시스, 적응형 threshold, 버그 수정 | 1, 3 |
| `src/translator/prompts.py` | Wait Tokens, JSON 스키마 확장 | 2 |
| `src/translator/gemini_client.py` | StreamStabilizer, 파서 확장, 타임아웃 | 1, 2, 3 |
| `src/translator/context_manager.py` | untranslated_suffix 지원 | 2 |
| `src/ui/gradio_app.py` | Confirmed/Provisional UI | 3 |

---

## 🎯 성공 기준

| 지표 | 현재 | 목표 |
|------|------|------|
| 문장 끊김 (2초 미만 세그먼트) | 빈번 | 70% 감소 |
| HESITATION 발진 | 빈번 | 80% 감소 |
| Flickering | 높음 | 50% 감소 |
| 평균 세그먼트 길이 | 4.5초 | 5.2초 이상 |

---

*작성일: 2026-01-29*
*버전: v0.4.0 코딩 플랜*

---

## ✅ 구현 완료 (2026-01-29)

### Phase 1 완료:
- [x] Task 1.1: VAD 히스테리시스 (Dual Threshold) - `VAD_THRESHOLD_ON=0.6`, `VAD_THRESHOLD_OFF=0.35`
- [x] Task 1.2: 적응형 SILENCE_THRESHOLD - `_get_adaptive_silence_frames()` 메서드 추가
- [x] Task 1.3: HESITATION 복귀 가능성 판단 - `_is_hesitation_recovery_likely()` 메서드 추가
- [x] Task 1.4: StreamStabilizer - LCP 기반 Flicker 제어 클래스 추가

### Phase 2 완료:
- [x] Task 2.1: Wait Tokens 프롬프트 최적화 - 조건부 미번역 지시 추가
- [x] Task 2.2: JSON 스키마 확장 - `confidence`, `untranslated_suffix` 필드 추가
- [x] Task 2.3: 응답 파서 확장 - 선택 필드 기본값 설정
- [x] Task 2.5: untranslated_suffix Re-injection - ContextManager 확장

### Phase 3 완료:
- [x] Task 3.2: HESITATION 발진 방지 - `MIN_HESITATION_FRAMES=10` (320ms)
- [x] Task 3.3: 짧은 세그먼트 방지 - `SAFE_MIN_CHUNK_FRAMES=94` (3초)
- [x] Task 3.4: 15초 API 타임아웃 추가

### 미완료 (UI 관련):
- [ ] Task 3.1: Gradio UI Confirmed/Provisional 분리 - 별도 UI 작업 필요

---

## ✅ v0.4.2 추가 구현 (2026-01-29)

### Gemini 중기 제안 구현:

**1. PRE_SPEECH_FRAMES 확장 (즉시 구현)**
- [x] `PRE_SPEECH_FRAMES = 3` → `PRE_SPEECH_FRAMES = 10` (~320ms)
- Gemini 권장: 200-300ms의 pre-speech 버퍼로 발화 시작점 보존

**2. UI 노이즈 캔슬링 슬라이더 (자동 감지 대신 수동 조절)**
- [x] `set_noise_canceling(level)` / `get_noise_canceling()` 메서드 추가
- [x] UI 슬라이더 추가 (레벨 미터 옆, 30~80 범위)
- [x] 기본값: 60 (=0.6)
- [x] 실시간 반영: 슬라이더 조절 시 즉시 VAD threshold 변경

**UI 배치:**
```
[Audio Selector] [Level Meter ████] [🔇 슬라이더 60] [Preview]
```

**권장 수치:**
| 환경 | 값 | 설명 |
|------|-----|------|
| 조용한 방 | 50-60 | 기본값, 민감하게 감지 |
| 사무실 | 65-75 | 배경 대화/에어컨 무시 |
| 시끄러운 곳 | 70-80 | 강한 필터링 |
