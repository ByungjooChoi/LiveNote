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
    /// 클라우드 번역 (Gemini Live Translate) — 번역 모드가 .cloud일 때만 동작
    @ObservationIgnored let gemini = GeminiLiveTranslator()

    /// 번역 제공자. 기본 로컬(Apple). 클라우드는 회의 오디오가 Google로 전송됨.
    private(set) var translationMode: TranslationMode = .local
    /// 클라우드 번역 문제 안내 배너 (nil이면 정상)
    var cloudTranslationMessage: String?
    /// Gemini API 키 입력 시트 표시
    var showGeminiKeyPrompt = false

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
        if let savedMode = defaults.string(forKey: "translationMode"),
           let mode = TranslationMode(rawValue: savedMode) {
            translationMode = mode
        }
        registerMeetingAppLaunchObserver()

        // 클라우드 번역 문제 배너 배선
        let geminiRef = gemini
        Task {
            await geminiRef.setIssueHandler { message in
                Task { @MainActor [weak self] in
                    self?.cloudTranslationMessage = message
                }
            }
        }

        // 캘린더 팝업의 [참가] → Zoom 실행 + 기록 시작
        calendar.onJoinRequested = { [weak self] in
            guard let self, !self.isActive else { return }
            self.start()
            self.noticeMessage = "캘린더 알림에서 Zoom 참가 — 기록을 시작합니다."
        }
    }

    // MARK: - 화자 이름

    func displayName(for row: TranscriptRow) -> String {
        MeetingStore.resolveName(row: row, myName: myName, speakerNames: speakerNames)
    }

    func volatileName(for channel: AudioChannel) -> String {
        channel == .me ? myName : "상대방"
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

    func setMicMuted(_ muted: Bool) {
        micMuted = muted
        if muted {
            volatileText[.me] = ""
        }
        let engineRef = engine
        let geminiRef = gemini
        Task {
            await engineRef?.setMicMuted(muted)
            await geminiRef.setMicMuted(muted)
        }
    }

    // MARK: - 번역 모드 (로컬/클라우드)

    func setTranslationMode(_ mode: TranslationMode) {
        // 클라우드 전환 시 API 키가 없으면 먼저 입력받음 (저장 후 재호출됨)
        if mode == .cloud, GeminiKeychain.load() == nil {
            showGeminiKeyPrompt = true
            return
        }
        translationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
        cloudTranslationMessage = nil
        guard isRunning else { return }
        let geminiRef = gemini
        switch mode {
        case .cloud:
            let key = GeminiKeychain.load()
            Task {
                await geminiRef.configure(apiKey: key)
                await geminiRef.start()
            }
        case .local:
            translator.activate()
            Task { await geminiRef.stop() }
        case .off:
            Task { await geminiRef.stop() }
        }
    }

    func saveGeminiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        showGeminiKeyPrompt = false
        guard !trimmed.isEmpty else { return }
        GeminiKeychain.save(trimmed)
        setTranslationMode(.cloud)
    }

    // MARK: - 시작/중지

    func start() {
        guard !isActive else { return }
        phase = .preparing("준비 중…")
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
        // 진행 중인 캘린더 일정의 참석자 → 화자 이름 원클릭 후보
        attendeeCandidates = calendar.attendeeNamesForOngoingMeeting()

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
                phase = .error("마이크 권한이 거부되었습니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 livenote2를 허용해 주세요.")
                return
            }

            // 2) ASR 모델 준비 (최초 실행 시 다운로드)
            do {
                try await newEngine.prepare()
            } catch {
                phase = .error("모델 준비 실패: \(error.localizedDescription)\n네트워크 연결을 확인한 뒤 다시 시도해 주세요.")
                return
            }

            // 3) 화자구분 모델 준비 (실패해도 전사는 계속 — 라벨만 "상대방" 단일)
            phase = .preparing("화자구분 모델 준비 중… (최초 실행 시 다운로드)")
            let diarizer = SpeakerDiarizer()
            do {
                try await diarizer.prepare()
                speakerDiarizer = diarizer
            } catch {
                speakerDiarizer = nil
                diarizerMessage = "화자구분 모델을 불러오지 못해 상대방을 단일 라벨로 표시합니다. (\(error.localizedDescription))"
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
                phase = .error("마이크 시작 실패: \(error.localizedDescription)")
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
                systemAudioMessage = "시스템 오디오를 캡처할 수 없어 마이크만 전사합니다.\n\(error.localizedDescription)"
            }

            // 7) 번역 활성화. Apple 세션은 로컬 모드에서만 준비
            //    (끔/클라우드에서는 한국어 언어팩 다운로드 프롬프트를 띄우지 않음 — 팀원 배포 배려)
            cloudTranslationMessage = nil
            switch translationMode {
            case .off:
                break
            case .local:
                translator.activate()
            case .cloud:
                if let key = GeminiKeychain.load() {
                    let geminiCloud = gemini
                    Task {
                        await geminiCloud.configure(apiKey: key)
                        await geminiCloud.start()
                    }
                } else {
                    translationMode = .local
                    translator.activate()
                    cloudTranslationMessage = "Gemini API 키가 없어 로컬 번역으로 시작했습니다. 번역 메뉴에서 클라우드를 다시 선택해 키를 입력할 수 있습니다."
                }
            }

            // 8) 회의 자동 종료 감지
            startAutoStopMonitoring()

            phase = .listening
        }
    }

    func stop() {
        guard isRunning else { return }
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
                    self.noticeMessage = "\(minutes)분간 발화가 없어 자동으로 중지하고 저장했습니다."
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
            let appName = app.localizedName ?? "회의 앱"
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.noticeMessage = "\(appName) 종료를 감지해 자동으로 중지하고 저장했습니다."
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
            let appName = app.localizedName ?? "회의 앱"
            Task { @MainActor [weak self] in
                guard let self, self.autoStartOnMeetingApp, !self.isRunning else { return }
                self.start()
                self.noticeMessage = "\(appName) 실행을 감지해 자동으로 시작했습니다."
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
            do {
                let summary = try await SummaryService().generateSummary(transcript: transcript)
                guard let self else { return }
                self.currentSummary = summary
                self.summaryPhase = .idle
                self.persistCurrentSession()
            } catch {
                self?.summaryPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// 저장된 회의의 요약 생성 (session.json + summary.md 갱신).
    func generateSummary(for url: URL) {
        guard summaryPhase != .generating, let meeting = meetingStore.load(url) else { return }
        let transcript = MeetingStore.transcriptForSummary(meeting) { row in
            MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
        }
        summaryPhase = .generating
        Task { [weak self] in
            do {
                let summary = try await SummaryService().generateSummary(transcript: transcript)
                guard let self else { return }
                self.meetingStore.updateSummary(at: url, summary: summary)
                self.summaryPhase = .idle
            } catch {
                self?.summaryPhase = .failed(error.localizedDescription)
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
        guard let stabilizedText = stabilizedFinalText(segment) else {
            volatileText[segment.channel] = ""
            return
        }

        let row = TranscriptRow(
            id: UUID(),
            channel: segment.channel,
            speakerSlot: segment.channel == .them ? slot : nil,
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
        switch translationMode {
        case .off:
            break
        case .local:
            translationContinuation?.yield(TranslationRequest(rowID: row.id, text: stabilizedText))
        case .cloud:
            scheduleCloudClaim(rowID: row.id, channel: row.channel)
        }
    }

    /// 클라우드 번역 회수: Gemini의 한국어 출력이 행 확정보다 몇 초 늦게 흘러오므로
    /// linger(2.5s) 후 그때까지 쌓인 조각을 이 행에 붙인다. 비어 있으면 3초 뒤 1회 재시도.
    /// 한계: Gemini와 우리 문장 분할이 달라 경계에서 번역이 이웃 행으로 번질 수 있음 (§5.4).
    private func scheduleCloudClaim(rowID: UUID, channel: AudioChannel) {
        let geminiRef = gemini
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            var korean = await geminiRef.claimKorean(channel: channel)
            if korean == nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                korean = await geminiRef.claimKorean(channel: channel)
            }
            guard let korean else { return }
            await MainActor.run { self?.applyTranslation(korean, to: rowID) }
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
