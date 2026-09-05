import SwiftUI

/// 전역 Tasks 목록 화면 (필터, 그룹화, 수동 추가, 회의 바로가기).
struct TasksView: View {
    @Environment(AppState.self) private var app
    @Binding var screen: ContentView.Screen

    @State private var newTitle = ""
    @State private var newOwner = ""
    @State private var newDue = ""
    @State private var dueValidationError: String? = nil
    @State private var showManualInput = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = app.tasks.lastError {
                errorBanner(error)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear {
            app.tasks.refresh()
        }
        .onChange(of: newDue) { _, _ in
            dueValidationError = nil
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button {
                app.tasks.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks")
                    .font(.title2.weight(.bold))
                Text("Action items and commitments from meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Picker("Filter", selection: Bindable(app.tasks).filter) {
                ForEach(TasksController.Filter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Picker("Group by", selection: Bindable(app.tasks).grouping) {
                ForEach(TasksController.Grouping.allCases, id: \.self) { grouping in
                    Text(grouping.rawValue).tag(grouping)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showManualInput.toggle()
                }
            } label: {
                Label("Add task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.card)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showManualInput {
                    manualInputRow
                }

                let visibleTasks = app.tasks.visible(filter: app.tasks.filter, myName: app.myName)
                let grouped = TasksController.grouped(visibleTasks, by: app.tasks.grouping)

                if visibleTasks.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.key) { group in
                        groupSection(title: group.key, tasks: group.tasks)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var manualInputRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New manual task")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                TextField("Task title", text: $newTitle)
                    .textFieldStyle(.roundedBorder)

                TextField("Owner (optional)", text: $newOwner)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                TextField("Due yyyy-MM-dd", text: $newDue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)

                Button("Add") {
                    guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let trimmedDue = newDue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedDue.isEmpty && !TaskExtractor.isValidDueDate(trimmedDue) {
                        dueValidationError = "Due must be yyyy-MM-dd"
                        return
                    }
                    dueValidationError = nil
                    app.tasks.addManual(
                        title: newTitle,
                        owner: newOwner.isEmpty ? nil : newOwner,
                        due: newDue.isEmpty ? nil : newDue
                    )
                    newTitle = ""
                    newOwner = ""
                    newDue = ""
                    showManualInput = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let dueError = dueValidationError {
                Text(dueError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .themedCard()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No tasks found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tasks extracted from meeting minutes or added manually will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
        .themedCard()
    }

    private func groupSection(title: String, tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    taskRow(task)
                    if task.id != tasks.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .themedCard()
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                app.tasks.toggle(task)
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.status == .done ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.body)
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

                    Spacer()

                    if let meetingURL = task.meetingURL {
                        Button {
                            screen = .meeting(meetingURL)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Open meeting")
                                    .font(.caption)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                            }
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    } else if let meetingTitle = task.meetingTitle, !meetingTitle.isEmpty {
                        HStack(spacing: 6) {
                            Text("\(meetingTitle) (source unmatched)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button {
                                app.tasks.delete(task)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            app.tasks.delete(task)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let quote = task.quote, !quote.isEmpty {
                    Text("\"\(quote)\"")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
    }
}
