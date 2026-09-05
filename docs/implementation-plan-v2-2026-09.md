# LiveNote v2 구현 기획서 (Phase별)

작성일 2026-09-02. 기준 v1.3.0. 제품 개선 기획서(docs/product-plan-v2-2026-09.md)의 기술 분석을 실제 코드 변경 단위로 옮긴 문서. 실제 코딩은 이 문서를 기준으로 Phase 순서대로 진행한다.

공통 규칙
- 한 Phase = 한 마이너 버전(v1.4 → v1.8). 각 Phase 끝에 package.sh 빌드, 설치, 실회의 검증, 스펙 문서 갱신, 커밋·푸시.
- 새 파일은 `livenote2/` 아래 기존 폴더 구조(Engine / Storage / Calendar / Models)를 따른다. 새 뷰는 ContentView.swift가 이미 1,400줄이므로 `Views/` 폴더를 신설해 화면 단위로 분리한다(기존 뷰 이동은 하지 않음).
- 기능 플래그: 새 기능은 Settings 토글 또는 UserDefaults 키로 끌 수 있게 하고, 기본값은 켬.
- 하위 호환: session.json 신규 필드는 전부 optional. 구 폴더는 그대로 열린다.
- 로그: 새 카테고리(brief/recipe/voice/tasks)에 크기·상태·오류만 기록, 내용은 기록하지 않는다(기존 원칙).

의존 관계
```
Phase 0 (기반·G 일부) ─┬─> Phase 1 (Recipes)
                       ├─> Phase 2 (Tasks → Brief)   [Brief는 attendees(P0) + Tasks(P2 전반) 의존]
                       ├─> Phase 3 (Speaker Memory)  [2-pass(v1.2.0) 의존, P0의 attendees 활용]
                       └─> Phase 4 (전사 편집·용어 학습, People 뷰, 리마인더, 내보내기)
```

---

## Phase 0: 기반 확장 + 알림 분할 버튼 + 소소한 개선 (v1.4.0)

목표: 이후 Phase가 기대는 데이터(참석자, 컨텍스트 빌더, 뷰 분리)를 먼저 깔고, 즉시 체감되는 작은 UI 개선을 함께 출시한다.

### 0.1 데이터 모델
- `Models/TranscriptModels.swift` 또는 `Storage/MeetingStore.swift`의 `SavedMeeting`에 `attendees: [Attendee]?` 추가. `Attendee { name: String; email: String? }`, Codable, optional.
- `AppState.start()`에서 `calendar.attendeesForOngoingMeeting()`(현재 이름만 반환)을 이메일 포함 버전으로 확장(`CalendarMonitor`에 `ongoingMeetingAttendees() -> [Attendee]` 추가, EKParticipant.url의 mailto 로컬파트를 email로).
- `persistCurrentSession()`에 attendees 전달, `MeetingStore.save(...)` 시그니처에 attendees 추가, `writeAll`에서 session.json에 기록. `MeetingSummary`(목록용)에도 attendees 포함(People 뷰 대비).

### 0.2 컨텍스트 빌더 승격
- 신규 `Engine/ContextBuilder.swift`: `static func build(meetings: [MeetingSummary], store: MeetingStore, budget: Int, perMeetingTranscriptCap: Int) -> (text: String, used: [MeetingSummary], truncated: Int)`. 회의 헤더(제목·날짜·참석자·소요) + summary.md 우선, 없으면 전사 앞부분.
- `AppState.buildChatContext(.archive)`를 ContextBuilder 호출로 교체(동작 동일, 리팩터).

### 0.3 알림 팝업 분할 버튼 (Granola 캡처)
- `Calendar/MeetingAlertPanel.swift`: 현재 [Join] 버튼을 HStack(spacing 0)의 분할 버튼으로 교체.
  - 주 버튼: 라벨 `"Join \(platformName) & start LiveNote"`, platformName은 링크 호스트로 결정(zoom.us → Zoom, teams → Teams, meet.google → Meet, webex → Webex, 그 외 "meeting"). 아이콘은 `video.fill`.
  - ▾ 버튼: `Menu` with "Join meeting only", "Start LiveNote only", Divider, "Change notification settings".
  - 콜백 확장: 기존 `onJoin` 외 `onJoinOnly`, `onRecordOnly`, `onOpenSettings`. `AppState`에서 각각 `NSWorkspace.open(link)`만 / `start()`만 / `screen = .settings` + 창 활성화로 배선(Screen 상태는 ContentView 소유이므로 AppState에 `pendingScreen` 신호 추가 후 ContentView가 onChange로 반영).
  - 부제 줄: 브리핑이 있으면 Suggested agenda 1행(Phase 2 이후 채워짐, 이번엔 nil 처리).
