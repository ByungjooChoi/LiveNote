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

    private var pollTask: Task<Void, Never>?
    private var segments: [Segment] = []
    private var currentActive: (name: String, since: Date)?
    private var lastSelfMuted: Bool?
    private var myNameHint = "Philip"

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
        zoomDetected = false
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

    private func poll() {
        guard let zoom = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "us.zoom.xos"
        }) else {
            closeActive()
            zoomDetected = false
            return
        }

        let app = AXUIElementCreateApplication(zoom.processIdentifier)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
            closeActive()
            zoomDetected = false
            return
        }

        var activeName: String?
        var selfMuted: Bool?
        var tileCount = 0

        for window in windows {
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
                // 내 타일: 표시명에 내 이름 포함 (myName 설정 기반)
                if name.localizedCaseInsensitiveContains(myNameHint) {
                    let unmuted = desc.contains("음소거 해제") || desc.contains("unmuted")
                    selfMuted = !unmuted
                }
            }
        }

        let wasDetected = zoomDetected
        zoomDetected = tileCount > 0
        if zoomDetected != wasDetected {
            AppLog.write("zoomtag", zoomDetected ? "타일 감지 (\(tileCount)개)" : "타일 사라짐 (화면 공유/창 닫힘?)")
        }

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
