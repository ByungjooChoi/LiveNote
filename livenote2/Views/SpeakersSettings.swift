import SwiftUI

/// 설정 화면의 화자 성문 관리 카드 (Settings > Speakers).
struct SpeakersSettingsCard: View {
    let store: any VoiceprintStoring

    @State private var selectedIDs: Set<String> = []
    @State private var editingID: String? = nil
    @State private var editingName: String = ""
    @State private var showForgetAllAlert = false
    @State private var showMergeAlert = false
    @State private var actionError: String? = nil

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = actionError ?? store.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.vermilion)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.vermilion)
                    Spacer()
                }
                .padding(8)
                .background(Theme.vermilion.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if store.people.isEmpty {
                Text("No voiceprints saved yet. Names and voices will be learned automatically during meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.people) { person in
                        personRow(person)
                    }
                }

                // 다중 선택 액션 바
                HStack(spacing: 10) {
                    if selectedIDs.count == 2 {
                        Button("Merge Selected (2)") {
                            showMergeAlert = true
                        }
                        .controlSize(.small)
                    }

                    if !selectedIDs.isEmpty {
                        Button("Delete Selected (\(selectedIDs.count))") {
                            deleteSelected()
                        }
                        .controlSize(.small)
                        .foregroundStyle(Theme.vermilion)
                    }

                    Spacer()

                    Button("Forget all voices") {
                        showForgetAllAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(Theme.vermilion)
                }
                .padding(.top, 4)
            }

            Divider()

            Text("Voiceprints stay on this Mac. Audio is never stored.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Forget all voices?",
            isPresented: $showForgetAllAlert,
            titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) {
                forgetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all saved voiceprints? This action cannot be undone.")
        }
        .confirmationDialog(
            "Merge selected voiceprints?",
            isPresented: $showMergeAlert,
            titleVisibility: .visible
        ) {
            Button("Merge") {
                mergeSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let names = selectedIDs.compactMap { id in store.people.first(where: { $0.id == id })?.name }
            Text("Merge voiceprints for \(names.joined(separator: " and ")) into one profile?")
        }
    }

    @ViewBuilder
    private func personRow(_ person: Person) -> some View {
        let isSelected = selectedIDs.contains(person.id)
        let isEditing = editingID == person.id

        HStack(spacing: 8) {
            // 선택 체크박스
            Button {
                if isSelected {
                    selectedIDs.remove(person.id)
                } else {
                    selectedIDs.insert(person.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)

            if isEditing {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit {
                        commitRename(for: person)
                    }

                Button("Save") {
                    commitRename(for: person)
                }
                .controlSize(.small)

                Button("Cancel") {
                    editingID = nil
                    editingName = ""
                }
                .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(person.name)
                            .font(.body.weight(.medium))

                        if person.isMe {
                            Text("You")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.15))
                                .foregroundStyle(Theme.accent)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 4) {
                        Text("\(person.meetings) \(person.meetings == 1 ? "meeting" : "meetings")")
                        if let lastSeen = person.lastSeen {
                            Text("· Last seen \(Self.dateFormatter.string(from: lastSeen))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    editingID = person.id
                    editingName = person.name
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Rename")

                Button {
                    deletePerson(person)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Theme.accent.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func commitRename(for person: Person) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.rename(id: person.id, to: trimmed)
            editingID = nil
            editingName = ""
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deletePerson(_ person: Person) {
        do {
            try store.delete(id: person.id)
            selectedIDs.remove(person.id)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteSelected() {
        actionError = nil
        for id in Array(selectedIDs) {
            do {
                try store.delete(id: id)
                selectedIDs.remove(id)
            } catch {
                actionError = store.lastError ?? error.localizedDescription
                break
            }
        }
    }

    private func mergeSelected() {
        let ids = Array(selectedIDs)
        guard ids.count == 2 else { return }
        let targetID = ids[0]
        let sourceID = ids[1]
        do {
            try store.merge(sourceID, into: targetID)
            selectedIDs.removeAll()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func forgetAll() {
        do {
            try store.forgetAll()
            selectedIDs.removeAll()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}
