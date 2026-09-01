# livenote2 — 개발 스펙 문서 (AI 핸드오프용)

작성일: 2026-08-06 · 대상: 이 문서만 보고 동일한 앱을 재구축해야 하는 제로베이스 AI/개발자
현재 상태: **1단계 완성 + 출시 패키징 완료** (빌드·실전 사용 검증 완료, /Applications 설치본 운영 중)

---

## 1. 목적 — 이것을 잊으면 안 됨

**livenote2는 Granola와 Alt의 개인용 대체 앱이다.** 기능 하나하나는 수단이고, 목적은 다음 요구를 전부 만족하는 것:

1. **Granola의 경험**: 봇 없이 회의를 자동 기록(마이크+시스템 오디오), 실시간 전사, 회의 후 AI 요약. 단 Granola는 클라우드 처리 + 유료.
2. **Alt의 경험**: 무료·무제한·완전 로컬 전사. 단 Alt는 **화자구분이 Pro 유료**($7/mo)이고, 사용자는 딱 그 기능이 필요해서 이 프로젝트가 시작됨.
3. **추가 요구**: 영어 회의의 **한국어 실시간 번역** (Granola/Alt free에 없는 조합).

### 사용자 프로필과 제약 (설계를 결정한 조건들)
- 사용자: Elastic 직원(한국어 화자), 영어 Zoom 회의 다수. 개인용 1인 도구.
- 기기: MacBook Pro 14 (M3 Pro, 36GB RAM), macOS Tahoe 26.x. **Apple Silicon 전용 설계.**
- 인식 언어: **영어만**. 번역 출력: **한국어만**.
- **100% 로컬 처리** (네트워크는 최초 모델 다운로드만). 오디오 파일 저장 금지 — 텍스트(en/ko)만 저장.
- 상주 메모리 가볍게(회의 중 ~1GB 미만), 요약 생성 시에만 일시적으로 +~2.5GB 허용.
- 지연 허용: 한국어 번역까지 2~3초.
- Python 런타임 금지 — **더블클릭으로 실행되는 네이티브 .app**.

### 핵심 아키텍처 결정과 근거 (기각된 대안 포함)

| 결정 | 채택 | 기각된 대안과 이유 |
|---|---|---|
| 전사 엔진 | **Parakeet TDT v2** (NVIDIA, CoreML/ANE, FluidAudio 경유) | Whisper 계열(MacWhisper, Lightning-SimulWhisper): LibriSpeech 벤치마크에서 영어 정확도 열위(Whisper Small 3.74% vs Parakeet 2.01% WER), 회의 노이즈(AMI 11.16%)에 강한 쪽이 Parakeet. Apple SpeechTranscriber: 정확도 근소 열위 + 어차피 화자구분 별도 필요 |
| 화자구분 | **LS-EEND** (FluidAudio, 스트리밍, 10화자, 100ms) | Sortformer(4화자 한계), Pyannote 스트리밍(느림). 오프라인 정밀 재처리는 백로그 |
| 번역 | **Apple Translation framework** (온디바이스, macOS 15+) | 로컬 LLM 번역: 품질은 낫지만 상주 메모리 비용. 백로그 옵션 |
| 요약 | **Qwen3.5-4B-4bit** (MLX, 온디맨드 로드) | Qwen3.6-27B(15GB, 사용자가 거부), Jina 모델(임베딩·리랭커라 생성 불가) |
| 에코 제거 | **자체 소프트웨어 에코 게이트** (포락선 상관) | macOS VPIO(`setVoiceProcessingEnabled`): 이 기기에서 입력 무음 또는 초기화 실패(-10875). §7.3 참조 |
| 시스템 오디오 | **Core Audio Process Tap** (macOS 14.4+) | BlackHole 등 가상 드라이버: 설치 마찰. ScreenCaptureKit: 화면기록 권한이 더 무거움 |
| UI | SwiftUI + MenuBarExtra | — |

**2채널 분리 설계 (가장 중요한 설계 결정)**: 마이크와 시스템 오디오를 섞지 않고 별도 채널로 유지한다. 마이크 = 사용자 본인("나") 확정 라벨, 시스템 오디오 = 회의 상대방. 화자구분 모델(LS-EEND)은 **시스템 채널에만** 적용한다. 이로써 화자구분 난이도가 절반이 되고, "나"는 100% 정확하다. Meeting Transcriber 등 FluidAudio 생태계 앱들이 쓰는 검증된 패턴.

---

## 2. 기능 명세 — 목표 대비 현재 상태

### Granola 기능 대비

| Granola 기능 | livenote2 상태 |
|---|---|
| 봇 없는 회의 캡처 (마이크+시스템) | ✅ 구현 |
| 실시간 전사 표시 | ✅ 구현 (+ 잠정/확정 2단계 표시) |
| 회의 자동 감지 | ✅ 구현: ① Zoom/Teams/Webex 앱 실행 시 자동 시작(옵션), 앱 종료·4분 무음 시 자동 중지·저장 ② **캘린더 연동(2026-08-06 추가)**: 회의 1분 전 우상단 팝업 + Zoom 참가 버튼(§5.8). 브라우저(Meet) 탭 감지만 미구현 |
| AI 요약 | ✅ 구현 (로컬 Qwen3.5-4B, 한국어 출력) |
| 회의 중 사용자 메모 + AI 병합 | ❌ 미구현 (Granola의 시그니처 기능 — 백로그) |
| 템플릿, 회의록 공유, 팀 기능 | ❌ 의도적 제외 (개인용) |

### Alt 기능 대비

| Alt 기능 | livenote2 상태 |
|---|---|
| 무료·무제한·로컬 전사 | ✅ 구현 |
| **화자구분 (Alt에선 Pro 유료 — 프로젝트의 발단)** | ✅ 구현 (나/상대방 1/2/3…, 이름 클릭 편집). 품질 이슈는 §8 |
| 실시간 번역 | ✅ 구현 (EN→KO, 확정 문장 단위, 2~3초 지연) |
| 로컬 LLM 요약 | ✅ 구현 |
| 회의 저장·다시 보기 | ✅ 구현 (사이드바 + md 파일) |
| 플러그인/MCP | ❌ 의도적 제외 |

### 자체 추가 기능
- 에코 3층 방어 (§5.2) — 스피커 사용 시 이중 전사 방지
- 한/영 동시 라이브 뷰 (EN 즉시 + KO 2~3초 후 같은 화면)
- 메뉴바 상주, 설정 영속화(UserDefaults), 마이크 레벨 미터, 에코 필터 실시간 토글

### 미완/백로그 (우선순위 순)
1. ~~**출시 패키징**~~ ✅ 완료 (2026-08-06): `xcodebuild archive` → /Applications 설치. CLI 절차는 §8.7 참조
2. **화자 일관성 개선**: LS-EEND가 액센트가 다른 화자(미국/인도)도 혼동. 대책: 회의 중 임시 오디오 보관 → 종료 후 오프라인 정밀 재처리(FluidAudio `OfflineDiarizerManager`, Pyannote Community-1) → 라벨 확정 후 오디오 삭제
2-1. **진짜 AEC 이식 (webrtc-audio-processing AEC3)**: far-end=시스템 탭, near-end=마이크로 신호 수준 에코 제거. 지연·드리프트 자동 보정. 성공 시 §5.2 게이트·dedup은 보조로 강등. C++ 벤더링+Swift 브리지 필요 (§7.3 로드맵 참조)
3. **회의 중 메모 패널** + 요약 시 전사본과 병합 (Granola 핵심 경험)
4. **시맨틱 검색 (Phase 6)**: Jina embeddings (jina-embeddings-v5-omni, Elastic 직원 온프렘 무제한, Docker) 로 회의 아카이브 의미 검색 → 나아가 Qwen(생성)+Jina(검색) RAG
5. 라이브 번역 LLM 옵션(Apple Translation 품질 불만 시), 브라우저 회의 감지(Meet 등). ~~캘린더 연동~~ ✅ §5.8로 구현됨

