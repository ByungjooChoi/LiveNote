import Foundation

/// 저장된 회의들을 LLM 입력 컨텍스트 문자열로 조립.
///
/// 회의당 한 섹션: 헤더(제목·날짜·소요·참석자) + 본문.
/// 본문은 summary.md가 있으면 요약, 없으면 전사 앞부분(perMeetingTranscriptCap자).
/// 예산(budget)을 넘어서면 이후 회의는 넣지 않고 truncated로 센다.
///
/// AppState의 아카이브 채팅 컨텍스트에서 승격된 로직이며, Recipes(Phase 1)·
/// 사전 브리핑(Phase 2)이 예산만 바꿔 재사용한다.
@MainActor
enum ContextBuilder {

    /// 예산이 이 값 이하로 남으면 더 넣지 않는다 (조각난 섹션 방지).
    private static let minimumSectionBudget = 2_000

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
            guard remaining > minimumSectionBudget else {
                truncated += 1
                continue
            }
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
            parts.append(String(section.prefix(remaining)))
            used.append(meeting)
            remaining -= section.count
        }

        return (parts.joined(separator: "\n\n"), used, truncated)
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
