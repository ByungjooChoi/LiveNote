import AppKit
import Foundation
import Observation

/// 종료를 감지할 회의 앱 번들 ID.
/// (Sendable 클로저에서 참조하므로 MainActor 격리 밖의 파일 스코프 상수로 둠)
private let meetingAppBundleIDs: Set<String> = [
    "us.zoom.xos",              // Zoom
    "com.microsoft.teams2",     // Teams (신버전)
    "com.microsoft.teams",      // Teams (구버전)
    "Cisco-Systems.Spark",      // Webex
]

/// 앱 전체 상태와 파이프라인 배선.
/// 오디오 콜백(오디오 스레드) → AsyncStream → 엔진/화자구분(actor) → 콜백 → MainActor UI 갱신.
/// 회의가 끝나면 MeetingStore를 통해 ~/Documents/livenote2/ 에 저장됩니다 (오디오 미저장).
@MainActor
@Observable
final class AppState {

    enum Phase: Equatable {
        case idle
        case preparing(String)
        case listening
        case error(String)
    }

    // MARK: - UI 상태

    var phase: Phase = .idle
    var rows: [TranscriptRow] = []
    var volatileText: [AudioChannel: String] = [.me: "", .them: ""]
    var systemAudioAvailable = true
    var systemAudioMessage: String?
    var diarizerMessage: String?
    /// 자동 중지 등 정보성 안내 (파란 배너)
    var noticeMessage: String?
    /// 마이크 입력 레벨 (0~1, 헤더 미터용)
    var micLevel: Float = 0
    /// 에코 필터(엔진의 채널 간 에너지 게이트) 사용 여부. 끄면 텍스트 중복 제거만 동작.
    private(set) var echoFilterEnabled = true
    /// 마이크 뮤트. 켜면 "나" 채널 오디오를 엔진에서 버림 — 에코 유입도 원천 차단.
    /// 세션 시작 시 항상 해제 상태로 리셋 (지난 회의의 뮤트를 잊는 사고 방지).
    private(set) var micMuted = false

    /// 화자 이름. 세션이 바뀌어도 유지됩니다.
    var myName = "Philip"
    var speakerNames: [Int: String] = [:]
    /// 현재 회의의 캘린더 참석자 이름 후보 (화자 rename 원클릭용, 시작 시점에 조회)
    private(set) var attendeeCandidates: [String] = []

    let translator = TranslationCoordinator()
    let meetingStore = MeetingStore()
    /// 캘린더 회의 임박 알림 (1분 전 팝업 + Zoom 참가)
    let calendar = CalendarMonitor()
    /// Zoom 활성 화자 태그 (AX) — 화자 자동 명명 + 뮤트 동기화
    @ObservationIgnored let zoomTagger = ZoomSpeakerTagger()
    /// Zoom 뮤트와 마이크 캡처 동기화 (기본 켜짐)
    private(set) var syncMuteWithZoom = true
    /// Zoom 태그용 손쉬운 사용 권한 안내 배너
    var zoomTagMessage: String?
    /// Internal jargon (쉼표 구분) — ASR 고유명사 교정 풀에 참석자 이름과 함께 사용
    private(set) var internalJargon: String = ""
    /// 로컬 LLM 선택 (요약·로컬 채팅 공유)
    private(set) var localModelID: String = SummaryService.defaultModelID
    /// Zoom 동기화로 뮤트된 상태 (수동 뮤트와 구분 — 발화 경고 억제용)
    @ObservationIgnored private var micMutedByZoom = false
    /// 클라우드 번역 (Gemini Live Translate) — 번역 모드가 .cloud일 때만 동작
    @ObservationIgnored let gemini = GeminiLiveTranslator()

    /// 번역 사용 여부 (체크박스). 백엔드와 독립 — 꺼도 백엔드 선택은 요약·채팅에 계속 적용.
    private(set) var translationEnabled = true
    /// 처리 백엔드 (번역·요약 제공자). 로컬=Apple+Qwen, 클라우드=Gemini.
    private(set) var backend: ProcessingBackend = .local
    /// 클라우드 번역 문제 안내 배너 (nil이면 정상)
    var cloudTranslationMessage: String?
    /// 클라우드 번역 연결 상태 (헤더 표시등, nil이면 비활성)
    var cloudStatus: CloudStatus?
    /// Gemini API 키 입력 시트 표시
    var showGeminiKeyPrompt = false

    // MARK: - AI 채팅 (Granola식 하단 대화창)

    /// 채팅 범위: 라이브(현재 회의) / 저장 회의 / 전체 아카이브
    enum ChatScope: Equatable {
        case live
        case saved(URL)
        case archive

        var key: String {
            switch self {
            case .live: return "live"
            case .saved(let url): return "saved:\(url.path)"
            case .archive: return "archive"
            }
        }
    }

    var chatMessages: [ChatMessage] = []
    var chatBusy = false
    /// 채팅 모델 (상단 백엔드와 독립, 영속)
    private(set) var chatModel: ChatModelChoice = .cloudGemini
    @ObservationIgnored private var chatScopeKey: String?
    @ObservationIgnored private let localChat = LocalChatEngine()

