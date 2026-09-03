import AppKit
import SwiftUI

/// 자동 시작 직전 카운트다운 패널 (MeetingAlertPanel과 같은 nonactivating 플로팅 패널).
///
/// 회의 앱 실행이나 캘린더 회의 시작 시각을 감지해 자동으로 기록을 시작하기 전,
/// 몇 초의 취소 여지를 준다. 잘못된 감지로 회의가 아닌 통화까지 기록되는 사고를 막는 장치.
@MainActor
final class CountdownPanelController {

    private var panel: NSPanel?
    private var expireTask: Task<Void, Never>?

    /// - Parameters:
    ///   - reason: 카운트다운 이유 (예: "Zoom launched", "Meeting is starting")
    ///   - seconds: 남은 시간
    ///   - onExpire: 카운트다운 만료 시 호출 (기록 시작)
    ///   - onCancel: Cancel 클릭 시 호출
    func show(
        reason: String,
        seconds: TimeInterval,
        onExpire: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        let deadline = Date().addingTimeInterval(seconds)

        let hosting = NSHostingController(
            rootView: CountdownView(
                reason: reason,
                deadline: deadline,
                onCancel: { [weak self] in
                    self?.close()
                    onCancel()
                }
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
        newPanel.setContentSize(NSSize(width: 320, height: max(fitting.height, 110)))

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = newPanel.frame.size
            newPanel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 20,
                y: visible.maxY - size.height - 20
            ))
        }

        newPanel.orderFrontRegardless()
        panel = newPanel

        expireTask = Task { @MainActor [weak self] in
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.panel != nil else { return }
            self.close()
            onExpire()
        }
    }

    /// 카운트다운이 떠 있는지 (중복 표시 방지용)
    var isVisible: Bool { panel != nil }

    func close() {
        expireTask?.cancel()
        expireTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 패널 내용: 사유 한 줄 + 남은 초 + Cancel.
struct CountdownView: View {
    let reason: String
    let deadline: Date
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(reason, systemImage: "record.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text("Starting LiveNote in \(Self.remainingSeconds(deadline: deadline, now: context.date))s")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// 남은 초 (0 미만으로 내려가지 않게 자름).
    static func remainingSeconds(deadline: Date, now: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}
