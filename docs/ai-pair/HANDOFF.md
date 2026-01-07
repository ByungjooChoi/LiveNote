# 🎯 작업 지시서 (HANDOFF)

## 📋 프로젝트 개요
**LiveNote**: Zoom 통화 실시간 영어→한국어 음성 번역 데스크톱 앱

### 핵심 요구사항
- ⚡ **최우선 목표**: 실시간 번역 속도 (빠른 대화 따라잡기)
- 🎙️ Zoom 통화 오디오를 실시간 캡처
- 🤖 Gemini Native Flash Audio 2.5를 이용한 영어→한국어 번역
- 🖥️ 화면에 번역 결과 실시간 표시
- 💾 번역 내용을 텍스트 파일로 자동 저장
- 🎚️ 오디오 소스 선택 기능

---

## 🏗️ 기술 스택 결정

### 추천 스택: Python + PyQt6
**선정 이유:**
1. **빠른 성능**: 네이티브 GUI, 비동기 처리로 실시간 응답성 확보
2. **오디오 처리**: sounddevice/pyaudio를 통한 저지연 오디오 캡처
3. **API 통합**: Gemini API Python SDK 지원 우수
4. **개발 속도**: 프로토타입부터 완성까지 빠른 개발 가능

### 핵심 라이브러리
```
- PyQt6: GUI 프레임워크 (네이티브 성능)
- google-generativeai: Gemini API 클라이언트
- sounddevice: 실시간 오디오 캡처 (WASAPI 지원)
- asyncio: 비동기 처리 (논블로킹 스트리밍)
- numpy: 오디오 데이터 처리
```

---

## ✅ 구현 체크리스트

### Phase 1: 프로젝트 초기 설정
- [ ] 프로젝트 디렉토리 구조 생성
  ```
  LiveNote/
  ├── src/
  │   ├── main.py              # 앱 진입점
  │   ├── ui/
  │   │   ├── main_window.py   # 메인 윈도우
  │   │   ├── settings_dialog.py # 설정 다이얼로그 (API 키, 모델 선택)
  │   │   └── audio_selector.py # 오디오 소스 선택 UI
  │   ├── audio/
  │   │   ├── capture.py       # 오디오 캡처 모듈
  │   │   └── device_manager.py # 오디오 디바이스 관리
  │   ├── translator/
  │   │   ├── gemini_client.py # Gemini API 클라이언트
  │   │   └── model_fetcher.py # Gemini 모델 리스트 조회
  │   ├── config/
  │   │   ├── settings_manager.py # 설정 저장/로드 관리
  │   │   └── secure_storage.py   # API 키 암호화 저장
  │   └── utils/
  │       └── file_writer.py   # 텍스트 파일 저장
  ├── output/                   # 번역 텍스트 저장 디렉토리
  ├── requirements.txt
  ├── config.yaml              # 설정 파일
  └── README.md
  ```

- [ ] `requirements.txt` 생성
  ```txt
  PyQt6>=6.6.0
  google-generativeai>=0.3.0
  sounddevice>=0.4.6
  numpy>=1.24.0
  pyyaml>=6.0
  python-dotenv>=1.0.0
  ```

- [ ] `.env.example` 생성 (Gemini API 키 설정용)
  ```
  GEMINI_API_KEY=your_api_key_here
  ```

- [ ] `config.yaml` 생성 (기본 설정)
  ```yaml
  audio:
    sample_rate: 16000  # Gemini에 최적화된 샘플레이트
    channels: 1         # 모노
    buffer_size: 1024   # 낮은 버퍼 크기로 지연 최소화
  
  translation:
    # 기본 모델: Gemini 2.5 Flash (Native Audio 지원)
    # 실제 모델명은 model_fetcher.py에서 API로 조회한 목록에서 선택
    # 후보 모델명들:
    #   - gemini-2.5-flash-preview-native-audio-dialog (Native Audio)
    #   - gemini-2.5-flash-preview (일반)
    #   - gemini-2.0-flash-live-001 (Live API)
    model: "gemini-2.5-flash-preview-native-audio-dialog"
    language_from: "en"
    language_to: "ko"
    streaming: true
  
  output:
    auto_save: true
    save_directory: "output"
    filename_format: "transcript_%Y%m%d_%H%M%S.txt"
  ```

  > ⚠️ **참고**: 정확한 모델명은 Google AI API에서 주기적으로 변경될 수 있음.
  > `model_fetcher.py`가 API에서 최신 모델 리스트를 조회하여 드롭다운에 표시하고,
  > 사용자가 선택한 모델로 자동 업데이트됨.