### 알려진 이슈 (실측)
- 50분 회의 기준 짧은 에코("Yeah" 등)가 "나"로 3~4회 누출 — 실용 수준으로 판정, 개선 여지 있음
- LS-EEND 화자 일관성 미흡 (위 백로그 2)
- 개발 빌드(⌘R)마다 시스템 오디오 권한 재요청 — TCC가 코드 서명에 묶이는 macOS 정책. Archive 설치로 해결됨

---

## 3. 기술 스택 (정확한 버전)

| 구성요소 | 버전/ID | 용도 |
|---|---|---|
| Swift / SwiftUI | Swift 5 모드 (SWIFT_VERSION=5.0), Xcode 26 | 앱 전체. Swift 6 strict concurrency 회피 목적 |
| 배포 타깃 | **macOS 15.0** (실사용 26.x) | Translation framework가 15+, Core Audio tap이 14.4+ |
| FluidAudio | **0.15.5** (요구조건 upToNextMinor from 0.15.0) `https://github.com/FluidInference/FluidAudio.git` | ASR + 화자구분. Apache 2.0 |
| └ ASR 모델 | `FluidInference/parakeet-tdt-0.6b-v2-coreml` (~460MB, 자동 다운로드) | 영어 전용, CC-BY-4.0, ANE 추론 |
| └ 화자구분 모델 | LS-EEND `.dihard3` variant (자동 다운로드) | 스트리밍, 최대 10화자 |
| mlx-swift-lm | **3.31.4** `https://github.com/ml-explore/mlx-swift-lm` | LLM 요약 런타임 (3.x — §7.6 브레이킹 체인지 주의) |
| swift-huggingface | 최신 `https://github.com/huggingface/swift-huggingface` | 3.x 필수 다운로더 |
| swift-transformers | 최신 `https://github.com/huggingface/swift-transformers` | 3.x 필수 토크나이저 |
| └ 요약 모델 | `mlx-community/Qwen3.5-4B-4bit` (~2.3GB, 첫 요약 때 다운로드) | 2026-03 출시, 4B급 최신, Apache 2.0, 262K ctx |
| Apple Translation | OS 내장 (`import Translation`) | EN→KO 온디바이스. 언어팩 최초 1회 다운로드 |
| Core Audio / AVFoundation | OS 내장 | 시스템 오디오 탭 / 마이크 |

**타깃에 링크된 패키지 제품 (General > Frameworks…)**: `FluidAudio`, `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, `HuggingFace`, `Tokenizers`
(주의: `MLX` 모듈은 간접 의존성이라 직접 링크 불가 — 앱 코드에서 `import MLX` 하지 말 것)

**프로젝트 설정 요점**: bundle ID `com.byungjoo.livenote2` · App Sandbox 없음 · Hardened Runtime 없음 · 서명 Automatic(Personal Team) · pbxproj는 objectVersion 77 + `PBXFileSystemSynchronizedRootGroup`(폴더 동기화 — 파일 추가 시 pbxproj 수정 불필요, 단 Info.plist는 membershipExceptions 처리) · `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_FILE=livenote2/Info.plist` 병용(병합됨)

**Info.plist (3키)**:
- `NSMicrophoneUsageDescription`
- `NSAudioCaptureUsageDescription` (Core Audio process tap 권한 — "화면 및 시스템 오디오 녹음" TCC)
- `NSCalendarsFullAccessUsageDescription` (EventKit 전체 접근 — 회의 임박 알림용, macOS 14+ 키)

**모델 캐시 위치**: FluidAudio → `~/Library/Application Support/FluidAudio/Models/` · MLX/HF → HuggingFace 캐시. 빌드가 바뀌어도 재다운로드 없음.

**앱 아이콘 (2026-08-06)**: 건곤감리 트라이그램, 태극기 모서리 배열(좌상 건 ☰ · 우상 감 ☵ · 좌하 리 ☲ · 우하 곤 ☷). 한지 배경에 건곤=먹색, 감(물)=파랑, 리(불)=빨강. 생성기: `script/make_icon.py` (Pillow, 1024 마스터 → AppIcon.appiconset 10종은 스크립트 하단 참조 로직으로 리사이즈). 변형 A(그래파이트)/B(남색)도 스크립트에 보존.

---

## 4. 아키텍처 — 데이터 흐름

```
 [MicCapture]                    [SystemAudioTap]
 AVAudioEngine inputNode 탭       CATapDescription(전역, 자기 제외 없음)
 → AudioConverter16k             → AudioHardwareCreateProcessTap
 (16kHz mono Float32)            → 비공개 Aggregate Device + IOProc
      │ onSamples                → AudioConverter16k
      │ onLevel(~4Hz, UI미터)          │ onSamples
      ▼                               ▼──────────────┐ (동일 샘플 분기)
 AsyncStream<(AudioChannel,[Float])>            AsyncStream<[Float]>
      │ (.me / .them 태깅)                            │
      ▼                                              ▼
 ┌────────────────── TranscriptionEngine (actor) ─┐  SpeakerDiarizer (actor)
 │ 채널별 ChannelTracker:                          │  LSEENDDiarizer(.dihard3)
 │  · RMS 에너지 문장 분리 상태머신 (§5.1)          │  process(samples:16000)
 │  · .me 채널: 에코 게이트 (§5.2 ①)               │  → DiarizerTimeline 누적
 │  · 1.4s 주기 잠정 전사 / 문장 확정 시 최종 전사  │
 │ ASR: AsrManager.transcribe(_, decoderState:&새것)│
 │  → onVolatile / onFinal 콜백                    │
 └──────────┬──────────────────────────────────────┘
            ▼ FinalSegment(.them이면 ↘ 슬롯 조회)
 AppState (@MainActor @Observable) ← dominantSlot(from:to:) — 최대 겹침 화자
 │ · 에코 텍스트 dedup (§5.2 ③) → rows 삽입(시작시각 정렬)
 │ · 번역 큐 yield ──────────→ TranslationCoordinator
 │ · lastSpeechAt 갱신(자동종료용)   .translationTask(config) 세션 유지
 │ · 중지 3s 후 MeetingStore.save    session.translate(en) → row.korean
 │ · 늦은 번역/이름변경 → 1.5s 디바운스 재저장
 ▼
 ContentView (NavigationSplitView)          MeetingStore
 사이드바: 라이브 + 저장 회의 목록            ~/Documents/livenote2/<yyyy-MM-dd HHmm>/
 라이브뷰: EN+KO 행, 화자칩(클릭 rename),     ├ session.json (재열람용 원본)
 요약 카드, 배너, 레벨미터, 토글              ├ en.md / ko.md / combined.md
 저장뷰: 읽기전용 + 요약 생성                 └ summary.md (요약 생성 시)
