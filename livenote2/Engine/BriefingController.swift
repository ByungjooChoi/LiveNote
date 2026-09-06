import AppKit
import Foundation
import Observation

/// 브리핑 상태.
enum BriefStatus: Equatable {
    case ready(Brief)
    case generating
    case noHistory
    case skipped
    case disabled
    case failed(String)
    case notStarted
}

/// 사전 브리핑 제어 및 아침 일괄/임박 생성 관리자.
@MainActor
@Observable
final class BriefingController {

    struct Settings {
        var enabled: Bool
        var skipLargeMeetings: Bool
        var batchHour: Int // default 7
        var dailyBatchLimit: Int {
            didSet {
                if dailyBatchLimit <= 0 { dailyBatchLimit = 10 }
            }
        }

        init(defaults: UserDefaults = .standard) {
            if defaults.object(forKey: "briefsEnabled") != nil {
                self.enabled = defaults.bool(forKey: "briefsEnabled")
            } else {
                self.enabled = true
            }
            if defaults.object(forKey: "briefsSkipLarge") != nil {
                self.skipLargeMeetings = defaults.bool(forKey: "briefsSkipLarge")
            } else {
                self.skipLargeMeetings = true
            }
            let hour = defaults.integer(forKey: "briefsBatchHour")
            self.batchHour = hour > 0 ? hour : 7

            if defaults.object(forKey: "briefsDailyBatchLimit") != nil {
                let limit = defaults.integer(forKey: "briefsDailyBatchLimit")
                self.dailyBatchLimit = limit > 0 ? limit : 10
            } else {
                self.dailyBatchLimit = 10
            }
        }

