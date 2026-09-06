import Foundation
import Observation

/// 사람 카드 모델 (PeopleDirectory 집계 결과).
struct PersonCard: Identifiable, Hashable, Sendable {
    var id: String                 // merge key
    var displayName: String
    var aliases: [String]          // distinct original spellings, display first
    var emails: [String]           // lowercased, unique, sorted
    var company: String?           // domain of the first email, nil without email
    var meetingURLs: [URL]         // newest first
    var lastMeetingAt: Date?
    var meetingCount: Int { meetingURLs.count }
}

/// 회사(도메인)별 사람 그룹.
struct PeopleGroup: Identifiable, Hashable, Sendable {
    var id: String { title }
    var title: String
    var people: [PersonCard]
}

/// 회의별 화자 이름 목록.
struct MeetingSpeakerNames: Sendable {
    var url: URL
    var names: [String]
}

/// People 집계 순수 함수 모음.
enum PeopleAggregator {

    /// 이름 정규화: trim, 내부 공백 축약, 소문자화, 후행 괄호(예: " (Elastic)") 및 후행 접미사(예: " - Company") 제거.
    static func normalizedName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            // 후행 괄호 제거 (예: " (Elastic)", "(HQ)")
            if let parenRange = text.range(of: #"\s*\([^)]*\)$"#, options: .regularExpression) {
                text.removeSubrange(parenRange)
                changed = true
            }
            // 후행 접미사 제거 (예: " - Elastic", " - Company")
            if let dashRange = text.range(of: #"\s+-\s+.*$"#, options: .regularExpression) {
                text.removeSubrange(dashRange)
                changed = true
            }
        }
        // 내부 연속 공백을 단일 공백으로 축약
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 화자 플레이스홀더 이름 여부 (예: "speaker 3").
    static func isPlaceholder(_ normalized: String) -> Bool {
        normalized.range(of: #"^speaker \d+$"#, options: .regularExpression) != nil
    }

    /// 회의 목록 및 화자 이름을 집계하여 PersonCard 배열 생성 (본인 제외).
    static func build(
        meetings: [MeetingSummary],
        speakerNames: [MeetingSpeakerNames],
        myName: String
    ) -> [PersonCard] {
        let normMyName = normalizedName(myName)

        // 회의 URL별 시작 시각 매핑
        var meetingDates: [URL: Date] = [:]
        for meeting in meetings {
            meetingDates[meeting.url] = meeting.startedAt
        }

        struct Candidate {
            let originalName: String
            let normalizedName: String
            let email: String?
            let url: URL
            let startedAt: Date
            let order: Int
        }

        var candidates: [Candidate] = []
        var orderCounter = 0

        // 1. 참석자(Attendee)에서 후보 수집
        for meeting in meetings {
            guard let attendees = meeting.attendees else { continue }
            for attendee in attendees {
                let norm = normalizedName(attendee.name)
                guard !norm.isEmpty else { continue }
                if !normMyName.isEmpty && norm == normMyName { continue }
                if isPlaceholder(norm) { continue }

                var cleanEmail: String?
                if let rawEmail = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawEmail.isEmpty {
                    cleanEmail = rawEmail
                }

                candidates.append(Candidate(
                    originalName: attendee.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedName: norm,
                    email: cleanEmail,
                    url: meeting.url,
                    startedAt: meeting.startedAt,
                    order: orderCounter
                ))
                orderCounter += 1
            }
        }

        // 2. 화자(SpeakerNames)에서 후보 수집
        for item in speakerNames {
            let date = meetingDates[item.url] ?? Date.distantPast
            for name in item.names {
                let norm = normalizedName(name)
                guard !norm.isEmpty else { continue }
                if !normMyName.isEmpty && norm == normMyName { continue }
                if isPlaceholder(norm) { continue }

                candidates.append(Candidate(
                    originalName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedName: norm,
                    email: nil,
                    url: item.url,
                    startedAt: date,
                    order: orderCounter
                ))
                orderCounter += 1
            }
        }

        guard !candidates.isEmpty else { return [] }

        // 3. Email identities 색인
        // attendee with email -> email identity (key: "email:\(email)")
        // 각 normalizedName별 연결된 email identities (Set<String>)
        var emailIdentitiesByName: [String: Set<String>] = [:]
        // 각 email identity별 등장한 회의 URL 목록 (Set<URL>)
        var emailIdentityMeetings: [String: Set<URL>] = [:]

        for c in candidates {
            guard let email = c.email else { continue }
            let emailKey = "email:\(email)"
            emailIdentitiesByName[c.normalizedName, default: []].insert(emailKey)
            emailIdentityMeetings[emailKey, default: []].insert(c.url)
        }

        // 4. 각 후보를 결정론적 클러스터 키로 확인
        func resolveClusterKey(for c: Candidate) -> String {
            if let email = c.email {
                // Email identity: 이메일이 있는 참석자는 항상 해당 email identity에 귀속
                return "email:\(email)"
            }

            // Name candidate (이메일 없는 참석자 또는 화자 이름)
            let norm = c.normalizedName
            let allEmailKeys = emailIdentitiesByName[norm] ?? []

            // 동일 회의에 해당 이름을 가진 email identity가 존재하는지 확인 (우선 결합)
            let sameMeetingEmailKeys = allEmailKeys.filter { emailKey in
                emailIdentityMeetings[emailKey]?.contains(c.url) == true
            }

            if sameMeetingEmailKeys.count == 1 {
                // 동일 회의에 해당 이름을 가진 유일한 email identity가 있으면 우선 결합
                return sameMeetingEmailKeys.first!
            } else if sameMeetingEmailKeys.count > 1 {
                // 동일 회의 내에 같은 이름을 쓰는 서로 다른 이메일이 둘 이상이면 모호하므로 독립 카드
                return "name:\(norm)"
            } else {
                // 동일 회의에는 없음 -> 전체 회의 대상 확인
                if allEmailKeys.count == 1 {
                    // 전체 회의에서 정확히 하나의 email identity만 해당 이름을 사용하면 결합
                    return allEmailKeys.first!
                } else {
                    // 0개(해당 이름의 이메일 없음)이거나 2개 이상(모호함)이면 독립 카드
                    return "name:\(norm)"
                }
            }
        }

        var clusterCandidates: [String: [Candidate]] = [:]
        for c in candidates {
            let clusterKey = resolveClusterKey(for: c)
            clusterCandidates[clusterKey, default: []].append(c)
        }

        // 5. 각 컴포넌트로부터 PersonCard 생성 (클러스터 키 정렬로 결정론적 순회 보장)
        var cards: [PersonCard] = []

        let sortedClusterKeys = clusterCandidates.keys.sorted()
        for clusterKey in sortedClusterKeys {
            guard let cluster = clusterCandidates[clusterKey] else { continue }
            // 이메일 목록 (소문자, 유일, 정렬)
            var emailSet = Set<String>()
            for c in cluster {
                if let e = c.email {
                    emailSet.insert(e)
                }
            }
            let sortedEmails = emailSet.sorted()

            // Merge key id: typed id ("email:<email>" 또는 "name:<norm>")
            let id = clusterKey

            // 회사 (첫 번째 이메일의 도메인)
            let company: String?
            if let firstEmail = sortedEmails.first {
                let parts = firstEmail.split(separator: "@")
                if parts.count >= 2 {
                    company = String(parts.last!)
                } else {
                    company = nil
                }
            } else {
                company = nil
            }

            // 표시 이름 및 별칭 (빈도수 내림차순 -> 최초 등장 순)
            var spellingCounts: [String: Int] = [:]
            var spellingFirstOrder: [String: Int] = [:]
            for c in cluster {
                let orig = c.originalName
                spellingCounts[orig, default: 0] += 1
                if spellingFirstOrder[orig] == nil {
                    spellingFirstOrder[orig] = c.order
                }
            }

            let sortedSpellings = spellingCounts.keys.sorted { a, b in
                let countA = spellingCounts[a] ?? 0
                let countB = spellingCounts[b] ?? 0
                if countA != countB {
                    return countA > countB
                }
                let orderA = spellingFirstOrder[a] ?? 0
                let orderB = spellingFirstOrder[b] ?? 0
                return orderA < orderB
            }

            let displayName = sortedSpellings.first ?? id
            let aliases = sortedSpellings

            // 회의 URL 목록 (유일, startedAt 최신순)
            var urlDates: [URL: Date] = [:]
            for c in cluster {
                urlDates[c.url] = c.startedAt
            }
            let sortedURLs = urlDates.keys.sorted { url1, url2 in
                let d1 = urlDates[url1] ?? Date.distantPast
                let d2 = urlDates[url2] ?? Date.distantPast
                if d1 != d2 {
                    return d1 > d2
                }
                return url1.path < url2.path
            }

            let lastMeetingAt = sortedURLs.first.flatMap { urlDates[$0] }

            cards.append(PersonCard(
                id: id,
                displayName: displayName,
                aliases: aliases,
                emails: sortedEmails,
                company: company,
                meetingURLs: sortedURLs,
                lastMeetingAt: lastMeetingAt
            ))
        }

        // 전체 카드 정렬: 최신 회의순 -> 표시 이름순 -> id순
        return cards.sorted { a, b in
            let dateA = a.lastMeetingAt ?? Date.distantPast
            let dateB = b.lastMeetingAt ?? Date.distantPast
            if dateA != dateB {
                return dateA > dateB
            }
            let nameOrder = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return a.id < b.id
        }
    }

    /// 회사(이메일 도메인)별 그룹핑 ("Other"는 최하단, 그룹은 인원수 desc -> 이름 asc, 그룹 내는 최근 회의 desc -> 이름 asc).
    static func grouped(_ people: [PersonCard]) -> [PeopleGroup] {
        var domainBuckets: [String: [PersonCard]] = [:]
        var otherPeople: [PersonCard] = []

        for person in people {
            if let company = person.company, !company.isEmpty {
                domainBuckets[company, default: []].append(person)
            } else {
                otherPeople.append(person)
            }
        }

        func sortGroupMembers(_ list: [PersonCard]) -> [PersonCard] {
            list.sorted { a, b in
                let d1 = a.lastMeetingAt ?? Date.distantPast
                let d2 = b.lastMeetingAt ?? Date.distantPast
                if d1 != d2 {
                    return d1 > d2
                }
                let nameOrder = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return a.id < b.id
            }
        }

        let sortedDomainKeys = domainBuckets.keys.sorted { a, b in
            let countA = domainBuckets[a]?.count ?? 0
            let countB = domainBuckets[b]?.count ?? 0
            if countA != countB {
                return countA > countB
            }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        var groups: [PeopleGroup] = []
        for key in sortedDomainKeys {
            let members = sortGroupMembers(domainBuckets[key] ?? [])
            groups.append(PeopleGroup(title: key, people: members))
        }

        if !otherPeople.isEmpty {
            let sortedOther = sortGroupMembers(otherPeople)
            groups.append(PeopleGroup(title: "Other", people: sortedOther))
        }

        return groups
    }

    /// 검색어로 그룹 필터링 (이름, 별칭, 이메일 대소문자 무시 부분일치).
    static func filter(_ groups: [PeopleGroup], query: String) -> [PeopleGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }

        var result: [PeopleGroup] = []
        for group in groups {
            let matched = group.people.filter { person in
                if person.displayName.localizedCaseInsensitiveContains(trimmed) {
                    return true
                }
                for alias in person.aliases {
                    if alias.localizedCaseInsensitiveContains(trimmed) {
                        return true
                    }
                }
                for email in person.emails {
                    if email.localizedCaseInsensitiveContains(trimmed) {
                        return true
                    }
                }
                return false
            }
            if !matched.isEmpty {
                result.append(PeopleGroup(title: group.title, people: matched))
            }
        }
        return result
    }

    /// 최근 회의 상대 날짜 레이블 (Today / Yesterday / "MMM d" (en_US_POSIX) / 다른 연도면 "MMM d, yyyy").
    static func lastMeetingLabel(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)

        if startOfDate == startOfNow {
            return "Today"
        }

        let dayDiff = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day
        if dayDiff == 1 {
            return "Yesterday"
        }

        let yearOfNow = calendar.component(.year, from: now)
        let yearOfDate = calendar.component(.year, from: date)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        if yearOfNow == yearOfDate {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }
}