```

**시간축**: 각 채널의 타임스탬프는 "그 채널에 유입된 누적 샘플 수 ÷ 16000"(초). 마이크/시스템 캡처가 거의 동시에 시작되므로 두 채널 시계는 실용상 일치. 화자구분 타임라인도 같은 시스템 채널 샘플을 먹으므로 일치.

**동시성 모델**: 오디오 콜백(오디오 스레드) → `AsyncStream.yield`(동기, 락프리) → actor 소비. UI 갱신은 콜백 클로저 안에서 `Task { @MainActor in }`. **UI와 무관한 AppState 내부 상태는 전부 `@ObservationIgnored`** (§7.4).

---

## 5. 핵심 알고리즘 (튜닝 상수 포함 — 전부 실전 조정된 값)

### 5.1 에너지 기반 문장 분리 (TranscriptionEngine, 채널별 독립)

상수(16kHz 샘플 기준): `speechThreshold` RMS 0.008 · `hangover` **1.8s** · `hardCap` **24s** · `volatileInterval` 1.4s · `minSegment` 0.4s · `preRoll` 0.3s · `earlyCloseMin` **14s** (경계 하한 6s)
(2026-08-21 튜닝: 절단 주기를 일괄 2배로 — "너무 자주 잘려 파편화된다"는 실사용 피드백. 무음 0.9s는 문장 중간 숨 고르기에도 잘렸음. 트레이드오프: them 채널 한 행에 화자 교대가 섞일 확률 소폭 증가 — 화자 교대 지점 분할은 백로그)

상태머신: 대기 중엔 0.3s 프리롤 링만 유지 → isSpeech 청크에서 문장 오픈(프리롤 포함, 시작시각 = 누적샘플 - 청크 - 프리롤) → 활성 중 버퍼 축적, isSpeech면 lastSpeech 갱신 → 무음 0.9s 지속 또는 12s 도달 시 확정(12s 컷이면 0.2s 꼬리 물고 즉시 재오픈) → 확정 시 전체 버퍼를 최종 전사. 활성 중 1.4s마다(버퍼 ≥0.4s, ASR 유휴 시) 버퍼 전체를 잠정 전사해 회색 이탤릭으로 표시. 2글자 미만 결과 폐기. `flushAll()`/`flushChannel(_:)`은 중지·뮤트 시 열린 문장 강제 확정.

**내부 문장 경계 조기 확정 (2026-08-21 재설계 — v2)**: 연속 발화로 버퍼가 7초를 넘으면, 잠정 전사의 **내부** 문장 경계(종결부호로 끝나는 토큰 뒤에 토큰이 2개 이상 더 있고, 경계 시각 ≥ 3초)에서 문장을 닫는다. `ASRResult.tokenTimings`(토큰별 startTime/endTime)로 오디오를 경계 시각+0.05s에서 정확히 자르고, 텍스트는 토큰 순번↔텍스트 종결부호 순번 대응으로 절단. 경계 뒤 오디오는 버퍼에 남아 다음 확정에서 온전히 재전사됨 (단어 유실·중복 없음). 타임스탬프가 없으면 조기 확정 안 함 (12s 캡만).
⚠️ 폐기된 v1 (2026-08-06~21): "잠정 전사 끝이 종결부호면 통째로 승격" — Parakeet이 잘린 오디오 끝에 붙이는 추정 마침표에 속아 가짜 경계에서 잘렸고, 실사용에서 하드캡 시절보다 더 어색하다는 피드백으로 폐기. 끝 종결부호는 신뢰하지 말 것.

**확정 경계 안정화 후처리 (2026-08-06 추가, AppState.stabilizedFinalText — AirTranslate 1.4.1 패턴 이식)**: 같은 채널 직전 확정 행과 비교해 ① 간격 5s 미만이고 토큰 포함률 ≥0.85 & 길이 비슷(≤1.5배)이면 유사 중복 확정으로 폐기, ② 간격 1.5s 미만(이월 경계 시그니처)이면 직전 꼬리 1~3토큰과 새 머리 토큰이 일치할 때 중복 머리 제거(새 문장이 4단어 이상일 때만). 하드캡 0.2s 꼬리 이월과 조기 확정 경계에서 생기는 단어 반복 아티팩트 대응.

### 5.1-2 2-pass 전사 정제 (2026-08-31, v1.2.0)

라이브 경로(짧은 창 분할 디코딩)는 경계 잘림·구두점 아티팩트가 불가피 → 상용 STT의 2-pass 방식 도입.
- **기록**: 세션 중 16kHz mono를 채널별 WAV로 임시 폴더에 기록 (`SessionAudioRecorder`, 시간당 채널별 약 115MB). 회의 폴더에는 절대 저장 안 함, 정제 후 즉시 삭제, 앱 시작 시 잔재 청소.
- **정제**: stop 시 `TranscriptRefiner`가 전체 오디오를 Parakeet으로 재디코딩 (`AsrManager.transcribe(url:)` — FluidAudio 디스크 기반 청크 병합, 메모리 일정). 문장 분리는 토큰 타임스탬프 기준: 종결 부호 / 토큰 간 1.2s 침묵 / 30s 상한. 화자·한국어 번역은 라이브 행과의 시간 겹침 최대 매칭으로 승계.
- **가드**: 정제 텍스트가 라이브의 50% 미만이면 실패 간주, 라이브 전사 유지.
- **순서**: 1차 저장(라이브, 즉시 열람) → 정제 → 재저장 → 자동 요약(정제본 입력). 라이브 화면·실시간 채팅은 스트리밍 행 그대로 사용.

**Transcription language (v1.2.0)**: Settings > Language. English = Parakeet v2 (영어 최고 정확도, 기본), Multilingual = Parakeet v3 (25언어 자동 인식, 첫 사용 시 별도 다운로드, `AsrModels.downloadAndLoad(version:)`). 다음 세션부터 적용.

### 5.2 에코 방어 — 수동 뮤트 + 3층 자동 필터 (스피커 사용 시 상대방 음성이 마이크로 재유입되는 문제)

**⓪ 마이크 뮤트 (2026-08-06 추가, 가장 확실한 방어)**: 헤더 마이크 아이콘 클릭(⌘⇧M)으로 토글. 뮤트 시 엔진이 `.me` 채널 오디오를 통째로 버림(actor 내부 판정 — 오디오 스레드에서 관찰 프로퍼티 안 읽음, §7.4) + 열려 있던 "나" 문장은 `flushChannel(.me)`로 즉시 확정. 레벨 미터는 뮤트 중에도 입력을 표시(마이크는 살아 있고 앱이 버리는 중이라는 피드백, 미터는 빨간색). 세션 시작 시 항상 해제로 리셋. 말하지 않는 회의에서 켜 두면 에코 누출이 구조적으로 0이 됨.
**뮤트 중 발화 감지 경고 (2026-08-21 추가)**: 뮤트 상태에서 micLevel > 0.15가 약 2초 누적되면 배너로 해제 권고 (60초 스로틀). 실측 사고에서 도입: 뮤트를 켠 채 발화해 21분 회의의 "나" 채널이 통째로 소실된 사례.

**① 포락선 상관 게이트** (1차, 오디오 레벨 — VPIO 대체품): 두 채널 모두 10ms(160샘플) 프레임 RMS 포락선을 유지(them 링 150프레임=1.5s, me는 30프레임=0.3s + 여유). `.me` 청크의 isSpeech 판정 전에:
- them 최근 피크 ≤ 0.008 → 스피커 조용 → 통과
- micRMS > themPeak × **1.5** → 근접 발화 우세 → 통과
- 아니면 me 최근 30프레임 로그 포락선을 them 포락선의 lag 0~60프레임(0~0.6s, 2프레임 간격 탐색) 구간들과 Pearson 상관 → 최대 상관 ≥ **0.55** 이면 에코 판정(원리: 에코는 원본의 시간이동 복사본이라 파형 모양이 닮음 — 볼륨 무관)

**② 세그먼트 폐기** (2차): 확정된 `.me` 세그먼트에서 게이트 판정 청크 중 에코 비율 > **0.6** (총 ≥4청크)이면 전사 없이 폐기.

**③ 텍스트 소급 dedup** (3차, AppState): 정규화 토큰(소문자, 영숫자만) 포함률 = 교집합/min(집합크기). `.me` 확정 시 최근 12행의 `.them`과 시간창 겹침(±10s) & 포함률 ≥ **0.65** (≥3토큰) → 버림. `.them`이 늦게 확정되면 기존 `.me` 행을 소급 삭제.

트레이드오프(문서화된 한계): 사용자가 상대방 말을 수 초 내 그대로 복창하면 ③이 오탐할 수 있음. 완전 동시발화 중 일부 사용자 발화가 ①에 씹힐 수 있음.

### 5.3 화자 식별 — Zoom 태그(1순위) + LS-EEND 슬롯(폴백)

**Zoom 활성 화자 태그 (2026-08-27 추가, `ZoomSpeakerTagger`)**: 손쉬운 사용(AX) 권한으로 Zoom 회의 창의 참가자 타일을 1초 주기 폴링. 타일 구조(실회의 덤프로 검증): AXTabGroup description에 "이름, 음소거 상태, Video 상태[, active speaker]", 자식 AXButton description에 이름만. 활성 화자 타임라인을 누적하고, `.them` 행 확정 시 구간 겹침 최대 이름(겹침 ≥ max(0.5s, 15%))을 `row.speakerName`에 자동 부여 (직함 꼬리는 `shortName`으로 제거: " @ ", " | ", ", " 앞까지). 시간 기준은 sessionStartedAt이 아니라 **captureStartedAt**(모델 준비 시간만큼 어긋나므로 캡처 시작 시각 별도 기록). resolveName 우선순위: speakerName > speakerNames[slot] > "상대방 N". 자동 인식 행의 칩은 편집 불가(이름 기반 안정 해시 색), 무명 행만 기존 클릭 편집 유지.

**LS-EEND 기동 조건**: 시작 시 Zoom 타일이 감지되면(첫 폴 1.5s 대기) **LS-EEND를 아예 기동하지 않음** (모델 로드·추론 부하 0 — Zoom에선 태그가 더 정확하고 이름까지 제공). Zoom이 없을 때만 기존 §5.3 슬롯 매핑 가동 (Teams/Meet/대면 폴백).

**Zoom 뮤트 동기화 (에코 방어 ⓪의 자동화)**: 내 타일(표시명에 myName 포함으로 식별)의 음소거 상태 변화를 감지해 마이크 캡처 뮤트를 자동 추종 (`syncMuteWithZoom`, 기본 켜짐, 메뉴바 토글). Zoom 뮤트 습관 그대로 에코 유입이 차단되고, 동기화 뮤트 중에는 발화 경고를 억제 (회의 밖 발화가 정상이므로). 수동 뮤트 버튼은 그대로 동작.

**한계 (문서화)**: Zoom 데스크톱(macOS) 전용 — Teams/Meet은 폴백 경로. Zoom UI 구조 변경에 취약 (파싱은 "active speaker" 영어 토큰과 자식 버튼 이름에 의존해 로케일 영향 최소화). 화면 공유·발표자 보기에서 타일 노출이 줄면 태그 공백 → 해당 행은 무명 폴백. 동시 발화 시 1명만 표시. 손쉬운 사용 권한 필요 (미허용 시 배너 안내, 태그 없이 진행).

### 5.3-구 화자 슬롯 매핑 (LS-EEND 폴백 경로)

`.them` 문장이 확정되면 `SpeakerDiarizer.dominantSlot(from:to:)` — 타임라인의 각 화자(`finalizedSegments + tentativeSegments`)와 [start,end] 겹침 시간 합산, 최대 화자 선택. 신뢰 조건: 겹침 ≥ max(0.3s, 구간의 15%). 미달이면 nil → UI에 "상대방"(무색). 슬롯 라벨은 "상대방 N"(slot+1), `speakerNames[slot]`으로 사용자 개명 가능(전 행 즉시 반영, 세션 간 유지... 단 slot 번호는 세션별 리셋됨에 유의).

### 5.4 번역 — 이원화: 로컬(기본) / 클라우드(옵션, 2026-08-06 추가)

**모드 선택 (2026-08-27 재편)**: **번역 체크박스**(`translationEnabled`) + **백엔드 Picker 로컬/클라우드**(`ProcessingBackend`, 키 "backend")로 분리. 백엔드는 번역뿐 아니라 요약(§5.5)의 제공자를 결정하고, 채팅(§5.9)은 독립 선택. 구 `translationMode`(off/local/cloud) 키에서 자동 이행. 파이프라인 정렬은 `applyTranslationPipeline()` 한 곳에서: 번역 켬+클라우드+키 → Gemini 라이브 기동, 아니면 정지; 번역 켬+로컬 → Apple activate(언어팩 프롬프트는 이때만). 번역이 하나도 없는 회의는 ko.md 생성 생략. 클라우드 최초 선택 시 API 키 시트 → **Keychain 보관**(`GeminiKeychain`). UI에 "오디오가 Google로 전송됨" 명시.

**로컬 (Apple Translation)**: `TranslationSession`은 직접 생성 불가 — SwiftUI `.translationTask(config)`가 세션을 주입하는 구조. config = `TranslationSession.Configuration(source: en, target: ko)`를 시작 시 set(nil→값). 뷰 최상위(NavigationSplitView 루트)에 부착해 사이드바 전환에도 세션 유지. serve 루프: `prepareTranslation()`(언어팩 다운로드 유도) 후 AppState의 `AsyncStream<TranslationRequest>` 소비 → `session.translate(text).targetText` → `applyTranslation(_:to: rowID)`. **확정 문장만 번역**(잠정 텍스트 번역 금지 — 화면 덜컹거림 방지, 지연 2~3초는 사용자 승인 사양). 실패 시 배너만, 영어 전사는 계속. Apple 세션은 클라우드 모드에서도 항상 activate 유지(전환 대비).

**클라우드 (GeminiLiveTranslator, 실험적)**: `gemini-3.5-live-translate-preview` — LiveNote1 S2ST의 후속. **오디오 입력 전용(텍스트 미지원)이 핵심 제약** → 확정 문장을 보낼 수 없고 채널별 오디오를 스트리밍해야 함. 구조: 채널(나/상대방)별 WebSocket 세션 2개(`BidiGenerateContent`, v1beta, API 키 쿼리스트링 — 무료 티어는 동시 WS 3~5개 제한이라 2세션이 상한 근처임에 유의).

**setup 스키마 (⚠️ 공식 문서 예제가 틀림)**: `inputAudioTranscription {}`/`outputAudioTranscription {}`은 **setup 루트**, `translationConfig { targetLanguageCode: "ko", echoTargetLanguage: false }`는 generationConfig 안. 문서 예제대로 전사 설정을 generationConfig에 넣으면 CloseCode 1007로 거부됨 (kkdai/gemini-live-translate-macos 실전 검증, 2026-08-21 반영 — 참조프로젝트-7종-분석리포트.md).

입력: Float32→Int16LE 변환, 100ms(1600샘플) 청크, **무음 게이트**(RMS 0.004, hangover 1s — 무음은 전송 안 해 쿼터 절약. Silero VAD 승급은 백로그). **핸드셰이크·로테이션 중 오디오는 최근 3초 버퍼 → setupComplete에서 방출**(첫 문장 유실 방지, ALAD 패턴). 출력: `outputTranscription` 한국어 조각을 채널별 누적, 번역 오디오(24kHz)와 inputTranscription은 폐기(EN은 Parakeet 담당). **행 매칭(클레임 방식)**: 행 확정 2.5s 후 누적분 회수(비면 3s 후 1회 재시도) → row.korean. 한계(문서화): Gemini와 우리 문장 분할이 달라 경계에서 번역이 이웃 행으로 번질 수 있음.

연결 수명 관리 (2026-08 개정): ① **선제 로테이션** — 채널별 8분 주기로 미리 재연결(Live 세션 수명 한계 대응, Voxis·vtuber 패턴, LiveNote1 실측 8~10분 리셋), ② goAway 수신 시 즉시 재연결, ③ 오류 시 지수 백오프 2s×시도 상한 30s로 **세션이 사는 동안 무제한 재시도** (연속 5회째에 경고 배너, 성공 시 해제. 과거 "5회 후 영구 중단" 정책은 네트워크 순단 한 번에 세션이 죽는 실사용 문제로 폐기). 수신 루프는 소켓 아이덴티티 체크로 이중 수신 방지. 뮤트 시 .me 채널 전송 중단.

**진단 가시성 (2026-08 추가)**: 연결 이벤트(connect/setupComplete/disconnect 사유/goAway/로테이션/출력 조각 수)를 `~/Documents/livenote2/logs/cloud.log`에 기록 (전사 텍스트는 기록 안 함). 헤더에 연결 표시등(초록=양 채널 연결, 주황=연결·재연결 중). "갑자기 안 됨"을 소급 진단할 수 없던 문제로 도입. 참고: API 레벨 재현 테스트 스크립트 경험상 키·모델·스키마가 정상이어도 톤/무음에는 출력이 없는 것이 정상 (모델이 비음성 필터링).

### 5.5 요약 (SummaryService + GeminiSummarizer)

**이원화 (2026-08-21)**: 클라우드 번역 모드 + API 키 보유 시 요약은 **Gemini 3.7 Flash**(`gemini-3.7-flash`, 2026-08-13 GA, generateContent REST, 프롬프트는 Qwen과 공유)로 실행 — 모델 로드 없이 수 초, 품질 우위, 비용 회의당 수 센트 미만. 실패 시 로컬 Qwen 자동 폴백 (`AppState.runSummary`). 로컬/끔 모드에서는 기존 Qwen 경로.

**로컬 모델 선택 (Settings, UserDefaults `localModelID`, 2026-08-28 확장)**: Qwen3.5 4B(기본)·9B, Qwen3.8 4B·9B(experimental — `SiddhJagani/Qwen3.8-{4B,9B}-mlx-4Bit`). Qwen3.8은 공식 mlx-community 변환이 아직 없어 커뮤니티 변환본 사용, config의 `model_type: "qwen3_5"`라 mlx-swift-lm 레지스트리(qwen3_5)로 로드 가능함을 확인 (2026-08-28). 품질 미검증이라 experimental 표기.

온디맨드 원칙(로컬 경로): 모델을 상주시키지 않고 요청 시 로드 → 생성 → 참조 해제(메모리 반환). 로드: `#huggingFaceLoadModelContainer(configuration: ModelConfiguration(id:))` (§7.6) → `ChatSession(container, instructions: 시스템프롬프트)` → `respond(to:)`. 입력: `MeetingStore.transcriptForSummary` = `[mm:ss] 화자: 영어원문` 행들, suffix 60,000자 컷. 프롬프트: 한국어 시스템 프롬프트(ASR 오류 보정 지시 + 사고 과정 출력 금지 + 첫 줄 "## 개요" 강제 포함) + 출력 형식 지정(개요/핵심 논의/결정 사항/액션 아이템). **thinking 억제 (2026-08-06 개정)**: `/no_think` 소프트 스위치는 Qwen3 전용이라 Qwen3.5에서 무시됨(실측: 평문 "Thinking Process:" 누출) → 제거함. 후처리 `cleaned()`: ① `<think>...</think>` 블록 제거, ② 줄 시작이 "## 개요"인 첫 줄 앞을 전부 절단(태그 없는 평문 사고 제거; 정상 출력이면 no-op). 결과는 현재 세션이면 재저장, 저장 회의면 `updateSummary` → session.json + summary.md 갱신.

