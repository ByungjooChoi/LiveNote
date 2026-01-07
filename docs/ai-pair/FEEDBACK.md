# 📝 코드 리뷰 피드백 (FEEDBACK)

**리뷰어**: Senior Architect (Claude)
**최종 리뷰 일시**: 2026-01-07
**대상 커밋**: `b005f25` (모델 검증 로직 수정 후)

---

## 🔴 긴급 수정 필요: 모델명 및 드롭다운 문제

### 문제 1: 잘못된 모델명 사용

Google 공식 문서 확인 결과, 현재 사용 중인 모델명이 잘못되었습니다.

**참고**: https://ai.google.dev/gemini-api/docs/models#gemini-2.5-flash-live

| 위치 | 현재 (잘못됨) | 올바른 모델명 |
|------|--------------|--------------|
| `config.yaml` | `gemini-2.5-flash-preview-native-audio-dialog` | `gemini-2.5-flash-native-audio-preview-12-2025` |
| `gemini_client.py` (fallback) | 〃 | 〃 |

### 문제 2: 모델 드롭다운에 2.5 모델 없음

`model_fetcher.py`의 fallback 모델 목록에 Live API 모델이 없습니다.

**원인 분석**:
- Google API는 **API 키 없이는 모델 목록 조회 불가** (403 PERMISSION_DENIED)
- API 호출이 실패하면 fallback 목록을 사용
- 현재 fallback에는 2.5 모델이 없음

---

### 수정 지시 1: config.yaml

**파일**: `config.yaml` Line 9

```yaml
# 변경 전
model: "gemini-2.5-flash-preview-native-audio-dialog"

# 변경 후
model: "gemini-2.5-flash-native-audio-preview-12-2025"
```

---

### 수정 지시 2: gemini_client.py

**파일**: `src/translator/gemini_client.py` Line 25

```python
# 변경 전
self.model_name = "gemini-2.5-flash-preview-native-audio-dialog"

# 변경 후
self.model_name = "gemini-2.5-flash-native-audio-preview-12-2025"
```

---

### 수정 지시 3: model_fetcher.py

**파일**: `src/translator/model_fetcher.py`

**3-1. Live API 모델 상수 추가** (클래스 내부, `_cached_models` 아래):
```python
# Live API compatible models (may not appear in models.list())
# See: https://ai.google.dev/gemini-api/docs/models#gemini-2.5-flash-live
LIVE_API_MODELS = [
    {"name": "gemini-2.5-flash-native-audio-preview-12-2025", "displayName": "Gemini 2.5 Flash Native Audio (Dec 2025)"},
    {"name": "gemini-2.0-flash-exp", "displayName": "Gemini 2.0 Flash Live (Exp)"},
]
```

**3-2. API 키 없을 때 fallback 수정** (Line 28-31):
```python
if not api_key:
    # Return Live API models + fallback when no API key
    return ModelFetcher.LIVE_API_MODELS + [
        {"name": "gemini-1.5-flash-latest", "displayName": "Gemini 1.5 Flash"},
    ]
```

**3-3. API 결과에 Live API 모델 병합** (Line 56 이후에 추가):
```python
# Ensure Live API models are always available (may not be in models.list())
for live_model in ModelFetcher.LIVE_API_MODELS:
    if not any(m['name'] == live_model['name'] for m in models):
        models.insert(0, live_model)
```

**3-4. 에러 발생 시 fallback 수정** (Line 63-64):
```python
return ModelFetcher._cached_models if ModelFetcher._cached_models else ModelFetcher.LIVE_API_MODELS
```

---

---

### 수정 지시 4: gemini_client.py - Live API Config 형식 수정

**문제**: Live API 연결 시 다음 에러 발생:
```
Cannot extract voices from a non-audio request.
```

**원인**: Native Audio 모델은 `types` 객체를 사용한 config가 필요할 수 있음.

**파일**: `src/translator/gemini_client.py`

**4-1. import 추가** (Line 5 이후):
```python
from google.genai import types
```

