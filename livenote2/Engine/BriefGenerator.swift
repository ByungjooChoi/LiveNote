import Foundation

enum BriefError: LocalizedError, Equatable {
    case noHistory
    case skippedLargeMeeting
    case emptyResponse
    case malformed(missing: [String])

    var errorDescription: String? {
        switch self {
        case .noHistory:
            return "No relevant meeting history found"
        case .skippedLargeMeeting:
            return "Meeting has 8 or more attendees, skipping briefing"
        case .emptyResponse:
            return "Empty response received from LLM"
        case .malformed(let missing):
            return "Briefing output is malformed, missing sections: \(missing.joined(separator: ", "))"
        }
    }
}

enum BriefGenerator {

    struct Candidate: Equatable {
        var meeting: MeetingSummary
        var score: Int
    }

    static let contextBudget = 40_000
    static let perMeetingTranscriptCap = 4_000

    /// 브리핑 마크다운 유효성 검증: 필수 3개 섹션 누락 목록 반환.
    /// "# Last time", "# Open items", "# Suggested agenda" 확인.
    /// Suggested agenda 불릿이 3개가 아니면 경고만 기록.
    static func validate(markdown: String) -> [String] {
        var missing: [String] = []
        let lines = markdown.components(separatedBy: .newlines)
        var hasLastTime = false
        var hasOpenItems = false
        var hasSuggestedAgenda = false
        var inAgenda = false
        var agendaBulletCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("# last time") || lower.hasPrefix("## last time") {
                hasLastTime = true
                inAgenda = false
            } else if lower.hasPrefix("# open items") || lower.hasPrefix("## open items") {
                hasOpenItems = true
                inAgenda = false
            } else if lower.hasPrefix("# suggested agenda") || lower.hasPrefix("## suggested agenda") {
                hasSuggestedAgenda = true
                inAgenda = true
            } else if inAgenda {
                if trimmed.hasPrefix("#") {
                    inAgenda = false
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    agendaBulletCount += 1
                }
            }
        }

        if !hasLastTime { missing.append("# Last time") }
        if !hasOpenItems { missing.append("# Open items") }
        if !hasSuggestedAgenda {
            missing.append("# Suggested agenda")
        } else if agendaBulletCount != 3 {
            missing.append("Suggested agenda must have exactly 3 bullets (found \(agendaBulletCount))")
        }