### 5.6 자동 시작/종료

- 종료 ①: 30s 주기 체크, `lastSpeechAt`(양 채널 잠정/확정 발화 시 갱신)로부터 **4분** 무음 → stop() + 파란 배너
- 종료 ②: `NSWorkspace.didTerminateApplicationNotification` — 번들 ID `us.zoom.xos`, `com.microsoft.teams2`, `com.microsoft.teams`, `Cisco-Systems.Spark` 종료 시 → stop()
- 시작: `didLaunchApplicationNotification` 같은 목록, 옵션(`autoStartOnMeetingApp`, 기본 off, 메뉴바 토글) 켜져 있으면 start()
- stop() → 3s 대기(마지막 번역 도착 여유) → 저장. 이후 이름변경/늦은 번역 → 1.5s 디바운스 재저장(같은 폴더 덮어씀)

### 5.7 저장 (MeetingStore)

루트 `~/Documents/livenote2/`, 폴더명 `yyyy-MM-dd HHmm`(충돌 시 " (2)"). 구성: `session.json`(SavedMeeting Codable: startedAt ISO8601, durationSeconds, myName, speakerNames[Int:String], rows[TranscriptRow], summary?; prettyPrinted+sortedKeys. 주의: Swift의 [Int:String]은 JSON 배열 [키,값,...]로 인코딩됨 — 같은 디코더로만 읽으면 무해) · `en.md` · `ko.md`(번역 없으면 "_(번역 없음)_ 원문") · `combined.md`(EN + `> KO`) · `summary.md`. 마크다운 헤더: 일시/길이/참석(등장 순 화자명). 오디오는 어떤 형태로도 저장하지 않음.

