import XCTest
@testable import LiveNote

@MainActor
final class PeopleDirectoryTests: XCTestCase {

    private var tempLogDir: URL!
    private var testStore: MeetingStore?
    private var previousLogOverride: URL?

    override func setUp() {
        super.setUp()
        TestLogSandbox.activate()
        previousLogOverride = AppLog.directoryOverride
        tempLogDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempLogDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempLogDir
    }

    override func tearDown() {
        AppLog.flush()
        AppLog.directoryOverride = previousLogOverride
        if let tempLogDir {
            try? FileManager.default.removeItem(at: tempLogDir)
        }
        if let store = testStore {
            MeetingStoreFixture.cleanUp(store)
            testStore = nil
        }
        super.tearDown()
    }

    // MARK: - 1. 이름 정규화 테스트

    func testNormalizedName() {
        XCTAssertEqual(PeopleAggregator.normalizedName("  Alice Smith  "), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Alice    Smith"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("ALICE SMITH"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Alice Smith (Elastic)"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Alice Smith (HQ)"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Alice Smith - Elastic"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Alice Smith - Company"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Alice Smith (Acme) - Dept"), "alice smith")
        XCTAssertEqual(PeopleAggregator.normalizedName("Jean-Luc Picard"), "jean-luc picard")
    }

    // MARK: - 2. 플레이스홀더 감지 테스트

    func testIsPlaceholder() {
        XCTAssertTrue(PeopleAggregator.isPlaceholder("speaker 1"))
        XCTAssertTrue(PeopleAggregator.isPlaceholder("speaker 3"))
        XCTAssertTrue(PeopleAggregator.isPlaceholder("speaker 12"))
        XCTAssertTrue(PeopleAggregator.isPlaceholder("speaker 0"))

        XCTAssertFalse(PeopleAggregator.isPlaceholder("speaker"))
        XCTAssertFalse(PeopleAggregator.isPlaceholder("speaker bob"))
        XCTAssertFalse(PeopleAggregator.isPlaceholder("speaker 3a"))
        XCTAssertFalse(PeopleAggregator.isPlaceholder("alice"))
    }

    // MARK: - 3. 대소문자 다른 참석자 + 화자 병합 테스트

    func testMergeAttendeeAndSpeakerWithDifferentCasing() {
        let mURL = URL(fileURLWithPath: "/tmp/meeting1")
        let summary = MeetingSummary(
            url: mURL,
            title: "Sprint Planning",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 5,
            durationSeconds: 300,
            attendees: [Attendee(name: "Alice Smith", email: "alice@example.com")]
        )
        let speaker = MeetingSpeakerNames(url: mURL, names: ["alice smith"])

        let cards = PeopleAggregator.build(
            meetings: [summary],
            speakerNames: [speaker],
            myName: "Bob"
        )

        XCTAssertEqual(cards.count, 1)
        let card = cards[0]
        XCTAssertEqual(card.id, "email:alice@example.com")
        XCTAssertEqual(card.displayName, "Alice Smith")
        XCTAssertEqual(card.emails, ["alice@example.com"])
        XCTAssertEqual(card.meetingURLs, [mURL])
    }

    // MARK: - 4. 이메일 키 기반 두 가지 표기 병합 테스트

    func testSameEmailDifferentSpellingsMerge() {
        let m1URL = URL(fileURLWithPath: "/tmp/meeting1")
        let m2URL = URL(fileURLWithPath: "/tmp/meeting2")

        let m1 = MeetingSummary(
            url: m1URL,
            title: "Meeting 1",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 5,
            durationSeconds: 300,
            attendees: [Attendee(name: "Robert Smith", email: "bob@acme.com")]
        )
        let m2 = MeetingSummary(
            url: m2URL,
            title: "Meeting 2",
            dateLabel: "9/2 10:00",
            startedAt: Date(timeIntervalSince1970: 2000),
            rowCount: 5,
            durationSeconds: 300,
            attendees: [Attendee(name: "Bob Smith", email: "bob@acme.com")]
        )

        let cards = PeopleAggregator.build(
            meetings: [m1, m2],
            speakerNames: [],
            myName: "Charlie"
        )

        XCTAssertEqual(cards.count, 1)
        let card = cards[0]
        XCTAssertEqual(card.id, "email:bob@acme.com")
        XCTAssertEqual(card.company, "acme.com")
        XCTAssertTrue(card.aliases.contains("Robert Smith"))
        XCTAssertTrue(card.aliases.contains("Bob Smith"))
        XCTAssertEqual(card.meetingURLs.count, 2)
    }

    // MARK: - 5. 본인(myName) 및 Speaker N 제외 테스트

    func testMyNameAndSpeakerNExcluded() {
        let mURL = URL(fileURLWithPath: "/tmp/meeting1")
        let summary = MeetingSummary(
            url: mURL,
            title: "Design Review",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 10,
            durationSeconds: 600,
            attendees: [
                Attendee(name: "John Doe", email: "john@elastic.co"),
                Attendee(name: "Alice", email: "alice@elastic.co")
            ]
        )
        let speaker = MeetingSpeakerNames(url: mURL, names: ["Speaker 1", "speaker 2", "John Doe"])

        let cards = PeopleAggregator.build(
            meetings: [summary],
            speakerNames: [speaker],
            myName: "John Doe"
        )

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].displayName, "Alice")
    }

    // MARK: - 6. 빈도수 기반 표시 이름 선택 테스트

    func testDisplayNameByFrequency() {
        let m1 = URL(fileURLWithPath: "/tmp/m1")
        let m2 = URL(fileURLWithPath: "/tmp/m2")
        let m3 = URL(fileURLWithPath: "/tmp/m3")

        let meetings = [
            MeetingSummary(url: m1, title: "1", dateLabel: "d", startedAt: Date(timeIntervalSince1970: 100), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Robert", email: "r@b.com")]),
            MeetingSummary(url: m2, title: "2", dateLabel: "d", startedAt: Date(timeIntervalSince1970: 200), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Bob", email: "r@b.com")]),
            MeetingSummary(url: m3, title: "3", dateLabel: "d", startedAt: Date(timeIntervalSince1970: 300), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Bob", email: "r@b.com")])
        ]

        let cards = PeopleAggregator.build(
            meetings: meetings,
            speakerNames: [],
            myName: "Admin"
        )

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].displayName, "Bob")
        XCTAssertEqual(cards[0].aliases.first, "Bob")
    }

    // MARK: - 7. meetingURLs 중복 제거 및 최신순 정렬, lastMeetingAt 검증

    func testMeetingURLsUniqueAndNewestFirst() {
        let u1 = URL(fileURLWithPath: "/tmp/m1")
        let u2 = URL(fileURLWithPath: "/tmp/m2")
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        let meetings = [
            MeetingSummary(url: u1, title: "Older", dateLabel: "d", startedAt: date1, rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Alice", email: "a@test.com")]),
            MeetingSummary(url: u2, title: "Newer", dateLabel: "d", startedAt: date2, rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Alice", email: "a@test.com")])
        ]
        // u2에 화자로도 등장
        let speakers = [MeetingSpeakerNames(url: u2, names: ["Alice"])]

        let cards = PeopleAggregator.build(
            meetings: meetings,
            speakerNames: speakers,
            myName: "Me"
        )

        XCTAssertEqual(cards.count, 1)
        let card = cards[0]
        XCTAssertEqual(card.meetingURLs, [u2, u1])
        XCTAssertEqual(card.lastMeetingAt, date2)
        XCTAssertEqual(card.meetingCount, 2)
    }

    // MARK: - 8. 회사별 그룹핑 및 Other 최하단 정렬 테스트

    func testGroupingByDomainWithOtherLast() {
        let p1 = PersonCard(id: "1", displayName: "A1", aliases: ["A1"], emails: ["a1@alpha.com"], company: "alpha.com", meetingURLs: [], lastMeetingAt: Date(timeIntervalSince1970: 300))
        let p2 = PersonCard(id: "2", displayName: "A2", aliases: ["A2"], emails: ["a2@alpha.com"], company: "alpha.com", meetingURLs: [], lastMeetingAt: Date(timeIntervalSince1970: 100))
        let p3 = PersonCard(id: "3", displayName: "B1", aliases: ["B1"], emails: ["b1@beta.com"], company: "beta.com", meetingURLs: [], lastMeetingAt: Date(timeIntervalSince1970: 200))
        let p4 = PersonCard(id: "4", displayName: "O1", aliases: ["O1"], emails: [], company: nil, meetingURLs: [], lastMeetingAt: Date(timeIntervalSince1970: 400))
        let p5 = PersonCard(id: "5", displayName: "O2", aliases: ["O2"], emails: [], company: nil, meetingURLs: [], lastMeetingAt: Date(timeIntervalSince1970: 500))

        let groups = PeopleAggregator.grouped([p3, p1, p2, p4, p5])

        XCTAssertEqual(groups.count, 3)
        // alpha.com (인원 2) -> beta.com (인원 1) -> Other (인원 2, 최하단)
        XCTAssertEqual(groups[0].title, "alpha.com")
        XCTAssertEqual(groups[0].people.map(\.displayName), ["A1", "A2"])
        XCTAssertEqual(groups[1].title, "beta.com")
        XCTAssertEqual(groups[1].people.map(\.displayName), ["B1"])
        XCTAssertEqual(groups[2].title, "Other")
        XCTAssertEqual(groups[2].people.map(\.displayName), ["O2", "O1"])
    }

    // MARK: - 9. 검색 필터링 (이름, 별칭, 이메일)

    func testFilterByNameAliasAndEmail() {
        let p1 = PersonCard(id: "1", displayName: "Alice Wonderland", aliases: ["Alice", "Ally"], emails: ["alice@example.com"], company: "example.com", meetingURLs: [], lastMeetingAt: nil)
        let p2 = PersonCard(id: "2", displayName: "Bob Builder", aliases: ["Bob"], emails: ["bob@builder.com"], company: "builder.com", meetingURLs: [], lastMeetingAt: nil)
        let groups = [
            PeopleGroup(title: "example.com", people: [p1]),
            PeopleGroup(title: "builder.com", people: [p2])
        ]

        // 이름 검색
        let byName = PeopleAggregator.filter(groups, query: "wonderland")
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName[0].people[0].displayName, "Alice Wonderland")

        // 별칭 검색
        let byAlias = PeopleAggregator.filter(groups, query: "ally")
        XCTAssertEqual(byAlias.count, 1)
        XCTAssertEqual(byAlias[0].people[0].displayName, "Alice Wonderland")

        // 이메일 검색
        let byEmail = PeopleAggregator.filter(groups, query: "builder.com")
        XCTAssertEqual(byEmail.count, 1)
        XCTAssertEqual(byEmail[0].people[0].displayName, "Bob Builder")

        // 일치 없음
        let none = PeopleAggregator.filter(groups, query: "nobody")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - 10. lastMeetingLabel Today / Yesterday / 다른 연도

    func testLastMeetingLabel() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5
        components.hour = 12
        let now = cal.date(from: components)!

        // Today
        let today = cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 9))!
        XCTAssertEqual(PeopleAggregator.lastMeetingLabel(today, now: now, calendar: cal), "Today")

        // Yesterday
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 15))!
        XCTAssertEqual(PeopleAggregator.lastMeetingLabel(yesterday, now: now, calendar: cal), "Yesterday")

        // Same year earlier
        let earlierThisYear = cal.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        XCTAssertEqual(PeopleAggregator.lastMeetingLabel(earlierThisYear, now: now, calendar: cal), "Aug 15")

        // Previous year
        let lastYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 25))!
        XCTAssertEqual(PeopleAggregator.lastMeetingLabel(lastYear, now: now, calendar: cal), "Dec 25, 2025")
    }

    // MARK: - 11. refresh reader 오류 발생 시 lastWarning 설정 및 참석자 보존

    func testRefreshWithReaderThrowingSetsWarningAndKeepsAttendees() async {
        let u1 = URL(fileURLWithPath: "/tmp/good-meeting")
        let u2 = URL(fileURLWithPath: "/tmp/bad-meeting")

        let m1 = MeetingSummary(url: u1, title: "Good", dateLabel: "d", startedAt: Date(), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Good Attendee", email: "good@test.com")])
        let m2 = MeetingSummary(url: u2, title: "Bad", dateLabel: "d", startedAt: Date(), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Bad Attendee", email: "bad@test.com")])

        struct DummyError: Error, LocalizedError {
            var errorDescription: String? { "Simulated disk failure" }
        }

        let directory = PeopleDirectory { url in
            if url == u2 {
                throw DummyError()
            }
            return ["Good Speaker"]
        }

        await directory.refresh(meetings: [m1, m2], myName: "Me")

        XCTAssertNotNil(directory.lastWarning)
        XCTAssertTrue(directory.lastWarning?.contains("Simulated disk failure") == true)
        // 에러가 난 폴더의 참석자(Bad Attendee)도 여전히 디렉터리에 포함되어야 함
        let names = directory.people.map(\.displayName)
        XCTAssertTrue(names.contains("Good Attendee"))
        XCTAssertTrue(names.contains("Bad Attendee"))
    }

    // MARK: - 12. 캐시 동작 검증 (폴더 미변경 시 reader 중복 호출 방지)

    final class SafeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    func testCacheAvoidsSecondReaderCall() async {
        let u1 = URL(fileURLWithPath: "/tmp/cached-meeting-\(UUID().uuidString)")
        let m1 = MeetingSummary(url: u1, title: "M", dateLabel: "d", startedAt: Date(), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "A", email: "a@x.com")])

        let counter = SafeCounter()
        let directory = PeopleDirectory { _ in
            counter.increment()
            return ["Cached Speaker"]
        }

        await directory.refresh(meetings: [m1], myName: "Me")
        XCTAssertEqual(counter.value, 1)

        // 동일한 미변경 폴더로 2회차 refresh
        await directory.refresh(meetings: [m1], myName: "Me")
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - 13. Coalescing 동작 검증 (동시 호출 시 최대 2회 실행 및 최종 상태 정상 반영)

    func testConcurrentRefreshCoalescing() async {
        let u1 = URL(fileURLWithPath: "/tmp/coal-1-\(UUID().uuidString)")
        let u2 = URL(fileURLWithPath: "/tmp/coal-2-\(UUID().uuidString)")
        let u3 = URL(fileURLWithPath: "/tmp/coal-3-\(UUID().uuidString)")

        let m1 = MeetingSummary(url: u1, title: "M1", dateLabel: "d", startedAt: Date(timeIntervalSince1970: 100), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "User One", email: "one@test.com")])
        let m2 = MeetingSummary(url: u2, title: "M2", dateLabel: "d", startedAt: Date(timeIntervalSince1970: 200), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "User Two", email: "two@test.com")])
        let m3 = MeetingSummary(url: u3, title: "M3", dateLabel: "d", startedAt: Date(timeIntervalSince1970: 300), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "User Three", email: "three@test.com")])

        final class URLRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [URL] = []
            func record(_ url: URL) {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        let recorder = URLRecorder()

        let directory = PeopleDirectory { url in
            recorder.record(url)
            return [url.lastPathComponent]
        }

        actor TestGate {
            private var isReleased = false
            private var continuations: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                if isReleased { return }
                await withCheckedContinuation { cont in
                    continuations.append(cont)
                }
            }

            func release() {
                isReleased = true
                for cont in continuations {
                    cont.resume()
                }
                continuations.removeAll()
            }
        }

        let gate = TestGate()
        addTeardownBlock {
            Task {
                await gate.release()
            }
        }

        let readerEntered = expectation(description: "reader entered")
        let m2Queued = expectation(description: "m2 queued")
        let m3Queued = expectation(description: "m3 queued")

        final class FirstEntryFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func markFirst() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if !done {
                    done = true
                    return true
                }
                return false
            }
        }
        let firstEntry = FirstEntryFlag()

        directory.readGate = {
            if firstEntry.markFirst() {
                readerEntered.fulfill()
            }
            await gate.wait()
        }

        directory.onRefreshQueued = { meetings in
            let meetingUrls = meetings.map(\.url)
            if meetingUrls == [u2] {
                m2Queued.fulfill()
            } else if meetingUrls == [u3] {
                m3Queued.fulfill()
            }
        }

        let t1 = Task { @MainActor in
            await directory.refresh(meetings: [m1], myName: "Me")
        }
        await fulfillment(of: [readerEntered], timeout: 5.0)

        let t2 = Task { @MainActor in
            await directory.refresh(meetings: [m2], myName: "Me")
        }
        await fulfillment(of: [m2Queued], timeout: 5.0)

        let t3 = Task { @MainActor in
            await directory.refresh(meetings: [m3], myName: "Me")
        }
        await fulfillment(of: [m3Queued], timeout: 5.0)

        await gate.release()

        await t1.value
        await t2.value
        await t3.value

        XCTAssertEqual(recorder.urls, [u1, u3], "Reader should be called with u1 then u3, skipping u2")
        let peopleNames = directory.people.map(\.displayName)
        XCTAssertTrue(peopleNames.contains("User Three"))
        XCTAssertFalse(peopleNames.contains("User Two"))
        XCTAssertFalse(directory.isLoading)
        XCTAssertFalse(directory.isRefreshPending)
    }

    // MARK: - 14. 실제 Fixture 폴더에서 readSpeakerNames 파싱 검증

    func testReadSpeakerNamesFromRealFixture() throws {
        let store = try MeetingStoreFixture.makeStore()
        testStore = store

        let row1 = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 0,
            speakerName: "Alice Walker",
            english: "Hello everyone",
            korean: nil,
            startSeconds: 0,
            endSeconds: 5
        )

        let meetingURL = try store.save(
            rows: [row1],
            myName: "Host",
            speakerNames: [0: "Alice Walker", 1: "Bob Vance"],
            startedAt: Date(),
            durationSeconds: 60,
            title: "Fixture Meeting",
            summary: "Summary",
            attendees: [Attendee(name: "Carol", email: "carol@office.com")],
            existingURL: nil
        )

        let parsedNames = try PeopleDirectory.readSpeakerNames(folder: meetingURL)
        XCTAssertTrue(parsedNames.contains("Alice Walker"))
        XCTAssertTrue(parsedNames.contains("Bob Vance"))
    }

    // MARK: - 15. 중복 Meeting URL 처리 안전성 검증

    func testRefreshWithDuplicateMeetingURLsDoesNotCrashOrDoubleRead() async {
        let u1 = URL(fileURLWithPath: "/tmp/dup-meeting-\(UUID().uuidString)")
        let m1 = MeetingSummary(url: u1, title: "Dup M", dateLabel: "d", startedAt: Date(), rowCount: 1, durationSeconds: 10, attendees: [Attendee(name: "Dup User", email: "dup@example.com")])

        let counter = SafeCounter()
        let directory = PeopleDirectory { _ in
            counter.increment()
            return ["Speaker Dup"]
        }

        // 중복 URL이 포함된 배열 전달
        await directory.refresh(meetings: [m1, m1], myName: "Me")
        XCTAssertEqual(counter.value, 1)

        // uniquingKeysWith 사전 구성 안전성 확인
        let meetings = [m1, m1]
        let dict = Dictionary(meetings.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(dict.count, 1)
    }

    // MARK: - 16. 동일 이름 서로 다른 이메일 분리 보존 검증 (R1-2)

    func testSameNameDifferentEmailsStayTwoCards() {
        let m1 = URL(fileURLWithPath: "/tmp/meeting1")
        let m2 = URL(fileURLWithPath: "/tmp/meeting2")

        let s1 = MeetingSummary(
            url: m1,
            title: "Meeting 1",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice Smith", email: "alice@alpha.com")]
        )
        let s2 = MeetingSummary(
            url: m2,
            title: "Meeting 2",
            dateLabel: "9/2 10:00",
            startedAt: Date(timeIntervalSince1970: 2000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice Smith", email: "alice@beta.com")]
        )

        let cards = PeopleAggregator.build(
            meetings: [s1, s2],
            speakerNames: [],
            myName: "Bob"
        )

        XCTAssertEqual(cards.count, 2)
        let ids = Set(cards.map(\.id))
        XCTAssertEqual(ids, ["email:alice@alpha.com", "email:alice@beta.com"])
    }

    // MARK: - 17. 화자명이 동일 회의 내 email identity에 우선 결합 검증 (R1-2)

    func testSpeakerNameJoinsSameMeetingEmailIdentity() {
        let m1 = URL(fileURLWithPath: "/tmp/meeting1")
        let m2 = URL(fileURLWithPath: "/tmp/meeting2")

        let s1 = MeetingSummary(
            url: m1,
            title: "Meeting 1",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice Smith", email: "alice@alpha.com")]
        )
        let s2 = MeetingSummary(
            url: m2,
            title: "Meeting 2",
            dateLabel: "9/2 10:00",
            startedAt: Date(timeIntervalSince1970: 2000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice Smith", email: "alice@beta.com")]
        )

        // Meeting 1에 화자 "Alice Smith" 등장
        let speakers = [MeetingSpeakerNames(url: m1, names: ["Alice Smith"])]

        let cards = PeopleAggregator.build(
            meetings: [s1, s2],
            speakerNames: speakers,
            myName: "Bob"
        )

        XCTAssertEqual(cards.count, 2)
        let alphaCard = cards.first(where: { $0.id == "email:alice@alpha.com" })
        let betaCard = cards.first(where: { $0.id == "email:alice@beta.com" })
        XCTAssertNotNil(alphaCard)
        XCTAssertNotNil(betaCard)
        XCTAssertEqual(alphaCard?.meetingURLs, [m1])
        XCTAssertEqual(betaCard?.meetingURLs, [m2])
    }

    // MARK: - 18. 화자명이 다중 이메일과 매칭되고 동일 회의가 없으면 독립 카드 유지 검증 (R1-2)

    func testSpeakerNameAmbiguousAcrossEmailsStaysSeparate() {
        let m1 = URL(fileURLWithPath: "/tmp/meeting1")
        let m2 = URL(fileURLWithPath: "/tmp/meeting2")
        let m3 = URL(fileURLWithPath: "/tmp/meeting3")

        let s1 = MeetingSummary(
            url: m1,
            title: "Meeting 1",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice Smith", email: "alice@alpha.com")]
        )
        let s2 = MeetingSummary(
            url: m2,
            title: "Meeting 2",
            dateLabel: "9/2 10:00",
            startedAt: Date(timeIntervalSince1970: 2000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice Smith", email: "alice@beta.com")]
        )
        let s3 = MeetingSummary(
            url: m3,
            title: "Meeting 3",
            dateLabel: "9/3 10:00",
            startedAt: Date(timeIntervalSince1970: 3000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: []
        )

        // Meeting 3에 화자 "Alice Smith" 등장 (m1, m2 참석자 이메일과 동일 회의 아님)
        let speakers = [MeetingSpeakerNames(url: m3, names: ["Alice Smith"])]

        let cards = PeopleAggregator.build(
            meetings: [s1, s2, s3],
            speakerNames: speakers,
            myName: "Bob"
        )

        // alpha, beta, 그리고 name-only 카드 1개로 총 3개 생성되어야 함
        XCTAssertEqual(cards.count, 3)
        let ids = Set(cards.map(\.id))
        XCTAssertTrue(ids.contains("email:alice@alpha.com"))
        XCTAssertTrue(ids.contains("email:alice@beta.com"))
        XCTAssertTrue(ids.contains("name:alice smith"))

        let nameCard = cards.first(where: { $0.id == "name:alice smith" })
        XCTAssertEqual(nameCard?.meetingURLs, [m3])
        XCTAssertTrue(nameCard?.emails.isEmpty == true)
        XCTAssertNil(nameCard?.company)
    }

    // MARK: - 19. 카드 ID의 타입 지정 및 고유성 검증 (R1-3)

    func testCardIDsAreUniqueAndTyped() {
        let m1 = URL(fileURLWithPath: "/tmp/meeting1")
        let summary = MeetingSummary(
            url: m1,
            title: "Collision Test Meeting",
            dateLabel: "9/1 10:00",
            startedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Alice", email: "alice@example.com")]
        )
        // 화자의 이름이 문자 그대로 "alice@example.com"인 경우
        let speakers = [MeetingSpeakerNames(url: m1, names: ["alice@example.com"])]

        let cards = PeopleAggregator.build(
            meetings: [summary],
            speakerNames: speakers,
            myName: "Host"
        )

        XCTAssertEqual(cards.count, 2)
        let ids = cards.map(\.id)
        XCTAssertEqual(Set(ids).count, 2, "Card IDs must be unique")
        XCTAssertTrue(ids.contains("email:alice@example.com"))
        XCTAssertTrue(ids.contains("name:alice@example.com"))

        for id in ids {
            XCTAssertTrue(id.hasPrefix("email:") || id.hasPrefix("name:"), "ID must be typed: \(id)")
        }
    }

    // MARK: - 20. rows 내 잘못된 타입 시 decode 오류 전파 검증 (R1-4)

    func testReadSpeakerNamesThrowsOnWrongRowType() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WrongRowType-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionURL = tempDir.appendingPathComponent("session.json")
        let badJSON = """
        {
            "rows": [
                { "speakerName": 123 }
            ]
        }
        """
        try badJSON.write(to: sessionURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PeopleDirectory.readSpeakerNames(folder: tempDir)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - 21. speakerNames 필드 잘못된 타입 시 decode 오류 전파 검증 (R1-4)

    func testReadSpeakerNamesThrowsOnWrongSpeakerNamesType() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WrongSpeakerNames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionURL = tempDir.appendingPathComponent("session.json")
        let badJSON = """
        {
            "speakerNames": 123
        }
        """
        try badJSON.write(to: sessionURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PeopleDirectory.readSpeakerNames(folder: tempDir)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - 22. 손상된 세션 파일 발견 시 경고 노출 및 참석자 보존 검증 (R1-4)

    func testRefreshSurfacesWarningForCorruptSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorruptSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionURL = tempDir.appendingPathComponent("session.json")
        let badJSON = "{\"speakerNames\": 123}"
        try badJSON.write(to: sessionURL, atomically: true, encoding: .utf8)

        let summary = MeetingSummary(
            url: tempDir,
            title: "Corrupt Meeting",
            dateLabel: "9/5 10:00",
            startedAt: Date(),
            rowCount: 1,
            durationSeconds: 60,
            attendees: [Attendee(name: "Preserved Attendee", email: "preserved@example.com")]
        )

        let directory = PeopleDirectory()
        await directory.refresh(meetings: [summary], myName: "Me")

        XCTAssertNotNil(directory.lastWarning)
        XCTAssertTrue(directory.people.contains(where: { $0.displayName == "Preserved Attendee" }))
    }

    // MARK: - 23. speakerNames 파싱 시 키 순서와 무관한 결정론적 순서 검증 (R1-9)

    func testReadSpeakerNamesOrderIsStable() throws {
        let tempDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrderStable1-\(UUID().uuidString)", isDirectory: true)
        let tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrderStable2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
        }

        let json1 = """
        {
            "speakerNames": {
                "0": "Alice",
                "1": "ALICE"
            }
        }
        """
        let json2 = """
        {
            "speakerNames": {
                "1": "ALICE",
                "0": "Alice"
            }
        }
        """
        try json1.write(to: tempDir1.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        try json2.write(to: tempDir2.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let names1 = try PeopleDirectory.readSpeakerNames(folder: tempDir1)
        let names2 = try PeopleDirectory.readSpeakerNames(folder: tempDir2)

        XCTAssertEqual(names1, names2)
        XCTAssertEqual(names1, ["Alice", "ALICE"])
    }

    // MARK: - 24. 동일 회의 동일 이름 서로 다른 이메일 카드 정렬 안정성 (R2-1)

    func testSameNameSameMeetingCardsHaveStableOrder() {
        let url = URL(fileURLWithPath: "/tmp/meeting-stable-order")
        let meeting = MeetingSummary(
            url: url,
            title: "Stable Order Meeting",
            dateLabel: "Today",
            startedAt: Date(timeIntervalSince1970: 1700000000),
            rowCount: 5,
            durationSeconds: 300,
            attendees: [
                Attendee(name: "Alice", email: "a@x.com"),
                Attendee(name: "Alice", email: "a@y.com")
            ]
        )

        let expectedIDs = ["email:a@x.com", "email:a@y.com"].sorted()

        for _ in 0..<20 {
            let cards = PeopleAggregator.build(
                meetings: [meeting],
                speakerNames: [],
                myName: "Me"
            )
            let ids = cards.map(\.id)
            XCTAssertEqual(ids, expectedIDs)
        }
    }

    // MARK: - 25. 비정수 키 포함 speakerNames 파싱 안정성 및 전이성 (R1-9)

    func testReadSpeakerNamesStringKeyFallbackOrderIsStable() throws {
        let tempDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("FallbackStable1-\(UUID().uuidString)", isDirectory: true)
        let tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("FallbackStable2-\(UUID().uuidString)", isDirectory: true)
        let tempDir3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("FallbackStable3-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir3, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
            try? FileManager.default.removeItem(at: tempDir3)
        }

        let name2 = "Speaker Two"
        let name10 = "Speaker Ten"
        let name1a = "Speaker OneA"

        // 세 가지 다른 키 순서로 session.json 작성
        let json1 = """
        {
            "speakerNames": {
                "2": "\(name2)",
                "10": "\(name10)",
                "1a": "\(name1a)"
            }
        }
        """

        let json2 = """
        {
            "speakerNames": {
                "1a": "\(name1a)",
                "2": "\(name2)",
                "10": "\(name10)"
            }
        }
        """

        let json3 = """
        {
            "speakerNames": {
                "10": "\(name10)",
                "1a": "\(name1a)",
                "2": "\(name2)"
            }
        }
        """

        try json1.write(to: tempDir1.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        try json2.write(to: tempDir2.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        try json3.write(to: tempDir3.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let names1 = try PeopleDirectory.readSpeakerNames(folder: tempDir1)
        let names2 = try PeopleDirectory.readSpeakerNames(folder: tempDir2)
        let names3 = try PeopleDirectory.readSpeakerNames(folder: tempDir3)

        let expected = [name2, name10, name1a]

        XCTAssertEqual(names1, expected)
        XCTAssertEqual(names2, expected)
        XCTAssertEqual(names3, expected)
    }
}
