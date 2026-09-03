import Foundation

/// 저장된 회의들을 LLM 입력 컨텍스트 문자열로 조립.
///
/// 회의당 한 섹션: 헤더(제목·날짜·소요·참석자) + 본문.
/// 본문은 summary.md가 있으면 요약, 없으면 전사 앞부분(perMeetingTranscriptCap자).
///
/// 예산 계약: 섹션은 통째로만 넣는다. 구분자("\n\n")까지 포함해 남은 예산에 들어가면 넣고,
/// 안 들어가면 넣지 않고 truncated로 센다. 예외는 첫 섹션 하나뿐이다: 컨텍스트가 통째로 비는 것을
/// 막기 위해 예산을 넘겨도 잘라서 넣고, 잘렸으므로 truncated로 세고 used에는 넣지 않는다.
/// 따라서 used에는 온전히 들어간 회의만 담긴다.
///
/// AppState의 아카이브 채팅 컨텍스트에서 승격된 로직이며, Recipes(Phase 1)·
/// 사전 브리핑(Phase 2)이 예산만 바꿔 재사용한다.
@MainActor
enum ContextBuilder {

    /// 섹션 사이 구분자. 예산 계산에도 이 길이를 그대로 반영한다.
    private static let separator = "\n\n"

    static func build(
        meetings: [MeetingSummary],
        store: MeetingStore,
        budget: Int,
        perMeetingTranscriptCap: Int
    ) -> (text: String, used: [MeetingSummary], truncated: Int) {
        var parts: [String] = []
        var used: [MeetingSummary] = []
        var truncated = 0
        var remaining = budget

        for meeting in meetings {
            guard let saved = store.load(meeting.url) else { continue }

            let body: String
            if let summary = saved.summary {
                body = summary
            } else {
                let transcript = MeetingStore.transcriptForSummary(saved) { row in
                    MeetingStore.resolveName(
                        row: row,
                        myName: saved.myName,
                        speakerNames: saved.speakerNames
                    )
                }
                body = String(transcript.prefix(perMeetingTranscriptCap))
            }

            let section = "\(header(for: meeting))\n\(body)"
            let cost = section.count + (parts.isEmpty ? 0 : separator.count)
            if cost <= remaining {
                parts.append(section)
                used.append(meeting)
                remaining -= cost
                continue
            }
            // 첫 섹션만 잘라서라도 넣는다. 이후에는 남은 예산이 0이라 모두 truncated로 센다.
            if parts.isEmpty {
                parts.append(String(section.prefix(remaining)))
                remaining = 0
            }
            truncated += 1
        }

        return (parts.joined(separator: separator), used, truncated)
    }

    /// "## 제목 (8/27 09:01 · 45m 0s)" + 참석자가 있으면 다음 줄에 "Attendees: …"
    private static func header(for meeting: MeetingSummary) -> String {
        var header = "## \(meeting.title) (\(meeting.dateLabel) · \(meeting.durationLabel))"
        let names = (meeting.attendees ?? []).map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty {
            header += "\nAttendees: \(names.joined(separator: ", "))"
        }
        return header
    }
}