**4-2. config 형식 변경** (Line 63-72 대체):
```python
config = types.LiveConnectConfig(
    response_modalities=["TEXT"],
    system_instruction=types.Content(
        parts=[types.Part(text="You are a real-time interpreter. Translate English speech to Korean immediately as you hear it. Provide translations in a natural, conversational Korean style.")]
    )
)
```

**4-3. 만약 위 수정으로도 안 되면**, Native Audio 모델에 speech_config 추가:
```python
config = types.LiveConnectConfig(
    response_modalities=["TEXT"],
    speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
        )
    ),
    system_instruction=types.Content(
        parts=[types.Part(text="You are a real-time interpreter. Translate English speech to Korean immediately as you hear it. Provide translations in a natural, conversational Korean style.")]
    )
)
```

**4-4. 또는 일반 Live API 모델 사용** (가장 안전한 방법):
- config.yaml의 모델을 `gemini-2.0-flash-exp`로 변경
- 이 모델은 dict config로도 동작함

---

### 우선순위: 🔴 Critical

이 문제들로 인해:
1. 잘못된 모델명으로 API 호출이 실패할 수 있음
2. 드롭다운에서 원하는 모델을 선택할 수 없음
3. Live API 연결 실패

**순서대로 수정 후 테스트:**
1. 먼저 수정 지시 4-2 적용 (types 객체 사용)
2. 안 되면 4-3 적용 (speech_config 추가)
3. 그래도 안 되면 4-4 적용 (gemini-2.0-flash-exp 모델 사용)

---

## 🎉 Phase 5 리뷰 결과: **승인 (APPROVED)** ✅

### 리뷰 대상 파일

| 파일 | 상태 | 비고 |
|------|------|------|
| [`src/utils/file_writer.py`](../../src/utils/file_writer.py) | ✅ 승인 | 빈 텍스트 필터링 추가됨 |
| [`src/ui/main_window.py`](../../src/ui/main_window.py) | ✅ 승인 | FileWriter 연동 완료 |

### 구현 검토 결과

#### 1. [`file_writer.py`](../../src/utils/file_writer.py) - 파일 저장 모듈 ⭐

**우수 사항:**
- ✅ settings_manager와 잘 통합됨 (`output.save_directory`, `output.filename_format`)
- ✅ 디렉토리 자동 생성 (`ensure_directory()`)
- ✅ Line buffering (`buffering=1`) 사용으로 실시간 저장
- ✅ `flush()` 호출로 크래시 시에도 데이터 보존
- ✅ 예외 처리 포함
- ✅ 세션 시작/종료 메시지 포함
- ✅ 영어 주석 사용 (.roorules 준수)

**Architect가 추가한 개선:**
```python
# Skip empty or whitespace-only text
if not text or not text.strip():
    return
```

#### 2. [`main_window.py`](../../src/ui/main_window.py) 통합 ⭐

**우수 사항:**
- ✅ Line 12, 25: FileWriter import 및 인스턴스 생성
- ✅ Line 109-110: `auto_save` 설정 확인 후 세션 시작
- ✅ Line 134: `stop_translation()`에서 세션 종료
- ✅ Line 165: `process_audio_stream()`에서 텍스트를 파일에 기록

**Architect가 추가한 개선:**
```python
# Skip empty text
if not text or not text.strip():
    continue
```

### 최종 결론

Phase 5 파일 저장 모듈이 성공적으로 구현되었습니다!
빈 텍스트 필터링 로직을 추가하여 불필요한 빈 줄이 파일에 기록되지 않도록 개선했습니다.

---

## 📋 Phase 진행 상황 (업데이트됨)

| Phase | 상태 | 비고 |
|-------|------|------|
| Phase 1: 초기 설정 | ✅ 완료 | |
| Phase 2: 오디오 캡처 | ✅ 완료 | |
| Phase 3: Gemini API 통합 | ✅ 완료 | Live API로 마이그레이션 |
| Phase 4: UI 구현 | ✅ 완료 | |
| Phase 5: 파일 저장 | ✅ 완료 | file_writer.py 구현 완료 |
| Phase 6: 메인 앱 통합 | ✅ 완료 | |
| Phase 7: 최적화 | ⏳ 미진행 | |
| Phase 8: 테스트/문서화 | ⏳ 미진행 | |

