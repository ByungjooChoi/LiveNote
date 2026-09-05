import SwiftUI

/// 화자 이름 변경 및 성문 저장 여부를 설정하는 팝오버 뷰.
struct SpeakerNamePopover: View {
    let row: TranscriptRow
    let currentName: String
    let candidates: [String]
    let allowRememberVoice: Bool
    var errorMessage: String? = nil
    @Binding var rememberVoice: Bool
    let onSave: (String, Bool) -> Void

    @State private var draftName: String

    init(
        row: TranscriptRow,
        currentName: String,
        candidates: [String] = [],
        allowRememberVoice: Bool = true,
        errorMessage: String? = nil,
        rememberVoice: Binding<Bool> = .constant(false),
        onSave: @escaping (String, Bool) -> Void
    ) {
        self.row = row
        self.currentName = currentName
        self.candidates = candidates
        self.allowRememberVoice = allowRememberVoice
        self.errorMessage = errorMessage
        self._rememberVoice = rememberVoice
        self.onSave = onSave
        self._draftName = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.channel == .me ? "My name" : "Speaker name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit {
                    commit()
                }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.vermilion)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !candidates.isEmpty {
                Divider()
                Text("Suggestions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates.prefix(6), id: \.self) { candidate in
                        Button {
                            draftName = candidate
                            commit()
                        } label: {
                            Label(candidate, systemImage: "person.crop.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }

            if row.channel == .them {
                Divider()
                if allowRememberVoice {
                    Toggle("Remember this voice", isOn: $rememberVoice)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                } else {
                    Text("Voice data is only available right after a meeting ends")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Save") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func commit() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onSave(name, rememberVoice)
    }
}
