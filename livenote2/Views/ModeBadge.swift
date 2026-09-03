import SwiftUI

/// 헤더용 캡슐 배지. 지금은 대면 회의 모드 표시("In person")에 쓰인다.
struct ModeBadge: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Theme.accent)
        .background(Capsule().fill(Theme.accent.opacity(0.12)))
    }
}