### 5.9 AI 채팅 (ChatService + ChatPanel, 2026-08-27 추가 — Granola식 하단 대화창)

라이브/저장 회의 뷰 하단에 상주하는 질의응답 패널. **범위 자동 전환**: 저장 회의를 열면 그 회의의 전사+요약, 라이브 뷰에서 회의 중(또는 직후)이면 현재 세션의 실시간 전사("회의가 지금 진행 중" 힌트 포함 — 회의 중 캐치업 질문 가능), 둘 다 아니면 전체 아카이브(최근 15개 회의의 요약 또는 전사 앞부분, 총 60K자 상한). 범위 키가 바뀌면 대화 초기화.

**모델은 번역 백엔드와 독립 선택** (`ChatModelMenu`, UserDefaults `chatModel`, 홈 히어로·채팅 패널 공용, 전 범위 전역 유지 — 2026-08-28 v1.1.2 확장): Standard = `Gemini 3.7 Flash`(기본)·`3.5 Flash-Lite`, Thinking = `3.7 Flash Thinking high/medium`·`3.1 Pro`, Local = `Qwen`. Thinking 레벨은 `generationConfig.thinkingConfig.thinkingLevel`("high"/"medium")로 전달 (thinkingBudget은 레거시, 병행 금지). Gemini 경로는 generateContent 멀티턴 contents, 컨텍스트는 첫 user 턴으로 주입. 로컬은 `LocalChatEngine` actor가 첫 질문 때 컨테이너를 로드 후 **상주** (요약과 달리 연속 사용이 잦아 온디맨드 해제 안 함, 메모리 +2.3GB, 문서화된 예외). 이력은 최근 8턴을 프롬프트에 포함. 시스템 프롬프트: 기록 근거 답변, 없는 내용 추측 금지, 질문 언어 추종. 구 rawValue(`cloudGemini`)는 디코드 실패 시 기본값으로 자동 폴백.