- 검증: 알림 팝업에서 세 경로 각각 동작, Zoom 백그라운드 상태에서 Join only가 회의 참가로 이어지는지.

### 0.4 임시 회의 자동 제목
- `AppState.generateSummaryForCurrentSession()` 완료 시 `meetingTitle == nil`이면 요약 첫 줄 H1을 제목으로 채택(`# ` 제거, 60자 컷). `MeetingStore`에 `rename(at:url, title:)` 추가: session.json 갱신 + 폴더명을 `makeUniqueFolder` 규칙으로 rename(단 1회, `currentMeetingURL` 갱신).
- 검증: 캘린더 없이 Start → stop → 요약 후 Home 목록과 폴더명에 제목 반영.

### 0.5 대면 회의 모드 (기본형)
- `AppState.start(mode: StartMode = .online)`; `.inPerson`이면 `SystemAudioTap`을 열지 않고, 다이어라이저를 강제 준비하며, 마이크 샘플을 `.them` 채널로도 다이어라이저에 공급(현재 diarizerContinuation는 them만 받으므로 분기 추가). 화자 라벨은 슬롯(Speaker N)으로 표시, me 식별은 Phase 3에서 성문으로 승격.
- Home Start 버튼을 `Menu` 분할: "Start" / "Start in-person". LiveMeetingView 헤더에 모드 배지.
- 검증: 스피커폰으로 두 명 대화 → 슬롯 2개 분리.

### 0.6 자동 시작 카운트다운
- 신규 `Calendar/CountdownPanel.swift`(NSPanel, MeetingAlertPanel 패턴 재사용): 5초 카운트다운 + Cancel. 
- `AppState`의 회의 앱 실행 감지 자동 시작 경로에서 즉시 `start()` 대신 패널 표시 → 만료 시 start. 캘린더 회의 시작 시각 자동 시작은 옵션(`autoStartAtCalendarTime`, 기본 끔).
- Settings > Meetings: "Countdown before auto-start (5s)" 토글.

### 0.7 뷰 파일 분리 준비
- `Views/` 폴더 생성. 이번 Phase의 신규 화면은 없지만, Phase 1부터 `Views/RecipesSheet.swift` 등으로 추가한다. 기존 ContentView는 건드리지 않는다.

규모: 2일. 리스크: attendees 캡처가 회의 시작 시점 캘린더 상태에 의존(시작 10분 전~종료 창 로직 재사용).

---

## Phase 1: Recipes (v1.5.0, 완료: 2026-09-03)

