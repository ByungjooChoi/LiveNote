# 🔴 FEEDBACK - 긴급 버그 수정!

> **작성일**: 2026-01-08  
> **상태**: 🔴 긴급 - API 파라미터 오류  
> **대상**: Cline (Gemini)

---

## 📊 오류 로그

```
Error sending audio loop: AsyncSession.send_realtime_input() got an unexpected keyword argument 'media_chunks'
Receive loop cancelled. Total responses: 0
```

---

## 🐛 버그: `media_chunks` → `media`

**파일**: `src/translator/gemini_client.py`  
**라인**: 223-227

### 현재 코드 (버그):
```python
await session.send_realtime_input(
    media_chunks=[
        types.Blob(data=audio_data, mime_type="audio/pcm")
    ]
)
```

### 수정할 코드:
```python
await session.send_realtime_input(
    media=types.Blob(data=audio_data, mime_type="audio/pcm")
)
```

**변경사항**:
1. `media_chunks` → `media`
2. 리스트 `[...]` 제거 - 단일 Blob 객체만 전달

---

## 📌 수정 체크리스트

### 필수 (지금 바로!)
- [ ] `media_chunks=[...]` → `media=types.Blob(...)` 변경

### 완료됨 ✅
- [x] `turns=[]` → `turns=None` 변경
- [x] `has_sent_audio` 플래그 추가

---

## 📝 완료 보고

```bash
git add -A
git commit -m "fix: correct send_realtime_input parameter name"
```