### 5.8 캘린더 회의 임박 알림 (CalendarMonitor + MeetingAlertPanel, 2026-08-06 추가)

상수: `leadSeconds` 60 (시작 60초 전부터 팝업) · `graceSeconds` 600 (시작 후 10분까지 유지 — 지각 참가 대비) · 폴링 10s

- **감시**: EventKit 전체 접근(`requestFullAccessToEvents`, macOS 14+ API). 10초마다 `predicateForEvents(now-10분, now+30분, 전체 캘린더)` 조회 — Calendar.app에 연결된 구글 계정 일정 포함. 제외: 종일·취소·내가 거절한 초대(`EKParticipant.isCurrentUser` + `.declined`)·Zoom 링크 없는 일정. 알림 창(시작-60s ~ 시작+10분)에 든 첫 일정을 팝업. `eventIdentifier@시작시각` 키로 재알림 방지.
- **Zoom 링크 파싱**: event의 url → location → notes 순으로 정규식 `https://[A-Za-z0-9.-]*zoom\.us/[^\s<>"')\]]+` 첫 매치. `/j/{회의번호}` 형태면 `zoommtg://{host}/join?action=join&confno=...&pwd=...` 딥링크로 변환(브라우저 안 거치고 Zoom 앱 직접 실행). 개인 링크(/my/) 등 번호 없는 경우와 Zoom 앱 미설치 시 웹 링크 폴백.
- **팝업**: AppKit `NSPanel` — `.nonactivatingPanel`(포커스 안 뺏음), `.floating` 레벨, `[.canJoinAllSpaces, .fullScreenAuxiliary]`(전체 화면 Zoom 위에도 표시), 우상단 배치, Glass 사운드. 내용: 제목·시간·1초 카운트다운(TimelineView)·[Zoom 참가]·[닫기].
- **참가 동작**: 딥링크(또는 웹 링크) open + `onJoinRequested` 콜백 → AppState가 기록 시작(`isActive`가 아니면 start()). 설정: 메뉴바 토글 "회의 1분 전 Zoom 참가 알림", UserDefaults `calendarAlerts`, **기본 켜짐**. 최초 활성 시 캘린더 권한 프롬프트, 거부 시 주황 배너 안내.
- **Zoom 회의 종료 즉시 감지 (2026-08-27 추가, Granola식)**: ZoomSpeakerTagger가 회의 창(제목 "Zoom 회의"/"Zoom Meeting")·타일의 존재를 추적, 존재했다가 **12초 연속 부재**면 `onMeetingEnded` 1회 발화 → 기록 중이면 즉시 자동 중지·저장·요약 (4분 무음 대기 불필요). 화면 공유로 타일이 일시 감소해도 회의 창 제목이 남아 있어 오탐 방지.