---

## 🚀 다음 단계: Phase 7-8

### Phase 7: 성능 최적화
1. **메모리 관리**
   - 장시간 실행 시 텍스트 영역 최대 라인 수 제한
   - 오디오 버퍼 오버플로우 방지

2. **보안 강화** (선택)
   - `keyring` 라이브러리로 API 키 저장 마이그레이션

### Phase 8: 테스트 및 문서화
1. **통합 테스트**
   - 실제 마이크/오디오 장치로 테스트
   - Zoom 통화 중 WASAPI Loopback 캡처 테스트
   - 장시간 실행 안정성 테스트

2. **문서화**
   - README.md 사용법 업데이트
   - 트러블슈팅 가이드 추가

---

**Senior Architect의 코멘트:**

🎉 **Phase 5 승인 완료!**

파일 저장 모듈이 깔끔하게 구현되었습니다. 빈 텍스트 필터링을 추가하여 더 깔끔한 출력 파일을 생성합니다.

이제 핵심 기능은 모두 완성되었습니다! 🎊

Phase 7-8은 선택적 최적화 및 테스트 단계입니다.
실제 Zoom 통화로 통합 테스트를 진행해보시고, 문제가 있으면 알려주세요!

화이팅! 🚀

---
---

## [Archive] Phase 3.5-4 리뷰 결과: **승인 (APPROVED)** ✅

### 이전 피드백 반영 상태

| 피드백 항목 | 상태 |
|------------|------|
| Live API 마이그레이션 (Critical) | ✅ 완료 |
| google-genai 패키지 전환 | ✅ 완료 |
| WebSocket 기반 실시간 스트리밍 | ✅ 완료 |
| 다크 모드 UI 구현 | ✅ 완료 |
| 설정 다이얼로그 (API 키, 모델 선택) | ✅ 완료 |

### 우수 구현 사항

#### 1. [`gemini_client.py`](../../src/translator/gemini_client.py) - Live API 구현 ⭐
```python
async with self.client.aio.live.connect(model=self.model_name, config=config) as session:
    send_task = asyncio.create_task(self._send_audio_loop(session, audio_queue))
    async for response in session.receive():
        yield response.text
```
- `client.aio.live.connect()` 사용으로 WebSocket 스트리밍 정상 구현 ✅
- float32 → int16 PCM 변환 로직 포함 ✅
- 에러 핸들링 및 태스크 취소 처리 적절 ✅

