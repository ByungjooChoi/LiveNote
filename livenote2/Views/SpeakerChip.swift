import SwiftUI

/// 화자 칩 레이블 뷰 (아이콘 및 이름 표시)
struct SpeakerChipLabel: View {
    let name: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(name)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
        .frame(minWidth: 64, alignment: .leading)
    }

    /// 화자 이름 출처에 따른 SF Symbol 아이콘 반환
    static func icon(for source: NameSource?) -> String? {
        guard let source else { return nil }
        switch source {
        case .zoom:
            return "video"
        case .voice:
            return "waveform"
        case .manual:
            return "pencil"
        case .slot:
            return nil
        }
    }
}