/// 세션 디렉터리 내 speakerNames 로딩을 위한 경량 디코더.
private struct LightweightSession: Decodable {
    var speakerNames: [String] = []
    var rows: [LightweightRow] = []

    private enum CodingKeys: String, CodingKey {
        case speakerNames
        case rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rows = try container.decodeIfPresent([LightweightRow].self, forKey: .rows) ?? []

        if container.contains(.speakerNames) {
            do {
                if let intDict = try container.decodeIfPresent([Int: String].self, forKey: .speakerNames) {
                    self.speakerNames = intDict.sorted(by: { $0.key < $1.key }).map(\.value)
                } else {
                    self.speakerNames = []
                }
            } catch let firstError {
                if case .typeMismatch = firstError as? DecodingError,
                   let strDict = try? container.decode([String: String].self, forKey: .speakerNames) {
                    var numericPairs: [(key: String, intVal: Int, val: String)] = []
                    var nonNumericPairs: [(key: String, val: String)] = []

                    for (k, v) in strDict {
                        if let intVal = Int(k) {
                            numericPairs.append((key: k, intVal: intVal, val: v))
                        } else {
                            nonNumericPairs.append((key: k, val: v))
                        }
                    }

                    numericPairs.sort { a, b in
                        if a.intVal != b.intVal {
                            return a.intVal < b.intVal
                        }
                        return a.key < b.key
                    }

                    nonNumericPairs.sort { a, b in
                        return a.key < b.key
                    }

                    self.speakerNames = numericPairs.map(\.val) + nonNumericPairs.map(\.val)
                } else {
                    throw firstError
                }
            }
        } else {
            self.speakerNames = []
        }
    }
}

