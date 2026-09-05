import SwiftUI

/// 전사 편집 횟수 표시 배지 및 되돌리기(Undo) 메뉴.
struct TranscriptEditBadge: View {
    let log: TranscriptEditLog
    let onUndo: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        if log.editCount > 0 {
            Menu {
                if let last = log.batches.last {
                    let kindLabel = last.kind == .inline ? "Inline" : "Replace all"
                    let rowCount = last.rowEdits.count
                    let rowLabel = rowCount == 0 ? "summary only" : (rowCount == 1 ? "1 row" : "\(rowCount) rows")
                    Button {
                        onUndo()
                    } label: {
                        Label("Undo last edit (\(kindLabel), \(rowLabel))", systemImage: "arrow.uturn.backward")
                    }

                    Text("Edited at \(Self.timeFormatter.string(from: last.at))")
                        .disabled(true)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil.line")
                    Text("Edited \(log.editCount)")
                }
                .font(.caption)
            }
        }
    }
}
