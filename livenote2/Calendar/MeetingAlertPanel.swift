import AppKit
import SwiftUI

/// 회의 임박 알림 플로팅 패널.
/// 우상단 고정, 포커스를 뺏지 않는 nonactivating 패널, 전체 화면 앱 위에도 표시됩니다.
@MainActor
final class MeetingAlertPanelController {

    private var panel: NSPanel?

    /// - Parameters:
    ///   - onJoin: 회의 참가 + 기록 시작 (주 버튼)
    ///   - onJoinOnly: 링크만 열고 기록은 시작하지 않음
    ///   - onRecordOnly: 기록만 시작하고 링크는 열지 않음
    ///   - onOpenSettings: 알림 설정 화면 열기
    ///   - suggestedAgenda: 사전 브리핑 한 줄 (Phase 2부터 채워짐, 지금은 nil)
    func show(
        meeting: MeetingAlert,
        suggestedAgenda: String? = nil,
        onJoin: @escaping () -> Void,
        onJoinOnly: @escaping () -> Void,
        onRecordOnly: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        close()

        let hosting = NSHostingController(
            rootView: MeetingAlertView(
                meeting: meeting,
                suggestedAgenda: suggestedAgenda,
                onJoin: onJoin,
                onJoinOnly: onJoinOnly,
                onRecordOnly: onRecordOnly,
                onOpenSettings: onOpenSettings,
                onDismiss: onDismiss
            )
        )
        let newPanel = NSPanel(contentViewController: hosting)
        newPanel.styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            newPanel.standardWindowButton(buttonType)?.isHidden = true
        }
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isMovableByWindowBackground = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.isReleasedWhenClosed = false

        let fitting = hosting.view.fittingSize
        newPanel.setContentSize(NSSize(width: 420, height: max(fitting.height, 140)))

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = newPanel.frame.size
            newPanel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 20,
                y: visible.maxY - size.height - 20
            ))
        }

        newPanel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
        panel = newPanel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 팝업 내용: 제목·시간·카운트다운·분할 참가 버튼/닫기.
struct MeetingAlertView: View {
    let meeting: MeetingAlert
    /// 사전 브리핑의 제안 안건 한 줄. nil이면 그 줄을 그리지 않는다.
    var suggestedAgenda: String?
    let onJoin: () -> Void
    let onJoinOnly: () -> Void
    let onRecordOnly: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Meeting starting", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdown(now: context.date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
            }

            Text(meeting.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            Text("\(Self.timeFormatter.string(from: meeting.start)) ~ \(Self.timeFormatter.string(from: meeting.end)) · recording starts when you join")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let suggestedAgenda, !suggestedAgenda.isEmpty {
                Label(suggestedAgenda, systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                // 분할 버튼: 주 동작 + ▾ 대체 동작 메뉴 (spacing 0으로 하나처럼 붙임)
                HStack(spacing: 0) {
                    Button(action: onJoin) {
                        Label("Join \(platformName) & start LiveNote", systemImage: "video.fill")
                            .frame(minWidth: 190)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Menu {
                        Button("Join meeting only", action: onJoinOnly)
                        Button("Start LiveNote only", action: onRecordOnly)
                        Divider()
                        Button("Change notification settings", action: onOpenSettings)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(width: 30)
                    .fixedSize()
                }

                Spacer()

                Button("Dismiss", action: onDismiss)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    /// 주 버튼 라벨에 들어갈 플랫폼 이름.
    private var platformName: String {
        Self.platformName(for: meeting.webLink)
    }

    /// 링크 호스트로 회의 플랫폼 이름을 결정한다. 모르는 호스트나 nil이면 "meeting".
    static func platformName(for url: URL?) -> String {
        guard let host = url?.host()?.lowercased() else { return "meeting" }
        if matches(host, "zoom.us") { return "Zoom" }
        if matches(host, "teams.microsoft.com") || matches(host, "teams.live.com") { return "Teams" }
        if matches(host, "meet.google.com") { return "Meet" }
        if matches(host, "webex.com") { return "Webex" }
        return "meeting"
    }

    /// 도메인 자신이거나 그 하위 도메인일 때만 참.
    /// 부분 문자열 비교는 notzoom.us·teams.evil.example 같은 호스트를 오인식한다.
    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private func countdown(now: Date) -> String {
        let remaining = meeting.start.timeIntervalSince(now)
        if remaining > 5 { return "in \(Int(remaining))s" }
        if remaining > -60 { return "starting now" }
        return "in progress"
    }
}