    func setChatModel(_ model: ChatModelChoice) {
        chatModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "chatModel")
    }

    /// 범위(라이브/세션/아카이브)가 바뀌면 대화를 새로 시작.
    func ensureChatScope(_ scope: ChatScope) {
        guard chatScopeKey != scope.key else { return }
        chatScopeKey = scope.key
        chatMessages = []
    }

    func askChat(_ question: String, scope: ChatScope) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatBusy else { return }
        ensureChatScope(scope)
        chatMessages.append(ChatMessage(role: .user, text: trimmed))
        chatBusy = true
        AppLog.write("chat", "질문 scope=\(scope.key.prefix(40)) model=\(chatModel.rawValue) 질문=\(trimmed.count)자")

        let context = buildChatContext(scope)
        let history = chatMessages.dropLast().suffix(8).map { (isUser: $0.role == .user, text: $0.text) }
        let model = chatModel
        let localRef = localChat

        Task { [weak self] in
            var answer: String
            do {
                switch model {
                case .cloudGemini:
                    guard let key = GeminiKeychain.load() else {
                        throw NSError(domain: "livenote2.chat", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "No Gemini API key. Select the Cloud backend once in Settings to register a key."])
                    }
                    answer = try await GeminiChat.respond(
                        context: context, history: Array(history), question: trimmed, apiKey: key)
                case .localQwen:
                    answer = try await localRef.respond(
                        context: context, history: Array(history), question: trimmed)
                }
            } catch {
                answer = "Failed: \(error.localizedDescription)"
            }
            await MainActor.run {
                guard let self else { return }
                self.chatMessages.append(ChatMessage(role: .assistant, text: answer))
                self.chatBusy = false
            }
        }
    }

    /// 범위별 회의 컨텍스트 구성 (60K자 상한).
    private func buildChatContext(_ scope: ChatScope) -> String {
        switch scope {
        case .live:
            let meeting = SavedMeeting(
                startedAt: sessionStartedAt ?? Date(),
                durationSeconds: rows.map(\.endSeconds).max() ?? 0,
                title: meetingTitle,
                myName: myName,
                speakerNames: speakerNames,
                rows: rows,
                summary: currentSummary
            )
            let transcript = MeetingStore.transcriptForSummary(meeting) { [self] row in
                displayName(for: row)
            }
            let state = isRunning ? "회의가 지금 진행 중이며 아래는 현재까지의 전사입니다." : "방금 끝난 회의의 전사입니다."
            let title = meetingTitle.map { "회의 제목: \($0)\n" } ?? ""
            return "\(state)\n\(title)\n\(String(transcript.suffix(60_000)))"
        case .saved(let url):
            guard let meeting = meetingStore.load(url) else { return "회의 기록을 불러오지 못했습니다." }
            let transcript = MeetingStore.transcriptForSummary(meeting) { row in
                MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
            }
            let title = meeting.title.map { "회의 제목: \($0)\n" } ?? ""
            let summary = meeting.summary.map { "요약:\n\($0)\n\n" } ?? ""
            return "\(title)\(summary)전사:\n\(String(transcript.suffix(60_000)))"
        case .archive:
            var parts: [String] = []
            var budget = 60_000
            for meeting in meetingStore.meetings.prefix(15) {
                guard budget > 2_000, let saved = meetingStore.load(meeting.url) else { continue }
                let body: String
                if let summary = saved.summary {
                    body = summary
                } else {
                    let transcript = MeetingStore.transcriptForSummary(saved) { row in
                        MeetingStore.resolveName(row: row, myName: saved.myName, speakerNames: saved.speakerNames)
                    }
                    body = String(transcript.prefix(1_500))
                }
                let section = "## \(meeting.title) (\(meeting.dateLabel))\n\(body)"
                parts.append(String(section.prefix(budget)))
                budget -= section.count
            }
            return parts.isEmpty
                ? "저장된 회의가 아직 없습니다."
                : "아래는 저장된 회의 전체 기록입니다.\n\n" + parts.joined(separator: "\n\n")
        }
    }

    // MARK: - 요약 상태

    enum SummaryPhase: Equatable {
        case idle
        case generating
        case failed(String)
    }
    var summaryPhase: SummaryPhase = .idle
    /// 현재(방금 끝난) 세션의 요약
    var currentSummary: String?

    /// 회의 앱(Zoom/Teams 등) 실행 감지 시 자동 시작
    private(set) var autoStartOnMeetingApp = false

    /// 방금 끝난 회의가 저장된 폴더 (중지 후 이름 변경·늦은 번역 도착 시 재저장 대상).
    private(set) var currentMeetingURL: URL?

    // MARK: - 자동 종료 감지 설정

    /// 이 시간 동안 양쪽 채널 모두 발화가 없으면 자동 중지·저장.
    private static let autoStopAfterSilence: TimeInterval = 4 * 60

    // MARK: - 파이프라인 구성요소
    // @ObservationIgnored: UI와 무관한 내부 상태를 Observation 추적에서 제외.
    // 오디오 스레드가 추적 프로퍼티를 읽으면 QoS 우선순위 역전(Hang Risk) 경고가 발생함.

    @ObservationIgnored private var engine: TranscriptionEngine?
    @ObservationIgnored private var speakerDiarizer: SpeakerDiarizer?
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var systemTap: SystemAudioTap?
    @ObservationIgnored private var audioContinuation: AsyncStream<(AudioChannel, [Float])>.Continuation?
    @ObservationIgnored private var diarizerContinuation: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var consumerTask: Task<Void, Never>?
    @ObservationIgnored private var diarizerConsumerTask: Task<Void, Never>?
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var resaveTask: Task<Void, Never>?
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored private var appTerminateObserver: NSObjectProtocol?
    @ObservationIgnored private var meetingAppLaunchObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSpeechAt = Date()
    @ObservationIgnored private var mutedSpeechMonitor: Task<Void, Never>?
    @ObservationIgnored private var lastMutedSpeechWarningAt: Date?
    /// 오디오 캡처가 실제로 시작된 시각 (행 초 ↔ 실시각 매핑 기준)
    @ObservationIgnored private var captureStartedAt: Date?
    /// 현재 회의의 캘린더 일정 제목 (저장 시 함께 기록)
    @ObservationIgnored private var meetingTitle: String?

    // 번역 요청 큐
    struct TranslationRequest: Sendable {
        let rowID: UUID
        let text: String
    }
    @ObservationIgnored private var translationContinuation: AsyncStream<TranslationRequest>.Continuation?

    var isRunning: Bool {
        if case .listening = phase { return true }
        return false
    }

    /// 듣는 중이거나 준비 중이면 true. start()의 이중 진입 방지용.
    /// (캘린더 팝업의 참가 → start() 직후 Zoom 실행 감지 자동 시작이 겹치는 레이스 차단)
    var isActive: Bool {
        switch phase {
        case .listening, .preparing: return true
        default: return false
        }
    }

    // MARK: - 초기화 (설정 복원)

    init() {
        let defaults = UserDefaults.standard
        if let savedName = defaults.string(forKey: "myName"), !savedName.isEmpty {
            myName = savedName
        }
        if defaults.object(forKey: "echoFilter") != nil {
            echoFilterEnabled = defaults.bool(forKey: "echoFilter")
        }
        autoStartOnMeetingApp = defaults.bool(forKey: "autoStartOnMeetingApp")
        if defaults.object(forKey: "syncMuteWithZoom") != nil {
            syncMuteWithZoom = defaults.bool(forKey: "syncMuteWithZoom")
        }
        // 신규 키 우선, 없으면 구 translationMode(off/local/cloud)에서 이행
        if defaults.object(forKey: "translationEnabled") != nil {
            translationEnabled = defaults.bool(forKey: "translationEnabled")
        } else if let legacy = defaults.string(forKey: "translationMode") {
            translationEnabled = legacy != "off"
        }
        if let savedBackend = defaults.string(forKey: "backend"),
           let value = ProcessingBackend(rawValue: savedBackend) {
            backend = value
        } else if defaults.string(forKey: "translationMode") == "cloud" {
            backend = .cloud
        }
        if let savedChatModel = defaults.string(forKey: "chatModel"),
           let value = ChatModelChoice(rawValue: savedChatModel) {
            chatModel = value
        }
        internalJargon = defaults.string(forKey: "internalJargon") ?? ""
        localModelID = defaults.string(forKey: "localModelID") ?? SummaryService.defaultModelID
        ModelSeeder.seedIfNeeded()
        registerMeetingAppLaunchObserver()

        // Zoom 뮤트 동기화: 내 Zoom 타일의 음소거 상태를 따라 마이크 캡처를 켜고 끔
        // Zoom 회의 종료 즉시 감지 → 자동 중지·저장·요약 (Granola식, 4분 무음 대기 불필요)
        zoomTagger.onMeetingEnded = { [weak self] in
            guard let self, self.isRunning else { return }
            self.noticeMessage = "Zoom meeting ended — saving and generating minutes."
            self.stop()
        }

        zoomTagger.onSelfMuteChange = { [weak self] muted in
            guard let self, self.syncMuteWithZoom, self.isRunning else { return }
            guard muted != self.micMuted else { return }
            self.setMicMuted(muted, fromZoomSync: true)
            self.noticeMessage = muted
                ? "Zoom muted — mic recording paused."
                : "Zoom unmuted — mic recording resumed."
        }

        // 클라우드 번역 문제 배너·상태 표시등 배선
        let geminiRef = gemini
        Task {
            await geminiRef.setIssueHandler { message in
                Task { @MainActor [weak self] in
                    self?.cloudTranslationMessage = message
                }
            }
            await geminiRef.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.cloudStatus = status
                }
            }
        }

        // 캘린더 팝업의 [참가] → Zoom 실행 + 기록 시작
        calendar.onJoinRequested = { [weak self] in
            guard let self, !self.isActive else { return }
            self.start()
            self.noticeMessage = "Joining Zoom from the calendar alert — recording started."
        }
    }

    // MARK: - 화자 이름

    func displayName(for row: TranscriptRow) -> String {
        MeetingStore.resolveName(row: row, myName: myName, speakerNames: speakerNames)
    }

    func volatileName(for channel: AudioChannel) -> String {
        channel == .me ? myName : "Them"
    }

    func renameMe(to name: String) {
        myName = name
        UserDefaults.standard.set(name, forKey: "myName")
        scheduleResave()
    }

    func renameSpeaker(slot: Int, to name: String) {
        speakerNames[slot] = name
        scheduleResave()
    }

    // MARK: - 에코 필터 토글

    func setEchoFilter(_ enabled: Bool) {
        echoFilterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "echoFilter")
        let engineRef = engine
        Task {
            await engineRef?.setEchoFilter(enabled)
        }
    }

    // MARK: - 마이크 뮤트

    func setMicMuted(_ muted: Bool, fromZoomSync: Bool = false) {
        micMuted = muted
        micMutedByZoom = fromZoomSync && muted
        if muted {
            volatileText[.me] = ""
            startMutedSpeechMonitor()
        } else {
            mutedSpeechMonitor?.cancel()
            mutedSpeechMonitor = nil
        }
        let engineRef = engine
        let geminiRef = gemini
        Task {
            await engineRef?.setMicMuted(muted)
            await geminiRef.setMicMuted(muted)
        }
    }

    func setSyncMuteWithZoom(_ enabled: Bool) {
        syncMuteWithZoom = enabled
        UserDefaults.standard.set(enabled, forKey: "syncMuteWithZoom")
    }

    func setInternalJargon(_ text: String) {
        internalJargon = text
        UserDefaults.standard.set(text, forKey: "internalJargon")
    }

    func setLocalModelID(_ id: String) {
        localModelID = id
        UserDefaults.standard.set(id, forKey: "localModelID")
    }

    /// 뮤트 중 발화 감지: 뮤트 상태에서 마이크 레벨이 지속적으로 올라가면 경고 배너.
    /// (실측 사고: 뮤트를 켠 채 발화해 "나" 채널이 통째로 소실된 회의가 있었음 — 2026-08-21)
    private func startMutedSpeechMonitor() {
        mutedSpeechMonitor?.cancel()
        mutedSpeechMonitor = Task { @MainActor [weak self] in
            var loudTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Zoom 동기화 뮤트 중의 발화는 회의 밖 발화라 경고하지 않음
                guard let self, self.isRunning, self.micMuted, !self.micMutedByZoom else {
                    loudTicks = 0
                    continue
                }
                if self.micLevel > 0.15 {
                    loudTicks += 1
                } else {
                    loudTicks = max(0, loudTicks - 1)
                }
                // 약 2초 누적 발화 감지 시 경고 (60초 스로틀)
                if loudTicks >= 4 {
                    loudTicks = 0
                    let now = Date()
                    let throttled = self.lastMutedSpeechWarningAt.map { now.timeIntervalSince($0) < 60 } ?? false
                    if !throttled {
                        self.lastMutedSpeechWarningAt = now
                        self.noticeMessage = "Speech detected while the mic is muted. Unmute (⌘⇧M) to record your voice."
                    }
                }
            }
        }
    }

    // MARK: - 번역 토글 + 백엔드 선택

    func setTranslationEnabled(_ enabled: Bool) {
        translationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "translationEnabled")
        cloudTranslationMessage = nil
        guard isRunning else { return }
        applyTranslationPipeline()
    }

    func setBackend(_ newBackend: ProcessingBackend) {
        // 클라우드 전환 시 API 키가 없으면 먼저 입력받음 (저장 후 재호출됨)
        if newBackend == .cloud, GeminiKeychain.load() == nil {
            showGeminiKeyPrompt = true
            return
        }
        backend = newBackend
        UserDefaults.standard.set(newBackend.rawValue, forKey: "backend")
        cloudTranslationMessage = nil
        guard isRunning else { return }
        applyTranslationPipeline()
    }

    /// 현재 토글·백엔드 상태에 맞게 번역 파이프라인(Apple 세션/Gemini 라이브)을 정렬.
    private func applyTranslationPipeline() {
        let geminiRef = gemini
        if translationEnabled, backend == .cloud, let key = GeminiKeychain.load() {
            Task {
                await geminiRef.configure(apiKey: key)
                await geminiRef.start()
            }
        } else {
            Task { await geminiRef.stop() }
        }
        if translationEnabled, backend == .local {
            translator.activate()
        }
    }

    func saveGeminiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        showGeminiKeyPrompt = false
        guard !trimmed.isEmpty else { return }
        GeminiKeychain.save(trimmed)
        setBackend(.cloud)
    }

    // MARK: - 시작/중지

    func start() {
        guard !isActive else { return }
        phase = .preparing("Preparing…")
        rows.removeAll()
        volatileText = [.me: "", .them: ""]
        systemAudioAvailable = true
        systemAudioMessage = nil
        diarizerMessage = nil
        noticeMessage = nil
        micLevel = 0
        sessionStartedAt = Date()
        currentMeetingURL = nil
        currentSummary = nil
        summaryPhase = .idle
        resaveTask?.cancel()
        lastSpeechAt = Date()
        micMuted = false
        micMutedByZoom = false
        zoomTagMessage = nil
        captureStartedAt = nil
        // 진행 중인 캘린더 일정의 참석자 → 화자 이름 원클릭 후보, 제목 → 회의 이름
        attendeeCandidates = calendar.attendeeNamesForOngoingMeeting()
        meetingTitle = calendar.ongoingMeetingTitle()

        // Zoom 화자 태그: Zoom이 떠 있으면 폴링 시작 (권한 없으면 요청 다이얼로그 + 안내)
        if ZoomSpeakerTagger.zoomRunning() {
            if ZoomSpeakerTagger.accessibilityTrusted(prompt: false) {
                zoomTagger.start(myName: myName)
            } else {
                _ = ZoomSpeakerTagger.accessibilityTrusted(prompt: true)
                zoomTagMessage = "Zoom speaker recognition needs Accessibility permission. Enable livenote2 in System Settings > Privacy & Security > Accessibility (applies from the next session)."
            }
        }

        let newEngine = TranscriptionEngine(
            onVolatile: { [weak self] channel, text in
                Task { @MainActor in
                    self?.volatileText[channel] = text
                    if !text.isEmpty {
                        self?.lastSpeechAt = Date()
                    }
                }
            },
            onFinal: { [weak self] segment in
                Task { [weak self] in
                    guard let self else { return }
                    // 상대방 세그먼트는 화자구분 타임라인에서 슬롯을 조회한 뒤 반영
                    var slot: Int?
                    if segment.channel == .them {
                        let diarizer = await self.speakerDiarizer
                        slot = await diarizer?.dominantSlot(
                            from: segment.startSeconds,
                            to: segment.endSeconds
                        )
                    }
                    let resolvedSlot = slot
                    await MainActor.run {
                        self.lastSpeechAt = Date()
                        self.appendFinal(segment, slot: resolvedSlot)
                    }
                }
            },
            onStatus: { [weak self] message in
                Task { @MainActor in
                    guard let self, !self.isRunning else { return }
                    self.phase = .preparing(message)
                }
            }
        )
        engine = newEngine

        Task {
            // 0) 에코 필터 상태 전달
            await newEngine.setEchoFilter(echoFilterEnabled)

            // 1) 마이크 권한
            let granted = await MicCapture.requestPermission()
            guard granted else {
                phase = .error("Microphone access denied. Allow livenote2 in System Settings > Privacy & Security > Microphone.")
                return
            }

            // 2) ASR 모델 준비 (최초 실행 시 다운로드)
            do {
                try await newEngine.prepare()
            } catch {
                phase = .error("Model preparation failed: \(error.localizedDescription)\nCheck your network and try again.")
                return
            }

            // 3) 화자구분 준비. Zoom 태그가 잡히면 LS-EEND는 기동하지 않음 (부하 절감 —
            //    Zoom 회의에서는 타일의 활성 화자 이름이 슬롯보다 정확하고 이름까지 공짜)
            if ZoomSpeakerTagger.zoomRunning(), !zoomTagger.permissionMissing {
                // 첫 폴 결과를 잠깐 기다려 타일 존재 확인
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if zoomTagger.zoomDetected {
                speakerDiarizer = nil
            } else {
                phase = .preparing("Preparing speaker diarization model… (downloads on first run)")
                let diarizer = SpeakerDiarizer()
                do {
                    try await diarizer.prepare()
                    speakerDiarizer = diarizer
                } catch {
                    speakerDiarizer = nil
                    diarizerMessage = "Speaker diarization unavailable — remote speakers use a single label. (\(error.localizedDescription))"
                }
            }

            // 4) 오디오 스트림 → 엔진/화자구분/클라우드 번역 소비 루프
            let stream = AsyncStream<(AudioChannel, [Float])> { continuation in
                self.audioContinuation = continuation
            }
            let geminiRef = gemini
            consumerTask = Task.detached(priority: .userInitiated) {
                for await (channel, samples) in stream {
                    await newEngine.ingest(samples, channel: channel)
                    // 클라우드 번역 활성 시에만 실제 전송 (내부에서 no-op 판정)
                    await geminiRef.ingest(samples, channel: channel)
                }
            }

            if speakerDiarizer != nil {
                let diarizerStream = AsyncStream<[Float]> { continuation in
                    self.diarizerContinuation = continuation
                }
                let diarizerRef = speakerDiarizer
                diarizerConsumerTask = Task.detached(priority: .utility) {
                    for await samples in diarizerStream {
                        await diarizerRef?.ingest(samples)
                    }
                }
            }

            // 5) 마이크 시작 (필수)
            do {
                try startMicCapture()
            } catch {
                phase = .error("Microphone start failed: \(error.localizedDescription)")
                teardownAudio()
                return
            }

            // 6) 시스템 오디오 탭 (실패해도 마이크 전용으로 계속)
            let tap = SystemAudioTap()
            tap.onSamples = { [weak self] samples in
                self?.audioContinuation?.yield((.them, samples))
                self?.diarizerContinuation?.yield(samples)
            }
            do {
                try tap.start()
                systemTap = tap
            } catch {
                systemAudioAvailable = false
                systemAudioMessage = "System audio capture unavailable — transcribing microphone only.\n\(error.localizedDescription)"
            }

            // 7) 번역 활성화. Apple 세션은 번역 켬+로컬일 때만 준비
            //    (끔/클라우드에서는 한국어 언어팩 다운로드 프롬프트를 띄우지 않음 — 팀원 배포 배려)
            cloudTranslationMessage = nil
            if translationEnabled, backend == .cloud, GeminiKeychain.load() == nil {
                backend = .local
                cloudTranslationMessage = "No Gemini API key — started with the local backend. Select Cloud again in Settings to add a key."
            }
            applyTranslationPipeline()

            // 8) 회의 자동 종료 감지
            startAutoStopMonitoring()

            // 오디오 타임라인 기준 시각 (Zoom 태그 매칭용 — 모델 준비 시간만큼
            // sessionStartedAt과 어긋나므로 캡처 시작 시각을 별도 기록)
            captureStartedAt = Date()
            AppLog.write("app", "세션 시작 backend=\(backend.rawValue) 번역=\(translationEnabled) zoom태그=\(zoomTagger.zoomDetected) 다이어라이저=\(speakerDiarizer != nil) 제목=\(meetingTitle ?? "-")")
            phase = .listening
        }
    }

    func stop() {
        guard isRunning else { return }
        AppLog.write("app", "세션 중지 rows=\(rows.count)")
        zoomTagger.stop()
        micMutedByZoom = false
        mic?.stop()
        systemTap?.stop()
        mic = nil
        systemTap = nil
        micLevel = 0
        phase = .idle
        stopAutoStopMonitoring()

        let engineRef = engine
        let diarizerRef = speakerDiarizer
        let geminiRef = gemini
        Task {
            await engineRef?.flushAll()
            await diarizerRef?.finish()
            teardownAudio()
            // 마지막 문장들의 번역이 도착할 시간을 준 뒤 저장
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await geminiRef.stop()
            persistCurrentSession()
            // 자동 요약: 실제 회의 규모(15행 이상)면 저장 직후 자동 생성
            if rows.count >= 15, currentSummary == nil {
                generateSummaryForCurrentSession()
            }
        }
    }

    private func startMicCapture() throws {
        let micCapture = MicCapture()
        micCapture.onSamples = { [weak self] samples in
            self?.audioContinuation?.yield((.me, samples))
        }
        micCapture.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        try micCapture.start()
        mic = micCapture
    }

    private func teardownAudio() {
        audioContinuation?.finish()
        audioContinuation = nil
        diarizerContinuation?.finish()
        diarizerContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
        diarizerConsumerTask?.cancel()
        diarizerConsumerTask = nil
    }

    // MARK: - 회의 자동 종료 감지

    private func startAutoStopMonitoring() {
        // ① 무음 타임아웃: 4분간 양쪽 채널 모두 발화가 없으면 자동 중지·저장
        autoStopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.isRunning else { continue }
                if Date().timeIntervalSince(self.lastSpeechAt) > Self.autoStopAfterSilence {
                    let minutes = Int(Self.autoStopAfterSilence / 60)
                    self.noticeMessage = "Auto-stopped and saved after \(minutes) minutes of silence."
                    self.stop()
                    return
                }
            }
        }

        // ② 회의 앱 종료 감지: Zoom/Teams/Webex가 종료되면 자동 중지·저장
        appTerminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  meetingAppBundleIDs.contains(bundleID) else { return }
            let appName = app.localizedName ?? "meeting app"
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.noticeMessage = "\(appName) quit — auto-stopped and saved."
                self.stop()
            }
        }
    }

    private func stopAutoStopMonitoring() {
        autoStopTask?.cancel()
        autoStopTask = nil
        if let observer = appTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminateObserver = nil
        }
    }

    // MARK: - 회의 저장

    /// 현재 세션을 저장(또는 같은 폴더에 재저장). 저장 후에도 이름 변경·늦은 번역이 오면 갱신됨.
    private func persistCurrentSession() {
        guard !rows.isEmpty, let startedAt = sessionStartedAt else { return }
        let duration = rows.map(\.endSeconds).max() ?? 0
        currentMeetingURL = meetingStore.save(
            rows: rows,
            myName: myName,
            speakerNames: speakerNames,
            startedAt: startedAt,
            durationSeconds: duration,
            title: meetingTitle,
            summary: currentSummary,
            existingURL: currentMeetingURL
        )
    }

    /// 중지 후 상태에서 이름 변경/늦은 번역이 생기면 1.5초 뒤 조용히 재저장.
    private func scheduleResave() {
        guard !isRunning, currentMeetingURL != nil else { return }
        resaveTask?.cancel()
        resaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persistCurrentSession() }
        }
    }

    // MARK: - 회의 앱 실행 감지 (자동 시작)

    func setAutoStart(_ enabled: Bool) {
        autoStartOnMeetingApp = enabled
        UserDefaults.standard.set(enabled, forKey: "autoStartOnMeetingApp")
    }

    private func registerMeetingAppLaunchObserver() {
        meetingAppLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  meetingAppBundleIDs.contains(bundleID) else { return }
            let appName = app.localizedName ?? "meeting app"
            Task { @MainActor [weak self] in
                guard let self, self.autoStartOnMeetingApp, !self.isRunning else { return }
                self.start()
                self.noticeMessage = "\(appName) launched — recording started automatically."
            }
        }
    }

    // MARK: - 요약 생성 (Qwen3-4B, 온디맨드 로드)

    /// 방금 끝난 세션의 요약 생성.
    func generateSummaryForCurrentSession() {
        guard summaryPhase != .generating, !rows.isEmpty else { return }
        let meeting = SavedMeeting(
            startedAt: sessionStartedAt ?? Date(),
            durationSeconds: rows.map(\.endSeconds).max() ?? 0,
            myName: myName,
            speakerNames: speakerNames,
            rows: rows,
            summary: nil
        )
        let transcript = MeetingStore.transcriptForSummary(meeting) { [self] row in
            displayName(for: row)
        }
        summaryPhase = .generating
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.runSummary(transcript: transcript)
                self.currentSummary = summary
                self.summaryPhase = .idle
                self.persistCurrentSession()
            } catch {
                self.summaryPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// 요약 실행 라우팅: 클라우드 백엔드 + API 키 보유 시 Gemini 3.7 Flash
    /// (빠르고 품질 우위, 모델 로드 불필요), 실패하거나 로컬 백엔드면 Qwen 로컬.
    private func runSummary(transcript: String) async throws -> String {
        if backend == .cloud, let key = GeminiKeychain.load() {
            do {
                return try await GeminiSummarizer.generateSummary(transcript: transcript, apiKey: key)
            } catch {
                AppLog.write("summary", "클라우드 실패 → 로컬 Qwen 폴백: \(error.localizedDescription.prefix(150))")
            }
        }
        AppLog.write("summary", "로컬 Qwen 요약 시작 transcript=\(transcript.count)자")
        return try await SummaryService().generateSummary(transcript: transcript)
    }

    /// 저장된 회의의 요약 생성 (session.json + summary.md 갱신).
    func generateSummary(for url: URL) {
        guard summaryPhase != .generating, let meeting = meetingStore.load(url) else { return }
        let transcript = MeetingStore.transcriptForSummary(meeting) { row in
            MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
        }
        summaryPhase = .generating
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.runSummary(transcript: transcript)
                self.meetingStore.updateSummary(at: url, summary: summary)
                self.summaryPhase = .idle
            } catch {
                self.summaryPhase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 전사 결과 반영

    private func appendFinal(_ segment: FinalSegment, slot: Int?) {
        // 에코 방어 2차: 방금 확정된 상대방 문장과 거의 같은 "내" 문장은 에코로 판단하고 버림
        if segment.channel == .me, isEchoOfRecentThem(segment) {
            volatileText[.me] = ""
            return
        }

        // 확정 경계 안정화: 유사 중복 확정 폐기, 이월 경계의 중복 머리 토큰 제거
        guard let stabilized = stabilizedFinalText(segment) else {
            volatileText[segment.channel] = ""
            return
        }
        // 참석자 이름 교정: ASR이 뭉갠 고유명사를 캘린더 참석자 이름으로 보정
        let stabilizedText = correctedAttendeeNames(stabilized)

        // Zoom 태그: 행 구간에서 가장 오래 활성 화자였던 이름 (슬롯보다 우선)
        var autoName: String?
        if segment.channel == .them, let captureStart = captureStartedAt {
            autoName = zoomTagger.dominantName(
                fromSeconds: segment.startSeconds,
                toSeconds: segment.endSeconds,
                sessionStart: captureStart
            )
        }

        let row = TranscriptRow(
            id: UUID(),
            channel: segment.channel,
            speakerSlot: segment.channel == .them ? slot : nil,
            speakerName: autoName,
            english: stabilizedText,
            korean: nil,
            startSeconds: segment.startSeconds,
            endSeconds: segment.endSeconds
        )
        // 채널 간 도착 순서가 어긋날 수 있어 시작 시각 기준으로 삽입
        let index = rows.lastIndex(where: { $0.startSeconds <= row.startSeconds }).map { $0 + 1 } ?? 0
        rows.insert(row, at: index)

        // 상대방 문장이 내 에코 문장보다 늦게 확정되는 경우: 이미 올라간 에코 행을 소급 제거
        if segment.channel == .them {
            removeEchoedMeRows(matching: row)
        }

        // 번역 라우팅: 끔=안 함, 로컬=Apple 세션 큐, 클라우드=Gemini 누적분 회수 예약
        if translationEnabled {
            switch backend {
            case .local:
                translationContinuation?.yield(TranslationRequest(rowID: row.id, text: stabilizedText))
            case .cloud:
                scheduleCloudClaim(rowID: row.id, channel: row.channel)
            }
        }
    }

    /// 클라우드 번역 회수: Gemini의 한국어 출력이 행 확정보다 몇 초 늦게 흘러오므로
    /// linger(2.5s) 후 그때까지 쌓인 조각을 이 행에 붙인다. 비면 3초 간격 3회까지 재시도
    /// (번역 지연 내성). 한계: Gemini와 우리 문장 분할이 달라 경계에서 번역이 이웃 행으로
    /// 번질 수 있음 (§5.4).
    private func scheduleCloudClaim(rowID: UUID, channel: AudioChannel) {
        let geminiRef = gemini
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            var korean = await geminiRef.claimKorean(channel: channel)
            var retries = 0
            while korean == nil, retries < 3 {
                retries += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                korean = await geminiRef.claimKorean(channel: channel)
            }
            guard let korean else { return }
            await MainActor.run { self?.applyTranslation(korean, to: rowID) }
        }
    }

    /// 사이드바 "오늘 일정"의 지금 시작: Zoom 미실행이면 참가 링크를 열고 기록 시작.
    func startUpcomingMeeting(link: URL?) {
        if !ZoomSpeakerTagger.zoomRunning(), let link {
            NSWorkspace.shared.open(link)
        }
        if !isActive {
            start()
        }
    }

    // MARK: - 확정 경계 안정화 (AirTranslate 1.4.1 패턴 이식)
    // 하드캡 꼬리 이월(0.2s)과 문장부호 조기 확정 경계에서 생기는 두 가지 아티팩트를 정리:
    // ① 직전 확정과 거의 같은 내용이 다시 확정되어 오는 "유사 중복 확정" → 폐기
    // ② 직전 확정 꼬리 단어가 새 문장 머리에 반복되는 "중복 접두" → 머리 토큰 제거

    /// 안정화된 확정 텍스트. nil이면 유사 중복으로 판단해 통째로 폐기.
    private func stabilizedFinalText(_ segment: FinalSegment) -> String? {
        guard let prev = rows.last(where: { $0.channel == segment.channel }) else { return segment.text }
        let gap = segment.startSeconds - prev.endSeconds
        let prevTokens = Self.normalizedTokens(prev.english)
        let newTokens = Self.normalizedTokens(segment.text)

        // ① 유사 중복 확정 폐기 (짧은 간격, 내용 85% 이상 겹침, 길이 비슷)
        if gap < 5.0, newTokens.count >= 4, prevTokens.count >= 4,
           Self.tokenSimilarity(newTokens, prevTokens) >= 0.85,
           Double(newTokens.count) <= Double(prevTokens.count) * 1.5 {
            return nil
        }

        // ② 이어지는 문장의 중복 머리 토큰 제거 (연속 발화 이월 경계에서만: 간격 1.5s 미만)
        if gap < 1.5 {
            var words = segment.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let prevWords = prev.english.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.count >= 3, !prevWords.isEmpty {
                let maxOverlap = min(3, prevWords.count, words.count - 1)
                for k in stride(from: maxOverlap, through: 1, by: -1) {
                    let prevTail = prevWords.suffix(k).map(Self.normalizeWord)
                    let newHead = words.prefix(k).map(Self.normalizeWord)
                    if prevTail == newHead, prevTail.joined().count >= 2 {
                        words.removeFirst(k)
                        return words.joined(separator: " ")
                    }
                }
            }
        }
        return segment.text
    }

    private static func normalizeWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - 참석자 이름 교정 (Granola 어휘 힌트의 후처리판)
    // ASR이 뭉갠 고유명사(Herminder, Poonaraj 등)를 캘린더 참석자 이름 토큰과
    // 편집거리 비교로 보정. 보수적 조건: 대문자 시작 + 5자 이상 + 거리 ≤ 2 + 길이차 ≤ 2.

    private func correctedAttendeeNames(_ text: String) -> String {
        let nameTokens = attendeeNameTokens()
        guard !nameTokens.isEmpty else { return text }
        var changed = false
        let corrected = text.split(separator: " ", omittingEmptySubsequences: false).map { rawWord -> String in
            let word = String(rawWord)
            let core = word.trimmingCharacters(in: CharacterSet.letters.inverted)
            guard core.count >= 5, let first = core.first, first.isUppercase else { return word }
            let coreLower = core.lowercased()
            for name in nameTokens where abs(name.count - core.count) <= 2 {
                let nameLower = name.lowercased()
                if coreLower == nameLower { return word }   // 이미 정답
                if Self.editDistance(coreLower, nameLower) <= 2 {
                    changed = true
                    return word.replacingOccurrences(of: core, with: name)
                }
            }
            return word
        }
        return changed ? corrected.joined(separator: " ") : text
    }

    /// 참석자 후보 + 내 이름 + internal jargon에서 4자 이상 토큰 추출 (ASR 교정 풀).
    private func attendeeNameTokens() -> [String] {
        var tokens = Set<String>()
        for candidate in attendeeCandidates {
            for part in candidate.split(separator: " ") where part.count >= 4 {
                tokens.insert(String(part))
            }
        }
        for part in myName.split(separator: " ") where part.count >= 4 {
            tokens.insert(String(part))
        }
        // Internal jargon (쉼표 구분): 단어 단위로 교정 풀에 추가
        for term in internalJargon.split(separator: ",") {
            for part in term.trimmingCharacters(in: .whitespaces).split(separator: " ")
            where part.count >= 4 {
                tokens.insert(String(part))
            }
        }
        return Array(tokens)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }

    // MARK: - 에코 중복 제거 (2차 방어)
    // 1차 방어는 MicCapture의 AEC(voice processing). 여기는 그래도 새어 들어온 것을
    // 텍스트 유사도로 잡는다. 상대방 발화와 시간대가 겹치고 단어가 75% 이상 겹치는
    // "내" 문장은 에코로 간주.

    private static let echoWindowSeconds = 10.0
    private static let echoSimilarityThreshold = 0.65
    private static let echoMinimumTokens = 3

    private func isEchoOfRecentThem(_ segment: FinalSegment) -> Bool {
        let meTokens = Self.normalizedTokens(segment.text)
        guard meTokens.count >= Self.echoMinimumTokens else { return false }
        for row in rows.suffix(12) where row.channel == .them {
            let timeOverlaps = row.endSeconds >= segment.startSeconds - Self.echoWindowSeconds
                && row.startSeconds <= segment.endSeconds + 2.0
            guard timeOverlaps else { continue }
            if Self.tokenSimilarity(meTokens, Self.normalizedTokens(row.english)) >= Self.echoSimilarityThreshold {
                return true
            }
        }
        return false
    }

    private func removeEchoedMeRows(matching themRow: TranscriptRow) {
        let themTokens = Self.normalizedTokens(themRow.english)
        guard themTokens.count >= Self.echoMinimumTokens else { return }
        rows.removeAll { row in
            guard row.channel == .me else { return false }
            let meTokens = Self.normalizedTokens(row.english)
            guard meTokens.count >= Self.echoMinimumTokens else { return false }
            let timeOverlaps = row.endSeconds >= themRow.startSeconds - 2.0
                && row.startSeconds <= themRow.endSeconds + Self.echoWindowSeconds
            guard timeOverlaps else { return false }
            return Self.tokenSimilarity(meTokens, themTokens) >= Self.echoSimilarityThreshold
        }
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// 두 토큰 집합의 포함률 (작은 쪽 기준). 0.0~1.0
    private static func tokenSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let setA = Set(a)
        let setB = Set(b)
        let common = setA.intersection(setB).count
        return Double(common) / Double(min(setA.count, setB.count))
    }

    // MARK: - 번역 연동

    /// TranslationCoordinator.serve가 소비하는 요청 스트림.
    /// translationTask가 재시작되면 새 스트림으로 교체됩니다.
    func translationRequests() -> AsyncStream<TranslationRequest> {
        translationContinuation?.finish()
        return AsyncStream { continuation in
            self.translationContinuation = continuation
        }
    }

    func applyTranslation(_ korean: String?, to rowID: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].korean = korean ?? rows[index].korean
        // 저장 이후 도착한 번역도 파일에 반영
        scheduleResave()
    }
}
