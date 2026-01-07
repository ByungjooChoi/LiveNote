# 🔴 FEEDBACK - 긴급 수정 필요

> **작성일**: 2026-01-07  
> **상태**: 🔴 수정 필요  
> **대상**: Cline (Gemini)

---

## 📋 코드 리뷰 결과

### ✅ 잘 된 부분
- `config.yaml` - 올바른 모델명 설정: `gemini-2.5-flash-native-audio-preview-12-2025`
- `model_fetcher.py` - LIVE_API_MODELS에 올바른 모델 포함
- `gemini_client.py` Line 64-74 - `types.LiveConnectConfig` 올바르게 사용, `speech_config` 추가

---

## 🔴 수정해야 할 사항

### Issue 1: Fallback 모델명 오류
**파일**: `src/translator/gemini_client.py`  
**라인**: 26

**현재 코드**:
```python
self.model_name = "gemini-2.0-flash-exp"
```

**문제점**: fallback 모델이 여전히 2.0 버전임

**수정할 코드**:
```python
self.model_name = "gemini-2.5-flash-native-audio-preview-12-2025"
```

---

### Issue 2: session.send() 호출 방식 오류 (Critical!)
**파일**: `src/translator/gemini_client.py`  
**라인**: 145-152

**에러 메시지**: 
```
AsyncSession.send() takes 1 positional argument but 2 were given
```

**현재 코드 (잘못됨)**:
```python
await session.send({
    "realtime_input": {
        "media_chunks": [{
            "mime_type": "audio/pcm",
            "data": audio_data
        }]
    }
})
```

**문제점**: `google-genai` SDK의 `session.send()`는 dict를 positional argument로 받지 않음. `input=` 키워드 인자 또는 `types` 객체를 사용해야 함.

**수정할 코드**:
```python
await session.send(
    input=types.LiveClientRealtimeInput(
        media_chunks=[
            types.Blob(data=audio_data, mime_type="audio/pcm")
        ]
    )
)
```

> **참고**: `types.LiveClientRealtimeInput`과 `types.Blob`을 사용. 만약 import 에러가 발생하면 `google.genai.types`에서 사용 가능한 클래스를 확인할 것.

---

### Issue 3: Settings 변경이 적용되지 않음
**파일**: `src/ui/main_window.py`  
**라인**: 24, 78-81

**문제점**: 
- `GeminiClient`가 앱 시작 시 `__init__()`에서 한 번만 초기화됨 (Line 24)
- Settings Dialog에서 모델을 변경해도 이미 생성된 `GeminiClient.model_name`은 업데이트되지 않음

**현재 코드**:
```python
# Line 24
self.gemini_client = GeminiClient()

# Line 78-81
def open_settings(self):
    dialog = SettingsDialog(self)
    if dialog.exec():
        self.status_bar.showMessage("Settings saved.")
```

**수정 방법**: Settings 저장 후 `GeminiClient`를 재생성

**수정할 코드**:
```python
def open_settings(self):
    dialog = SettingsDialog(self)
    if dialog.exec():
        # Reinitialize GeminiClient with new settings
        self.gemini_client = GeminiClient()
        self.status_bar.showMessage("Settings saved. Client reinitialized.")
```

---

## 📌 수정 체크리스트

- [ ] `gemini_client.py` Line 26: fallback 모델을 `gemini-2.5-flash-native-audio-preview-12-2025`로 변경
- [ ] `gemini_client.py` Line 145-152: `session.send()`를 `types.LiveClientRealtimeInput` 사용하도록 수정
- [ ] `main_window.py` Line 78-81: Settings 저장 후 `GeminiClient` 재생성 로직 추가

---

## 🔍 테스트 방법

수정 후 다음을 확인:

1. **앱 실행**: `python -m src.main`
2. **Settings에서 모델 변경 테스트**: 
   - 톱니바퀴(⚙️) 클릭 → 모델 드롭다운에서 다른 모델 선택 → Save
   - "Settings saved. Client reinitialized." 메시지 확인
3. **번역 시작**:
   - 오디오 장치 선택 → Start Translation
   - 콘솔에서 `Connecting to Live API with model: gemini-2.5-flash-native-audio-preview-12-2025...` 확인
   - `AsyncSession.send()` 에러가 발생하지 않아야 함
   - 영어 음성 입력 → 한국어 번역 출력

---

## 📝 완료 보고

수정이 완료되면 `docs/ai-pair/SESSION_LOG.md`에 다음 내용을 기록:

```markdown
## Session: Bug Fix - session.send() and Settings Reload
- Fixed fallback model name
- Fixed session.send() to use types.LiveClientRealtimeInput
- Added GeminiClient reinitialization after settings change
- Tested: [테스트 결과]
```

그리고 git commit:
```bash
git add -A
git commit -m "fix: session.send() API call and settings reload"
```