**UI 구조 (2026-08-27 전면 개편, Granola식)**: NavigationSplitView 폐기 → 좌측 고정 레일(180px, 먹남 그라데이션: 홈/채팅/라이브) + 메인 콘텐츠 전환(`Screen` enum). **홈 (2026-08-28 v1.1.2 재배치)** = 중앙 히어로 "Hi {myName}, ask anything" + ask 박스(제출 → Chat 화면 전환 + 아카이브 범위 질문, `ChatModelMenu` 칩 포함) → Coming up 카드(오늘 일정+지금 시작+새 회의 시작) → Recents **최근 3건** + "See all" 토글(전체 날짜 섹션 피드 확장). **회의 상세** = 요약(회의록) 중심 + 경량 마크다운 렌더러(`SummaryRenderView`: #/##/불릿/인라인 굵게) + "전사 보기" 토글(기본 접힘) + 하단 채팅(.saved). **채팅** = 전체 화면 아카이브 채팅(ChatPanel expanded). 테마 `Theme`: 한지 캔버스·쪽빛 액센트·주홍 포인트 (앱 아이콘과 동일 계열), 라이트 고정(`preferredColorScheme(.light)`).
- **참석자 이름 후보 (2026-08-21 추가)**: `attendeeNamesForOngoingMeeting()` — 진행 중(시작 10분 전~종료)인 일정의 참석자(사람만, 본인 제외, 최대 10명)를 start() 시점에 `AppState.attendeeCandidates`로 캡처. 화자 칩 rename 팝오버(.them 전용)에 원클릭 후보로 표시. 이름이 이메일이면 로컬 파트를 사람 이름처럼 정리(`prettyName`).
- **참석자 이름 교정 (2026-08-21 추가, Granola 어휘 힌트의 후처리판)**: 확정 텍스트의 대문자 시작 5자 이상 토큰을 참석자 이름 토큰(4자 이상, 내 이름 포함)과 대조해 편집거리 ≤ 2 & 길이차 ≤ 2면 교체 (Herminder→Harvinder류). Granola 대비 열세였던 고유명사 정확도 격차 대응 (WD 회의 실측 비교에서 도입 결정). 디코더 수준 어휘 부스팅(FluidAudio CustomVocabulary, SlidingWindowAsrManager 전환 필요)은 백로그.
- **이중 시작 가드**: 참가로 start()한 직후 Zoom 실행 감지 자동 시작이 겹칠 수 있어 start() 가드를 `!isRunning`(listening만 차단)에서 `!isActive`(preparing 포함 차단)로 강화. 기존에도 있던 잠재 레이스의 수정임.

---

## 6. 파일별 스펙 (livenote2/livenote2/ 아래 15파일)

| 파일 | 역할 · 핵심 내용 |
|---|---|
| `livenote2App.swift` | `WindowGroup(id:"main")` 1020×680(min 840×520) + `MenuBarExtra`(waveform 아이콘, 실행 중 filled). MenuBarView: 상태줄, 시작/중지, 메인 창 열기(openWindow+activate), 자동 시작 토글, 종료(실행 중이면 stop 후 4.5s 지연 terminate — 저장 보장) |
| `Models/TranscriptModels.swift` | `AudioChannel{me,them}`(Codable) · `TranscriptRow{id,channel,speakerSlot?,english,korean?,startSeconds,endSeconds}`(Identifiable+Codable, timeLabel mm:ss) · `FinalSegment` |
| `Audio/AudioConverter16k.swift` | AVAudioConverter 래퍼: 임의 포맷 → 16kHz mono Float32. 스트림당 1인스턴스(리샘플 상태 유지). 입력버퍼 1회 공급 클로저 패턴 |
| `Audio/MicCapture.swift` | AVAudioEngine inputNode 탭(4096). **VPIO 사용 안 함**(§7.3). onSamples + onLevel(0.25s마다 peak RMS×8). `requestPermission()` = AVCaptureDevice.requestAccess(.audio) |
| `Audio/SystemAudioTap.swift` | `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, isPrivate, unmuted → `AudioHardwareCreateProcessTap` → 비공개 aggregate device(TapList에 tap UUID, DriftCompensation, TapAutoStart; SubDeviceList 빈 배열) → `AudioDeviceCreateIOProcIDWithBlock` → `AVAudioPCMBuffer(bufferListNoCopy:)` 제로카피 → 변환. 포맷은 `kAudioTapPropertyFormat`으로 조회. 실패 시 OSStatus+단계명 담은 에러(마이크 전용 모드로 계속) |
| `Engine/TranscriptionEngine.swift` | actor. §5.1 상태머신 + §5.2①② 에코 게이트 + ASR 직렬화(asrBusy 폴링 30ms). `prepare()`=모델 다운로드+로드, `ingest(_:channel:)`, `flushAll()`, `setEchoFilter(_)` |
| `Engine/SpeakerDiarizer.swift` | actor. FluidAudio diarizer API를 만지는 **유일한** 파일(시그니처 드리프트 격리 목적). prepare/ingest/dominantSlot/finish. 실패 시 failed 플래그 → 라벨만 포기 |
| `Engine/TranslationCoordinator.swift` | @MainActor @Observable. config 보유, `serve(session:state:)` 루프, issueMessage 배너 |
| `Engine/GeminiLiveTranslator.swift` | actor. §5.4 클라우드 번역: 채널별 WebSocket 2개, PCM 변환·무음 게이트·전송, outputTranscription 누적·claim, 재연결. + `GeminiKeychain`(API 키 Keychain 보관) |
| `Engine/ZoomSpeakerTagger.swift` | @MainActor. §5.3 Zoom AX 폴링: 타일 파싱(이름·active speaker·뮤트), 활성 화자 타임라인, dominantName, 내 뮤트 변화 콜백. AX API를 만지는 유일한 파일 |
| `Engine/ChatService.swift` | §5.9 채팅: `ChatPrompt`(공유 프롬프트·이력 합성), `LocalChatEngine` actor(Qwen 상주), `GeminiChat`(3.7 Flash 멀티턴 REST) |
| `Calendar/CalendarMonitor.swift` | @MainActor @Observable. §5.8 감시 루프·자격 판정·Zoom 링크 파싱(`firstZoomLink`/`zoomDeepLink` static)·참가 실행. EventKit을 만지는 유일한 파일 |
| `Calendar/MeetingAlertPanel.swift` | `MeetingAlertPanelController`(NSPanel 생성·우상단 배치·닫기) + `MeetingAlertView`(SwiftUI: 제목·시간·카운트다운·참가/닫기) |
| `Engine/SummaryService.swift` | actor. §5.5. 모델 ID 상수 한 줄로 교체 가능하게 유지할 것 |
| `AppState.swift` | @MainActor @Observable 중심 허브. phase(idle/preparing/listening/error), rows, volatileText, 배너 4종(systemAudio/diarizer/translation/notice), micLevel, echoFilterEnabled·myName·autoStartOnMeetingApp(UserDefaults 영속), start()/stop() 오케스트레이션(§4 흐름), 에코 dedup(§5.2③), 저장·재저장(§5.6~7), 자동 시작/종료 옵저버, 요약 상태머신(summaryPhase). **파이프라인 내부 상태 14개 프로퍼티에 @ObservationIgnored 필수**(§7.4). 회의 앱 번들ID 목록은 **파일 스코프 상수**(§7.5) |
| `ContentView.swift` | NavigationSplitView: 사이드바(라이브 + MeetingStore.meetings, 컨텍스트 메뉴: Finder에서 보기/삭제) / LiveMeetingView(헤더: 상태·미터·에코필터 토글·시작/중지 ⌘R, 배너들, SummaryCard, 전사 리스트: 화자칩 popover rename·EN·KO·"번역 중…"·타임스탬프·잠정 행, 자동 스크롤) / SavedMeetingView(읽기전용 + SummaryCard + onChange(summaryPhase) 재로드). 화자칩 색: me=blue, 슬롯=8색 팔레트 순환, nil=회색 |
| `Storage/MeetingStore.swift` | §5.7 + `resolveName(row:myName:speakerNames:)` 정적 헬퍼(이름 해석 단일 소스) + 마크다운 생성기 4종 + `transcriptForSummary` |

---

## 7. 함정 목록 — 재구축 시 반드시 알아야 할 것 (전부 실제로 밟은 것)

1. **FluidAudio 문서는 코드보다 앞서간다.** README/API.md가 `transcribe(_, source:)`를 문서화하지만 v0.15.x 실제 공개 API는 `transcribe(_ samples: [Float], decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult`뿐. `TdtDecoderState()`는 `throws`, 기본 2레이어(v2 모델과 일치). 배치 전사이므로 **매 호출 새 상태** 사용. 최소 300ms 오디오 요구(미달 시 invalidAudioData throw — minSegment 0.4s로 자연 회피). 검증법: 문서 말고 태그된 소스 파일을 직접 읽을 것.
2. **LS-EEND API는 동기.** `LSEENDDiarizer(variant:)`만 async throws. `process(samples:sourceSampleRate:)`는 sync throws, `timeline` 프로퍼티·`finalizeSession()` sync. 불필요한 await는 경고만 나오니 처음엔 방어적으로 붙였다 정리.
3. **macOS VPIO(에코제거)는 이 용도에 부적합.** `inputNode.setVoiceProcessingEnabled(true)`: 입력만 켜면 **마이크가 통째로 무음**(이 기기에서 재현), 입출력+무음출력 구성은 **-10875 kAudioUnitErr_FailedInitialization**(외장 디스플레이 오디오/가상장치 조합에서). 자동 게인으로도 무음은 못 살림. 결론: VPIO 포기, §5.2 소프트웨어 게이트 채택.
   **Granola 사실관계 (2026-08-06 공식 문서로 검증)**: Granola도 마이크("Me", 초록 말풍선)+시스템 오디오("Them", 회색 말풍선) 2채널 raw 캡처로 우리와 동일 구조이며 VPIO를 쓰지 않는다. 그러나 에코가 "없는" 것이 아니라 ① 자체 소프트웨어 에코 처리를 반복 개선 중이고(changelog에 수정 이력, 알고리즘 비공개), ② 공식 권장이 헤드셋 사용이며, ③ 데스크톱 화자 라벨은 음향 화자구분이 아니라 Zoom/Meet 참가자 메타데이터 연동이라 오귀속이 눈에 덜 띈다. 브라우저 기반 앱들이 깔끔한 이유는 getUserMedia에 WebRTC AEC3가 기본 적용되기 때문. **신호 수준 해법 로드맵: webrtc-audio-processing(AEC3) 이식이 1순위 백로그** (far-end=시스템 탭, near-end=마이크, 지연·드리프트 자동 보정). 차선: speexdsp MDF(드리프트 취약). 현재 방어: 뮤트(⓪) + 3층 필터.
4. **@Observable 프로퍼티를 오디오 스레드에서 읽으면 안 됨.** AsyncStream continuation 등 파이프라인 상태가 관찰 추적되면 QoS 우선순위 역전(Hang Risk) 경고. UI 비표시 상태는 전부 `@ObservationIgnored`.
5. **@MainActor 클래스의 static 프로퍼티는 @Sendable 클로저(NSWorkspace 옵저버 등)에서 참조 불가** — 컴파일 에러. 파일 스코프 `private let`으로 뺄 것.
6. **mlx-swift-lm 3.x 브레이킹 체인지.** 2.x의 `LLMModelFactory.shared.loadContainer(configuration:)` 소멸 — 다운로더/토크나이저가 별도 패키지로 분리됨. 정식 경로: swift-huggingface + swift-transformers 추가, `MLXHuggingFace`/`HuggingFace`/`Tokenizers` 링크, `#huggingFaceLoadModelContainer(configuration:)` 매크로 (첫 빌드 때 매크로 Trust & Enable 승인 필요). `import MLX`는 간접 의존성이라 링크 불가 → 쓰지 말 것. ChatSession(3.x): `ChatSession(container, instructions:)` → `respond(to:)`.
7. **TCC 권한은 코드 서명 단위.** ⌘R마다 바이너리가 바뀌어 시스템 오디오 권한 재요청 — 버그 아님. 해결: Archive → Copy App → /Applications 설치본 사용. 시스템 오디오 녹음 권한은 Apple 정책상 출시 앱도 주기적 재확인 있음.
8. **pbxproj 수작업 시**: objectVersion 77 + PBXFileSystemSynchronizedRootGroup 구조면 소스 파일 추가에 pbxproj 수정 불필요. 단 ①앱 product의 PBXFileReference 정의 누락 ②ID 길이 불일치가 흔한 수작업 사고 — 24자 hex 통일, 참조↔정의 검증 스크립트 돌릴 것.
9. **모델 선택은 LM Studio 카탈로그와 무관.** 기준은 ①HF에 MLX 변환 존재 ②mlx-swift-lm `LLMTypeRegistry`에 아키텍처 등록(예: qwen3_5 ✓). 확인법: `Libraries/MLXLLM/LLMModelFactory.swift` 소스 열람.
10. **Xcode 진단 읽는 법 교육 필요(비개발자 사용자)**: 노란색=경고(빌드됨), 빨간색=에러. "No async operations in await" 류는 경고. 실행 로그의 `throwing -10877`/`HALDevice.cpp`는 CoreAudio 무해 노이즈.
11. **채널 간 행 정렬**: 확정 도착 순서가 시간순이 아닐 수 있음 → rows 삽입 시 startSeconds 기준 위치 탐색.
12. **잠정 번역 금지**: volatile 텍스트를 번역하면 문장이 계속 뒤집혀 UX 파탄. 확정 문장만.
13. **Qwen3.5 thinking 억제는 프롬프트/kwarg로 안 됨.** `/no_think`는 Qwen3 전용 소프트 스위치(3.5는 무시, 평문 사고 누출 실측). `enable_thinking=false` 템플릿 kwarg도 mlx-swift-lm이 chat template에 전달하지 않음(issue #154). 유일한 신뢰 경로는 시스템 프롬프트 지시 + 출력 후처리(§5.5 앵커 절단).
14. **이 기기에는 코드서명 인증서가 없음** (`security find-identity` 0건) — Xcode에 Apple ID 미등록 상태. 모든 빌드(⌘R·archive)가 ad-hoc 서명이라 빌드마다 cdhash가 바뀌어 TCC 재요청이 발생했던 것(§7.7의 실체). /Applications 설치본은 바이너리가 고정되므로 권한이 유지되지만, **업데이트 재설치 시에는 마이크·시스템 오디오 권한을 다시 허용해야 함**. 영구화하려면 Xcode > Settings > Accounts에 Apple ID 추가 후 Personal Team 서명.
15. **이 기기의 xcode-select는 CommandLineTools를 가리킴** → CLI에서 `xcodebuild` 실패. `sudo xcode-select -s` 대신 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`로 우회 (package.sh에 내장).
16. **Gemini Live Translate는 오디오 입력 전용.** 텍스트 번역 요청 불가 — 확정 문장 텍스트를 보내 번역받는 설계는 성립하지 않음. 오디오 스트리밍 + 전사 클레임 방식(§5.4)이 유일한 통합 경로. 프리뷰 모델이라 쿼터·모델명 변경 리스크 있음 (모델명은 `GeminiLiveTranslator.model` 상수 한 줄).

---

## 8. 재구축 순서 (검증된 단계별 경로 — 각 단계가 실행 가능한 앱)

1. **Phase 1**: 프로젝트 스캐폴드 + 2채널 캡처 + 라이브 영어 전사 + (선택) 번역까지. 검증: 영어 영상 → "상대방" 행, 육성 → "나" 행, 확정 후 2~3초 내 KO.
2. **Phase 2**: LS-EEND 화자구분 + 칩 rename. 검증: 2인 이상 인터뷰 영상에서 색 분리.
3. **에코**: 실제 Zoom 콜에서 이중 전사 확인 → §5.2 3층 적용. 검증: 스피커로 영상 틀며 동시 발화.
4. **Phase 4**: 저장/사이드바/재저장. 검증: 중지 → md 3종 + 이름 변경 반영 + 앱 재시작 후 목록 유지.
5. **마이크/자동화**: 레벨 미터, 자동 시작/종료.
6. **Phase 5**: 메뉴바 + Qwen 요약. 검증: 저장된 장시간 회의에 "요약 생성".
7. **패키징** (✅ 완료, 스크립트화 — 2026-08-06 배포 위생 도입): `./script/package.sh [버전]` 한 방이 Release 아카이브 → `dist/livenote2-{버전}.dmg`(Applications 심볼릭 링크 포함) + `.sha256` 체크섬 + `INSTALL.md` 생성. 로컬 설치는 아카이브에서 `ditto .../livenote2.app /Applications/`. 실행 중인 앱은 먼저 종료 후 교체. 재설치 후 첫 시작 시 마이크·시스템 오디오 권한 재허용 필요(§7.14). DEVELOPER_DIR은 스크립트가 자동 설정(§7.15 참고: 이 기기 xcode-select는 CLT를 가리킴).

---

## 9. 참고 근거 자료

- 벤치마크(엔진 선택 근거): Inscribe "Apple Speech API vs Whisper" Round 1/2 — get-inscribe.com/blog/apple-speech-api-benchmark.html, /parakeet-moss-apple-speech-benchmark.html
- FluidAudio: github.com/FluidInference/FluidAudio (Apache 2.0) · Parakeet v2 모델카드: huggingface.co/nvidia/parakeet-tdt-0.6b-v2 (CC-BY-4.0, AMI 11.16 WER)
- mlx-swift-lm: github.com/ml-explore/mlx-swift-lm (3.x 사용법: Libraries/MLXLMCommon/Documentation.docc/using.md)
- Qwen3.5-4B: huggingface.co/mlx-community/Qwen3.5-4B-4bit (Apache 2.0)
- 대체 대상: Granola(granola.ai) · Alt(altalt.io — 화자구분/플러그인 Pro 유료, 엔진 오픈소스판: github.com/altalt-org/Lightning-SimulWhisper, PolyForm NC 라이선스라 업무용 부적합했음)

— 끝. 이 문서와 동일 폴더의 소스 코드가 유일한 진실이다. 문서와 코드가 다르면 코드를 믿고, 외부 라이브러리는 문서 말고 태그된 소스를 믿어라.