private struct LightweightRow: Decodable {
    let speakerName: String?

    private enum CodingKeys: String, CodingKey {
        case speakerName
    }
}

/// 인물 색인 및 그룹 관리 서비스 (@MainActor @Observable).
@MainActor
@Observable
final class PeopleDirectory {
    private(set) var people: [PersonCard] = []
    private(set) var groups: [PeopleGroup] = []
    private(set) var isLoading = false
    private(set) var lastWarning: String?

    @ObservationIgnored private let reader: @Sendable (URL) throws -> [String]
    @ObservationIgnored private var cache: [URL: (modDate: Date, names: [String])] = [:]
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var nextMeetings: [MeetingSummary]?
    @ObservationIgnored private var nextMyName: String?

    init(reader: @escaping @Sendable (URL) throws -> [String] = { @Sendable folder in
        try PeopleDirectory.readSpeakerNames(folder: folder)
    }) {
        self.reader = reader
    }

    /// PeopleAggregator.normalizedName 프록시.
    static func normalizedName(_ raw: String) -> String {
        PeopleAggregator.normalizedName(raw)
    }

    /// session.json 파일에서 speakerNames 및 rows의 speakerName을 추출.
    nonisolated static func readSpeakerNames(folder: URL) throws -> [String] {
        let sessionURL = folder.appendingPathComponent("session.json")
        let data = try Data(contentsOf: sessionURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(LightweightSession.self, from: data)

        var seen = Set<String>()
        var result: [String] = []

        for name in session.speakerNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                result.append(trimmed)
            }
        }

