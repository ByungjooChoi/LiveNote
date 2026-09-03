# LiveNote (livenote2) — Claude Code 작업 지침

macOS 네이티브 회의 노트테이커 (SwiftUI, Apple Silicon). 봇 없이 마이크(나)+시스템 오디오(상대방) 2채널 캡처, 로컬 Parakeet STT, 실시간 한국어 번역, Zoom 화자 태그, 자동 회의록, 아카이브 채팅. Granola/Jamie 대체가 목표. 현재 v1.3.1.

## 먼저 읽을 문서
- `livenote2-개발스펙.md`: 아키텍처·알고리즘·튜닝 상수·함정(§7). 기능 변경 시 해당 절을 갱신한다.
- `docs/product-plan-v2-2026-09.md`: 다음 기능들의 제품 기획 (Recipes, 사전 브리핑, Speaker Memory, Tasks, 전사 편집, 소소한 개선).
- `docs/implementation-plan-v2-2026-09.md`: 위 기획의 Phase별 구현 계획. **다음 작업은 Phase 0 (v1.4.0)부터.**
- `docs/feature-plan-jamie-granola-2026-09.md`: 경쟁 분석 배경.
- `README.md`: 사용자 관점 기능 설명.

## 코드 구조 (livenote2/)
- `AppState.swift`: 중앙 허브(@MainActor @Observable). 세션 수명, 행 생성, 화자 명명, 번역 파이프라인, 채팅, 2-pass, 설정. 1,300줄 이상이라 새 기능은 별도 파일로.
- `ContentView.swift`: 전 화면(Home/Chat/Live/Meeting/Settings) + Theme. 새 화면은 `Views/` 폴더에 분리해서 추가.
- `Engine/`: TranscriptionEngine(라이브 STT, 에너지 세그멘테이션), TranscriptRefiner(2-pass), SessionAudioRecorder(세션 한정 WAV), EchoDedup, ZoomSpeakerTagger(AX), SpeakerDiarizer(LS-EEND), GeminiLiveTranslator, TranslationCoordinator, SummaryService(+GeminiSummarizer), ChatService, Logging(AppLog, GeminiREST), ModelSeeder.
- `Storage/`: MeetingStore(회의 폴더·md), ChatStore. `Calendar/`: CalendarMonitor(EventKit), MeetingAlertPanel. `Models/TranscriptModels.swift`: 공용 타입·LanguagePrefs.
- 의존성: FluidAudio 0.15.5 (Parakeet v2/v3, LS-EEND, 오프라인 DiarizerManager), mlx-swift-lm 3.31 (Qwen 로컬).

## 빌드·설치·배포
- 빌드: `./script/package.sh <version>` → `dist/LiveNote-<version>.dmg` + `/tmp/livenote2.xcarchive`. 스크립트가 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 설정한다(xcode-select는 CLT를 가리킴).
- 실패 시 package.sh는 `tail -3`으로 오류를 숨긴다. 직접 `xcodebuild -project livenote2.xcodeproj -scheme livenote2 -configuration Release build -destination 'platform=macOS,arch=arm64'`로 전체 로그를 받아 `grep -oE "\.swift:[0-9]+:[0-9]+: error: .{0,150}"`.
- 설치: `/Applications/LiveNote.app` 교체 후 `open`. 앱 이름은 LiveNote, 번들 ID는 `com.byungjoo.livenote2`(변경 금지: 권한·키체인·UserDefaults 유지).
- 서명: Personal Team `W48965CX9B`(pbxproj DEVELOPMENT_TEAM). 이 덕에 재설치해도 마이크·시스템 오디오·손쉬운 사용 권한이 유지된다. ad-hoc으로 되돌리지 말 것.
- **녹음 중 설치 금지**: `tail -1 ~/Documents/LiveNote/logs/app.log`가 `세션 시작`이고 `세션 중지`가 아직 없으면 회의 중이다. cloud.log 갱신 시각도 참고.
- 아카이브 실패 "couldn't be removed because you don't have permission": DerivedData(`~/Library/Developer/Xcode/DerivedData/livenote2-*`) 삭제 후 재빌드.
- 첫 서명 빌드 시 키체인 접근 대화상자가 뜨면 사용자가 "항상 허용"을 눌러야 진행된다.

## 데이터·로그
- 회의: `~/Documents/LiveNote/<yyyy-MM-dd HHmm 제목>/` (session.json, en.md, ko.md, combined.md, summary.md). 오디오는 저장하지 않는다(2-pass 후 임시 WAV 삭제).
- 채팅: `~/Documents/LiveNote/chats/*.json`. 로그: `~/Documents/LiveNote/logs/{app,cloud,chat,summary,zoomtag}.log` (내용은 기록하지 않음, 상태·크기·오류만).
- Gemini API 키: 키체인 `com.byungjoo.livenote2.gemini`.
- `~/Documents/LiveNote-v1-archive`는 폐기된 v1 파이썬 프로젝트. 건드리지 말 것.

## 규칙
- 커밋 메시지 끝에 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. 작업 단위마다 커밋·푸시(`git push` to origin main).
- 버전은 마이너/패치로 올리고 package.sh 인자로 전달. 기능 변경 시 스펙 문서 해당 절 갱신.
- UI 문자열은 영어. 코드 주석·문서는 한국어 가능. 문서·주석에 em dash(—) 금지.
- 회의록·번역 출력 언어는 Settings(Summary language, Translation language)를 따른다.
- 실시간 경로(라이브 전사·번역·채팅)의 지연을 늘리는 변경은 회의 후(2-pass) 또는 회의 전(브리핑)으로 옮긴다.

## 현재 상태와 알려진 사실 (2026-09-02)
- Zoom 최신 버전은 타일 AX 설명에 "active speaker" 토큰을 더 이상 노출하지 않는다(zoomtag.log 원문으로 확인). 1:1 회의는 "나 외 유일 타일" 폴백으로 상대방 이름을 붙인다. 그룹 회의 화자명은 Phase 3 Speaker Memory(오프라인 DiarizerManager 임베딩)로 해결 예정.
- 내 이름 우선순위: Zoom 타일 이름 > 마지막 Zoom 이름(UserDefaults zoomSelfName) > macOS 계정 이름.
- 2-pass 재디코딩은 마이크 WAV에 에코가 섞이므로 EchoDedup(채널 간 텍스트 유사도)이 필수다.
- 스마트 검색(FTS5·agentic)은 2차 프로젝트로 보류. Scratchpad/템플릿은 제외 결정.
