import SwiftUI

@main
struct livenote2App: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 840, minHeight: 520)
        }
        .defaultSize(width: 1020, height: 680)

        // 메뉴바 상주 — 창을 닫아도 여기서 시작/중지 가능
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRunning ? "waveform.circle.fill" : "waveform")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(statusLine)

            Divider()

            Button(app.isRunning ? "Stop & Save" : "Start") {
                if app.isRunning {
                    app.stop()
                } else {
                    app.start()
                }
            }

            Button("Open main window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Toggle("Auto-start with meeting apps", isOn: Binding(
                get: { app.autoStartOnMeetingApp },
                set: { app.setAutoStart($0) }
            ))

            Toggle("Meeting alerts (1 min before)", isOn: Binding(
                get: { app.calendar.isEnabled },
                set: { app.calendar.setEnabled($0) }
            ))

            Toggle("Sync mute with Zoom", isOn: Binding(
                get: { app.syncMuteWithZoom },
                set: { app.setSyncMuteWithZoom($0) }
            ))

            Divider()

            Button("Quit livenote2") {
                if app.isRunning {
                    // 저장이 끝날 시간을 준 뒤 종료
                    app.stop()
                    Task {
                        try? await Task.sleep(nanoseconds: 4_500_000_000)
                        NSApplication.shared.terminate(nil)
                    }
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var statusLine: String {
        switch app.phase {
        case .idle:
            return "Idle"
        case .preparing(let message):
            return message
        case .listening:
            return "Listening — \(app.rows.count) segments"
        case .error:
            return "Error — check main window"
        }
    }
}
