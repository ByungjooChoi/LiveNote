import SwiftUI

/// 전사 수정 5건 이상 누적 시 요약 재생성 유도 배너.
struct ResummarizeBanner: View {
    let pendingEdits: Int
    let isGenerating: Bool
    let onRegenerate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(Theme.accent)
                .font(.title3)

            Text("\(pendingEdits) edits since the minutes were generated. Regenerate minutes?")
                .font(.callout)

            Spacer()

            Button("Regenerate") {
                onRegenerate()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(isGenerating)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
        )
    }
}