### Phase 2: 오디오 캡처 모듈 구현
- [ ] `src/audio/device_manager.py` 구현
  - [ ] 시스템의 모든 오디오 입력 장치 목록 가져오기
  - [ ] Windows WASAPI 루프백 지원 (시스템 오디오 캡처용)
  - [ ] 가상 오디오 케이블 감지 (VB-Audio Cable, Voicemeeter 등)
  - [ ] 장치 이름, ID, 채널 수, 샘플레이트 정보 반환

- [ ] `src/audio/capture.py` 구현
  - [ ] sounddevice를 사용한 실시간 오디오 스트림 캡처
  - [ ] 선택된 오디오 소스에서 오디오 데이터 읽기
  - [ ] 16kHz, 모노로 리샘플링 (Gemini 최적화)
  - [ ] 오디오 버퍼를 큐(Queue)에 넣어 비동기 처리 준비
  - [ ] VAD (Voice Activity Detection) 간단 구현 - 침묵 구간 필터링으로 불필요한 API 호출 방지
  - [ ] 에러 핸들링: 장치 연결 끊김, 버퍼 오버플로우 처리

### Phase 3: Gemini API 통합
- [ ] `src/translator/model_fetcher.py` 구현 (API 키 없이도 동작해야 함)
  - [ ] Google AI API에서 사용 가능한 모델 목록 조회
  - [ ] 모델 리스트 API 엔드포인트: `GET https://generativelanguage.googleapis.com/v1beta/models`
  - [ ] 오디오 입력을 지원하는 모델만 필터링 (inputTokenLimit, supportedGenerationMethods 확인)
  - [ ] 모델 정보 캐싱 (앱 시작 시 로드, 주기적 업데이트 - 예: 24시간마다)
  - [ ] 네트워크 오류 시 캐시된 모델 목록 사용

- [ ] `src/translator/gemini_client.py` 구현
  - [ ] Gemini API 클라이언트 초기화 (API 키 로드)
  - [ ] **Gemini Live API (Multimodal Live API)** 사용 - 오디오 스트리밍 지원
    - [ ] WebSocket 또는 스트리밍 연결 설정
    - [ ] 실시간으로 오디오 청크를 Gemini에 전송
    - [ ] 스트리밍 응답 수신 (partial results 포함)
  - [ ] 프롬프트 엔지니어링:
    ```
    "You are a real-time interpreter. Translate English speech to Korean immediately as you hear it.
    Provide translations in a natural, conversational Korean style.
    If you hear technical terms or proper nouns, transliterate them appropriately."
    ```
  - [ ] 에러 처리: API 할당량 초과, 네트워크 오류, 타임아웃
  - [ ] 재연결 로직 구현

- [ ] `src/config/settings_manager.py` 구현
  - [ ] 설정 파일 (config.yaml) 로드/저장
  - [ ] API 키, 선택된 모델, 오디오 설정 등 관리
  - [ ] 기본값 제공 (첫 실행 시)

- [ ] `src/config/secure_storage.py` 구현
  - [ ] API 키를 로컬에 암호화하여 저장
  - [ ] Windows: DPAPI 또는 Windows Credential Manager 사용
  - [ ] 키 저장/조회/삭제 기능

### Phase 4: UI 구현 (PyQt6)
- [ ] `src/ui/settings_dialog.py` 구현 (다크 모드 UI)
  - [ ] **API Configuration 섹션** (참고 이미지처럼 구현):
    - [ ] "API Provider" 레이블: "Google Gemini" (고정 텍스트, 변경 불가)
    - [ ] "Gemini API Key" 입력 필드:
      - [ ] 비밀번호 마스킹 (●●●●●●●●●●)
      - [ ] 입력 시 실시간 유효성 검증 (API 테스트 호출)
      - [ ] "This key is stored locally and only used to make API requests" 안내 문구
    - [ ] "Model" 드롭다운:
      - [ ] Google에서 조회한 모델 리스트를 드롭다운으로 표시
      - [ ] 새로고침 버튼 (모델 목록 다시 조회)
      - [ ] 선택한 모델 저장
  - [ ] 설정 저장/취소 버튼
  - [ ] 변경사항 있을 시 저장 확인 다이얼로그

