import Foundation
import CoreAudio
import AppKit
import Observation

/// 녹음 리마인더 상태 검사 결과
struct RecordingReminderProbe: Sendable {
    var meetingAppName: String?
    var micInUse: Bool
    var liveNoteActive: Bool
}

/// 리마인더 상태 검사기 프로토콜 (MainActor)
protocol RecordingReminderProbing: AnyObject {
    @MainActor func probe() -> RecordingReminderProbe
}

/// 리마인더 시스템 알림 발송 프로토콜
protocol RecordingReminderNotifying: AnyObject {
    func requestAuthorizationIfNeeded(_ completion: @escaping @MainActor (Bool) -> Void)
    func deliver(appName: String, completion: @escaping @MainActor (Error?) -> Void)
}

/// 리마인더 정책 판정 결과
enum RecordingReminderDecision: Equatable {
    case idle
    case armed
    case notify(appName: String)
    case suppressed
}

/// 순수 상태 머신: 연속 충족 횟수와 발송 여부 관리
struct RecordingReminderPolicy: Equatable {
    private(set) var consecutiveHits = 0
    private(set) var notified = false

    mutating func tick(_ p: RecordingReminderProbe, requiredHits: Int = 2) -> RecordingReminderDecision {
        guard let appName = p.meetingAppName else {
            reset()
            return .idle
        }

        let conditionMet = p.micInUse && !p.liveNoteActive
        guard conditionMet else {
            consecutiveHits = 0
            return .idle
        }

        consecutiveHits += 1
        if notified {
            return .suppressed
        }
        if consecutiveHits >= requiredHits {
            notified = true
            return .notify(appName: appName)
        }
        return .armed
    }

    mutating func clearHits() {
        consecutiveHits = 0
    }

    mutating func rearm() {
        consecutiveHits = 0
        notified = false
    }

    mutating func reset() {
        consecutiveHits = 0
        notified = false
    }
}

/// 기본 프로브 구현: NSWorkspace 앱 실행 상태 및 CoreAudio 기본 입력 마이크 사용 여부 조회
@MainActor
final class SystemRecordingReminderProbe: RecordingReminderProbing {
    var isActive: () -> Bool
    private static var hasLoggedCoreAudioError = false

    init(isActive: @escaping () -> Bool = { true }) {
        self.isActive = isActive
    }

    func probe() -> RecordingReminderProbe {
        let appName = findRunningMeetingAppName()
        let micInUse = checkDefaultInputMicInUse()
        let liveNoteActive = isActive()
        return RecordingReminderProbe(
            meetingAppName: appName,
            micInUse: micInUse,
            liveNoteActive: liveNoteActive
        )
    }

    private func findRunningMeetingAppName() -> String? {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let bundleID = app.bundleIdentifier, meetingAppBundleIDs.contains(bundleID) {
                return app.localizedName ?? "Meeting app"
            }
        }
        return nil
    }

    private func checkDefaultInputMicInUse() -> Bool {
        var defaultInputDevice = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &propertySize,
            &defaultInputDevice
        )

        guard status == noErr, defaultInputDevice != AudioObjectID(kAudioObjectUnknown) else {
            logCoreAudioErrorOnce(status: status, operation: "kAudioHardwarePropertyDefaultInputDevice")
            return false
        }

        var isRunningSomewhere: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        status = AudioObjectGetPropertyData(
            defaultInputDevice,
            &runningAddress,
            0,
            nil,
            &isRunningSize,
            &isRunningSomewhere
        )

        guard status == noErr else {
            logCoreAudioErrorOnce(status: status, operation: "kAudioDevicePropertyDeviceIsRunningSomewhere")
            return false
        }

        return isRunningSomewhere != 0
    }

    private func logCoreAudioErrorOnce(status: OSStatus, operation: String) {
        guard !Self.hasLoggedCoreAudioError else { return }
        Self.hasLoggedCoreAudioError = true
        AppLog.write("reminder", "CoreAudio error in \(operation): \(status)")
    }
}

/// 녹음 누락 방지 리마인더 관리자
@MainActor
@Observable
final class RecordingReminder {
    private enum AuthorizationState {
        case notRequested
        case requesting
        case granted
        case denied
    }

    var isEnabled: Bool
    private(set) var statusMessage: String?

    @ObservationIgnored private var policy = RecordingReminderPolicy()
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let probe: RecordingReminderProbing
    @ObservationIgnored private let notifier: RecordingReminderNotifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tickInterval: TimeInterval
    @ObservationIgnored private var authState: AuthorizationState = .notRequested
    @ObservationIgnored private var pendingDelivery: (appName: String, generation: Int)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previousDecision: RecordingReminderDecision = .idle

    init(
        probe: RecordingReminderProbing,
        notifier: RecordingReminderNotifying,
        defaults: UserDefaults = .standard,
        tickInterval: TimeInterval = 60
    ) {
        self.probe = probe
        self.notifier = notifier
        self.defaults = defaults
        self.tickInterval = tickInterval

        if defaults.object(forKey: "recordingReminderEnabled") != nil {
            self.isEnabled = defaults.bool(forKey: "recordingReminderEnabled")
        } else {
            self.isEnabled = true
        }
    }

