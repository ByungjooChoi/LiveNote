import SwiftUI

/// 회의 상세 화면 상단의 화자별 발화 시간 요약 줄 ("Craig 21 min · Philip 18 min").
struct SpeakersSummaryLine: View {
    let stats: [SpeakerStat]

    var body: some View {
        if !stats.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryText: String {
        stats.map { stat in
            let minutes = max(1, Int(round(stat.seconds / 60)))
            return "\(stat.name) \(minutes) min"
        }.joined(separator: " · ")
    }
}