- [ ] `src/ui/main_window.py` 구현
  - [ ] 메인 윈도우 레이아웃:
    - [ ] 상단: 오디오 소스 선택 콤보박스 + 시작/정지 버튼 + ⚙️ 설정 버튼
    - [ ] 중앙: 실시간 번역 텍스트 표시 영역 (QTextEdit, 스크롤 가능, 읽기 전용)
    - [ ] 하단: 상태 바 (연결 상태, 현재 모델명, 처리 속도, 오류 메시지)
  - [ ] 번역 텍스트 실시간 업데이트:
    - [ ] 새 번역이 오면 즉시 화면에 추가
    - [ ] 자동 스크롤 (최신 내용이 항상 보이도록)
    - [ ] 타임스탬프 표시 옵션
  - [ ] "다크 모드" UI 스타일 적용 (첨부 이미지 스타일 참고)
    - [ ] 배경색: #1E1E1E (어두운 회색)
    - [ ] 입력 필드 배경: #2D2D2D
    - [ ] 텍스트 색상: #FFFFFF (흰색)
    - [ ] 강조 색상: #007ACC (파란색)
  - [ ] 윈도우 최소화 시에도 백그라운드 처리 유지
  - [ ] 첫 실행 시 설정 다이얼로그 자동 표시 (API 키 미설정 시)

- [ ] `src/ui/audio_selector.py` 구현
  - [ ] 오디오 장치 목록을 콤보박스에 표시
  - [ ] 장치 변경 시 오디오 캡처 재시작
  - [ ] 새로고침 버튼 (장치 목록 다시 스캔)
  - [ ] 선택된 장치의 샘플 오디오 레벨 표시 (VU 미터)

### Phase 5: 파일 저장 모듈
- [ ] `src/utils/file_writer.py` 구현
  - [ ] 번역 텍스트를 타임스탬프와 함께 저장
  - [ ] 파일 형식: `[HH:MM:SS] 원문 | 번역문` 형태
  - [ ] 실시간 쓰기 (버퍼링 최소화)
  - [ ] 세션별 파일 자동 생성 (타임스탬프 기반 파일명)
  - [ ] 파일 저장 경로 설정 옵션
  - [ ] 저장 실패 시 에러 핸들링 및 재시도

### Phase 6: 메인 앱 통합
- [ ] `src/main.py` 구현
  - [ ] PyQt6 애플리케이션 초기화
  - [ ] 모든 모듈 임포트 및 연결
  - [ ] asyncio 이벤트 루프와 PyQt 이벤트 루프 통합 (qasync 사용)
  - [ ] 시작/정지 버튼 로직:
    - [ ] 시작: 오디오 캡처 → Gemini 스트리밍 시작
    - [ ] 정지: 스트림 종료, 파일 저장 완료
  - [ ] 애플리케이션 종료 시 리소스 정리
  - [ ] 에러 발생 시 사용자에게 알림

### Phase 7: 최적화 및 성능 튜닝
- [ ] **레이턴시 최소화**:
  - [ ] 오디오 버퍼 크기 최적화 (512-1024 샘플)
  - [ ] Gemini API 호출 간격 조정 (너무 잦으면 느림, 너무 드물면 지연)
  - [ ] 스레드/프로세스 풀 사용 검토
- [ ] **메모리 관리**:
  - [ ] 오래된 번역 텍스트 자동 아카이빙
  - [ ] 메모리 누수 체크
- [ ] **에러 복구**:
  - [ ] 네트워크 끊김 시 자동 재연결
  - [ ] 오디오 디바이스 연결 해제 시 사용자 알림

### Phase 8: 테스트 및 문서화
- [ ] 단위 테스트 작성 (주요 모듈별)
- [ ] 통합 테스트: 실제 Zoom 통화로 테스트
- [ ] 성능 측정: 음성 입력 → 번역 출력 레이턴시 측정
- [ ] `README.md` 작성:
  - [ ] 설치 방법
  - [ ] Gemini API 키 설정 방법
  - [ ] 사용 방법
  - [ ] 가상 오디오 케이블 설정 가이드 (Zoom 오디오 캡처용)
  - [ ] 트러블슈팅

---

## 🎯 추가 고려사항

### 1. Zoom 오디오 캡처 방법
**문제**: Zoom은 기본적으로 시스템 오디오로 출력되지만, 마이크 입력은 직접 캡처 불가

**해결책**:
- **Option A (추천)**: 가상 오디오 케이블 사용
  - VB-Audio Cable 또는 Voicemeeter 설치
  - Zoom 오디오 출력을 가상 케이블로 라우팅
  - 앱에서 가상 케이블을 입력 소스로 선택
  - README에 설정 가이드 포함 필수