        for row in session.rows {
            if let name = row.speakerName {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    result.append(trimmed)
                }
            }
        }

        return result
    }

    /// 회의 목록을 기반으로 인물 디렉터리 새로고침 (동시 호출 시 coalescing 처리).
    func refresh(meetings: [MeetingSummary], myName: String) async {
        nextMeetings = meetings
        nextMyName = myName

        if let existing = activeTask {
            needsRefresh = true
            await existing.value
            return
        }

        isLoading = true
        let task = Task { @MainActor in
            while true {
                guard let targetMeetings = self.nextMeetings, let targetMyName = self.nextMyName else {
                    break
                }
                self.needsRefresh = false
                self.nextMeetings = nil
                self.nextMyName = nil

                await self.performRefresh(meetings: targetMeetings, myName: targetMyName)

                if !self.needsRefresh {
                    break
                }
            }
            self.isLoading = false
            self.activeTask = nil
        }
        activeTask = task
        await task.value
    }

    private func performRefresh(meetings: [MeetingSummary], myName: String) async {
        let currentURLs = Set(meetings.map(\.url))
        cache = cache.filter { currentURLs.contains($0.key) }

        let cachedDates = cache.mapValues { $0.modDate }
        let urls = meetings.map(\.url)
        let reader = self.reader

        let readResults = await Task.detached(priority: .utility) { () -> [(URL, Date, Result<[String], Error>)] in
            var list: [(URL, Date, Result<[String], Error>)] = []
            var seen = Set<URL>()
            for url in urls {
                guard !seen.contains(url) else { continue }
                seen.insert(url)

                let sessionURL = url.appendingPathComponent("session.json")
                let modDate = (try? FileManager.default.attributesOfItem(atPath: sessionURL.path)[.modificationDate] as? Date)
                    ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                    ?? Date.distantPast

                if cachedDates[url] != modDate {
                    do {
                        let names = try reader(url)
                        list.append((url, modDate, .success(names)))
                    } catch {
                        list.append((url, modDate, .failure(error)))
                    }
                }
            }
            return list
        }.value

        var resolvedNames: [URL: [String]] = [:]
        for meeting in meetings {
            if let cached = cache[meeting.url] {
                resolvedNames[meeting.url] = cached.names
            }
        }

        var failCount = 0
        var firstError: String?

        for (url, modDate, result) in readResults {
            switch result {
            case .success(let names):
                cache[url] = (modDate, names)
                resolvedNames[url] = names
            case .failure(let error):
                failCount += 1
                if firstError == nil {
                    firstError = error.localizedDescription
                }
                resolvedNames[url] = []
            }
        }

        if failCount > 0 {
            let errText = firstError ?? "unknown error"
            AppLog.write("app", "People 디렉터리 읽기 실패 \(failCount)건: \(errText)")
            self.lastWarning = "Failed to read \(failCount) meeting folder(s): \(errText)"
        } else {
            self.lastWarning = nil
        }

        var speakerNamesList: [MeetingSpeakerNames] = []
        for meeting in meetings {
            let names = resolvedNames[meeting.url] ?? []
            speakerNamesList.append(MeetingSpeakerNames(url: meeting.url, names: names))
        }

        let cards = PeopleAggregator.build(
            meetings: meetings,
            speakerNames: speakerNamesList,
            myName: myName
        )
        let groups = PeopleAggregator.grouped(cards)

        self.people = cards
        self.groups = groups
    }
}