    var consecutiveHitsForTesting: Int {
        policy.consecutiveHits
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        generation += 1
        defaults.set(on, forKey: "recordingReminderEnabled")
        if on {
            start()
        } else {
            stop()
            pendingDelivery = nil
            policy.clearHits()
            previousDecision = .idle
            statusMessage = nil
        }
    }

    func start() {
        guard isEnabled else { return }
        guard timerTask == nil else { return }

        let interval = tickInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard let self else { break }
                self.tickNow()
            }
        }

        tickNow()
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    func meetingAppTerminated() {
        invalidateMeetingState()
    }

    private func invalidateMeetingState() {
        generation += 1
        pendingDelivery = nil
        let hadState = policy.consecutiveHits > 0 || policy.notified
        policy.reset()
        if hadState || previousDecision != .idle {
            AppLog.write("reminder", "reset")
        }
        previousDecision = .idle
    }

    func tickNow() {
        guard isEnabled else { return }
        let p = probe.probe()

        if p.meetingAppName == nil {
            if pendingDelivery != nil || policy.consecutiveHits > 0 || policy.notified || previousDecision != .idle {
                invalidateMeetingState()
            }
            return
        }

        let conditionC = p.micInUse && !p.liveNoteActive
        if conditionC && authState == .notRequested {
            requestAuthSingleFlight()
        }

        if !conditionC && authState == .requesting && pendingDelivery != nil {
            pendingDelivery = nil
            policy.rearm()
            previousDecision = .idle
            AppLog.write("reminder", "notify intent cancelled: condition dropped while awaiting authorization")
        }

        let decision = policy.tick(p)
        logDecisionTransitionIfNeeded(from: previousDecision, to: decision)
        previousDecision = decision

        switch decision {
        case .notify(let appName):
            handleNotificationDecision(appName: appName)
        case .idle, .armed, .suppressed:
            break
        }
    }

    private func requestAuthSingleFlight() {
        guard authState == .notRequested else { return }
        authState = .requesting
        notifier.requestAuthorizationIfNeeded { [weak self] granted in
            guard let self else { return }
            self.authState = granted ? .granted : .denied
            if !granted {
                self.statusMessage = "Notifications are off for LiveNote in System Settings > Notifications."
                AppLog.write("reminder", "authorization denied")
                self.pendingDelivery = nil
                return
            }
            if let pending = self.pendingDelivery {
                self.pendingDelivery = nil
                if pending.generation != self.generation || !self.isEnabled {
                    self.policy.rearm()
                    self.previousDecision = .idle
                    AppLog.write("reminder", "notify intent cancelled: stale generation")
                    return
                }
                self.deliver(appName: pending.appName, generation: pending.generation)
            }
        }
    }

    private func handleNotificationDecision(appName: String) {
        switch authState {
        case .notRequested:
            pendingDelivery = (appName: appName, generation: generation)
            requestAuthSingleFlight()
        case .requesting:
            pendingDelivery = (appName: appName, generation: generation)
        case .granted:
            deliver(appName: appName, generation: generation)
        case .denied:
            statusMessage = "Notifications are off for LiveNote in System Settings > Notifications."
            pendingDelivery = nil
        }
    }

    private func deliver(appName: String, generation: Int) {
        guard generation == self.generation, isEnabled else {
            policy.rearm()
            previousDecision = .idle
            AppLog.write("reminder", "notify intent cancelled: stale generation")
            return
        }

        let currentProbe = probe.probe()
        let conditionC = currentProbe.meetingAppName != nil && currentProbe.micInUse && !currentProbe.liveNoteActive
        guard conditionC else {
            policy.rearm()
            previousDecision = .idle
            AppLog.write("reminder", "notify intent cancelled: condition no longer holds")
            return
        }

        notifier.deliver(appName: appName) { [weak self] error in
            guard let self else { return }
            if self.generation != generation || !self.isEnabled {
                AppLog.write("reminder", "stale delivery dropped")
                return
            }
            if let error {
                self.statusMessage = "Notification delivery failed: \(error.localizedDescription)"
                AppLog.write("reminder", "notify failed: \(error.localizedDescription)")
            } else {
                AppLog.write("reminder", "delivered \(appName)")
            }
        }
    }

    private func logDecisionTransitionIfNeeded(
        from oldDecision: RecordingReminderDecision,
        to newDecision: RecordingReminderDecision
    ) {
        guard oldDecision != newDecision else { return }
        switch newDecision {
        case .armed:
            AppLog.write("reminder", "armed")
        case .notify(let appName):
            AppLog.write("reminder", "notify intent \(appName)")
        case .idle:
            if oldDecision == .armed || oldDecision == .suppressed {
                AppLog.write("reminder", "reset")
            }
        case .suppressed:
            break
        }
    }
}
