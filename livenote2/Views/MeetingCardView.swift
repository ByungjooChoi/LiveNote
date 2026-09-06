import SwiftUI
import AppKit

/// 회의 카드 뷰 (Home 및 People 타임라인에서 재사용).
struct MeetingCardView: View {
    @Environment(AppState.self) private var app
    let meeting: MeetingSummary
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Text(String(meeting.title.prefix(1)))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(meeting.dateLabel) · \(meeting.rowCount)건 · \(meeting.durationLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .themedCard()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
            }
            Button("Delete", role: .destructive) {
                app.meetingStore.delete(meeting)
            }
        }
    }
}
