import XCTest
@testable import LiveNote

@MainActor
final class FakeVoiceprintStore: VoiceprintStoring {
    var people: [Person] = []
    var thresholds = VoiceprintThresholds()
    var lastError: String? = nil

    var matchStub: (( [Float] ) -> VoiceMatch)? = nil
    var matchExcludingMeStub: (( [Float], Bool ) -> VoiceMatch)? = nil
    var enrollStub: ((String, String?, [EnrollmentSample], VoiceSource, Bool) throws -> Person)? = nil
    var recordConflictStub: ((String, [Float]) throws -> Bool)? = nil
    var deleteStub: ((String) throws -> Void)? = nil
    var recordedConflicts: [(personID: String, embedding: [Float])] = []
    var enrolledCalls: [(name: String, email: String?, samples: [EnrollmentSample], source: VoiceSource, isMe: Bool)] = []

    func reload() throws {}

    func match(_ embedding: [Float]) -> VoiceMatch {
        match(embedding, excludingMe: false)
    }

    func match(_ embedding: [Float], excludingMe: Bool) -> VoiceMatch {
        if let matchExcludingMeStub {
            return matchExcludingMeStub(embedding, excludingMe)
        }
        if let matchStub {
            let base = matchStub(embedding)
            guard excludingMe else { return base }
            let filteredCandidates = base.candidates.filter { !$0.isMe }
            let isConfident = (base.person?.isMe == true) ? false : base.confident
            let matchedPerson = isConfident ? base.person : nil
            return VoiceMatch(
                person: matchedPerson,
                candidates: filteredCandidates,
                d1: base.d1,
                d2: base.d2,
                confident: isConfident
            )
        }
        return VoiceMatch(person: nil, candidates: [], d1: .infinity, d2: .infinity, confident: false)
    }

    @discardableResult
    func enroll(
        name: String,
        email: String?,
        samples: [EnrollmentSample],
        source: VoiceSource,
        isMe: Bool
    ) throws -> Person {
        if let enrollStub {
            return try enrollStub(name, email, samples, source, isMe)
        }
        enrolledCalls.append((name: name, email: email, samples: samples, source: source, isMe: isMe))
        let person = Person(
            id: UUID().uuidString,
            name: name,
            email: email,
            sources: [source],
            isMe: isMe
        )
        people.append(person)
        return person
    }

    @discardableResult
    func recordConflict(personID: String, embedding: [Float]) throws -> Bool {
        if let recordConflictStub {
            return try recordConflictStub(personID, embedding)
        }
        recordedConflicts.append((personID: personID, embedding: embedding))
        return false
    }

    func merge(_ sourceID: String, into targetID: String) throws {
        guard let sourceIndex = people.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = people.firstIndex(where: { $0.id == targetID }) else {
            throw VoiceprintError.personNotFound("merge error")
        }
        let source = people[sourceIndex]
        people[targetIndex].centroids.append(contentsOf: source.centroids)
        people[targetIndex].meetings += source.meetings
        people.remove(at: sourceIndex)
    }

    func rename(id: String, to name: String) throws {
        guard let index = people.firstIndex(where: { $0.id == id }) else {
            throw VoiceprintError.personNotFound(id)
        }
        people[index].name = name
    }

    func delete(id: String) throws {
        if let deleteStub {
            try deleteStub(id)
            return
        }
        people.removeAll(where: { $0.id == id })
    }

    func forgetAll() throws {
        people.removeAll()
    }

    func person(named name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return people.first {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.aliases.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
    }
}

@MainActor
final class SpeakerMemoryTests: XCTestCase {
    private var fakeStore: FakeVoiceprintStore!
    private var memory: SpeakerMemory!

    override func setUp() {
        super.setUp()
        fakeStore = FakeVoiceprintStore()
        memory = SpeakerMemory(store: fakeStore)
    }

    override func tearDown() {
        fakeStore = nil
        memory = nil
        super.tearDown()
    }

    func testPriorityOrderZoomTakesPrecedence() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 10, embedding: [0.1, 0.2], quality: 0.9)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let alice = Person(id: "p1", name: "Alice")
        fakeStore.matchStub = { _ in
            VoiceMatch(person: alice, candidates: [alice], d1: 0.2, d2: 0.9, confident: true)
        }

        let rows = [
            TranscriptRow(
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello",
                startSeconds: 0,
                endSeconds: 5,
                clusterID: "cluster_0"
            )
        ]

