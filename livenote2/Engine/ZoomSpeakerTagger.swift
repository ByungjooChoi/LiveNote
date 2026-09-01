import AppKit
import ApplicationServices
import Foundation

/// Zoom 활성 화자 태그 — 손쉬운 사용(AX) 권한으로 Zoom 회의 창의 참가자 타일을 읽음.
/// Granola의 Zoom speaker tags와 같은 방식 (2026-08-27 실회의 AX 덤프로 구조 검증).
///
/// 타일 구조 (실측):
///   [AXTabGroup] d="Steve Mayzak @ …, 컴퓨터 오디오 음소거 해제됨, Video on, active speaker"
///     [AXButton]  d="Steve Mayzak @ …"   ← 이름만 깨끗하게 (상태 토큰 없음)
///
/// 제공 기능:
/// 1. 활성 화자 타임라인 → 확정 행 구간과 겹침 매칭으로 화자 이름 자동 부여
/// 2. 내 Zoom 뮤트 상태 감지 → livenote2 마이크 캡처 자동 동기화 (에코 원천 차단)
/// 3. Zoom 회의 감지 → LS-EEND 미기동 판단 근거 (부하 절감)
///
/// 한계 (문서화): Zoom 전용 (Teams/Meet 불가), macOS 전용, Zoom UI 구조 변경에 취약,
/// 화면 공유·발표자 보기에서 타일 노출이 줄면 태그 공백 발생 가능, 동시 발화 시 1명만 표시.
@MainActor
final class ZoomSpeakerTagger {

    /// 활성 화자 구간 (세션 시작 기준 초)
    private struct Segment {
        let name: String
        let start: Date
        var end: Date
    }

    /// Zoom 회의 타일이 현재 보이는지 (최근 폴에서)
    private(set) var zoomDetected = false
    /// AX 권한 없음 (안내 배너용)
    private(set) var permissionMissing = false
    /// 내 Zoom 뮤트 상태 변화 콜백 (AppState가 마이크 동기화 배선)
    var onSelfMuteChange: ((Bool) -> Void)?
    /// Zoom 회의 종료 감지 콜백 (회의 창·타일이 5초간 사라지면 1회 호출 — 즉시 저장·요약용).
    /// 즉시(1초)로 안 하는 이유: 창 전환·레이아웃 재구성 순간 AX 트리에서 잠깐 사라질 수 있어
    /// 진행 중 회의를 오탐으로 끊는 것을 방지하는 최소 버퍼. 실제 종료 체감은 5~6초.
    var onMeetingEnded: (() -> Void)?

    /// 종료 감지 상태
    private var meetingWasPresent = false
    private var absentStreak = 0
    private var endedFired = false

    private var pollTask: Task<Void, Never>?
    private var segments: [Segment] = []
    private var currentActive: (name: String, since: Date)?
    private var lastSelfMuted: Bool?
    private var myNameHint = "Philip"

    /// 내 타일 식별 (v1.2.2 재설계 — 이름 매칭 실패 회귀 대응)
    /// 1순위: 마이크 상관 학습 — 내가 말할 때(마이크 레벨 높음) 활성으로 표시되는 타일을
    ///        3회 이상, 타 후보의 2배 이상 득표하면 내 타일로 확정. Zoom 표시명과 무관하게 동작.
    /// 2순위(부트스트랩): myName의 단어(4자 이상)가 타일 이름에 포함되면 즉시 확정.
    private(set) var selfTileName: String?
    private var selfVotes: [String: Int] = [:]
    /// 마이크에 직접 발화가 실리는 중인지 (AppState가 micLevel 기반으로 배선)
    var micActive: (() -> Bool)?

    // MARK: - 수명

