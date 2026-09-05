import SwiftUI

/// 찾아바꾸기 후 사내 전문용어 등록 제안 토스트 (12초 자동 해제).
struct JargonToast: View {
    let term: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(Theme.accent)

            Text("Add '\(term)' to internal jargon?")
                .font(.callout)

            Button("Add") {
                onAdd()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Theme.accent)

            Button("Not now") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .task(id: term) {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if !Task.isCancelled {
                onDismiss()
            }
        }
    }
}