#### 2. [`main_window.py`](../../src/ui/main_window.py) - 메인 UI ⭐
- qasync의 `@asyncSlot()` 데코레이터 사용으로 비동기 버튼 핸들링 ✅
- 다크 모드 스타일 (#1E1E1E 배경, #007ACC 강조색) 적용 ✅
- API 키 미설정 시 설정 다이얼로그 자동 표시 ✅
- 상태 바에 실시간 상태 표시 ✅

#### 3. [`settings_dialog.py`](../../src/ui/settings_dialog.py) - 설정 화면 ⭐
- HANDOFF.md 스펙대로 구현:
  - API Provider: "Google Gemini" (고정) ✅
  - API Key: 비밀번호 마스킹 ✅
  - Model: 드롭다운 + 새로고침 버튼 ✅
- 깔끔한 다크 모드 UI ✅

#### 4. [`main.py`](../../src/main.py) - 앱 진입점
- qasync `QEventLoop`으로 PyQt + asyncio 통합 ✅
- 간결하고 명확한 구조 ✅

#### 5. [`requirements.txt`](../../requirements.txt) 업데이트
- `google-genai>=0.3.0` (새 패키지) ✅
- `qasync>=0.27.1` 추가 ✅

### 개선 권장사항 (선택적)

#### 1. 🟢 [Low] 오디오 PCM 변환 최적화
현재 `_send_audio_loop`의 변환 로직이 약간 복잡합니다.
더 깔끔하게 정리 가능:
```python
# Simplified conversion
if isinstance(audio_data, np.ndarray) and audio_data.dtype == np.float32:
    audio_bytes = (audio_data * 32767).astype(np.int16).tobytes()
else:
    audio_bytes = audio_data
```

#### 2. 🟢 [Low] Model Fallback 메시지
Line 22-24에서 모델명 검증 시 콘솔에만 출력됩니다.
추후 UI에서도 알림 표시 권장.

---

## 📋 Phase 진행 상황

| Phase | 상태 | 비고 |
|-------|------|------|
| Phase 1: 초기 설정 | ✅ 완료 | |
| Phase 2: 오디오 캡처 | ✅ 완료 | |
| Phase 3: Gemini API 통합 | ✅ 완료 | Live API로 마이그레이션 |
| Phase 4: UI 구현 | ✅ 완료 | |
| Phase 5: 파일 저장 | ⏳ 미구현 | `file_writer.py` 필요 |
| Phase 6: 메인 앱 통합 | ✅ 완료 | |
| Phase 7: 최적화 | ⏳ 미진행 | |
| Phase 8: 테스트/문서화 | ⏳ 미진행 | |

---

## 🚀 다음 단계

### Phase 5 구현 지시
1. `src/utils/file_writer.py` 구현:
   - 번역 텍스트를 타임스탬프와 함께 저장
   - 파일 형식: `[HH:MM:SS] 번역문`
   - 세션별 파일 자동 생성

2. `main_window.py`에 파일 저장 기능 연동

### 테스트 권장
1. 실제 마이크/오디오 장치로 테스트
2. API 응답 속도 및 번역 품질 확인
3. 장시간 실행 시 메모리 누수 체크

---

**Senior Architect의 코멘트:**

🎉 **훌륭한 작업입니다!**

이전 피드백의 가장 중요한 사항인 **Live API 마이그레이션**이 완벽하게 반영되었습니다.
UI도 HANDOFF.md 스펙대로 깔끔하게 구현되었고, qasync를 활용한 비동기 처리도 적절합니다.

Phase 5 (파일 저장) 구현 후 실제 Zoom 통화로 통합 테스트를 진행해주세요!

화이팅! 🚀

---
---

# 📝 [Archive] Phase 1-3 리뷰 (2026-01-07)

**대상 커밋**: `c08f921` (Phase 1-3)

---

## ✅ 잘 구현된 부분

### 1. 코드 구조 및 스타일
- 디렉토리 구조가 HANDOFF.md 지침을 잘 따름 ✅
- 모든 코드와 주석이 영어로 작성됨 (.roorules 준수) ✅
- 클래스와 메서드에 적절한 docstring 작성됨 ✅

### 2. device_manager.py
- sounddevice를 사용한 입력 장치 목록 조회 기능 잘 구현됨 ✅
- 에러 핸들링 포함 ✅
- 테스트용 `__main__` 블록 포함 ✅

### 3. audio/capture.py
- asyncio Queue 기반 비동기 처리 잘 구현됨 ✅
- RMS 기반 VAD (Voice Activity Detection) 구현됨 ✅
- 스레드 세이프한 `call_soon_threadsafe` 사용 ✅

### 4. settings_manager.py
- Singleton 패턴으로 전역 설정 관리 잘 구현됨 ✅
- YAML 파일 로드/저장 기능 ✅
- 기본값 fallback 제공 ✅

---

## ⚠️ 수정 필요 사항

### 1. 🔴 [Critical] gemini_client.py - Live API 미사용

**문제**: 현재 구현은 일반 `chat.send_message_async()`를 사용하고 있습니다. 
HANDOFF.md에서 명시한 **Gemini Live API (Multimodal Live API)**를 사용해야 합니다.

**현재 코드** (Line 77-79):
```python
response = await self.chat_session.send_message_async(
    {"mime_type": "audio/wav", "data": audio_data}, 
    stream=True
)
```

**수정 방향**:
```python
# Live API 사용 (WebSocket 기반)
async with client.aio.live.connect(model=model_name, config=config) as session:
    await session.send({"realtime_input": {"media_chunks": [...]}})
    async for response in session.receive():
        yield response.text
```

**참고 문서**: https://ai.google.dev/api/multimodal-live

---

### 2. 🟡 [Medium] model_fetcher.py - API 키 없이 모델 조회

**문제**: HANDOFF.md에서 "API 키 없이도 동작해야 함"이라고 명시했습니다.
현재 구현은 API 키 없으면 하드코딩된 기본 목록만 반환합니다.

**수정 방향**:
- Google AI API는 API 키 없이도 public 모델 목록 조회가 가능합니다
- `https://generativelanguage.googleapis.com/v1beta/models` 엔드포인트를 직접 HTTP 호출
- 또는 사용자에게 API 키 설정을 먼저 요청하는 것도 가능 (차선책)

---

### 3. 🟡 [Medium] secure_storage.py - 보안 강화 필요

**문제**: HANDOFF.md에서 "Windows DPAPI 또는 Credential Manager 사용"을 명시했습니다.
현재 구현은 단순히 `.env` 파일에 평문 저장합니다.

**현재 코드**:
```python
set_key(env_path, "GEMINI_API_KEY", api_key)
```

**수정 방향** (Phase 4 UI 구현 후 진행 가능):
```python
import keyring  # pip install keyring

class SecureStorage:
    SERVICE_NAME = "LiveNote"
    
    @staticmethod
    def save_api_key(api_key):
        keyring.set_password(SecureStorage.SERVICE_NAME, "gemini_api_key", api_key)
    
    @staticmethod
    def get_api_key():
        return keyring.get_password(SecureStorage.SERVICE_NAME, "gemini_api_key")
```

**결정**: 현재는 `.env` 방식으로 진행하고, Phase 7 최적화 단계에서 `keyring` 라이브러리로 마이그레이션 예정

---

### 4. 🟢 [Low] audio/capture.py - 리샘플링 로직 미구현

**문제**: HANDOFF.md에서 "16kHz, 모노로 리샘플링"을 명시했습니다.
현재 코드는 sounddevice의 기본 샘플레이트를 그대로 사용합니다.

**현재 코드** (Line 56-61):
```python
self.stream = sd.InputStream(
    device=self.device_id,
    channels=self.channels,
    samplerate=self.sample_rate,  # 16000으로 설정됨
    ...
)
```

**분석**: sounddevice는 `samplerate` 파라미터를 통해 하드웨어에서 직접 리샘플링을 요청합니다.
다만, 장치가 16kHz를 지원하지 않으면 에러가 발생할 수 있습니다.

**수정 방향** (선택적):
- `samplerate=None`으로 설정 후 네이티브 샘플레이트로 캡처
- `scipy.signal.resample` 또는 `librosa.resample`로 후처리 리샘플링
- 현재 구현도 대부분의 장치에서 동작하므로 일단 유지

---

## 🎯 다음 단계 지시

### Phase 4 진행 전 필수 수정사항:
1. **gemini_client.py**를 Live API 기반으로 재구현 (Critical)
   - `google.genai` 패키지의 `client.aio.live.connect()` 사용
   - WebSocket 기반 실시간 오디오 스트리밍 구현

### Phase 4에서 구현할 사항:
1. `src/ui/settings_dialog.py` - API 설정 다이얼로그 (다크 모드)
2. `src/ui/main_window.py` - 메인 윈도우 레이아웃
3. `src/ui/audio_selector.py` - 오디오 장치 선택 UI

### 추후 개선 사항 (Phase 7):
- `secure_storage.py`를 `keyring` 라이브러리로 마이그레이션
- 오디오 리샘플링 후처리 로직 추가 (필요시)

---

## 📋 체크리스트 업데이트 요청

`HANDOFF.md`의 Phase 1-3 체크리스트를 완료 처리하되, 
다음 항목은 미완료로 표시해주세요:

- [ ] `src/translator/gemini_client.py` - Live API 재구현 필요

---

**Senior Architect의 코멘트:**

전반적으로 좋은 구현입니다! 👍

가장 중요한 수정사항은 **gemini_client.py의 Live API 전환**입니다.
현재 구현은 일반 채팅 API로 되어 있어 실시간 오디오 번역에 적합하지 않습니다.

Live API로 전환 후 Phase 4 UI 구현을 진행해주세요.
질문이 있으면 문의해주세요!

화이팅! 🚀
