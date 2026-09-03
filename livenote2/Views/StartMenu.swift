import SwiftUI

/// 기록 시작 분할 버튼. 본체를 누르면 온라인 회의 모드로 바로 시작하고,
/// ▾ 메뉴에서 대면 회의 모드를 고를 수 있다 (Phase 0.5).
struct StartMenu: View {
    /// 선택된 모드로 시작 요청. 화면 전환은 호출부가 담당.
    let onStart: (StartMode) -> Void

    var body: some View {
        Menu {
            Button {
                onStart(.inPerson)
            } label: {
                Label("Start in-person", systemImage: "person.2.fill")
            }
        } label: {
            Text("Start")
        } primaryAction: {
            onStart(.online)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.small)
        .fixedSize()
        .help("Start recording. Use the arrow for in-person meetings (mic only, speaker separation).")
    }
}
