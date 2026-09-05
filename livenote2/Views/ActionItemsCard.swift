import SwiftUI

/// 회의 상세 뷰의 Action Items 카드 (요약 카드 아래 표시).
struct ActionItemsCard: View {
    @Environment(AppState.self) private var app
    let meetingURL: URL

    private var meetingTasks: [TaskItem] {
        let standardPath = meetingURL.standardizedFileURL.path
        return app.tasks.tasks.filter {
            $0.meetingURL?.standardizedFileURL.path == standardPath
        }
    }

    var body: some View {
        if !meetingTasks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "checklist")
                        .foregroundStyle(Theme.accent)
                    Text("Action Items")
                        .font(.headline)
                    Spacer()
                    let openCount = meetingTasks.filter { $0.status == .open }.count
                    if openCount > 0 {
                        Text("\(openCount) open")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                VStack(spacing: 0) {
                    ForEach(meetingTasks) { task in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                app.tasks.toggle(task)
                            } label: {
                                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.status == .done ? Theme.accent : .secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(task.title)
                                        .font(.callout)
                                        .strikethrough(task.status == .done)
                                        .foregroundStyle(task.status == .done ? .secondary : .primary)

                                    if let owner = task.owner {
                                        Text(owner)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Theme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.accent.opacity(0.1))
                                            .clipShape(Capsule())
                                    }

                                    if let due = task.due {
                                        HStack(spacing: 3) {
                                            Image(systemName: "calendar")
                                                .font(.caption2)
                                            Text(due)
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.1))
                                        .clipShape(Capsule())
                                    }
                                }

                                if let quote = task.quote, !quote.isEmpty {
                                    Text("\"\(quote)\"")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 8)

                        if task.id != meetingTasks.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard()
        }
    }
}
