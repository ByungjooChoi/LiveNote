# 🔴🔴🔴 FEEDBACK - 핵심 수정 누락! 다시 확인 필요!

> **작성일**: 2026-01-08  
> **상태**: 🔴🔴🔴 재수정 필요 - 핵심 코드 누락됨!  
> **대상**: Cline (Gemini)

---

## ⚠️ 이전 작업에서 누락된 사항

**FEEDBACK.md를 다시 읽고 아래 코드를 정확히 추가하세요!**

### ❌ 누락 1: float32 → int16 변환

**로그 증거:**
```
Sent 10 audio chunks to API (4096 bytes each)  ← 4096은 float32!
```
- **4096 bytes** = float32 그대로 전송됨 ❌
- **2048 bytes**가 되어야 int16으로 변환된 것 ✅

---

## 🔧 수정 1: float32 → int16 변환 (필수!)

**파일**: `src/translator/gemini_client.py`  
**함수**: `_send_audio_loop()`  
**라인**: 189-191

### 현재 코드 (잘못됨):
```python
# Convert numpy array to bytes
if hasattr(audio_data, 'tobytes'):
    audio_data = audio_data.tobytes()
```

### 수정할 코드 (정확히 복사하세요!):
```python
# Convert numpy array to bytes
if hasattr(audio_data, 'tobytes'):
    # CRITICAL: Convert float32 to int16 for Gemini Live API
    # Gemini expects 16-bit signed PCM audio, not float32!
    if audio_data.dtype == np.float32:
        # Scale float32 (-1.0 to 1.0) to int16 (-32768 to 32767)
        audio_data = (audio_data * 32767).astype(np.int16)
    audio_data = audio_data.tobytes()
```

---

## 🔧 수정 2: API 응답 전체 로깅 (필수!)

**파일**: `src/translator/gemini_client.py`  
**함수**: `_stream_audio_session()`  
**라인**: 129 부근

### 현재 코드:
```python
async for response in session.receive():
    response_count += 1
    print(f"Response #{response_count} received")
    
    if response.server_content:
```

### 수정할 코드 (정확히 복사하세요!):
```python
async for response in session.receive():
    response_count += 1
    print(f"Response #{response_count} received")
    
    # Log full response for debugging - see what API returns
    print(f"   [RAW] {response}")
    
    if response.server_content:
```

---

## 📌 수정 체크리스트 (반드시 확인!)

- [ ] `gemini_client.py` 라인 189-191: `audio_data.dtype == np.float32` 체크 추가
- [ ] `gemini_client.py` 라인 189-191: `(audio_data * 32767).astype(np.int16)` 변환 추가
- [ ] `gemini_client.py` 라인 129 부근: `print(f"   [RAW] {response}")` 추가

---

## 🔍 수정 후 예상 로그

### 변경 전 (현재):
```
Sent 10 audio chunks to API (4096 bytes each)  ← 4096 = float32
```

### 변경 후 (기대):
```
Sent 10 audio chunks to API (2048 bytes each)  ← 2048 = int16 ✅
Response #1 received
   [RAW] LiveServerMessage(setup_complete=...)  ← API 응답 보임!
```

---

## ⚠️ 주의사항

1. **numpy import 확인**: 파일 상단에 `import numpy as np`가 있는지 확인 (이미 있음)
2. **정확한 위치에 추가**: `audio_data.tobytes()` 호출 **직전**에 변환 코드 추가
3. **들여쓰기 주의**: if 문 안에 정확히 들여쓰기

---

## 📝 완료 보고

```bash
git add -A
git commit -m "fix: convert float32 to int16 and add RAW response logging"
```
