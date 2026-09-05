import SwiftUI

/// HomeView Coming up 행에 표시되는 브리핑 상태 배지 및 새로고침 버튼.
struct BriefRowAccessory: View {
    let status: BriefStatus
    var lastError: String? = nil
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .ready:
                Text("Brief")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            case .generating:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Preparing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            case .noHistory:
                Text("No history")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            case .skipped:
                Text("Skipped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            case .notStarted:
                if let lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            case .disabled:
                EmptyView()
            }

            if status != .disabled {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh briefing")
            }
        }
    }
}

/// 브리핑 마크다운 및 기반 회의 출처 렌더링 카드.
struct BriefDisclosure: View {
    let brief: Brief
    var lastError: String? = nil
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let lastError, !lastError.isEmpty {
                    Text("Error: \(lastError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                SummaryRenderView(markdown: brief.markdown)

                if !brief.basedOn.isEmpty {
                    Text("Based on: \(brief.basedOn.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label("Pre-meeting brief", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 라이브 회의 상단에 노출되는 브리핑 패널 (접힘 기본).
struct LiveBriefPanel: View {
    let brief: Brief
    var lastError: String? = nil
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    SummaryRenderView(markdown: brief.markdown)

                    if !brief.basedOn.isEmpty {
                        Text("Based on: \(brief.basedOn.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                    Text("Pre-meeting brief")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let agenda = brief.suggestedAgendaFirstLine, !isExpanded {
                        Text(agenda)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
