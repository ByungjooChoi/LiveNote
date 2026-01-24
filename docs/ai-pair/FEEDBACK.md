# 🟡 FEEDBACK - API 응답 성공! 마이크 입력 및 thought 필터링 필요

> **작성일**: 2026-01-08  
> **상태**: 🟡 진행 중 - 마이크 입력 확인 + thought 필터링 필요  
> **대상**: Cline (Gemini)

---

## 📊 테스트 결과

### ✅ 성공한 것
- API 연결 성공
- 30개 이상의 응답 수신
- 텍스트 + 오디오 응답 모두 수신

### ❌ 문제점

#### 1. 마이크 입력이 거의 없음!
```
Audio callback: 100 calls, 0 queued, last RMS: 0.0004  ← 거의 무음!
```
- 사용자가 말했지만 마이크에서 소리가 캡처되지 않음
- `device 0`이 올바른 마이크인지 확인 필요

#### 2. 응답이 "thought" (내부 사고)임
```python
text="""**Commencing Translation Process**...""",
thought=True  ← 이것은 번역이 아님!
```
- 오디오 입력이 없어서 모델이 "준비됐다"는 응답만 보냄
- `thought=True`인 응답은 UI에 표시하면 안 됨

---

## 🔧 수정 1: thought 필터링

**파일**: `src/translator/gemini_client.py`  
**라인**: 141-144

### 현재 코드:
```python
for i, part in enumerate(parts):
    if part.text:
        print(f"   [TEXT] Part {i}: {part.text[:100]}...")
        yield ("text", part.text)
```

### 수정할 코드:
```python
for i, part in enumerate(parts):
    if part.text:
        # Skip "thought" responses - these are internal model thinking, not translation
        if hasattr(part, 'thought') and part.thought:
            print(f"   [THOUGHT] Part {i}: {part.text[:100]}... (skipped)")
            continue
        print(f"   [TEXT] Part {i}: {part.text[:100]}...")
        yield ("text", part.text)
```

---

## 🔧 수정 2: 오디오 장치 확인 로그 추가

**파일**: `src/audio/capture.py`

오디오 캡처 시작 시 장치 정보 출력:

```python
# 캡처 시작 시 장치 정보 출력
device_info = sd.query_devices(device_id, 'input')
print(f"Using audio device: {device_info['name']}")
print(f"  - Default sample rate: {device_info['default_samplerate']}")
print(f"  - Max input channels: {device_info['max_input_channels']}")
```

---

## 🔧 수정 3: 시스템 프롬프트 개선

**파일**: `src/translator/gemini_client.py`  
**라인**: 103-105

### 현재 프롬프트:
```python
system_instruction=types.Content(
    parts=[types.Part(text="You are a real-time interpreter. Listen to English speech and respond with Korean translation in both text and speech. Speak naturally in Korean.")]
)
```

### 개선된 프롬프트:
```python
system_instruction=types.Content(
    parts=[types.Part(text="""You are a real-time English to Korean interpreter.

IMPORTANT RULES:
1. Translate English speech to natural Korean immediately
2. Do NOT explain what you're doing - just translate
3. If you hear silence or unclear audio, say "..." in Korean
4. Keep translations concise and natural

Example:
- English: "Hello, how are you?"
- Korean: "안녕하세요, 잘 지내세요?"
""")]
)
```

---

## 📌 수정 체크리스트

### 필수
- [x] `gemini_client.py`: `thought=True` 응답 필터링 추가
- [x] `capture.py`: 오디오 장치 정보 로그 추가
- [x] `gemini_client.py`: 시스템 프롬프트 개선

### 사용자 확인 필요
- [ ] 올바른 마이크 장치 선택 확인 (UI에서 장치 변경 테스트)

---

## 📝 완료 보고

```bash
python -m src.main
# UI에서 올바른 마이크 장치 선택 확인!
git add -A
git commit -m "feat: filter thought responses and improve system prompt"
```
