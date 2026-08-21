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

            Button(app.isRunning ? "중지하고 저장" : "시작") {
                if app.isRunning {
                    app.stop()
                } else {
                    app.start()
                }
            }

            Button("메인 창 열기") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Toggle("회의 앱 실행 시 자동 시작", isOn: Binding(
                get: { app.autoStartOnMeetingApp },
                set: { app.setAutoStart($0) }
            ))

            Toggle("회의 1분 전 Zoom 참가 알림", isOn: Binding(
                get: { app.calendar.isEnabled },
                set: { app.calendar.setEnabled($0) }
            ))

            Divider()

            Button("livenote2 종료") {
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
            return "대기 중"
        case .preparing(let message):
            return message
        case .listening:
            return "듣는 중 — 전사 \(app.rows.count)건"
        case .error:
            return "오류 — 메인 창 확인"
        }
    }
}