구현 메모: 계획 대비 세 가지가 늘었다. 후속 채팅이 레시피 컨텍스트를 계속 근거로 쓰도록 `ChatMessage`/`SavedChat.Message`에 `promptText` 필드를 추가했다(계획엔 없던 항목, 구버전 chats/*.json과는 옵셔널로 호환). `systemPrompt` 오버라이드는 계획에 적힌 `GeminiChat`에 더해 `LocalChatEngine.respond`에도 추가해 로컬 폴백에서도 레시피 시스템 프롬프트가 적용되게 했다. 채팅 라벨에 예산 초과로 잘린 회의 수(truncated)를 표시하도록 늘렸다. 편집 폼은 `Views/RecipeEditorView.swift` 별도 파일로 뺐다(계획에는 Settings 카드 안 폼으로 적혀 있었으나, 다른 Views/* 분리 원칙에 맞췄다).

### 1.1 저장소
- 신규 `Storage/RecipeStore.swift`: `Recipe` Codable(id, title, icon, builtin, scopeDefault, modelHint, outputLanguage, system, prompt). 폴더 `~/Documents/LiveNote/recipes/`. `refresh()`, `upsert()`, `delete()`, `resetBuiltins()`.
- 내장 레시피 5종은 `Resources/Recipes/*.json`으로 번들에 포함, 첫 실행 시 폴더에 복사(`ModelSeeder` 패턴). `weekly-update.json`의 system 프롬프트에 주간보고 규칙 6항목을 명문화한다(1인칭 주어 생략, 판단·논리 흐름 서술 패턴, SA 행위 중심, 나열 금지, 배정 경위 미기재, 인과 압축, 계정별 단락, 한국어 출력, 고유명사 영문 유지).

### 1.2 실행 엔진
- 신규 `Engine/RecipeRunner.swift`: `run(recipe:, meetings:, model: ChatModelChoice, language:) async throws -> String`.
  - ContextBuilder로 컨텍스트 조립(budget 120K자).
  - 프롬프트 = recipe.prompt에서 `{{meetings}}` 치환, `{{today}}`, `{{language}}` 지원.
  - 모델: recipe.modelHint == "thinking"이면 `.gemini37FlashThinkingMedium` 기본, 사용자 덮어쓰기 허용. API 키 없으면 `LocalChatEngine` 경로.
  - 호출은 `GeminiChat.respond(context:history:question:...)`를 재사용하되 systemInstruction을 레시피 system으로 바꿔야 하므로 `GeminiChat.respond`에 `systemPrompt: String? = nil` 파라미터 추가(기본 ChatPrompt.system).
- 결과 처리(`AppState.runRecipe`): 새 채팅 시작(`startNewChat`) → 사용자 턴 = "Recipe: {title} ({scope label}, N meetings)" → 어시스턴트 턴 = 결과 → `persistCurrentChat()`. 동시에 `recipes-output/<yyyy-MM-dd> <title>.md` 저장. 후속 질문은 일반 채팅으로 이어진다(컨텍스트는 첫 사용자 턴에 포함해 두므로 history로 전달됨).

### 1.3 범위 선택
- 신규 `Models/RecipeScope.swift`: enum thisWeek / lastDays(Int) / currentMeeting(URL) / manual([URL]). `resolve(store:) -> [MeetingSummary]`. 주 시작은 월요일(Calendar.current.firstWeekday와 무관하게 고정, 주간보고 기준).

### 1.4 UI
- `Views/RecipesRow.swift`: 칩 행(내장 + 사용자 + See all). ChatFullView의 chatHome에서 히어로 아래에 삽입.
- `Views/RecipeRunSheet.swift`: 범위 세그먼트, 회의 미리보기 목록(체크 가능 = manual 전환), 모델 Picker(ChatModelMenu 재사용), 출력 언어, [Run]. 실행 중 ProgressView. 완료 시 시트 닫고 Chat 대화로.
- MeetingDetailView 툴바에 "Recipes" 메뉴(currentMeeting 범위 레시피만).
- Settings > Recipes 카드: 목록 + 편집 폼(제목/시스템/프롬프트/기본 범위/모델 힌트/언어) + 복제/삭제/Reset built-ins.

### 1.5 검증
- 이번 주 회의 5개로 Weekly Update 실행 → 계정별 단락, 주어 생략, 배정 경위 미기재 확인. 결과 md 파일 생성 확인. 후속 질문("MSG 단락 더 짧게")이 같은 대화에서 동작.
- 회의 0개일 때 비활성. API 키 없을 때 Qwen 경로 경고.

규모: 1.5일.

---

## Phase 2: Tasks + 사전 브리핑 (v1.6.0, 완료: 2026-09-05)

### 2.1 Tasks 추출 (D)
- `Engine/SummaryService.swift` userPrompt 끝에 tasks 블록 요구 문구 추가(회의 날짜를 프롬프트에 주입해 상대 기한을 절대 날짜로). `cleaned()`에서 `<!-- tasks … -->` 블록을 분리해 `(summary, tasksJSON)` 반환하도록 시그니처 확장(`cleanedWithTasks`). Gemini/Qwen 두 경로 모두 통과.
- 신규 `Storage/TaskStore.swift`: `TaskItem` Codable(id, meetingURL, meetingTitle, meetingDate, title, owner, due, quote, status, createdAt, completedAt). 회의 폴더 `tasks.json` 기록 + 전역 `tasks/index.json` upsert. 상태 변경은 index만. `open(for owners:)`, `open(for meetingURL:)` 조회.
- 담당자 정규화: attendees(P0) + speakerNames + myName 토큰 매칭. "me/I/나" → myName.
- `AppState.generateSummaryForCurrentSession()` 완료 시 TaskStore에 저장.

### 2.2 Tasks UI
- `ContentView.Screen`에 `.tasks` 추가, 사이드바 레일에 "Tasks"(Chat 아래).
- `Views/TasksView.swift`: 필터 세그먼트(Open/Done/Mine/All), 그룹 토글(회의별/담당자별), 행(체크박스·제목·담당자 칩·기한·출처 회의 버튼 → `.meeting(url)`), 상단 수동 추가 입력줄.
- MeetingDetailView: 요약 아래 "Action items" 카드(체크 연동).
- HomeView Coming up: 각 일정에 연결된 미완료 태스크 수 배지(참석자 이름 매칭).
- "Extract tasks" 레시피 추가(Phase 1 저장소 이용, 과거 회의 소급용; 결과 JSON을 TaskStore에 import하는 특수 처리).

### 2.3 사전 브리핑 (B)
- 신규 `Engine/BriefGenerator.swift`:
  - `candidates(for event: UpcomingMeetingItem, store:) -> [MeetingSummary]`: 점수식(참석자 겹침 +3/명, 제목 Jaccard ≥0.5 +2, 30일 내 +1), 최근 90일, 상위 5. 참석자 8명 이상이면 nil.
  - `generate(event:, candidates:, openTasks:) async throws -> String`: ContextBuilder(budget 40K) + TaskStore.open + 이벤트 notes 앞 1,000자. 고정 3섹션 프롬프트. 모델 3.7 Flash standard(Qwen 폴백). 출력 언어 = Summary language 설정.
  - 저장 `briefs/<eventKey>.md`(+ 생성 시각 헤더). 캐시 존재 시 스킵.
- 신규 `Storage/BriefStore.swift`: 조회/저장/수동 무효화.
- 트리거(`AppState`): ① 07:00 일괄 `Task` 스케줄(앱 기동 시 다음 07:00 계산, 깨어남 감지는 `NSWorkspace.didWakeNotification`), ② `CalendarMonitor` 폴링 루프에서 시작 10분 전 이벤트 발견 시 없으면 생성, ③ Coming up 새로고침 버튼.
- `UpcomingMeetingItem`에 `attendees: [Attendee]`, `eventKey`, `notes` 추가(CalendarMonitor refreshTodayUpcoming에서 채움).
- 회의 저장 시 `brief.md` 사본을 회의 폴더에 복사(있을 때).

### 2.4 브리핑 UI
- HomeView Coming up 행: "Brief" 배지 + 클릭 펼침(SummaryRenderView), 하단에 "Based on: 회의 제목 3개" 줄(검증용), 새로고침 아이콘.
- LiveMeetingView: 시작 시 상단 접힌 Brief 패널(DisclosureGroup), 첫 확정 행이 생기면 접힘 유지.
- MeetingAlertPanel 부제: Suggested agenda 첫 항목(P0에서 만든 nil 슬롯 채움).
- Settings > Meetings: "Pre-meeting briefs" 토글, 생성 시각, "Skip meetings with 8+ attendees".

### 2.5 검증
- Craig 1:1 이벤트로 후보 회의가 "Philip / Craig" 과거 3건으로 잡히는지, Open items에 지난 회의 태스크가 오는지.
- 아침 일괄이 07:00에 오늘 일정 전부 생성하고 두 번 생성하지 않는지(캐시).
- Tasks 화면 체크 → index 반영 → 브리핑 Open items에서 사라지는지.

규모: 3일.

---

## Phase 3: Speaker Memory (v1.7.0)

### 3.1 오프라인 다이어라이저 도입
- 신규 `Engine/OfflineDiarizer.swift`(actor): FluidAudio `DiarizerModels.downloadIfNeeded()` + `DiarizerManager(config:)`, `initialize(models:)`. `diarize(url: URL) async throws -> DiarizationResult`(WAV 로드 → Float 배열 → `performCompleteDiarization`). 모델 캐시 위치는 FluidAudio 기본(~/Library/Application Support/FluidAudio/Models), `ModelSeeder` BUNDLE_MODELS 대상에 추가.
- `TranscriptRefiner.refine(...)`에 `diarization: DiarizationResult?` 입력을 추가하고, them 채널 정제 행에 세그먼트 겹침으로 `clusterID`(임시 필드)를 붙인다.
- `AppState.stop()` 2-pass 블록: 재디코딩과 병렬로 `OfflineDiarizer.diarize(themWAV)` 실행(`async let`), 둘 다 끝나면 정제 + 명명 + 등록 순서.
- 시간 예산: 1시간 회의 60초 초과 시 로그 경고, 다음 회의부터 발화 구간만(에너지 게이트 마스크) 처리하는 옵션 활성.

### 3.2 성문 저장소
- 신규 `Storage/VoiceprintStore.swift`: `Person { id, name, aliases, email?, centroids: [Centroid{v,n,quality,updated}], meetings, lastSeen, sources }`. 파일 `voiceprints.json`. API: `match(embedding) -> (person?, d1, d2)`, `enroll(name:, embeddings:, quality:, source:)`, `merge(a,b)`, `rename`, `delete`, `forgetAll`.
- 코사인 거리 구현은 FluidAudio `SpeakerManager.findSpeaker` 재사용 가능하나, 다중 중심·마진 규칙이 필요해 자체 구현(256차원 벡터 연산은 Accelerate vDSP).
- 임계값: `matchThreshold`(초기값은 SpeakerManager.speakerThreshold 기본값), `margin` 0.08, `mergeThreshold`, `minEnrollSeconds` 20, `minQuality` 0.6. 전부 UserDefaults로 튜닝 가능(디버그).

### 3.3 명명·등록 로직
- 신규 `Engine/SpeakerMemory.swift`:
  - `assignNames(refinedRows, diarization, zoomNames, fallbackName) -> rows`: 클러스터별 중심 임베딩(세그먼트 임베딩의 품질 가중 평균) → `VoiceprintStore.match` → 우선순위 Zoom 태그 > 성문 > 슬롯. 마진 미달 시 `candidateNames`(2명)를 행 메타에 기록(UI 제안용).
  - `enroll(from rows, diarization)`: 이름이 확정된(Zoom·폴백·수동) 클러스터의 임베딩을 등록. 충돌(성문 이름 ≠ Zoom 이름)은 Zoom 이름으로 등록하고 기존 중심 conflict 카운트 증가, 3회면 폐기.
- `TranscriptRow`에 `nameSource: enum {zoom, voice, slot, manual}?` 추가(칩 아이콘용), `candidateNames: [String]?`.
- 수동 명명: 상세·라이브 화자 칩 팝오버에서 이름 지정 시 "Remember this voice" 체크(기본 켬) → 해당 슬롯/클러스터 임베딩으로 enroll(라이브 중에는 stop 시 2-pass 결과로 수행).

### 3.4 라이브 승격 (3b)
- `SpeakerDiarizer`(LS-EEND)의 슬롯별 누적 오디오(them 채널 원본 샘플, 슬롯 구간 30초분)를 링버퍼로 유지. 30초 도달 시 `OfflineDiarizer.extractEmbedding(samples)`(=`DiarizerManager.extractSpeakerEmbedding`) 1회 → `VoiceprintStore.match` → 매칭되면 `speakerNames[slot] = name`(기존 rename 경로 재사용, 재저장 디바운스). 백그라운드 우선순위 `.utility`.
- 대면 모드(P0.5)에서 me 식별: 내 성문을 별도로 등록(첫 온라인 회의의 마이크 채널에서 자동 등록) → 대면 모드 슬롯이 내 성문과 매칭되면 me로 표시.

### 3.5 UI
- 화자 칩 아이콘: zoom `video`, voice `waveform`, manual `pencil`, slot 없음. 팝오버에 candidateNames 우선 표시.
- Settings > Speakers 카드(`Views/SpeakersSettings.swift`): 목록(이름·회의 수·마지막), 이름 변경, 병합(두 항목 선택 후 Merge), 삭제, Forget all voices, 프라이버시 문구.
- 회의 상세: "Speakers" 요약 줄(이름별 발화 시간, 다이어라이제이션 세그먼트 합).

### 3.6 검증 계획
- 회의 A(Zoom 태그 정상)에서 등록 → 회의 B(Teams 또는 발표자 보기)에서 자동 명명 확인. 3~5회의로 threshold/margin 튜닝(로그 `voice`에 d1/d2 기록).
- 오프라인 다이어라이저 처리 시간 로그.
- 에코 케이스: them 채널 내 목소리 세그먼트가 내 성문과 매칭되어 제외되는지(3b 이후).

규모: 4일 (3a 2.5일, 3b 1.5일).

---

## Phase 4: 전사 편집·용어 학습 + People 뷰 + 리마인더 + 내보내기 (v1.8.0)

**4.1 및 4.3 완료 (2026-09-05, codex 승인 라운드 5, 테스트 442개). 4.2 People 뷰와 4.4 내보내기는 2차 실행에서 v1.8.0으로 묶어 완료 예정.**

### 4.1 전사 편집·찾아바꾸기 (F) (완료)
- `MeetingDetailView` 전사 행 더블클릭 인라인 TextField(이미 `editingRowID` 상태 존재, 화자 편집용이던 것을 텍스트 편집으로 확장). 저장 시 `MeetingStore.updateRow(at:url, rowID:, english:)` → session.json + md 재생성 + `edits.json` append.
- `Views/FindReplaceBar.swift`: ⌘F로 토글, 검색어/치환어, 대소문자·단어 단위, 일치 수, [Replace all], "Also apply to summary" 체크. `MeetingStore.replaceAll(...)` 구현.
- 용어 학습 토스트: 치환 대상이 대문자 시작 또는 전부 대문자(약어)면 "Add 'X' to internal jargon?" → `setInternalJargon` append.
- "Edited N" 배지 + Undo 메뉴(edits.json 역순 적용).
- 재요약 제안 배너(편집 5건 이상).
- 디코더 반영(word boost)은 라이브 경로 교체 작업으로 이관(이 Phase 범위 밖).
- 실제 구현 및 설계 구체화: `edits.json`은 원자적 배치 로그(inline/replaceAll 배치, before/after 및 요약 변경 기록)로 관리, 되돌리기(Undo)는 LIFO 단일 배치 단위로 디스크 텍스트 일치 충돌 검증 후 복원, 트랜잭션 스테이징 및 고정 순서(`session.json` 최우선 -> `edits.json` -> md 파일들) 커밋, 요약 전용 찾아바꾸기도 1건의 편집으로 가산, 비단어 문자(예: C++)로 시작/끝나는 용어의 `\b` 폴백 처리.

### 4.2 People / Accounts 뷰 (G.7)
- HomeView 상단 세그먼트 "Meetings | People". `Views/PeopleView.swift`: attendees(P0) + speakerNames 집계 → 사람 카드(회의 수, 마지막, 열린 태스크 수). 클릭 → 그 사람 회의 타임라인(기존 meetingCard 재사용). 이메일 도메인으로 회사 그룹핑(선택).

### 4.3 녹음 리마인더 (G.5) (완료)
- 신규 `Engine/RecordingReminder.swift`: 60초 주기. 조건 = 회의 앱 실행 중 + 기본 입력 장치 `kAudioDevicePropertyDeviceIsRunningSomewhere` true + `!app.isActive`. 세션당 1회 `NSUserNotification`(UNUserNotificationCenter) "Meeting in progress? [Start LiveNote]". Settings > Meetings 토글.
- 실제 구현 및 설계 구체화: Condition C(회의 앱 실행 중 + 기본 입력 오디오 장치 사용 중 + LiveNote 유휴 상태)를 60초 주기로 평가, 2회 연속 충족 시 회의당 1회 `UNUserNotificationCenter` 알림 발송, 단일 비행(single-flight) 지연 권한 요청, 세대(generation) 가드 기반 오래된 비동기 배송 무효화, Settings > Meetings 토글 및 권한/에러 상태 메시지, `reminder.log` 로깅.

### 4.4 내보내기 (G.6)
- MeetingDetailView 툴바: "Copy summary"(md → NSPasteboard), "Export…"(NSSavePanel, md/HTML; HTML은 SummaryRenderView 규칙을 간단 변환). 레시피 결과 대화에도 동일 버튼.

### 4.5 검증
- 이름 오인식 5건 찾아바꾸기 → md 반영, jargon 추가, 다음 회의 교정 풀 적용.
- People 뷰에서 Craig 클릭 → 회의 타임라인.
- Zoom 회의 중 LiveNote 미기동 시 60초 후 알림 1회.

규모: 2.5일.

---

## Phase 요약

| Phase | 버전 | 내용 | 규모 | 산출물 검증 포인트 |
|---|---|---|---|---|
| 0 | v1.4.0 | attendees·ContextBuilder 기반, 알림 분할 버튼, 자동 제목, 대면 모드, 카운트다운 | 2일 | 팝업 3경로, 제목 폴더 반영 |
| 1 | v1.5.0 | Recipes(내장 5 + Weekly Update 규칙) | 1.5일 | 금요일 주간보고 초안 |
| 2 | v1.6.0 | Tasks 추출·화면, 사전 브리핑 (완료 2026-09-05) | 3일 | Craig 1:1 브리핑 |
| 3 | v1.7.0 | Speaker Memory(오프라인 등록·매칭, 라이브 승격) (완료 2026-09-05) | 4일 | Teams/발표자 보기 자동 명명 |
| 4 | v1.8.0 | 전사 편집·용어 학습, People 뷰, 리마인더, 내보내기 (4.1·4.3 완료 2026-09-05, 4.2·4.4 진행 예정) | 2.5일 | 오인식 정정 루프 |

총 13일 규모. Phase 1은 Phase 0 직후 가장 먼저 체감되는 항목이므로, Phase 0에서 ContextBuilder만 먼저 끝내면 Phase 1을 병행 착수할 수 있다.

## 보류·이관 항목
- 라이브 경로 교체(Nemotron 스트리밍 / SlidingWindowAsrManager + word boost): 14초 창 휴리스틱 폐기 작업. 별도 트랙으로, Phase 4의 용어 학습이 끝나면 jargon을 디코더에 공급하는 형태로 연결.
- 스마트 검색(FTS5 + agentic): 2차 프로젝트. People 뷰(P4)와 attendees(P0)가 그때의 메타데이터 필드가 된다.
- Scratchpad·템플릿(E): 제외 결정.

## Phase 2 후속 항목 (codex 리뷰 7라운드 후 보류, 2026-09-05)
- TaskStore 2파일 커밋(회의 `tasks.json` → `tasks/index.json`)의 크래시 내구성: 두 쓰기 사이에 강제 종료되면 세대 불일치가 남는다. 저널/커밋 마커와 시작 시 복구가 필요하면 Phase 4 저장소 정리 때 함께 다룬다. 현재는 `.prev` 백업과 `commitFailed` 오류 표면화까지만 구현.
- 브리핑 세션 귀속: `start()`가 `calendar.ongoingUpcomingItem()` 휴리스틱으로 이벤트를 고른다(Phase 0의 제목·참석자 캡처와 동일 방식). Coming up의 Start now와 캘린더 자동 시작이 정확한 `eventKey`를 넘기도록 바꾸면 겹친 일정·수동 시작의 오귀속이 사라진다.
- `scheduleMorningBatch` 재호출 시 wake observer가 첫 provider를 유지한다(현재 init에서 1회만 호출하므로 영향 없음). provider를 저장 프로퍼티로 바꾸고 startup task에 취소 확인을 넣을 것.
- 아침 배치의 LLM 호출 상한(일일 N건, 초과분은 10분 전 트리거·수동 새로고침으로): 공유 캘린더 사용자 대비.

## Phase 3 완료 (v1.7.0, 2026-09-05)

codex critic 리뷰 14라운드에서 승인 완료 (2026-09-05, 라운드 11부터 원장 프로토콜 적용).
테스트 374개 전체 통과 및 Release 빌드 검증 완료.
Phase 3 (Speaker Memory, v1.7.0) 구현 및 안정화 완료.

### 구현 요약
- FluidAudio DiarizerManager 기반 오프라인 다이어라이제이션 (them WAV 처리, clusterID 매핑, voice 카테고리 소요 시간 로깅)
- VoiceprintStore: 다중 센트로이드(최대 5개) 코사인 유사도 매칭(matchThreshold + margin d1/d2), 3회 충돌 시 센트로이드 자동 제거, copy-on-write 파일 저장(voiceprints.json) 및 .corrupt 백업
- 화자 명명 우선순위 적용: Zoom 태그 > 성문 매칭 > 슬롯명 > 폴백 순서이며, 사용자가 수동 편집한 manual 라벨은 절대 덮어쓰지 않고 후보 화자명(candidateNames) 보존
- 마이크 WAV 스트리밍 유성 구간 스캔을 통한 Me 성문 자동 등록 (침묵 제외 최대 60초 유성 발화 수집, them 채널 매칭 시 Me 제외)
- 전용 임베딩 추출기를 통한 라이브 슬롯 승격 (LS-EEND 30초 유성 발화 누적 시 백그라운드 매칭 및 슬롯명 자동 승격)
- 비동기 2-pass 수명주기: 세션 스냅샷 분리, 120초 대기 경주(TimeoutRace), 디스크 수동 편집본과 다이어라이제이션 결과 병합, 세션 WAV 폴더 리스(ActiveFolderRegistry) 및 30분 보존 마커, 저장 실패 시 재시도(pendingDiarizationResults)

### Phase 3 후속 항목 (codex follow-ups, 비차단)
- (r13) TwoPassJob.makeEmbeddingEngine 실제 배선을 구동하는 통합 테스트 보강 (현재 결함 증거 없음).
- (r12) SessionAudioRecorder.deleteFiles() 실패 시 단순 로깅 외 재시도 또는 다음 purge 예약 추가로 민감한 임시 WAV 잔류 방지 (현재 다음 앱/세션 시작 시 purge로 완화).
- (r12) 실제 하드웨어에서 3개의 FluidOfflineEngine 인스턴스에 대한 메모리 및 모델 초기화 비용 측정 (수동 QA).
- (r11) WAVStreamReader가 선언된 데이터 청크보다 짧은 파일을 정상 EOF로 처리하는 동작을, 외부 WAV 입력 허용 시 명시적 오류로 전환 (현재 자체 생성 세션 WAV에서는 허용).

### 수동 QA 항목
- Zoom 회의 A에서 화자 성문 등록 후, 태그가 없는 회의 B에서 성문으로 자동 명명되는지 확인 (`voice` 로그 d1/d2 마진 확인)
- 45분 길이 WAV에 대한 오프라인 다이어라이제이션 소요 시간 및 메모리 부하 확인
- 에코 케이스 검증: them 채널 구간이 내 성문(isMe)과 매칭되어 오분류되지 않는지 확인
- Teams 통화에서 30초 발화 후 라이브 승격(Live promotion)이 정상 동작하는지 확인
- 3개의 FluidOfflineEngine 인스턴스(오프라인 다이어라이저, 라이브 임베딩 추출기, Me 등록 임시 추출기)의 메모리 점유 및 초기화 비용 확인

## Phase 4a 후속 항목 (codex follow-ups, 비차단)
- (r1) 최초 리마인더 알림까지 약 120초 소요 (60초 첫 틱 + 2회 연속 히트): 시작 시 즉시 첫 프로브 실행 검토.
- (r1) 요약 생성 전에 수행된 편집을 되돌릴 경우 editCount가 editsAtLastSummary 아래로 감소하여, 이후 수정된 요약에 대해 배너가 트리거되지 않을 수 있음.
- (r1, disputed) 1글자 교체어는 전문용어로 제안하지 않음 (리드 결정: 교정 풀 노이즈 방지).

### Phase 4a 수동 QA 항목
- ⌘F 전사 숨김 상태 토글: 전사 표시가 꺼진 상태에서 ⌘F 또는 "Find & Replace" 클릭 시 "Show transcript"가 자동으로 켜지며 FindReplaceBar가 열리는지 확인
- 화자 팝오버 열림 중 더블클릭 편집: 화자 이름 변경 팝오버(`SpeakerNamePopover`)가 열린 상태에서 인라인 편집 상호작용이 독립적으로 안전하게 동작하는지 확인
- 요약 재생성 후 되돌리기: 요약을 변경한 배치를 Undo할 때 전사 행과 요약 마크다운이 함께 복원되거나, 요약이 이미 재생성된 경우 충돌 오류가 정상 표시되는지 확인
- 전문용어 토스트 12초 타이머: 제안 토스트가 12초 후 자동 닫히거나 다른 화면 이동 시 취소되는지 확인
- 유휴 회의 리마인더 알림: LiveNote가 멈춘 상태에서 Zoom 마이크 활성화 시 약 60~120초 후 시스템 배너 알림("Meeting in progress? Zoom is using the microphone but LiveNote is not recording.")이 1회 발송되는지 확인
- "Start LiveNote" 액션: 알림의 "Start LiveNote" 버튼 또는 배너 클릭 시 LiveNote 창이 활성화되고 녹음 세션이 즉시 시작되는지 확인
- 알림 억제 및 리셋: Zoom 회의가 지속되는 동안 중복 알림이 발생하지 않으며, Zoom 종료 후 재참가 시 2틱 후 다시 알림이 오는지 확인
- 설정 토글 동작: Settings > Meetings에서 녹음 리마인더 토글을 끄면 타이머가 중지되고 알림이 발생하지 않는지 확인
- 동일 회의 중 토글 껐다 켜기: Zoom 회의 중 알림이 이미 발송된 후 설정을 껐다 켜도 동일 회의 내에서 중복 알림이 발생하지 않는지 확인
- 알림 권한 거부: 시스템 설정에서 알림 권한을 끈 경우 토글 아래에 "Notifications are off for LiveNote in System Settings > Notifications." 상태 메시지가 노출되는지 확인
- 세션 교체 요약 저장 실패 에러 처리: 백그라운드 요약 생성 중 세션 교체로 읽기 전용 폴더에 저장 실패 시 "Minutes for the previous meeting could not be saved: <error>" 배너가 노출되는지 확인