        return missing
    }

    /// 과거 회의 후보군 선정 (순수 함수).
    /// 90일 이내, 참석자 겹침(+3/명), 제목 Jaccard >= 0.5(+2), 30일 이내(+1).
    /// 점수 0 제외, 점수 내림차순 -> 시작시각 내림차순, 상위 5개.
    /// 참석자 8명 이상이고 skipLarge가 true이면 nil 반환.
    static func candidates(
        for event: UpcomingMeetingItem,
        meetings: [MeetingSummary],
        speakerNamesByMeeting: [URL: [String]] = [:],
        now: Date = Date(),
        skipLarge: Bool = true
    ) -> [Candidate]? {
        if skipLarge && event.attendees.count >= 8 {
            return nil
        }

        let ninetyDaysAgo = now.addingTimeInterval(-90 * 86400)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)

        var results: [Candidate] = []

        for meeting in meetings {
            guard meeting.startedAt >= ninetyDaysAgo, meeting.startedAt < now else {
                continue
            }

            var score = 0

            // 1. 참석자 겹침 (+3/명)
            let meetingAttendees = meeting.attendees ?? []
            let meetingSpeakers = speakerNamesByMeeting[meeting.url] ?? []

            var matchedPersonCount = 0
            for eventAttendee in event.attendees {
                var isMatched = false

                // 과거 회의 참석자와 대조
                for pastAttendee in meetingAttendees {
                    if personMatches(
                        eventName: eventAttendee.name,
                        eventEmail: eventAttendee.email,
                        pastName: pastAttendee.name,
                        pastEmail: pastAttendee.email
                    ) {
                        isMatched = true
                        break
                    }
                }

                // 화자명과 대조
                if !isMatched {
                    for speakerName in meetingSpeakers {
                        if speakerMatches(
                            eventName: eventAttendee.name,
                            eventEmail: eventAttendee.email,
                            speakerName: speakerName
                        ) {
                            isMatched = true
                            break
                        }
                    }
                }

                if isMatched {
                    matchedPersonCount += 1
                }
            }
            score += matchedPersonCount * 3

            // 2. 제목 Jaccard 유사도 (>= 0.5면 +2)
            let similarity = jaccard(event.title, meeting.title)
            if similarity >= 0.5 {
                score += 2
            }

            // 3. 30일 이내 최근성 (+1) - 관련성(참석자 또는 제목)이 있는 경우에만 가산
            if score > 0 && meeting.startedAt >= thirtyDaysAgo {
                score += 1
            }

            if score > 0 {
                results.append(Candidate(meeting: meeting, score: score))
            }
        }

        results.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.meeting.startedAt > $1.meeting.startedAt
        }

        return Array(results.prefix(5))
    }

    /// 제목 토큰 Jaccard 유사도 계산 (소문자, 비알파벳 분리, 불용어 제거).
    static func jaccard(_ a: String, _ b: String) -> Double {
        let tokensA = normalizedTitleTokens(a)
        let tokensB = normalizedTitleTokens(b)

        if tokensA.isEmpty && tokensB.isEmpty {
            return 0.0
        }

        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    private static func normalizedTitleTokens(_ title: String) -> Set<String> {
        let stopWords: Set<String> = ["1", "1:1", "sync", "meeting", "call", "weekly"]
        let rawTokens = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let filtered = rawTokens.filter { !stopWords.contains($0) }
        return Set(filtered)
    }

    /// 사람 이름 정규화 (ZoomSpeakerTagger.shortName 접미사 제거 규칙, 소문자, 공백 축약, diacritic 제거).
    static func normalizePersonName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var name = raw
        if let at = name.range(of: " @ ") { name = String(name[..<at.lowerBound]) }
        if let bar = name.range(of: " | ") { name = String(name[..<bar.lowerBound]) }
        if let comma = name.range(of: ", ") { name = String(name[..<comma.lowerBound]) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let folded = collapsed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.isEmpty ? nil : folded
    }

    /// 이메일 정규화 (소문자, 앞뒤 공백 제거).
    static func normalizeEmail(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    /// 참석자 일치 여부 확인: (a) 이메일 완전 일치(대소문자 무시) 또는 (b) 정규화된 전체 이름 완전 일치.
    static func personMatches(
        eventName: String?,
        eventEmail: String?,
        pastName: String?,
        pastEmail: String?
    ) -> Bool {
        let normEventEmail = normalizeEmail(eventEmail)
        let normPastEmail = normalizeEmail(pastEmail)
        if let normEventEmail, let normPastEmail, normEventEmail == normPastEmail {
            return true
        }

        let normEventName = normalizePersonName(eventName)
        let normPastName = normalizePersonName(pastName)
        if let normEventName, let normPastName, normEventName == normPastName {
            return true
        }

        return false
    }

    /// 과거 회의 화자명 일치 여부 확인 (전체 이름 완전 일치 규칙).
    static func speakerMatches(
        eventName: String?,
        eventEmail: String?,
        speakerName: String?
    ) -> Bool {
        guard let normEventName = normalizePersonName(eventName),
              let normSpeakerName = normalizePersonName(speakerName) else {
            return false
        }
        return normEventName == normSpeakerName
    }

    /// 브리핑 시스템 프롬프트 (고정 3섹션).
    static func systemPrompt(language: String) -> String {
        """
        You are an AI meeting assistant. Generate a concise, high-value pre-meeting briefing in \(language).
        The output MUST have exactly three sections with markdown headers:

        # Last time
        - 3 to 5 key decisions and progress updates from past meetings, with dates noted.

        # Open items
        - Open action items formatted as: - task (owner) [meeting title]

        # Suggested agenda
        - Exactly 3 actionable agenda topics or questions for this upcoming meeting.

        Rules:
        - Word count: 200 to 350 words total.
        - Be concrete, professional, and actionable.
        - Output strictly in \(language).
        """
    }

    /// 브리핑 유저 프롬프트 (이벤트 정보 + 과거 회의 컨텍스트 + 미완료 태스크).
    static func userPrompt(
        event: UpcomingMeetingItem,
        contextText: String,
        openTasks: [TaskItem],
        today: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd, EEEE"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let todayStr = formatter.string(from: today)

        var lines: [String] = []
        lines.append("Today's date: \(todayStr)")
        lines.append("Upcoming meeting: \(event.title)")
        if !event.attendees.isEmpty {
            lines.append("Attendees: \(event.attendees.map(\.name).joined(separator: ", "))")
        }
        if let notes = event.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let notesPrefix = String(notes.prefix(1_000))
            lines.append("Meeting notes / description:\n\(notesPrefix)")
        }
        lines.append("")
        lines.append("--- Past Meeting Records ---")
        lines.append(contextText.isEmpty ? "(No past transcripts available)" : contextText)
        lines.append("--- End of Past Meeting Records ---")
        lines.append("")
        lines.append("--- Open Tasks ---")
        if openTasks.isEmpty {
            lines.append("No open items recorded.")
        } else {
            for task in openTasks {
                var itemStr = "- \(task.title)"
                if let owner = task.owner, !owner.isEmpty {
                    itemStr += " (\(owner))"
                }
                if let due = task.due, !due.isEmpty {
                    itemStr += " [due \(due)]"
                }
                if let meetingTitle = task.meetingTitle, !meetingTitle.isEmpty {
                    itemStr += " [\(meetingTitle)]"
                }
                lines.append(itemStr)
            }
        }
        lines.append("--- End of Open Tasks ---")
        lines.append("")
        lines.append("Please generate the pre-meeting brief based on the above information.")
        return lines.joined(separator: "\n")
    }

    /// LLM 백엔드 주입 인터페이스.
    struct Backend: Sendable {
        var apiKey: @MainActor @Sendable () -> String?
        var cloud: @Sendable (
            _ system: String,
            _ user: String,
            _ apiModel: String
        ) async throws -> String
        var local: @Sendable (
            _ system: String,
            _ user: String
        ) async throws -> String

        static func live(
            apiKey: @escaping @MainActor @Sendable () -> String?,
            localEngine: LocalChatEngine? = nil
        ) -> Backend {
            Backend(
                apiKey: apiKey,
                cloud: { system, user, apiModel in
                    guard let key = await apiKey(), !key.isEmpty else {
                        throw BriefError.emptyResponse
                    }
                    return try await GeminiChat.respond(
                        context: "",
                        history: [],
                        question: user,
                        apiKey: key,
                        model: apiModel,
                        thinkingLevel: nil,
                        systemPrompt: system
                    )
                },
                local: { system, user in
                    guard let engine = localEngine else {
                        throw BriefError.emptyResponse
                    }
                    return try await engine.respond(
                        context: "",
                        history: [],
                        question: user,
                        systemPrompt: system
                    )
                }
            )
        }
    }

    /// 브리핑 생성 실행.
    @MainActor
    static func generate(
        event: UpcomingMeetingItem,
        candidates: [Candidate],
        openTasks: [TaskItem],
        store: MeetingStore,
        language: String,
        backend: Backend,
        now: Date = Date()
    ) async throws -> Brief {
        guard !candidates.isEmpty else {
            throw BriefError.noHistory
        }

        let built = ContextBuilder.build(
            meetings: candidates.map(\.meeting),
            store: store,
            budget: contextBudget,
            perMeetingTranscriptCap: perMeetingTranscriptCap
        )

        let system = systemPrompt(language: language)
        let user = userPrompt(
            event: event,
            contextText: built.text,
            openTasks: openTasks,
            today: now
        )

        let responseText: String
        let maybeKey = backend.apiKey()
        if let key = maybeKey, !key.isEmpty {
            responseText = try await backend.cloud(system, user, "gemini-3.7-flash")
        } else {
            responseText = try await backend.local(system, user)
        }

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BriefError.emptyResponse
        }

        let missing = validate(markdown: trimmed)
        guard missing.isEmpty else {
            throw BriefError.malformed(missing: missing)
        }

        let usedTitles = built.used.map(\.title)
        let basedOn = usedTitles.isEmpty ? candidates.map(\.meeting.title) : usedTitles
        let firstAgenda = BriefStore.firstAgendaLine(in: trimmed)

        return Brief(
            eventKey: event.eventKey,
            markdown: trimmed,
            generatedAt: now,
            basedOn: basedOn,
            suggestedAgendaFirstLine: firstAgenda
        )
    }
}