- **Option B**: Windows WASAPI 루프백
  - 스피커 출력을 직접 캡처
  - 장점: 추가 소프트웨어 불필요
  - 단점: 다른 시스템 사운드도 함께 캡처됨

### 2. 실시간 성능 최적화 전략
- **청크 크기 조정**: 오디오를 몇 초 단위로 묶어 전송 (1-3초 권장)
- **부분 결과 활용**: Gemini의 partial results를 즉시 표시 (완전한 번역 전에도)
- **로컬 버퍼링**: 네트워크 지연 시 로컬에서 큐잉
- **우선순위 스레드**: 오디오 캡처 스레드를 높은 우선순위로 설정

### 3. 번역 품질 향상
- **Context 유지**: 이전 대화 내용을 컨텍스트로 제공 (최근 N개 문장)
- **화자 구분**: 가능하면 여러 화자를 구분해서 표시
- **전문 용어 사전**: 자주 나오는 기술 용어나 고유명사 매핑

### 4. 사용자 경험 개선
- **핫키 지원**: 전역 단축키로 시작/정지 (예: Ctrl+Shift+R)
- **알림**: 번역 시작/종료 시 시스템 알림
- **설정 UI**: 샘플레이트, 버퍼 크기, API 키 등을 GUI에서 변경 가능
- **통계 표시**: 처리한 오디오 시간, API 호출 횟수, 평균 레이턴시

### 5. 보안 및 프라이버시
- **API 키 보호**: 환경 변수나 암호화된 설정 파일에 저장
- **로컬 처리 옵션**: 추후 Whisper 등 로컬 모델 통합 고려
- **데이터 보존 정책**: 저장된 텍스트 파일 자동 삭제 옵션

### 6. 배포 및 패키징
- **PyInstaller**: 단일 실행 파일로 패키징
- **자동 업데이트**: 추후 버전 관리 시스템 고려
- **설치 프로그램**: NSIS나 Inno Setup으로 인스톨러 제작

---

## ⚠️ 기술적 주의사항

### Gemini API 사용 시 주의점
1. **Rate Limiting**: 분당 API 호출 제한 확인, 초과 시 대기 로직 필요
2. **Audio Format**: Gemini가 지원하는 포맷 (16kHz, 16-bit PCM 권장)
3. **Streaming vs Batch**: Live API의 스트리밍 모드 사용 (낮은 레이턴시)
4. **비용**: API 사용량 모니터링 기능 추가 고려

### 오디오 처리 시 주의점
1. **샘플레이트 변환**: sounddevice에서 리샘플링 품질 확인
2. **버퍼 언더런/오버런**: 콜백 함수에서 빠르게 처리
3. **동기화**: 오디오 타임스탬프와 번역 결과 타임스탬프 매칭

### 크로스 플랫폼 고려사항
- 현재는 Windows 우선이지만, 추후 macOS/Linux 지원 시:
  - 오디오 백엔드 추상화 (WASAPI/CoreAudio/ALSA)
  - 파일 경로 처리 (pathlib 사용)

---

## 📝 구현 우선순위

1. **Phase 1-3**: 핵심 기능 (오디오 캡처 + API 통합) → 최우선
2. **Phase 4**: 기본 UI → 기능 확인용
3. **Phase 5**: 파일 저장 → 필수 기능
4. **Phase 6**: 통합 및 동작 확인
5. **Phase 7-8**: 최적화 및 완성도 향상

---

## 🚀 시작 방법

1. 이 HANDOFF.md를 꼼꼼히 읽고 전체 구조를 이해하십시오.
2. Phase 1부터 순차적으로 구현하십시오.
3. 각 체크리스트 항목을 완료할 때마다 `SESSION_LOG.md`에 기록하십시오.
4. 불명확한 부분이 있으면 구현 전에 문의하십시오.
5. 모든 Phase가 완료되면 최종 테스트 후 보고하십시오.

---

**Senior Architect의 메시지:**
이 프로젝트의 핵심은 **속도**입니다. 모든 설계 결정은 레이턴시를 최소화하는 방향으로 이루어져야 합니다. 
Gemini의 Native Audio API를 최대한 활용하고, 비동기 처리를 통해 병목 지점을 제거하십시오.
코드는 명확하고 유지보수 가능하게 작성하되, 성능을 희생하지 마십시오.

화이팅! 🚀