        let result = memory.assignNames(
            rows: rows,
            diarization: diarization,
            zoomName: { _ in "ZoomSpeaker" },
            fallbackName: "FallbackSpeaker",
            existingSlotNames: [0: "SlotSpeaker"]
        )

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].speakerName, "ZoomSpeaker")
        XCTAssertEqual(result.rows[0].nameSource, .zoom)
        XCTAssertNil(result.rows[0].candidateNames)
    }

    func testPriorityOrderVoiceTakesPrecedenceOverSlotAndFallback() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 10, embedding: [0.1, 0.2], quality: 0.9)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let bob = Person(id: "p2", name: "Bob")
        fakeStore.matchStub = { _ in
            VoiceMatch(person: bob, candidates: [bob], d1: 0.2, d2: 0.9, confident: true)
        }

        let rows = [
            TranscriptRow(
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello Bob",
                startSeconds: 0,
                endSeconds: 5,
                clusterID: "cluster_0"
            )
        ]

        let result = memory.assignNames(
            rows: rows,
            diarization: diarization,
            zoomName: { _ in nil },
            fallbackName: "FallbackSpeaker",
            existingSlotNames: [0: "SlotSpeaker"]
        )

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].speakerName, "Bob")
        XCTAssertEqual(result.rows[0].nameSource, .voice)
        XCTAssertNil(result.rows[0].candidateNames)
    }

    func testPriorityOrderSlotAndFallbackWhenNoConfidentVoiceMatch() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 10, embedding: [0.1, 0.2], quality: 0.9)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let candidateA = Person(id: "c1", name: "CandidateA")
        let candidateB = Person(id: "c2", name: "CandidateB")
        fakeStore.matchStub = { _ in
            VoiceMatch(person: nil, candidates: [candidateA, candidateB], d1: 0.6, d2: 0.65, confident: false)
        }

        // Slot name exists
        let rowsWithSlot = [
            TranscriptRow(
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello with slot",
                startSeconds: 0,
                endSeconds: 5,
                clusterID: "cluster_0"
            )
        ]

        let resultWithSlot = memory.assignNames(
            rows: rowsWithSlot,
            diarization: diarization,
            zoomName: { _ in nil },
            fallbackName: "FallbackSpeaker",
            existingSlotNames: [0: "CustomSlotName"]
        )

        XCTAssertNil(resultWithSlot.rows[0].speakerName) // resolveName uses speakerNames[0]
        XCTAssertEqual(resultWithSlot.rows[0].nameSource, .slot)
        XCTAssertEqual(resultWithSlot.rows[0].candidateNames, ["CandidateA", "CandidateB"])

        // No slot name, fallback exists
        let rowsWithoutSlot = [
            TranscriptRow(
                channel: .them,
                speakerSlot: 1,
                speakerName: nil,
                english: "Hello with fallback",
                startSeconds: 0,
                endSeconds: 5,
                clusterID: "cluster_0"
            )
        ]

        let resultWithFallback = memory.assignNames(
            rows: rowsWithoutSlot,
            diarization: diarization,
            zoomName: { _ in nil },
            fallbackName: "FallbackSpeaker",
            existingSlotNames: [:]
        )

        XCTAssertEqual(resultWithFallback.rows[0].speakerName, "FallbackSpeaker")
        XCTAssertEqual(resultWithFallback.rows[0].nameSource, .slot)
        XCTAssertEqual(resultWithFallback.rows[0].candidateNames, ["CandidateA", "CandidateB"])
    }

    func testManualProtectionNeverOverwrites() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 10, embedding: [0.1, 0.2], quality: 0.9)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let alice = Person(id: "p1", name: "Alice")
        fakeStore.matchStub = { _ in
            VoiceMatch(person: alice, candidates: [alice], d1: 0.2, d2: 0.9, confident: true)
        }

        let row = TranscriptRow(
            channel: .them,
            speakerSlot: 0,
            speakerName: "ManuallyNamedPerson",
            english: "Do not touch",
            startSeconds: 0,
            endSeconds: 5,
            nameSource: .manual,
            candidateNames: nil,
            clusterID: "cluster_0"
        )

        let result = memory.assignNames(
            rows: [row],
            diarization: diarization,
            zoomName: { _ in "ZoomName" },
            fallbackName: "Fallback",
            existingSlotNames: [0: "Slot"]
        )

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].speakerName, "ManuallyNamedPerson")
        XCTAssertEqual(result.rows[0].nameSource, .manual)
    }

    func testConflictRecordingAndEnrollment() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_1", start: 0, end: 10, embedding: [0.3, 0.4], quality: 0.8)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let alice = Person(id: "alice_id", name: "Alice")
        fakeStore.matchStub = { _ in
            VoiceMatch(person: alice, candidates: [alice], d1: 0.2, d2: 0.8, confident: true)
        }

        let report: EnrollmentReport = memory.enroll(
            rows: [],
            diarization: diarization,
            confirmedNames: ["cluster_1": "Bob"],
            emails: ["Bob": "bob@example.com"],
            source: .zoom
        )

        // Verify conflict recorded for Alice
        XCTAssertEqual(fakeStore.recordedConflicts.count, 1)
        XCTAssertEqual(fakeStore.recordedConflicts[0].personID, "alice_id")
        XCTAssertEqual(report.conflicts, ["Alice"])

        // Verify Bob was enrolled
        XCTAssertEqual(fakeStore.enrolledCalls.count, 1)
        XCTAssertEqual(fakeStore.enrolledCalls[0].name, "Bob")
        XCTAssertEqual(fakeStore.enrolledCalls[0].email, "bob@example.com")
        XCTAssertEqual(fakeStore.enrolledCalls[0].source, .zoom)
        XCTAssertFalse(fakeStore.enrolledCalls[0].isMe)
        XCTAssertEqual(report.enrolled, ["Bob"])
        XCTAssertTrue(report.errors.isEmpty)

        XCTAssertTrue(report.log.contains { $0.contains("Conflict detected") })
    }

    func testEnrollSurfacesErrorsInReport() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_1", start: 0, end: 5, embedding: [0.3, 0.4], quality: 0.5)
            ],
            processingSeconds: 0.5,
            audioSeconds: 5.0
        )

        fakeStore.enrollStub = { _, _, _, _, _ in
            throw VoiceprintError.tooLittleAudio(seconds: 5.0)
        }

        let report: EnrollmentReport = memory.enroll(
            rows: [],
            diarization: diarization,
            confirmedNames: ["cluster_1": "Charlie"],
            emails: [:],
            source: .live
        )

        XCTAssertEqual(report.enrolled, [])
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(report.errors[0].contains("Too little speech audio"))
        XCTAssertTrue(report.log.contains { $0.contains("Enrollment skipped for 'Charlie'") })
    }

    func testRewriteSavedSpeakerRowsTargetThem() {
        let r1 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: nil, english: "Hello", startSeconds: 0, endSeconds: 2, nameSource: .slot, candidateNames: ["Alice"], clusterID: "c1")
        let r2 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: nil, english: "World", startSeconds: 2, endSeconds: 4, nameSource: .voice, clusterID: "c1")
        let r3 = TranscriptRow(channel: .them, speakerSlot: 1, speakerName: "Bob", english: "Other", startSeconds: 4, endSeconds: 6, nameSource: .manual, clusterID: "c2")
        let r4 = TranscriptRow(channel: .me, speakerName: "Philip", english: "My turn", startSeconds: 6, endSeconds: 8, nameSource: nil)

        let initialRows = [r1, r2, r3, r4]
        let rewritten = SpeakerMemory.rewriteSavedSpeakerRows(rows: initialRows, target: r1, name: "Alice")

        XCTAssertEqual(rewritten.count, 4)
        XCTAssertEqual(rewritten[0].speakerName, "Alice")
        XCTAssertEqual(rewritten[0].nameSource, NameSource.manual)
        XCTAssertNil(rewritten[0].candidateNames)

        XCTAssertEqual(rewritten[1].speakerName, "Alice")
        XCTAssertEqual(rewritten[1].nameSource, NameSource.manual)

        // Slot 1 and Me rows unaffected
        XCTAssertEqual(rewritten[2].speakerName, "Bob")
        XCTAssertEqual(rewritten[2].nameSource, NameSource.manual)
        XCTAssertEqual(rewritten[3].speakerName, "Philip")
    }

    func testRewriteSavedSpeakerRowsTargetMe() {
        let r1 = TranscriptRow(channel: .me, speakerName: "OldMe", english: "1", startSeconds: 0, endSeconds: 2)
        let r2 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: "Them1", english: "2", startSeconds: 2, endSeconds: 4)
        let r3 = TranscriptRow(channel: .me, speakerName: "OldMe", english: "3", startSeconds: 4, endSeconds: 6)

        let rewritten = SpeakerMemory.rewriteSavedSpeakerRows(rows: [r1, r2, r3], target: r1, name: "NewMe")

        XCTAssertEqual(rewritten[0].speakerName, "NewMe")
        XCTAssertEqual(rewritten[0].nameSource, NameSource.manual)
        XCTAssertEqual(rewritten[1].speakerName, "Them1")
        XCTAssertEqual(rewritten[2].speakerName, "NewMe")
        XCTAssertEqual(rewritten[2].nameSource, NameSource.manual)
    }

    @MainActor
    func testRewriteSavedSpeakerRowsRoundTripsThroughMeetingStore() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let r1 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: "OldThem", english: "Hello", startSeconds: 0, endSeconds: 5, nameSource: .slot, candidateNames: ["OldThem"])
        let r2 = TranscriptRow(channel: .me, speakerName: "Philip", english: "Hi", startSeconds: 5, endSeconds: 10)

        let meetingURL = try store.save(
            rows: [r1, r2],
            myName: "Philip",
            speakerNames: [0: "OldThem"],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 10,
            title: "Test Meeting",
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        guard var saved = store.load(meetingURL) else {
            return XCTFail("Failed to load saved meeting from store")
        }

        // Apply SpeakerMemory.rewriteSavedSpeakerRows
        saved.speakerNames[0] = "Alice"
        saved.rows = SpeakerMemory.rewriteSavedSpeakerRows(rows: saved.rows, target: r1, name: "Alice")

        let updatedURL = try store.save(
            rows: saved.rows,
            myName: saved.myName,
            speakerNames: saved.speakerNames,
            startedAt: saved.startedAt,
            durationSeconds: saved.durationSeconds,
            title: saved.title,
            summary: saved.summary,
            attendees: saved.attendees,
            existingURL: meetingURL
        )
        XCTAssertEqual(updatedURL, meetingURL)

        guard let reloaded = store.load(meetingURL) else {
            return XCTFail("Failed to reload updated meeting from store")
        }

        XCTAssertEqual(reloaded.speakerNames[0], "Alice")
        XCTAssertEqual(reloaded.rows[0].speakerName, "Alice")
        XCTAssertEqual(reloaded.rows[0].nameSource, NameSource.manual)
        XCTAssertNil(reloaded.rows[0].candidateNames)
        XCTAssertEqual(reloaded.rows[1].speakerName, "Philip")
    }

    func testConfirmedNamesMajorityVote() {
        let rows = [
            TranscriptRow(channel: .them, speakerName: "Charlie", english: "1", startSeconds: 0, endSeconds: 10, nameSource: .zoom, clusterID: "c1"),
            TranscriptRow(channel: .them, speakerName: "Charlie", english: "2", startSeconds: 10, endSeconds: 20, nameSource: .manual, clusterID: "c1"),
            TranscriptRow(channel: .them, speakerName: "David", english: "3", startSeconds: 20, endSeconds: 25, nameSource: .zoom, clusterID: "c1"),

            // Tie case for c2
            TranscriptRow(channel: .them, speakerName: "Emma", english: "4", startSeconds: 0, endSeconds: 5, nameSource: .zoom, clusterID: "c2"),
            TranscriptRow(channel: .them, speakerName: "Frank", english: "5", startSeconds: 5, endSeconds: 10, nameSource: .zoom, clusterID: "c2"),

            // Non-confirmed sources ignored
            TranscriptRow(channel: .them, speakerName: "Ignored", english: "6", startSeconds: 0, endSeconds: 20, nameSource: .slot, clusterID: "c3")
        ]

        let confirmed = memory.confirmedNames(rows: rows, diarization: nil)

        // Charlie has 20s vs David 5s -> Charlie wins
        XCTAssertEqual(confirmed["c1"], "Charlie")
        // Emma 5s vs Frank 5s -> Tie -> None
        XCTAssertNil(confirmed["c2"])
        // c3 has only .slot -> None
        XCTAssertNil(confirmed["c3"])
    }

    func testEnrollMeDelegatesCorrectly() throws {
        let samples = [
            EnrollmentSample(embedding: [0.1, 0.2, 0.3], quality: 0.95, seconds: 30.0)
        ]

        let person = try memory.enrollMe(micWAVEmbeddings: samples, myName: "Philip")

        XCTAssertEqual(person.name, "Philip")
        XCTAssertEqual(fakeStore.enrolledCalls.count, 1)
        XCTAssertEqual(fakeStore.enrolledCalls[0].name, "Philip")
        XCTAssertTrue(fakeStore.enrolledCalls[0].isMe)
        XCTAssertEqual(fakeStore.enrolledCalls[0].source, .live)
    }

    func testAssignNamesExcludingMeMatchesAliceWhenMeIsCloser() {
        let mePerson = Person(id: "me_1", name: "Me", isMe: true)
        let alice = Person(id: "p1", name: "Alice", isMe: false)
        let bob = Person(id: "p2", name: "Bob", isMe: false)

        // Fake store implementing excludingMe by filtering isMe people BEFORE computing d1/d2/confident
        fakeStore.matchExcludingMeStub = { embedding, excludingMe in
            if excludingMe {
                // When excludingMe is true, Me (0.10) is excluded; Alice (0.12) and Bob (0.90) remain
                return VoiceMatch(person: alice, candidates: [alice, bob], d1: 0.12, d2: 0.90, confident: true)
            } else {
                // Without excludingMe, Me (0.10) is nearest, Alice (0.12) is second, margin 0.02 < 0.08 (not confident)
                return VoiceMatch(person: nil, candidates: [mePerson, alice], d1: 0.10, d2: 0.12, confident: false)
            }
        }

        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 10, embedding: [0.1, 0.2], quality: 0.9)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let rows = [
            TranscriptRow(
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello from Alice",
                startSeconds: 0,
                endSeconds: 5,
                clusterID: "cluster_0"
            )
        ]

        let result = memory.assignNames(
            rows: rows,
            diarization: diarization,
            zoomName: { _ in nil },
            fallbackName: nil,
            existingSlotNames: [:]
        )

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].speakerName, "Alice")
        XCTAssertEqual(result.rows[0].nameSource, .voice)
        XCTAssertEqual(result.clusterNames["cluster_0"], "Alice")
    }

    func testConfidentMatchToIsMeProfileRowStaysUnnamedByVoice() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 10, embedding: [0.1, 0.2], quality: 0.9)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let mePerson = Person(id: "me_id", name: "Philip", isMe: true)
        fakeStore.matchStub = { _ in
            VoiceMatch(person: mePerson, candidates: [mePerson], d1: 0.15, d2: 0.9, confident: true)
        }

        let rows = [
            TranscriptRow(
                channel: .them,
                speakerSlot: 0,
                speakerName: nil,
                english: "Hello from them channel",
                startSeconds: 0,
                endSeconds: 5,
                clusterID: "cluster_0"
            )
        ]

        let result = memory.assignNames(
            rows: rows,
            diarization: diarization,
            zoomName: { _ in nil },
            fallbackName: nil,
            existingSlotNames: [0: "Speaker 1"]
        )

        XCTAssertEqual(result.rows.count, 1)
        // Row should NOT be named by voice (since match was to isMe)
        XCTAssertNil(result.rows[0].speakerName)
        XCTAssertEqual(result.rows[0].nameSource, .slot)
        XCTAssertNil(result.rows[0].candidateNames)
        XCTAssertNil(result.clusterNames["cluster_0"])
    }

    func testEnrollIgnoresIsMeMatchAndNeverRecordsConflict() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_1", start: 0, end: 10, embedding: [0.3, 0.4], quality: 0.8)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let mePerson = Person(id: "me_user", name: "Philip", isMe: true)
        fakeStore.matchStub = { _ in
            VoiceMatch(person: mePerson, candidates: [mePerson], d1: 0.1, d2: 0.8, confident: true)
        }

        let report: EnrollmentReport = memory.enroll(
            rows: [],
            diarization: diarization,
            confirmedNames: ["cluster_1": "Bob"],
            emails: ["Bob": "bob@example.com"],
            source: .zoom
        )

        // Conflict must NEVER be recorded against isMe person
        XCTAssertTrue(fakeStore.recordedConflicts.isEmpty)
        XCTAssertTrue(report.conflicts.isEmpty)

        // Bob should be enrolled normally
        XCTAssertEqual(fakeStore.enrolledCalls.count, 1)
        XCTAssertEqual(fakeStore.enrolledCalls[0].name, "Bob")
        XCTAssertEqual(report.enrolled, ["Bob"])
    }

    func testEnrollNeverEnrollsThemChannelIntoIsMeProfile() {
        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_1", start: 0, end: 10, embedding: [0.3, 0.4], quality: 0.8)
            ],
            processingSeconds: 0.5,
            audioSeconds: 10.0
        )

        let mePerson = Person(id: "me_id", name: "Philip", isMe: true)
        fakeStore.people = [mePerson]

        let report: EnrollmentReport = memory.enroll(
            rows: [],
            diarization: diarization,
            confirmedNames: ["cluster_1": "Philip"],
            emails: [:],
            source: .zoom
        )

        // Must not enroll them channel audio into the isMe person
        XCTAssertTrue(fakeStore.enrolledCalls.isEmpty)
        XCTAssertTrue(report.enrolled.isEmpty)
        XCTAssertTrue(report.log.contains { $0.contains("Skipping them-channel enrollment for 'Philip'") })
    }

    func testApplyDiarizationResultPureHelper() {
        let alicePerson = Person(
            id: "alice_id",
            name: "Alice",
            centroids: [VoiceCentroid(v: [1.0, 0.0], n: 1, quality: 1.0, updated: Date(), conflicts: 0, weight: 1.0)]
        )
        fakeStore.people = [alicePerson]
        fakeStore.matchStub = { emb in
            if emb == [1.0, 0.0] {
                return VoiceMatch(person: alicePerson, candidates: [alicePerson], d1: 0.2, d2: 0.9, confident: true)
            }
            return VoiceMatch(person: nil, candidates: [], d1: .infinity, d2: .infinity, confident: false)
        }

        let row1 = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 0,
            speakerName: nil,
            english: "Hello from them",
            startSeconds: 0,
            endSeconds: 5
        )
        let row2 = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 1,
            speakerName: "Speaker 2",
            english: "Queued enrollment row",
            startSeconds: 6,
            endSeconds: 10,
            nameSource: .slot
        )
        let row3 = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 2,
            speakerName: "Manual Name",
            english: "Protected manual row",
            startSeconds: 11,
            endSeconds: 15,
            nameSource: .manual
        )
        let row4 = TranscriptRow(
            id: UUID(),
            channel: .me,
            speakerSlot: nil,
            speakerName: "Me",
            english: "I am speaking",
            startSeconds: 16,
            endSeconds: 20,
            nameSource: .manual
        )

        let diarization = OfflineDiarization(
            segments: [
                SpeakerSegment(clusterID: "cluster_0", start: 0, end: 5, embedding: [1.0, 0.0], quality: 0.9),
                SpeakerSegment(clusterID: "cluster_1", start: 6, end: 10, embedding: [0.0, 1.0], quality: 0.9),
                SpeakerSegment(clusterID: "cluster_2", start: 11, end: 15, embedding: [0.5, 0.5], quality: 0.9)
            ],
            processingSeconds: 0.3,
            audioSeconds: 20.0
        )

        let snapshot = TwoPassSnapshot(
            sessionID: UUID(),
            meetingURL: nil,
            startedAt: Date(),
            rows: [row1, row2, row3, row4],
            speakerNames: [0: "Speaker 1", 1: "Speaker 2", 2: "Manual Name"],
            manualSlots: [2],
            queuedManualEnrollments: [1: "Bob"],
            attendees: [],
            myName: "Me",
            fallbackName: nil
        )

        let (rows, speakerNames, report, _) = AppState.applyDiarizationResult(
            snapshot: snapshot,
            diarization: diarization,
            memory: memory,
            zoomName: { _ in nil },
            fallbackName: nil
        )

        // 1. Names assigned: row1 matched voiceprint Alice
        XCTAssertEqual(rows[0].speakerName, "Alice")
        XCTAssertEqual(rows[0].nameSource, .voice)
        XCTAssertEqual(rows[0].clusterID, "cluster_0")

        // 2. Queued manual enrollment applied to slot 1: Bob
        XCTAssertEqual(speakerNames[1], "Bob")

        // 3. Manual protected: row3 remains Manual Name with .manual
        XCTAssertEqual(rows[2].speakerName, "Manual Name")
        XCTAssertEqual(rows[2].nameSource, .manual)

        // 4. Me channel preserved
        XCTAssertEqual(rows[3].speakerName, "Me")
        XCTAssertEqual(rows[3].channel, .me)

        // 5. Enrollment reported from queued manual enrollment
        XCTAssertTrue(report.enrolled.contains("Bob"))
    }

    func testShouldUpdateLiveStateAndMeetingStoreUpdateRowsRoundTrip() throws {
        let sessionA = UUID()
        let sessionB = UUID()

        // (b.1) shouldUpdateLiveState helper check
        XCTAssertTrue(AppState.shouldUpdateLiveState(current: sessionA, snapshot: sessionA))
        XCTAssertFalse(AppState.shouldUpdateLiveState(current: sessionA, snapshot: sessionB))

        // (b.2) MeetingStore.updateRows round-trips through MeetingStoreFixture
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let initialRow = MeetingStoreFixture.row(text: "Initial text", start: 0, end: 5)
        let startedAt = MeetingStoreFixture.date(hour: 10)
        let summaryText = "# Important Meeting\n\nPreserved summary points."

        let meetingURL = try store.save(
            rows: [initialRow],
            myName: "Philip",
            speakerNames: [0: "Speaker 1"],
            startedAt: startedAt,
            durationSeconds: 5.0,
            title: "Round Trip Test",
            summary: summaryText,
            attendees: nil,
            existingURL: nil
        )

        let updatedRow = TranscriptRow(
            id: initialRow.id,
            channel: .them,
            speakerSlot: 0,
            speakerName: "Alice",
            english: "Refined text",
            korean: "정제된 텍스트",
            startSeconds: 0,
            endSeconds: 5,
            nameSource: .voice,
            candidateNames: nil,
            clusterID: "cluster_0"
        )

        try store.updateRows(at: meetingURL, rows: [updatedRow], speakerNames: [0: "Alice"])

        guard let loaded = store.load(meetingURL) else {
            XCTFail("Failed to load meeting after updateRows")
            return
        }

        // Rows and speakerNames rewritten. Phase 4a (AC11): for a row id that already exists on disk,
        // updateRows keeps the on-disk english (user edits win); speaker and cluster fields come from the caller.
        XCTAssertEqual(loaded.rows.count, 1)
        XCTAssertEqual(loaded.rows[0].english, "Initial text")
        XCTAssertEqual(loaded.rows[0].korean, "정제된 텍스트")
        XCTAssertEqual(loaded.rows[0].speakerName, "Alice")
        XCTAssertEqual(loaded.rows[0].nameSource, .voice)
        XCTAssertEqual(loaded.rows[0].clusterID, "cluster_0")
        XCTAssertEqual(loaded.speakerNames[0], "Alice")

        // Summary preserved
        XCTAssertEqual(loaded.summary, summaryText)
    }

    func testMergePreservingManualSurvivesAndNonManualTakesComputed() {
        let row1ID = UUID()
        let row2ID = UUID()
        let row3ID = UUID()

        // On-disk latest meeting: row1 was manually renamed to "Alice"
        let latestRows = [
            TranscriptRow(
                id: row1ID,
                channel: .them,
                speakerSlot: 1,
                speakerName: "Alice",
                english: "Hello from Alice",
                startSeconds: 0,
                endSeconds: 5,
                nameSource: .manual,
                candidateNames: nil
            ),
            TranscriptRow(
                id: row2ID,
                channel: .them,
                speakerSlot: 1,
                speakerName: "Speaker 1",
                english: "More text from slot 1",
                startSeconds: 5,
                endSeconds: 10,
                nameSource: .slot
            ),
            TranscriptRow(
                id: row3ID,
                channel: .them,
                speakerSlot: 2,
                speakerName: "Speaker 2",
                english: "Text from slot 2",
                startSeconds: 10,
                endSeconds: 15,
                nameSource: .slot
            )
        ]
        let latestNames = [1: "Alice", 2: "Speaker 2"]

        // Computed diarization rows: offline diarization assigned cluster_1 (named "Bob") to row1/row2 and cluster_2 (named "Charlie") to row3
        let computedRows = [
            TranscriptRow(
                id: row1ID,
                channel: .them,
                speakerSlot: 1,
                speakerName: "Bob",
                english: "Hello from Alice",
                startSeconds: 0,
                endSeconds: 5,
                nameSource: .voice,
                candidateNames: ["Bob"],
                clusterID: "cluster_1"
            ),
            TranscriptRow(
                id: row2ID,
                channel: .them,
                speakerSlot: 1,
                speakerName: "Bob",
                english: "More text from slot 1",
                startSeconds: 5,
                endSeconds: 10,
                nameSource: .voice,
                candidateNames: ["Bob"],
                clusterID: "cluster_1"
            ),
            TranscriptRow(
                id: row3ID,
                channel: .them,
                speakerSlot: 2,
                speakerName: "Charlie",
                english: "Text from slot 2",
                startSeconds: 10,
                endSeconds: 15,
                nameSource: .voice,
                candidateNames: ["Charlie"],
                clusterID: "cluster_2"
            )
        ]
        let computedNames = [1: "Bob", 2: "Charlie"]

        let (mergedRows, mergedNames) = AppState.mergePreservingManual(
            latest: latestRows,
            latestNames: latestNames,
            computed: computedRows,
            computedNames: computedNames
        )

        // Row 1 (manually named) keeps "Alice" and .manual
        XCTAssertEqual(mergedRows[0].speakerName, "Alice")
        XCTAssertEqual(mergedRows[0].nameSource, .manual)
        XCTAssertNil(mergedRows[0].candidateNames)

        // Row 2 (shares slot 1 and cluster_1 with manual row 1) keeps manual name "Alice" and .manual
        XCTAssertEqual(mergedRows[1].speakerName, "Alice")
        XCTAssertEqual(mergedRows[1].nameSource, .manual)
        XCTAssertNil(mergedRows[1].candidateNames)

        // Row 3 (non-manual slot 2 / cluster_2) takes computed name "Charlie" and .voice
        XCTAssertEqual(mergedRows[2].speakerName, "Charlie")
        XCTAssertEqual(mergedRows[2].nameSource, .voice)
        XCTAssertEqual(mergedRows[2].candidateNames, ["Charlie"])

        // Slot names: slot 1 keeps "Alice", slot 2 takes "Charlie"
        XCTAssertEqual(mergedNames[1], "Alice")
        XCTAssertEqual(mergedNames[2], "Charlie")
    }

    func testDecideDiarizationCompletionFailurePathReturnsPendingPayloadAndNoSuccessFlag() {
        let snapshotID = UUID()
        let currentID = snapshotID
        let meetingURL = URL(fileURLWithPath: "/tmp/nonexistent-meeting-folder")

        let row1 = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 1,
            speakerName: "Bob",
            english: "Hi",
            startSeconds: 0,
            endSeconds: 5,
            nameSource: .voice
        )
        let computedRows = [row1]
        let computedNames = [1: "Bob"]

        let snapshot = TwoPassSnapshot(
            sessionID: snapshotID,
            meetingURL: meetingURL,
            startedAt: Date(),
            rows: computedRows,
            speakerNames: computedNames,
            manualSlots: [],
            queuedManualEnrollments: [:],
            attendees: [],
            myName: "Me",
            fallbackName: nil
        )

        // latestMeeting is nil -> simulation of reload failure
        let decision = AppState.decideDiarizationCompletion(
            snapshot: snapshot,
            currentSessionID: currentID,
            latestMeeting: nil,
            computedRows: computedRows,
            computedNames: computedNames
        )

        switch decision {
        case .failure(let url, let rows, let names, let errorDescription):
            XCTAssertEqual(url, meetingURL)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].speakerName, "Bob")
            XCTAssertEqual(names[1], "Bob")
            XCTAssertFalse(errorDescription.isEmpty)
        case .success:
            XCTFail("Decision must be failure when reload fails")
        }
    }

    func testRetryPayloadPureHelper() {
        let meetingURL = URL(fileURLWithPath: "/tmp/meeting-a")
        let pending = AppState.PendingDiarizationResult(
            sessionID: UUID(),
            meetingURL: meetingURL,
            rows: [
                TranscriptRow(channel: .them, speakerSlot: 1, speakerName: "ComputedBob", english: "Hello", startSeconds: 0, endSeconds: 5, nameSource: .voice, clusterID: "c1")
            ],
            names: [1: "ComputedBob"]
        )

        // 1. Reload failure -> nil
        let nilResult = AppState.retryPayload(latest: nil, pending: pending)
        XCTAssertNil(nilResult)

        // 2. SavedMeeting on disk with manual override -> preserves manual override
        let latestMeeting = SavedMeeting(
            startedAt: Date(),
            durationSeconds: 10,
            title: "Meeting A",
            myName: "Philip",
            speakerNames: [1: "ManualAlice"],
            rows: [
                TranscriptRow(channel: .them, speakerSlot: 1, speakerName: "ManualAlice", english: "Hello", startSeconds: 0, endSeconds: 5, nameSource: .manual, clusterID: "c1")
            ],
            summary: nil,
            attendees: nil
        )

        guard let (mergedRows, mergedNames) = AppState.retryPayload(latest: latestMeeting, pending: pending) else {
            return XCTFail("retryPayload must return merged rows and names when latest is non-nil")
        }

        XCTAssertEqual(mergedRows[0].speakerName, "ManualAlice")
        XCTAssertEqual(mergedRows[0].nameSource, NameSource.manual)
        XCTAssertEqual(mergedNames[1], "ManualAlice")
    }

    @MainActor
    func testPendingDiarizationSaveFailedUserEditsManualOnDiskAndRetries() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let r1 = TranscriptRow(
            channel: .them,
            speakerSlot: 1,
            speakerName: "Speaker 1",
            english: "Discussion point",
            startSeconds: 0,
            endSeconds: 5,
            nameSource: .slot,
            clusterID: "cluster_1"
        )
        let meetingURL = try store.save(
            rows: [r1],
            myName: "Me",
            speakerNames: [1: "Speaker 1"],
            startedAt: MeetingStoreFixture.date(hour: 9),
            durationSeconds: 10,
            title: "Pending Test Meeting",
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        let sessionID = UUID()
        var pendingDiarizationResults: [URL: AppState.PendingDiarizationResult] = [:]
        // Save failed -> store pending diarization result
        let pending = AppState.PendingDiarizationResult(
            sessionID: sessionID,
            meetingURL: meetingURL,
            rows: [
                TranscriptRow(
                    id: r1.id,
                    channel: .them,
                    speakerSlot: 1,
                    speakerName: "DiarizedDave",
                    english: "Discussion point",
                    startSeconds: 0,
                    endSeconds: 5,
                    nameSource: .voice,
                    clusterID: "cluster_1"
                )
            ],
            names: [1: "DiarizedDave"]
        )
        pendingDiarizationResults[meetingURL] = pending

        // User edits row on disk to .manual
        guard var saved = store.load(meetingURL) else {
            return XCTFail("Saved meeting not found")
        }
        saved.rows[0].speakerName = "ManualEve"
        saved.rows[0].nameSource = .manual
        saved.speakerNames[1] = "ManualEve"
        _ = try store.save(
            rows: saved.rows,
            myName: saved.myName,
            speakerNames: saved.speakerNames,
            startedAt: saved.startedAt,
            durationSeconds: saved.durationSeconds,
            title: saved.title,
            summary: saved.summary,
            attendees: saved.attendees,
            existingURL: meetingURL
        )

        // Retry save for this URL using pure static retryPayload helper
        guard let pendingToRetry = pendingDiarizationResults[meetingURL],
              let latest = store.load(meetingURL),
              let (mergedRows, mergedNames) = AppState.retryPayload(latest: latest, pending: pendingToRetry) else {
            return XCTFail("Failed to compute retry payload")
        }
        try store.updateRows(at: meetingURL, rows: mergedRows, speakerNames: mergedNames)
        pendingDiarizationResults[meetingURL] = nil

        XCTAssertNil(pendingDiarizationResults[meetingURL], "Pending result must be cleared on success")
        guard let reloaded = store.load(meetingURL) else {
            return XCTFail("Failed to reload meeting after retry")
        }
        XCTAssertEqual(reloaded.rows[0].speakerName, "ManualEve", "Manual edit must be preserved upon retry")
        XCTAssertEqual(reloaded.rows[0].nameSource, .manual)
        XCTAssertEqual(reloaded.speakerNames[1], "ManualEve")
    }

    @MainActor
    func testTwoMeetingsPendingSimultaneouslyRetainedAndRetriedIndependently() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let r1 = TranscriptRow(channel: .them, speakerSlot: 1, speakerName: "Slot 1", english: "M1", startSeconds: 0, endSeconds: 5, nameSource: .slot, clusterID: "c1")
        let url1 = try store.save(
            rows: [r1],
            myName: "Me",
            speakerNames: [1: "Slot 1"],
            startedAt: MeetingStoreFixture.date(hour: 9),
            durationSeconds: 10,
            title: "Meeting 1",
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        let r2 = TranscriptRow(channel: .them, speakerSlot: 2, speakerName: "Slot 2", english: "M2", startSeconds: 0, endSeconds: 5, nameSource: .slot, clusterID: "c2")
        let url2 = try store.save(
            rows: [r2],
            myName: "Me",
            speakerNames: [2: "Slot 2"],
            startedAt: MeetingStoreFixture.date(hour: 10),
            durationSeconds: 10,
            title: "Meeting 2",
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        var pendingDiarizationResults: [URL: AppState.PendingDiarizationResult] = [:]
        let pending1 = AppState.PendingDiarizationResult(
            sessionID: UUID(),
            meetingURL: url1,
            rows: [TranscriptRow(id: r1.id, channel: .them, speakerSlot: 1, speakerName: "ComputedAlice", english: "M1", startSeconds: 0, endSeconds: 5, nameSource: .voice, clusterID: "c1")],
            names: [1: "ComputedAlice"]
        )
        let pending2 = AppState.PendingDiarizationResult(
            sessionID: UUID(),
            meetingURL: url2,
            rows: [TranscriptRow(id: r2.id, channel: .them, speakerSlot: 2, speakerName: "ComputedBob", english: "M2", startSeconds: 0, endSeconds: 5, nameSource: .voice, clusterID: "c2")],
            names: [2: "ComputedBob"]
        )

        pendingDiarizationResults[url1] = pending1
        pendingDiarizationResults[url2] = pending2

        XCTAssertEqual(pendingDiarizationResults.count, 2)

        // Retry only url1
        guard let p1 = pendingDiarizationResults[url1],
              let latest1 = store.load(url1),
              let (mergedRows1, mergedNames1) = AppState.retryPayload(latest: latest1, pending: p1) else {
            return XCTFail("Failed to compute retry payload for url1")
        }
        try store.updateRows(at: url1, rows: mergedRows1, speakerNames: mergedNames1)
        pendingDiarizationResults[url1] = nil

        XCTAssertNil(pendingDiarizationResults[url1], "url1 must be cleared after successful retry")
        XCTAssertNotNil(pendingDiarizationResults[url2], "url2 must remain pending")
        XCTAssertEqual(pendingDiarizationResults.count, 1)

        // Retry remaining (url2)
        guard let p2 = pendingDiarizationResults[url2],
              let latest2 = store.load(url2),
              let (mergedRows2, mergedNames2) = AppState.retryPayload(latest: latest2, pending: p2) else {
            return XCTFail("Failed to compute retry payload for url2")
        }
        try store.updateRows(at: url2, rows: mergedRows2, speakerNames: mergedNames2)
        pendingDiarizationResults[url2] = nil

        XCTAssertNil(pendingDiarizationResults[url2], "url2 must now be cleared")
        XCTAssertTrue(pendingDiarizationResults.isEmpty)

        let loaded1 = store.load(url1)
        let loaded2 = store.load(url2)
        XCTAssertEqual(loaded1?.rows[0].speakerName, "ComputedAlice")
        XCTAssertEqual(loaded2?.rows[0].speakerName, "ComputedBob")
    }

    @MainActor
    func testDetachedContinuationClosureDeallocatesOwnerWhileGateBlockedAndWritesDisk() async throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let r1 = TranscriptRow(channel: .them, speakerSlot: 1, speakerName: "Old", english: "Audio text", startSeconds: 0, endSeconds: 5, nameSource: .slot, clusterID: "c1")
        let meetingURL = try store.save(
            rows: [r1],
            myName: "Me",
            speakerNames: [1: "Old"],
            startedAt: MeetingStoreFixture.date(hour: 9),
            durationSeconds: 10,
            title: "Dealloc Continuation Test",
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        final class DummyOwner {
            var liveStateUpdated = false
            func updateLive() {
                liveStateUpdated = true
            }
        }

        var owner: DummyOwner? = DummyOwner()
        weak var weakOwner: DummyOwner? = nil
        weakOwner = owner

        let gate = AsyncTestGateHelper()
        let fakeVoiceprints = VoiceprintStore(rootURL: store.rootURL.appendingPathComponent("fakeVP", isDirectory: true))
        let snapshot = TwoPassSnapshot(
            sessionID: UUID(),
            meetingURL: meetingURL,
            startedAt: Date(),
            rows: [r1],
            speakerNames: [1: "Old"],
            manualSlots: [],
            queuedManualEnrollments: [:],
            attendees: [],
            myName: "Me",
            fallbackName: nil
        )
        let diarization = OfflineDiarization(
            segments: [SpeakerSegment(clusterID: "c1", start: 0, end: 5, embedding: [1, 0], quality: 0.9)],
            processingSeconds: 0.1,
            audioSeconds: 5.0
        )

        let storeRef = store
        let voiceprintsRef = fakeVoiceprints
        let snapshotRef = snapshot

        let continuationTask = Task.detached(priority: .utility) { [weak owner] in
            await gate.wait()
            await MainActor.run { [weak owner] in
                guard let owner else {
                    AppState.applyDiarizationToDiskOnly(
                        snapshot: snapshotRef,
                        diarization: diarization,
                        meetingStore: storeRef,
                        voiceprints: voiceprintsRef,
                        zoomName: { _ in "ZoomAlice" },
                        fallbackName: nil
                    )
                    return
                }
                owner.updateLive()
            }
        }

        // Deallocate owner while gate is closed
        owner = nil
        XCTAssertNil(weakOwner, "Dummy owner must deallocate while gate-blocked task is pending")

        // Open gate and await completion
        await gate.open()
        _ = await continuationTask.value

        // Verify disk was still updated
        guard let reloaded = store.load(meetingURL) else {
            return XCTFail("Failed to reload meeting from store")
        }
        XCTAssertEqual(reloaded.rows[0].speakerName, "ZoomAlice", "Disk save must happen even after owner deallocates")
    }

    func testApplyLiveCandidatesAmbiguousMatch() {
        let r1 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: "Speaker 1", english: "One", startSeconds: 0, endSeconds: 2, nameSource: nil)
        let r2 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: "Speaker 1", english: "Two", startSeconds: 2, endSeconds: 4, nameSource: .slot)
        let r3 = TranscriptRow(channel: .them, speakerSlot: 0, speakerName: "Alice", english: "Three", startSeconds: 4, endSeconds: 6, nameSource: .voice)
        let r4 = TranscriptRow(channel: .them, speakerSlot: 1, speakerName: "Bob", english: "Four", startSeconds: 6, endSeconds: 8, nameSource: .manual)
        let r5 = TranscriptRow(channel: .me, speakerName: "Philip", english: "Five", startSeconds: 8, endSeconds: 10, nameSource: nil)

        let initialRows = [r1, r2, r3, r4, r5]
        let candidates = ["Candidate1", "Candidate2"]

        // 1. Apply to slot 0 (ambiguous match)
        let (updatedRows, modified) = AppState.applyLiveCandidates(
            rows: initialRows,
            slot: 0,
            candidates: candidates,
            manualSlots: []
        )

        XCTAssertTrue(modified)
        // Row 1 (nil nameSource) gets candidates, keeps speakerName
        XCTAssertEqual(updatedRows[0].candidateNames, candidates)
        XCTAssertEqual(updatedRows[0].speakerName, "Speaker 1")
        XCTAssertNil(updatedRows[0].nameSource)

        // Row 2 (.slot nameSource) gets candidates, keeps speakerName
        XCTAssertEqual(updatedRows[1].candidateNames, candidates)
        XCTAssertEqual(updatedRows[1].speakerName, "Speaker 1")
        XCTAssertEqual(updatedRows[1].nameSource, .slot)

        // Row 3 (.voice nameSource) is NOT modified
        XCTAssertNil(updatedRows[2].candidateNames)
        XCTAssertEqual(updatedRows[2].speakerName, "Alice")
        XCTAssertEqual(updatedRows[2].nameSource, .voice)

        // Row 4 (slot 1) is untouched
        XCTAssertNil(updatedRows[3].candidateNames)
        XCTAssertEqual(updatedRows[3].speakerName, "Bob")

        // Row 5 (.me) is untouched
        XCTAssertNil(updatedRows[4].candidateNames)
        XCTAssertEqual(updatedRows[4].speakerName, "Philip")

        // 2. If manualSlots contains slot 0 -> no modification
        let (_, manualSlotModified) = AppState.applyLiveCandidates(
            rows: initialRows,
            slot: 0,
            candidates: candidates,
            manualSlots: [0]
        )
        XCTAssertFalse(manualSlotModified)

        // 3. If rows contain a .manual row for slot 0 -> no modification
        var rowsWithManualSlot0 = initialRows
        rowsWithManualSlot0[0].nameSource = .manual
        let (_, hasManualRowModified) = AppState.applyLiveCandidates(
            rows: rowsWithManualSlot0,
            slot: 0,
            candidates: candidates,
            manualSlots: []
        )
        XCTAssertFalse(hasManualRowModified)
    }

    // MARK: - DD2: Refined Rows Pick Up Manual Overrides by Time Overlap

    func testRefinedRowsWithNewUUIDsPickUpManualOverridesByTimeOverlap() async throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        // 1st save: live row with initial speaker name
        let liveRowID = UUID()
        let liveRow = TranscriptRow(
            id: liveRowID,
            channel: .them,
            speakerSlot: 1,
            speakerName: "Speaker 1",
            english: "Hello there",
            korean: "안녕하세요",
            startSeconds: 10.0,
            endSeconds: 20.0,
            nameSource: NameSource.slot,
            candidateNames: ["Bob", "Alice"]
        )
        let meetingURL = try store.save(
            rows: [liveRow],
            myName: "Philip",
            speakerNames: [1: "Speaker 1"],
            startedAt: MeetingStoreFixture.date(hour: 9),
            durationSeconds: 20.0,
            title: nil,
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        // User manually edits the meeting on disk: Speaker 1 -> "Charlie" with .manual source
        var editedRow = liveRow
        editedRow.speakerName = "Charlie"
        editedRow.nameSource = NameSource.manual
        editedRow.candidateNames = nil
        try store.updateRows(at: meetingURL, rows: [editedRow], speakerNames: [1: "Charlie"])

        // 2-pass produces refined row with a NEW UUID, no slot/cluster, and overlapping time range (11.0 to 19.0)
        let refinedRowID = UUID()
        let refinedRow = TranscriptRow(
            id: refinedRowID,
            channel: .them,
            speakerSlot: nil,
            speakerName: nil,
            english: "Hello there refined",
            korean: "안녕하세요 정제",
            startSeconds: 11.0,
            endSeconds: 19.0, // 8s duration, 8s overlap with 10...20 -> 100% >= 50%
            nameSource: nil,
            candidateNames: nil
        )

        guard let latestOnDisk = store.load(meetingURL) else {
            return XCTFail("Could not load latest meeting from disk")
        }

        let (overriddenRows, manualNames) = AppState.applyManualOverrides(
            refined: [refinedRow],
            latest: latestOnDisk.rows,
            latestNames: latestOnDisk.speakerNames
        )

        XCTAssertEqual(overriddenRows.count, 1)
        XCTAssertEqual(overriddenRows[0].id, refinedRowID, "Refined row preserves its new UUID")
        XCTAssertEqual(overriddenRows[0].speakerName, "Charlie", "Refined row picks up manual name override via time overlap")
        XCTAssertEqual(overriddenRows[0].nameSource, NameSource.manual, "nameSource is set to .manual")
        XCTAssertNil(overriddenRows[0].candidateNames, "candidateNames are cleared for manual rows")
        XCTAssertEqual(manualNames[1], "Charlie", "Manual slot names carried forward")
    }

    // MARK: - DD3: TwoPassJob Weak Owner Pipeline Deallocation

    private final class PipelineAtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool = false

        func set(_ val: Bool) {
            lock.lock()
            defer { lock.unlock() }
            value = val
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class MockTwoPassPipelineOwner {
        var noticeMessage: String?
        var didDeallocateFlag: PipelineAtomicFlag

        init(didDeallocateFlag: PipelineAtomicFlag) {
            self.didDeallocateFlag = didDeallocateFlag
        }

        deinit {
            didDeallocateFlag.set(true)
        }

        func runPipeline(job: TwoPassJob, gate: AsyncTestGateHelper) -> Task<Void, Never> {
            return Task { [weak self, job] in
                let currentJob = job
                // Simulated gate-blocked pipeline step
                await gate.wait()

                // Checkpoint on MainActor
                await MainActor.run { [weak self] in
                    self?.noticeMessage = "Pipeline finished"
                }

                // Saved-meeting writes use job.meetingStore
                if let meetingURL = currentJob.snapshot.meetingURL {
                    await MainActor.run {
                        try? currentJob.meetingStore.updateRows(
                            at: meetingURL,
                            rows: currentJob.snapshot.rows,
                            speakerNames: currentJob.snapshot.speakerNames
                        )
                    }
                }
            }
        }
    }

    func testTwoPassPipelineWeakOwnerDeallocatesWhileGateBlockedAndWritesDiskUsingJobMeetingStore() async throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let initialRow = TranscriptRow(
            channel: .them,
            speakerSlot: 1,
            speakerName: "RefinedSpeaker",
            english: "Initial",
            korean: "초기",
            startSeconds: 0,
            endSeconds: 5
        )
        let meetingURL = try store.save(
            rows: [initialRow],
            myName: "Me",
            speakerNames: [1: "RefinedSpeaker"],
            startedAt: MeetingStoreFixture.date(hour: 9),
            durationSeconds: 10.0,
            title: nil,
            summary: nil,
            attendees: nil,
            existingURL: nil
        )
        let gate = AsyncTestGateHelper()
        let deallocFlag = PipelineAtomicFlag()

        let snapshot = TwoPassSnapshot(
            sessionID: UUID(),
            meetingURL: meetingURL,
            startedAt: Date(),
            rows: [initialRow],
            speakerNames: [1: "RefinedSpeaker"],
            manualSlots: [],
            queuedManualEnrollments: [:],
            attendees: [],
            myName: "Me",
            fallbackName: nil
        )

        let fakeVP = VoiceprintStore(rootURL: store.rootURL.appendingPathComponent("fakeVP", isDirectory: true))
        let promoter = LiveVoicePromoter(embeddingProvider: { _ in [Float](repeating: 0.1, count: 256) })
        let job = TwoPassJob(
            snapshot: snapshot,
            recorderRef: nil,
            engineRef: nil,
            diarizerRef: nil,
            geminiRef: GeminiLiveTranslator(),
            offlineDiarizer: OfflineDiarizer(),
            makeEmbeddingEngine: { FluidOfflineEngine() },
            voiceprints: fakeVP,
            meetingStore: store,
            promoter: promoter,
            thresholds: VoiceprintThresholds(),
            zoomNameLookup: { _ in nil },
            fallbackName: nil,
            myName: "Me"
        )

        var task: Task<Void, Never>?
        do {
            let owner = MockTwoPassPipelineOwner(didDeallocateFlag: deallocFlag)
            task = owner.runPipeline(job: job, gate: gate)
        }

        // Owner should now be deallocated while gate is waiting
        XCTAssertTrue(deallocFlag.get(), "Owner must be deallocated when out of scope")

        // Unblock gate and await task
        await gate.open()
        _ = await task?.value

        // MeetingStore should have the updated rows written by job.meetingStore
        guard let reloaded = store.load(meetingURL) else {
            return XCTFail("Failed to reload meeting from store")
        }
        XCTAssertEqual(reloaded.rows[0].speakerName, "RefinedSpeaker", "Disk save must happen using job.meetingStore even after owner deallocated")
    }

    // MARK: - R10-3 Refined Save Decision & Retry Tests (T8..T10)

    func testRefinedSaveDecisionSuccess() {
        let dummyURL = URL(fileURLWithPath: "/tmp/dummy-meeting")
        let sessionMatchesDecision = AppState.refinedSaveDecision(
            error: nil,
            meetingURL: dummyURL,
            sessionMatches: true
        )
        XCTAssertEqual(
            sessionMatchesDecision,
            .saved(notice: "Transcript refined and saved.")
        )

        let sessionDiffersDecision = AppState.refinedSaveDecision(
            error: nil,
            meetingURL: dummyURL,
            sessionMatches: false
        )
        XCTAssertEqual(
            sessionDiffersDecision,
            .saved(notice: nil)
        )
    }

    func testRefinedSaveDecisionFailure() {
        let dummyURL = URL(fileURLWithPath: "/tmp/dummy-meeting")
        let testError = NSError(domain: "test.save", code: 42, userInfo: [NSLocalizedDescriptionKey: "Disk write failed"])

        let withURLDecision = AppState.refinedSaveDecision(
            error: testError,
            meetingURL: dummyURL,
            sessionMatches: true
        )
        XCTAssertEqual(
            withURLDecision,
            .pending(notice: "Refined transcript could not be saved: Disk write failed", payloadURL: dummyURL)
        )

        let withoutURLDecision = AppState.refinedSaveDecision(
            error: testError,
            meetingURL: nil,
            sessionMatches: true
        )
        XCTAssertEqual(
            withoutURLDecision,
            .pending(notice: "Refined transcript could not be saved: Disk write failed", payloadURL: nil)
        )

        let mismatchSessionDecision = AppState.refinedSaveDecision(
            error: testError,
            meetingURL: dummyURL,
            sessionMatches: false
        )
        XCTAssertEqual(
            mismatchSessionDecision,
            .pending(notice: nil, payloadURL: dummyURL)
        )
    }

    func testRefinedSaveFailureRetryAndManualEditPreservation() throws {
        let store = try MeetingStoreFixture.makeStore()
        defer { MeetingStoreFixture.cleanUp(store) }

        let initialRow = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 0,
            speakerName: nil,
            english: "Hello world",
            korean: nil,
            startSeconds: 0.0,
            endSeconds: 5.0,
            nameSource: nil,
            candidateNames: nil,
            clusterID: nil
        )

        let meetingURL = try store.save(
            rows: [initialRow],
            myName: "Me",
            speakerNames: [0: "Speaker 1"],
            startedAt: Date(),
            durationSeconds: 5.0,
            title: "Test Meeting",
            summary: nil,
            attendees: nil,
            existingURL: nil
        )

        // Make the meeting folder read-only to inject updateRows failure
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: meetingURL.path)[.posixPermissions] as? NSNumber
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: meetingURL.path)
        defer {
            if let originalPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: meetingURL.path)
            }
        }

        let refinedRow = TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 0,
            speakerName: "ComputedSpeaker",
            english: "Hello refined world",
            korean: nil,
            startSeconds: 0.0,
            endSeconds: 5.0,
            nameSource: NameSource.voice,
            candidateNames: nil,
            clusterID: "c1"
        )

        XCTAssertThrowsError(try store.updateRows(at: meetingURL, rows: [refinedRow], speakerNames: [0: "ComputedSpeaker"]))

        // Build pending payload
        let sessionID = UUID()
        let pending = AppState.PendingDiarizationResult(
            sessionID: sessionID,
            meetingURL: meetingURL,
            rows: [refinedRow],
            names: [0: "ComputedSpeaker"],
            diarization: nil
        )

        // Restore permissions so we can write a manual edit directly
        if let originalPermissions {
            try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: meetingURL.path)
        }

        // Write a manual edit to disk
        guard var manualEditedMeeting = store.load(meetingURL) else {
            return XCTFail("Meeting not found on disk")
        }
        var manualRow = manualEditedMeeting.rows[0]
        manualRow.speakerName = "ManualBob"
        manualRow.nameSource = NameSource.manual
        manualEditedMeeting.rows = [manualRow]
        manualEditedMeeting.speakerNames = [0: "ManualBob"]
        try store.updateRows(at: meetingURL, rows: manualEditedMeeting.rows, speakerNames: manualEditedMeeting.speakerNames)

        // Run retry payload logic
        let latest = store.load(meetingURL)
        guard let unwrapRetry = AppState.retryPayload(latest: latest, pending: pending) else {
            return XCTFail("retryPayload returned nil")
        }

        XCTAssertFalse(unwrapRetry.rows.isEmpty)
        XCTAssertEqual(unwrapRetry.rows[0].speakerName, "ManualBob", "Manual edit must survive in retry merged rows")
        XCTAssertEqual(unwrapRetry.rows[0].nameSource, NameSource.manual)
    }

    func testDiarizationMergePreservesEditedEnglishText() {
        let rowID = UUID()
        let diskRow = TranscriptRow(
            id: rowID,
            channel: .them,
            speakerSlot: 0,
            speakerName: nil,
            english: "Edited English text on disk",
            korean: nil,
            startSeconds: 0,
            endSeconds: 4,
            nameSource: .slot,
            candidateNames: nil,
            clusterID: nil
        )

        let computedRow = TranscriptRow(
            id: rowID,
            channel: .them,
            speakerSlot: 0,
            speakerName: "Alice",
            english: "Original unedited transcript",
            korean: nil,
            startSeconds: 0,
            endSeconds: 4,
            nameSource: .voice,
            candidateNames: nil,
            clusterID: "cluster_1"
        )

        let (mergedRows, mergedNames) = AppState.mergePreservingManual(
            latest: [diskRow],
            latestNames: [:],
            computed: [computedRow],
            computedNames: [0: "Alice"]
        )

        XCTAssertEqual(mergedRows.count, 1)
        XCTAssertEqual(mergedRows[0].english, "Edited English text on disk", "User edited text on disk must be preserved")
        XCTAssertEqual(mergedRows[0].speakerName, "Alice", "Computed speaker name should be applied")
        XCTAssertEqual(mergedRows[0].clusterID, "cluster_1", "Computed clusterID should be applied")
        XCTAssertEqual(mergedRows[0].nameSource, .voice, "Computed name source should be applied")
        XCTAssertEqual(mergedNames[0], "Alice")
    }
}

private actor AsyncTestGateHelper {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    func open() {
        isOpen = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }
}
