# Session Log

## 2026-01-07
### 구현 내용
- **Phase 1: 프로젝트 초기 설정**
  - 디렉토리 구조 생성
  - `requirements.txt`, `config.yaml`, `.env.example`, `src/main.py` 생성
- **Phase 2: 오디오 캡처 모듈 구현**
  - `src/audio/device_manager.py`: 입력 장치 목록 조회 기능
  - `src/audio/capture.py`: 실시간 오디오 캡처 및 VAD(침묵 필터링) 기능
- **Phase 3: Gemini API 통합**
  - `src/config/settings_manager.py`: 설정 관리
  - `src/config/secure_storage.py`: API 키 보안 관리 (환경 변수)
  - `src/translator/model_fetcher.py`: Gemini 모델 목록 조회
  - `src/translator/gemini_client.py`: Gemini API 클라이언트 기본 구조

## 2026-01-07 (Phase 4 Update)
### 구현 내용
- **Phase 3.5: 피드백 반영 (Live API 마이그레이션)**
  - `requirements.txt`: `google-generativeai` -> `google-genai` 변경
  - `src/translator/gemini_client.py`: `google.genai` 패키지 및 WebSocket 기반 Live API로 재구현
  - `src/translator/model_fetcher.py`: `google.genai` 클라이언트로 마이그레이션
- **Phase 4: UI 구현**
  - `src/ui/settings_dialog.py`: API 키 및 모델 선택 설정 다이얼로그 구현
  - `src/ui/audio_selector.py`: 오디오 장치 선택 콤보박스 위젯 구현
  - `src/ui/main_window.py`: 메인 UI, 비동기 번역 제어 및 실시간 텍스트 표시 구현
  - `src/main.py`: `MainWindow` 호출 로직 추가

## 2026-01-07 (Phase 5 Update)
### 구현 내용
- **Phase 5: 파일 저장 모듈 구현**
  - `src/utils/file_writer.py`: 번역 텍스트를 실시간으로 파일에 저장하는 기능 구현 (세션별 파일 생성, 타임스탬프 포함)
  - `src/ui/main_window.py`: `FileWriter`를 통합하여 번역 시작 시 세션 파일 생성, 번역 텍스트 수신 시 파일 쓰기 연동

## 2026-01-07 (Bugfix)
### 수정 내용
- **버그 수정**: `src/translator/gemini_client.py`에서 `gemini-2.5` 모델이 Live API 지원 모델로 인식되지 않는 문제 해결.
- **문서 수정**: `README.md`의 실행 명령어를 `python -m src.main`으로 수정하여 경로 문제 해결 안내.

## 2026-01-07 (Completion)
### 프로젝트 완료
- **Phase 5 완료**: 파일 저장 기능 구현 및 검증 완료.
- **핵심 기능 구현 완료**: 오디오 캡처, Gemini Live API 번역, UI, 파일 저장 등 모든 주요 기능이 구현됨.

## 2026-01-07 (Hotfix)
### 수정 내용
- **모델명 수정**: `gemini-2.5-flash-native-audio-preview-12-2025`로 올바른 모델명 적용.
- **모델 목록 개선**: `model_fetcher.py`에 Live API 지원 모델 상수(`LIVE_API_MODELS`)를 추가하고, API 키가 없거나 조회 결과에 없을 때 강제로 추가되도록 수정.

## 2026-01-07 (Bugfix - Audio Format)
### 수정 내용
- **Live API Config 수정**: `google.genai.types.LiveConnectConfig`를 사용하여 `response_modalities`와 `speech_config`를 명시적으로 설정.
- **모델 변경**: `gemini-2.5` Native Audio 모델 연결 문제로 인해 `gemini-2.0-flash-exp`로 모델 변경.

## 2026-01-07 (Feature - Native Audio Support)
### 구현 내용
- **Native Audio 모델 지원**: `gemini-2.5-flash-native-audio-preview-12-2025` 모델 사용 시 `response_modalities=["TEXT", "AUDIO"]`로 설정하여 에러 해결.
- **오디오 응답 처리**: `gemini_client.py` 및 `main_window.py`를 수정하여 텍스트와 오디오 응답(청크)을 구분하여 처리하도록 개선.

## 2026-01-07 (Phase 6 - Final Features)
### 구현 내용
- **오디오 출력 (Audio Output)**
  - `src/audio/device_manager.py`: 출력 장치 목록 조회 기능 추가.
  - `src/audio/playback.py`: `sounddevice` 기반 오디오 재생 모듈 구현 (볼륨 조절, 음소거 지원).
  - `src/ui/main_window.py`: 오디오 출력 장치 선택, 볼륨 슬라이더, 음소거 버튼 UI 추가 및 연동.
- **세션 관리 (Session Management)**
  - `src/translator/gemini_client.py`: 15분 세션 제한을 위한 타임아웃 모니터링 및 자동 재연결 로직 구현 (`SessionExpiredError` 사용).

## 2026-01-07 (Phase 7 - UI/UX Improvement)
### 구현 내용
- **UI 개선**:
  - `src/ui/main_window.py`: 오디오 레벨 미터, 상태 인디케이터, 오디오 미리보기 버튼 추가.
  - `src/audio/capture.py`: 오디오 레벨(dB) 계산 및 콜백 기능 추가.
- **UX 기능**:
  - 무음 감지 경고 로직 추가 (5초 이상 무음 시 상태 표시).
  - 실시간 상태 업데이트 (Capturing, Sending, Receiving 등).

## 2026-01-08 (Bugfix & UI Improvement)
### 수정 내용
- **스레드 안전성 확보 (Bug 0)**: `capture.py`에서 UI 업데이트 콜백(`on_level_update`)을 `loop.call_soon_threadsafe()`로 호출하도록 수정하여 Qt 스레드 경고 해결.
- **상태 인디케이터 개선 (Bug 1)**: `Translating` 상태가 실제 텍스트 수신 시에만 표시되도록 수정.
- **디버깅 로그 강화 (Bug 0.5)**: `capture.py`에 오디오 콜백 호출 횟수 및 큐잉 상태 로그 추가.
- **UI/UX 개선**: `main_window.py`에 오디오 레벨 미터, 프리뷰 버튼, 상태 인디케이터 추가 및 UI 레이아웃 개선.