    /// AX 권한 확인. prompt=true면 시스템 다이얼로그로 요청.
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            return AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    static func zoomRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "us.zoom.xos" }
    }

    func start(myName: String) {
        stop()
        myNameHint = myName
        segments = []
        currentActive = nil
        lastSelfMuted = nil
        selfTileName = nil
        selfVotes = [:]
        zoomDetected = false
        meetingWasPresent = false
        absentStreak = 0
        endedFired = false
        permissionMissing = !Self.accessibilityTrusted(prompt: false)
        AppLog.write("zoomtag", permissionMissing
            ? "시작 실패 — 손쉬운 사용 권한 없음 (재설치로 리셋됐을 수 있음)"
            : "폴링 시작 (myName=\(myName))")
        guard !permissionMissing else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let current = currentActive {
            segments.append(Segment(name: current.name, start: current.since, end: Date()))
            currentActive = nil
        }
    }

    // MARK: - 조회

    /// [from, to] (세션 시작 기준 초) 구간에서 가장 오래 활성 화자였던 이름.
    /// 겹침 ≥ max(0.5s, 구간의 15%) 일 때만 신뢰.
    func dominantName(fromSeconds: Double, toSeconds: Double, sessionStart: Date) -> String? {
        guard toSeconds > fromSeconds else { return nil }
        let from = sessionStart.addingTimeInterval(fromSeconds)
        let to = sessionStart.addingTimeInterval(toSeconds)

        var all = segments
        if let current = currentActive {
            all.append(Segment(name: current.name, start: current.since, end: Date()))
        }
        var overlaps: [String: TimeInterval] = [:]
        for segment in all {
            // 내 타일은 상대방 행 이름 후보에서 제외 (에코 유입 시 내 이름이 붙는 오염 방지)
            if let selfTileName, segment.name == selfTileName { continue }
            let start = max(from, segment.start)
            let end = min(to, segment.end)
            if end > start {
                overlaps[segment.name, default: 0] += end.timeIntervalSince(start)
            }
        }
        guard let best = overlaps.max(by: { $0.value < $1.value }) else { return nil }
        let minimum = max(0.5, (toSeconds - fromSeconds) * 0.15)
        return best.value >= minimum ? Self.shortName(best.key) : nil
    }

    /// 이름 부트스트랩: myName의 4자 이상 단어가 타일 표시명에 포함되면 매칭.
    /// (예: myName "Byung joo Choi" ↔ Zoom "Philip Choi" → "Choi" 일치)
    static func nameMatches(tile: String, hint: String) -> Bool {
        if tile.localizedCaseInsensitiveContains(hint) { return true }
        for part in hint.split(separator: " ") where part.count >= 4 {
            if tile.localizedCaseInsensitiveContains(part) { return true }
        }
        return false
    }

    /// Zoom 표시명에서 직함·소속 꼬리 제거 ("Philip Choi @ Elastic SA, Search Specialist" → "Philip Choi").
    static func shortName(_ raw: String) -> String {
        var name = raw
        if let at = name.range(of: " @ ") { name = String(name[..<at.lowerBound]) }
        if let bar = name.range(of: " | ") { name = String(name[..<bar.lowerBound]) }
        if let comma = name.range(of: ", ") { name = String(name[..<comma.lowerBound]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 폴링

    private func attr(_ element: AXUIElement, _ name: String) -> Any? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// 회의 창·타일 존재 여부로 종료를 판정 (12초 연속 부재 시 1회 통지).
    private func noteMeetingPresence(_ present: Bool) {
        if present {
            meetingWasPresent = true
            absentStreak = 0
            endedFired = false
        } else if meetingWasPresent, !endedFired {
            absentStreak += 1
            if absentStreak >= 5 {
                endedFired = true
                AppLog.write("zoomtag", "회의 종료 감지 (창·타일 5초 부재)")
                onMeetingEnded?()
            }
        }
    }

    private func poll() {
        guard let zoom = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "us.zoom.xos"
        }) else {
            closeActive()
            zoomDetected = false
            noteMeetingPresence(false)
            return
        }

        let app = AXUIElementCreateApplication(zoom.processIdentifier)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
            closeActive()
            zoomDetected = false
            noteMeetingPresence(false)
            return
        }

        var activeName: String?
        var selfMuted: Bool?
        var tileCount = 0
        var meetingWindowFound = false

        for window in windows {
            if let title = attr(window, kAXTitleAttribute) as? String,
               title.contains("Zoom 회의") || title.contains("Zoom Meeting") {
                meetingWindowFound = true
            }
            guard let children = attr(window, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for tile in children {
                guard (attr(tile, kAXRoleAttribute) as? String) == "AXTabGroup",
                      let desc = attr(tile, kAXDescriptionAttribute) as? String,
                      desc.contains("오디오") || desc.contains("audio") || desc.contains("Video")
                else { continue }

                var name = ""
                if let tileChildren = attr(tile, kAXChildrenAttribute) as? [AXUIElement],
                   let button = tileChildren.first(where: {
                       (attr($0, kAXRoleAttribute) as? String) == "AXButton"
                   }),
                   let buttonDesc = attr(button, kAXDescriptionAttribute) as? String {
                    name = buttonDesc
                }
                guard !name.isEmpty else { continue }
                tileCount += 1

                if desc.contains("active speaker") {
                    activeName = name
                }

                // 내 타일 판정: 확정된 selfTileName 우선, 미확정이면 이름 단어 부트스트랩
                var isSelf = false
                if let selfTileName {
                    isSelf = (name == selfTileName)
                } else if Self.nameMatches(tile: name, hint: myNameHint) {
                    selfTileName = name
                    isSelf = true
                    AppLog.write("zoomtag", "내 타일 확정 (이름 매칭): \(Self.shortName(name))")
                }
                if isSelf {
                    let unmuted = desc.contains("음소거 해제") || desc.contains("unmuted")
                    selfMuted = !unmuted
                }
            }
        }

        // 내 타일 학습 (마이크 상관): 내가 말하는 순간의 활성 타일에 투표
        if selfTileName == nil, let activeName, micActive?() == true {
            selfVotes[activeName, default: 0] += 1
            let votes = selfVotes[activeName] ?? 0
            let rival = selfVotes.filter { $0.key != activeName }.values.max() ?? 0
            if votes >= 3, votes >= rival * 2 {
                selfTileName = activeName
                AppLog.write("zoomtag", "내 타일 학습 완료 (마이크 상관, \(votes)표): \(Self.shortName(activeName))")
            }
        }

        let wasDetected = zoomDetected
        zoomDetected = tileCount > 0
        if zoomDetected != wasDetected {
            AppLog.write("zoomtag", zoomDetected ? "타일 감지 (\(tileCount)개)" : "타일 사라짐 (화면 공유/창 닫힘?)")
        }
        noteMeetingPresence(meetingWindowFound || tileCount > 0)

        // 활성 화자 타임라인 갱신
        let now = Date()
        if activeName != currentActive?.name {
            if let activeName {
                AppLog.write("zoomtag", "활성 화자 → \(Self.shortName(activeName))")
            }
            closeActive(at: now)
            if let activeName {
                currentActive = (activeName, now)
            }
        }
        // 30분 이전 구간은 버림
        if segments.count > 600 {
            let cutoff = now.addingTimeInterval(-30 * 60)
            segments.removeAll { $0.end < cutoff }
        }

        // 내 뮤트 상태 변화 통지
        if let selfMuted, selfMuted != lastSelfMuted {
            lastSelfMuted = selfMuted
            AppLog.write("zoomtag", "내 Zoom 뮤트 \(selfMuted ? "켜짐" : "해제")")
            onSelfMuteChange?(selfMuted)
        }
    }

    private func closeActive(at date: Date = Date()) {
        if let current = currentActive {
            segments.append(Segment(name: current.name, start: current.since, end: date))
            currentActive = nil
        }
    }
}
