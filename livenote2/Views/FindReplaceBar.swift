import SwiftUI

/// 전사 본문 찾아바꾸기 상단 바.
struct FindReplaceBar: View {
    @Binding var find: String
    @Binding var replacement: String
    @Binding var caseSensitive: Bool
    @Binding var wholeWord: Bool
    @Binding var includeSummary: Bool
    let matchCount: Int
    let matchedRows: Int
    let isBusy: Bool
    let onReplaceAll: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $find)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)

                Button("Replace All") {
                    onReplaceAll()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(matchCount == 0 || isBusy)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close (Escape)")
            }

            HStack(spacing: 14) {
                Toggle("Match case", isOn: $caseSensitive)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Toggle("Whole word", isOn: $wholeWord)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Toggle("Also apply to summary", isOn: $includeSummary)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Spacer()

                if !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(matchCount) \(matchCount == 1 ? "match" : "matches") across \(matchedRows) \(matchedRows == 1 ? "row" : "rows")")
                        .font(.caption)
                        .foregroundStyle(matchCount > 0 ? .secondary : Theme.vermilion)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .onExitCommand {
            onClose()
        }
    }
}
