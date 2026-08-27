import AppKit
import SwiftUI

/// 회의 임박 알림 플로팅 패널.
/// 우상단 고정, 포커스를 뺏지 않는 nonactivating 패널, 전체 화면 앱 위에도 표시됩니다.
@MainActor
final class MeetingAlertPanelController {

    private var panel: NSPanel?

    func show(meeting: MeetingAlert, onJoin: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        close()

        let hosting = NSHostingController(
            rootView: MeetingAlertView(meeting: meeting, onJoin: onJoin, onDismiss: onDismiss)
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
        newPanel.setContentSize(NSSize(width: 380, height: max(fitting.height, 140)))

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

/// 팝업 내용: 제목·시간·카운트다운·참가/닫기.
struct MeetingAlertView: View {
    let meeting: MeetingAlert
    let onJoin: () -> Void
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

            HStack(spacing: 10) {
                Button(action: onJoin) {
                    Label(meeting.deepLink != nil ? "Join Zoom" : "Open meeting link", systemImage: "video.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button("Dismiss", action: onDismiss)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func countdown(now: Date) -> String {
        let remaining = meeting.start.timeIntervalSince(now)
        if remaining > 5 { return "in \(Int(remaining))s" }
        if remaining > -60 { return "starting now" }
        return "in progress"
    }
}