        func persist(to defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: "briefsEnabled")
            defaults.set(skipLargeMeetings, forKey: "briefsSkipLarge")
            defaults.set(batchHour, forKey: "briefsBatchHour")
            defaults.set(dailyBatchLimit, forKey: "briefsDailyBatchLimit")
        }
    }

    enum BriefEnsureOutcome: Equatable, Sendable {
        case disabled
        case alreadyInMemory
        case loadedFromDisk
        case cacheUnreadable
        case inProgress
        case skippedLarge
        case noHistory
        case tasksUnavailable
        case generated
        case generationFailed
        case deferred
    }

    private(set) var briefs: [String: Brief] = [:]
    private(set) var generating: Set<String> = []
    private(set) var noHistoryKeys: Set<String> = []
    private(set) var skippedKeys: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var lastError: String?
    private(set) var currentBrief: Brief?
    private(set) var sessionEventKey: String?
    private(set) var lastBatchDeferredKeys: Set<String> = []
    var onUserNotice: ((String) -> Void)?

    var settings: Settings {
        didSet {
            settings.persist(to: defaults)
        }
    }

    let store: BriefStore
    let meetingStore: MeetingStore
    let defaults: UserDefaults
    let backend: BriefGenerator.Backend
    let openTasksProvider: ([String]) throws -> [TaskItem]
    let language: () -> String
    let now: () -> Date
    let calendar: Calendar

    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastBatchRunDate: Date?
    @ObservationIgnored private var itemsProvider: (() -> [UpcomingMeetingItem])?
    @ObservationIgnored private(set) var wakeHandleCount: Int = 0

    @ObservationIgnored var observerRegistered: Bool { wakeObserver != nil }
    @ObservationIgnored var batchTaskActive: Bool { batchTask != nil && !(batchTask?.isCancelled ?? true) }

    init(
        store: BriefStore = BriefStore(),
        meetingStore: MeetingStore,
        defaults: UserDefaults = .standard,
        backend: BriefGenerator.Backend,
        openTasksProvider: @escaping ([String]) throws -> [TaskItem],
        language: @escaping () -> String,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.meetingStore = meetingStore
        self.defaults = defaults
        self.backend = backend
        self.openTasksProvider = openTasksProvider
        self.language = language
        self.now = now
        self.calendar = calendar
        self.settings = Settings(defaults: defaults)
    }

    deinit {
        itemsProvider = nil
        startupTask?.cancel()
        batchTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// 배치 스케줄러 및 옵저버 취소.
    func cancelBatch() {
        itemsProvider = nil
        startupTask?.cancel()
        startupTask = nil
        batchTask?.cancel()
        batchTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// 특정 이벤트 키의 브리핑 조회 (순수 인메모리 읽기, 뷰 본문 호출 안전).
    func brief(for eventKey: String) -> Brief? {
        briefs[eventKey]
    }

    /// 일정 아이템에 대한 브리핑 상태 확인 (순수 인메모리 읽기).
    func status(for item: UpcomingMeetingItem) -> BriefStatus {
        guard settings.enabled else { return .disabled }
        if generating.contains(item.eventKey) { return .generating }
        if let err = errors[item.eventKey] { return .failed(err) }
        if let b = briefs[item.eventKey] { return .ready(b) }
        if skippedKeys.contains(item.eventKey) { return .skipped }
        if noHistoryKeys.contains(item.eventKey) { return .noHistory }
        return .notStarted
    }

    /// 캘린더 일정 업데이트 시 호출: 캐시 프리로드 및 필요 시 아침 일괄 브리핑 실행.
    func calendarItemsUpdated(_ items: [UpcomingMeetingItem]) {
        preloadCached(for: items)
        Task { @MainActor [weak self] in
            await self?.runMorningBatchIfNeeded(items: items, reason: "calendar-updated")
        }
    }

    /// 인메모리에 없는 일정의 브리핑을 디스크에서 미리 로드.
    func preloadCached(for items: [UpcomingMeetingItem]) {
        for item in items {
            guard briefs[item.eventKey] == nil else { continue }
            do {
                if let loaded = try store.load(eventKey: item.eventKey) {
                    briefs[item.eventKey] = loaded
                    errors.removeValue(forKey: item.eventKey)
                }
            } catch {
                let msg = "Cached brief unreadable: \(error.localizedDescription)"
                errors[item.eventKey] = msg
                lastError = msg
                AppLog.write("brief", "[\(item.eventKey)] \(msg)")
            }
        }
    }

    /// 브리핑 생성 보장 (캐시 확인, 미존재 시 생성).
    /// force=true 시 기존 캐시를 미리 지우지 않고 새로 생성 후 덮어씁니다(실패 시 이전 캐시 보존).
    @discardableResult
    func ensureBrief(for item: UpcomingMeetingItem, force: Bool = false, allowGeneration: Bool = true) async -> BriefEnsureOutcome {
        if !settings.enabled && !force { return .disabled }

        if force {
            noHistoryKeys.remove(item.eventKey)
            skippedKeys.remove(item.eventKey)
            errors.removeValue(forKey: item.eventKey)
        } else {
            if briefs[item.eventKey] != nil { return .alreadyInMemory }
            do {
                if let loaded = try store.load(eventKey: item.eventKey) {
                    briefs[item.eventKey] = loaded
                    errors.removeValue(forKey: item.eventKey)
                    if item.eventKey == sessionEventKey {
                        currentBrief = loaded
                    }
                    return .loadedFromDisk
                }
            } catch {
                let msg = "Cached brief unreadable: \(error.localizedDescription)"
                errors[item.eventKey] = msg
                lastError = msg
                AppLog.write("brief", "[\(item.eventKey)] \(msg)")
                return .cacheUnreadable
            }
            if skippedKeys.contains(item.eventKey) { return .skippedLarge }
            if noHistoryKeys.contains(item.eventKey) { return .noHistory }
        }

        guard allowGeneration else {
            return .deferred
        }

        guard !generating.contains(item.eventKey) else { return .inProgress }
        generating.insert(item.eventKey)
        defer { generating.remove(item.eventKey) }

        let ninetyDaysAgo = now().addingTimeInterval(-90 * 86400)
        let speakerMap = meetingStore.speakerNamesByMeeting(since: ninetyDaysAgo, limit: 50)

        let cand = BriefGenerator.candidates(
            for: item,
            meetings: meetingStore.meetings,
            speakerNamesByMeeting: speakerMap,
            now: now(),
            skipLarge: settings.skipLargeMeetings
        )

        guard let candidates = cand else {
            skippedKeys.insert(item.eventKey)
            AppLog.write("brief", "[\(item.eventKey)] 대규모 회의(8명 이상) 건너뜀")
            return .skippedLarge
        }

        guard !candidates.isEmpty else {
            noHistoryKeys.insert(item.eventKey)
            AppLog.write("brief", "[\(item.eventKey)] 과거 관련 회의 없음 (no history)")
            return .noHistory
        }

        let attendeeNames = item.attendees.map(\.name)
        let openTasks: [TaskItem]
        do {
            openTasks = try openTasksProvider(attendeeNames)
        } catch {
            let msg = "Tasks unavailable: \(error.localizedDescription)"
            errors[item.eventKey] = msg
            lastError = msg
            AppLog.write("brief", "[\(item.eventKey)] \(msg)")
            return .tasksUnavailable
        }

        let lang = language()

        do {
            let generated = try await BriefGenerator.generate(
                event: item,
                candidates: candidates,
                openTasks: openTasks,
                store: meetingStore,
                language: lang,
                backend: backend,
                now: now()
            )
            try store.save(generated)
            briefs[item.eventKey] = generated
            errors.removeValue(forKey: item.eventKey)
            if item.eventKey == sessionEventKey {
                currentBrief = generated
            }
            lastError = nil
            AppLog.write("brief", "[\(item.eventKey)] 브리핑 생성 완료 (기반 회의 \(generated.basedOn.count)건)")
            return .generated
        } catch {
            let msg = error.localizedDescription
            errors[item.eventKey] = msg
            lastError = msg
            AppLog.write("brief", "[\(item.eventKey)] 브리핑 생성 실패: \(error)")
            return .generationFailed
        }
    }

    /// 하루 1회 아침 일괄 브리핑 생성 (단일 진입점).
    func runMorningBatchIfNeeded(items: [UpcomingMeetingItem], reason: String = "manual") async {
        guard settings.enabled else { return }
        guard !items.isEmpty else { return }
        let currentNow = now()
        var comps = calendar.dateComponents([.year, .month, .day], from: currentNow)
        comps.hour = settings.batchHour
        comps.minute = 0
        comps.second = 0
        guard let todayBatch = calendar.date(from: comps) else { return }
        guard currentNow >= todayBatch else { return }

        let lastRun = (defaults.object(forKey: "briefsLastBatchRun") as? Date) ?? lastBatchRunDate ?? .distantPast
        guard !calendar.isDate(lastRun, inSameDayAs: currentNow) else { return }

        defaults.set(currentNow, forKey: "briefsLastBatchRun")
        lastBatchRunDate = currentNow

        AppLog.write("brief", "Running morning batch (\(reason)) for \(items.count) items")
        lastBatchDeferredKeys = []
        var consumedCount = 0
        let limit = settings.dailyBatchLimit

        for item in items {
            let allowGen = consumedCount < limit
            let outcome = await ensureBrief(for: item, allowGeneration: allowGen)
            if outcome == .generated || outcome == .generationFailed {
                consumedCount += 1
            } else if outcome == .deferred {
                lastBatchDeferredKeys.insert(item.eventKey)
            }
        }

        if !lastBatchDeferredKeys.isEmpty {
            AppLog.write("brief", "아침 배치 상한 \(limit)건 도달, \(lastBatchDeferredKeys.count)건 보류 (10분 전 트리거 또는 수동 새로고침으로 생성)")
        }
    }

    /// 아침 일괄 브리핑 순차 생성.
    func runMorningBatch(items: [UpcomingMeetingItem]) async {
        for item in items {
            await ensureBrief(for: item)
        }
    }

    /// 다음 배치 실행 시각 계산 (순수 함수: 오늘 지정 시각이 지났으면 내일).
    static func nextBatchDate(after now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        guard let targetToday = calendar.date(from: comps) else { return now }
        if targetToday > now {
            return targetToday
        }
        return calendar.date(byAdding: .day, value: 1, to: targetToday) ?? targetToday
    }

    /// 아침 일괄 배치 스케줄러 등록 (타이머 + Sleep 복귀 시 NSWorkspace.didWakeNotification 감지).
    func scheduleMorningBatch(itemsProvider: @escaping () -> [UpcomingMeetingItem]) {
        self.itemsProvider = itemsProvider
        startupTask?.cancel()
        batchTask?.cancel()

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.wakeHandleCount += 1
                    let items = self.itemsProvider?() ?? []
                    await self.runMorningBatchIfNeeded(items: items, reason: "wake")
                }
            }
        }

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let items = self.itemsProvider?() ?? []
            self.preloadCached(for: items)
            guard !Task.isCancelled else { return }
            await self.runMorningBatchIfNeeded(items: self.itemsProvider?() ?? [], reason: "startup")
        }

        batchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay: TimeInterval
                do {
                    guard let self else { break }
                    let next = Self.nextBatchDate(after: self.now(), hour: self.settings.batchHour, calendar: self.calendar)
                    delay = next.timeIntervalSince(self.now())
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { break }
                guard let self else { break }
                let items = self.itemsProvider?() ?? []
                await self.runMorningBatchIfNeeded(items: items, reason: "timer")
            }
        }
    }

    /// 라이브 회의 시작 시 호출: 해당 일정의 브리핑을 currentBrief에 설정.
    func beginSession(item: UpcomingMeetingItem?) {
        sessionEventKey = item?.eventKey
        if let item {
            if let inMemory = briefs[item.eventKey] {
                currentBrief = inMemory
            } else {
                do {
                    currentBrief = try store.load(eventKey: item.eventKey)
                } catch {
                    currentBrief = nil
                    let msg = "Cached brief unreadable: \(error.localizedDescription)"
                    errors[item.eventKey] = msg
                    lastError = msg
                    AppLog.write("brief", "[\(item.eventKey)] \(msg)")
                }
            }
        } else {
            currentBrief = nil
        }
    }

    /// 라이브 회의 종료 시 호출.
    func endSession() {
        currentBrief = nil
    }

    /// 회의 저장 시점에 브리핑 사본 복사.
    func copyBriefIfAvailable(toMeetingFolder url: URL) {
        guard let key = sessionEventKey else { return }
        let briefToCopy: Brief?
        if let inMemory = briefs[key] {
            briefToCopy = inMemory
        } else {
            do {
                briefToCopy = try store.load(eventKey: key)
            } catch {
                lastError = error.localizedDescription
                let notice = "Could not copy the pre-meeting brief into the meeting folder: \(error.localizedDescription)"
                onUserNotice?(notice)
                AppLog.write("brief", "[\(key)] copyBrief failed to load brief: \(error)")
                return
            }
        }
        guard let brief = briefToCopy else { return }
        do {
            try store.copyBrief(brief, toMeetingFolder: url)
        } catch {
            lastError = error.localizedDescription
            let notice = "Could not copy the pre-meeting brief into the meeting folder: \(error.localizedDescription)"
            onUserNotice?(notice)
            AppLog.write("brief", "[\(key)] copyBrief failed: \(error)")
        }
    }
}
