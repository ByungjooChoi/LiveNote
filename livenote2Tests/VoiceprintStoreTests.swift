import XCTest
@testable import LiveNote

@MainActor
final class VoiceprintStoreTests: XCTestCase {

    private var tempDir: URL!
    private var testDefaults: UserDefaults!
    private let suiteName = "VoiceprintStoreTests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceprintStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        AppLog.directoryOverride = tempDir.appendingPathComponent("logs")
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        AppLog.directoryOverride = nil
        testDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 벡터 생성 헬퍼

    private func makeUnitVector(dim: Int = 256, activeIndex: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[activeIndex % dim] = 1.0
        return v
    }

    // MARK: - 테스트

    func testInitialStateMissingFile() {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testEnrollmentValidation() {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 10.0,
            minQuality: 0.6,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let shortSample = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 5.0)
        ]
        XCTAssertThrowsError(try store.enroll(name: "Alice", email: nil, samples: shortSample, source: .live, isMe: false)) { error in
            guard case VoiceprintError.tooLittleAudio = error else {
                return XCTFail("Expected tooLittleAudio but got \(error)")
            }
        }

        let lowQualitySample = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.4, seconds: 12.0)
        ]
        XCTAssertThrowsError(try store.enroll(name: "Alice", email: nil, samples: lowQualitySample, source: .live, isMe: false)) { error in
            guard case VoiceprintError.lowQuality = error else {
                return XCTFail("Expected lowQuality but got \(error)")
            }
        }

        // 20s zero vector + 3s valid sample -> valid audio is 3s < 10s minEnrollSeconds -> throws tooLittleAudio
        let zeroVec = [Float](repeating: 0, count: 256)
        let mixedSamples = [
            EnrollmentSample(embedding: zeroVec, quality: 0.9, seconds: 20.0),
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 3.0)
        ]
        XCTAssertThrowsError(try store.enroll(name: "Alice", email: nil, samples: mixedSamples, source: .live, isMe: false)) { error in
            guard case VoiceprintError.tooLittleAudio(let seconds) = error else {
                return XCTFail("Expected tooLittleAudio but got \(error)")
            }
            XCTAssertEqual(seconds, 3.0, accuracy: 0.001)
        }

        // All zero vectors -> throws noValidSamples
        let onlyZero = [
            EnrollmentSample(embedding: zeroVec, quality: 0.9, seconds: 20.0)
        ]
        XCTAssertThrowsError(try store.enroll(name: "Alice", email: nil, samples: onlyZero, source: .live, isMe: false)) { error in
            guard case VoiceprintError.noValidSamples = error else {
                return XCTFail("Expected noValidSamples but got \(error)")
            }
        }
    }

    func testEnrollmentAndReload() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 5.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let samples = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.8, seconds: 6.0)
        ]
        let person = try store.enroll(name: "Craig", email: "craig@example.com", samples: samples, source: .zoom, isMe: false)

        XCTAssertEqual(person.name, "Craig")
        XCTAssertEqual(person.email, "craig@example.com")
        XCTAssertEqual(person.meetings, 1)
        XCTAssertEqual(person.centroids.count, 1)
        XCTAssertEqual(store.people.count, 1)

        // 디스크 재로드 확인
        let store2 = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        XCTAssertEqual(store2.people.count, 1)
        XCTAssertEqual(store2.people.first?.name, "Craig")
        XCTAssertEqual(store2.people.first?.email, "craig@example.com")
    }

    func testCentroidMergeVsAppend() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.15,
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let v1 = makeUnitVector(activeIndex: 0)
        let sample1 = [EnrollmentSample(embedding: v1, quality: 0.8, seconds: 2.0)]
        try store.enroll(name: "Philip", email: nil, samples: sample1, source: .live, isMe: false)
        XCTAssertEqual(store.people[0].centroids.count, 1)
        XCTAssertEqual(store.people[0].centroids[0].n, 1)

        // 아주 유사한 벡터 (거리 < 0.15) -> 기존 중심에 병합
        var vSimilar = v1
        vSimilar[1] = 0.05
        vSimilar = VoiceprintStore.l2Normalize(vSimilar)
        let sampleSimilar = [EnrollmentSample(embedding: vSimilar, quality: 0.9, seconds: 2.0)]
        try store.enroll(name: "Philip", email: nil, samples: sampleSimilar, source: .live, isMe: false)
        XCTAssertEqual(store.people[0].centroids.count, 1)
        XCTAssertEqual(store.people[0].centroids[0].n, 2)
        XCTAssertEqual(store.people[0].meetings, 2)

        // 완전히 다른 벡터 (거리 > 0.15) -> 새 중심 추가
        let vDifferent = makeUnitVector(activeIndex: 5)
        let sampleDifferent = [EnrollmentSample(embedding: vDifferent, quality: 0.8, seconds: 2.0)]
        try store.enroll(name: "Philip", email: nil, samples: sampleDifferent, source: .live, isMe: false)
        XCTAssertEqual(store.people[0].centroids.count, 2)
    }

    func testMaxCentroidsPruning() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.01,
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 2,
            conflictLimit: 3
        )

        for i in 0..<3 {
            let sample = [EnrollmentSample(embedding: makeUnitVector(activeIndex: i), quality: 0.8, seconds: 2.0)]
            try store.enroll(name: "Alice", email: nil, samples: sample, source: .live, isMe: false)
        }

        XCTAssertEqual(store.people[0].centroids.count, 2)
    }

    func testMatchingRules() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.35,
            margin: 0.10,
            mergeThreshold: 0.35,
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let vAlice = makeUnitVector(activeIndex: 0)
        let vBob = makeUnitVector(activeIndex: 10)

        try store.enroll(name: "Alice", email: nil, samples: [EnrollmentSample(embedding: vAlice, quality: 0.9, seconds: 2.0)], source: .live, isMe: false)
        try store.enroll(name: "Bob", email: nil, samples: [EnrollmentSample(embedding: vBob, quality: 0.9, seconds: 2.0)], source: .live, isMe: false)

        // 1. Alice와 아주 가까운 벡터
        var vNearAlice = vAlice
        vNearAlice[1] = 0.05
        vNearAlice = VoiceprintStore.l2Normalize(vNearAlice)

        let match1 = store.match(vNearAlice)
        XCTAssertTrue(match1.confident)
        XCTAssertEqual(match1.person?.name, "Alice")
        XCTAssertEqual(match1.candidates.count, 2)
        XCTAssertEqual(match1.candidates.first?.name, "Alice")

        // 2. 모호한 벡터 (Alice와 Bob 중간 거리)
        var vMid = [Float](repeating: 0, count: 256)
        vMid[0] = 0.707
        vMid[10] = 0.707
        let match2 = store.match(vMid)
        XCTAssertFalse(match2.confident)
        XCTAssertNil(match2.person)
    }

    func testConflictRecordingAndCentroidDeletion() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 2
        )

        let v = makeUnitVector(activeIndex: 1)
        let person = try store.enroll(name: "Charlie", email: nil, samples: [EnrollmentSample(embedding: v, quality: 0.9, seconds: 2.0)], source: .live, isMe: false)

        let conflict1 = try store.recordConflict(personID: person.id, embedding: v)
        XCTAssertFalse(conflict1)
        XCTAssertEqual(store.people[0].centroids.count, 1)
        XCTAssertEqual(store.people[0].centroids[0].conflicts, 1)

        let conflict2 = try store.recordConflict(personID: person.id, embedding: v)
        XCTAssertTrue(conflict2)
        XCTAssertEqual(store.people[0].centroids.count, 0)
    }

    func testMergePeople() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let p1 = try store.enroll(name: "Dan", email: "dan@test.com", samples: [EnrollmentSample(embedding: makeUnitVector(activeIndex: 1), quality: 0.9, seconds: 2.0)], source: .zoom, isMe: false)
        let p2 = try store.enroll(name: "Daniel", email: nil, samples: [EnrollmentSample(embedding: makeUnitVector(activeIndex: 2), quality: 0.9, seconds: 2.0)], source: .manual, isMe: false)

        try store.merge(p1.id, into: p2.id)

        XCTAssertEqual(store.people.count, 1)
        let merged = store.people[0]
        XCTAssertEqual(merged.name, "Daniel")
        XCTAssertTrue(merged.aliases.contains("Dan"))
        XCTAssertEqual(merged.email, "dan@test.com")
        XCTAssertEqual(merged.meetings, 2)
        XCTAssertTrue(merged.sources.contains(.zoom))
        XCTAssertTrue(merged.sources.contains(.manual))
    }

    func testRenameDeleteForgetAll() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let p = try store.enroll(name: "Eve", email: nil, samples: [EnrollmentSample(embedding: makeUnitVector(activeIndex: 3), quality: 0.9, seconds: 2.0)], source: .live, isMe: false)

        try store.rename(id: p.id, to: "Evelyn")
        XCTAssertEqual(store.people[0].name, "Evelyn")
        XCTAssertTrue(store.people[0].aliases.contains("Eve"))

        XCTAssertNotNil(store.person(named: "eve"))
        XCTAssertNotNil(store.person(named: "  EVELYN "))

        try store.delete(id: p.id)
        XCTAssertEqual(store.people.count, 0)

        try store.enroll(name: "Frank", email: nil, samples: [EnrollmentSample(embedding: makeUnitVector(activeIndex: 4), quality: 0.9, seconds: 2.0)], source: .live, isMe: false)
        XCTAssertEqual(store.people.count, 1)

        try store.forgetAll()
        XCTAssertEqual(store.people.count, 0)
    }

    func testCorruptFileRecovery() throws {
        let fileURL = tempDir.appendingPathComponent("voiceprints.json")
        let originalBytes = Data("CORRUPT_INVALID_JSON_CONTENT".utf8)
        try originalBytes.write(to: fileURL)

        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.isReadOnly)

        // Write corrupt file again to test reload() throwing corrupt error
        try originalBytes.write(to: fileURL)
        XCTAssertThrowsError(try store.reload()) { error in
            guard case VoiceprintError.corrupt = error else {
                return XCTFail("Expected corrupt error but got \(error)")
            }
        }
        XCTAssertTrue(store.isReadOnly)

        // 백업 corrupt 파일이 생성되었는지 확인
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let corruptBackups = files.filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertFalse(corruptBackups.isEmpty)
        if let firstBackup = corruptBackups.first {
            let backupBytes = try Data(contentsOf: firstBackup)
            XCTAssertEqual(backupBytes, originalBytes)
        }

        // reload() clears read-only since voiceprints.json was moved
        try store.reload()
        XCTAssertFalse(store.isReadOnly)

        // 이동 및 reload 성공 후에는 새로운 등록 가능
        store.thresholds = VoiceprintThresholds(minEnrollSeconds: 1.0, minQuality: 0.5)
        let sample = [EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 2.0)]
        let person = try store.enroll(name: "Grace", email: nil, samples: sample, source: .live, isMe: false)
        XCTAssertEqual(person.name, "Grace")
    }

    func testUnreadableFileSetsReadOnlyAndLeavesBytesUnchanged() throws {
        let fileURL = tempDir.appendingPathComponent("voiceprints.json")
        let originalBytes = Data("SOME_EXISTING_VALID_OR_INVALID_DATA".utf8)
        try originalBytes.write(to: fileURL)

        // chmod 000 (unreadable but file entry in dir is writable/deletable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }

        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.lastError)

        store.thresholds = VoiceprintThresholds(minEnrollSeconds: 1.0, minQuality: 0.5)
        let sample = [EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 2.0)]

        // enroll should throw .readOnly
        XCTAssertThrowsError(try store.enroll(name: "UnreadableTest", email: nil, samples: sample, source: .live, isMe: false)) { error in
            guard case VoiceprintError.readOnly = error else {
                return XCTFail("Expected readOnly error but got \(error)")
            }
        }

        // Restore permissions and verify bytes unchanged
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let bytesAfter = try Data(contentsOf: fileURL)
        XCTAssertEqual(bytesAfter, originalBytes)
    }

    func testForgetAllRemovesCorruptBackups() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(minEnrollSeconds: 1.0, minQuality: 0.5)

        let sample = [EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 2.0)]
        try store.enroll(name: "PersonA", email: nil, samples: sample, source: .live, isMe: false)
        XCTAssertEqual(store.people.count, 1)

        // Create corrupt backup files in rootURL
        let corruptBackup1 = tempDir.appendingPathComponent("voiceprints.json.corrupt-12345678")
        let corruptBackup2 = tempDir.appendingPathComponent("voiceprints.json.corrupt-12345679-1")
        try Data("corrupt1".utf8).write(to: corruptBackup1)
        try Data("corrupt2".utf8).write(to: corruptBackup2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptBackup1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptBackup2.path))

        try store.forgetAll()

        XCTAssertEqual(store.people.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptBackup1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptBackup2.path))
    }

    func testCorruptFileMoveFailureLeavesOriginalBytesAndSetsReadOnly() throws {
        let readOnlySubdir = tempDir.appendingPathComponent("readonly_test", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlySubdir, withIntermediateDirectories: true)
        let corruptFileURL = readOnlySubdir.appendingPathComponent("voiceprints.json")
        let originalBytes = Data("CORRUPTED_RAW_BYTES_DO_NOT_TOUCH".utf8)
        try originalBytes.write(to: corruptFileURL)

        // Make directory unwritable
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlySubdir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlySubdir.path)
        }

        let store = VoiceprintStore(rootURL: readOnlySubdir, defaults: testDefaults)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.lastError)

        // Mutating methods should throw VoiceprintError.readOnly
        let sample = [EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 2.0)]
        XCTAssertThrowsError(try store.enroll(name: "Heidi", email: nil, samples: sample, source: .live, isMe: false)) { error in
            guard case VoiceprintError.readOnly = error else {
                return XCTFail("Expected readOnly error but got \(error)")
            }
        }

        // Verify original corrupt file is untouched
        let remainingBytes = try Data(contentsOf: corruptFileURL)
        XCTAssertEqual(remainingBytes, originalBytes)
    }

    func testRollbackOnWriteFailure() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(minEnrollSeconds: 1.0, minQuality: 0.5)

        // Inject failing fileWriter
        store.fileWriter = { _, _ in
            throw NSError(domain: "test.io", code: -1, userInfo: [NSLocalizedDescriptionKey: "Injected disk write failure"])
        }

        let sample = [EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 0.9, seconds: 2.0)]
        XCTAssertThrowsError(try store.enroll(name: "Ian", email: nil, samples: sample, source: .live, isMe: false)) { error in
            guard case VoiceprintError.writeFailed = error else {
                return XCTFail("Expected writeFailed error but got \(error)")
            }
        }

        // Memory state should remain unchanged
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testThresholdsSetterValidation() {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        let originalMatch = store.thresholds.matchThreshold

        // Invalid: mergeThreshold > matchThreshold
        let invalid = VoiceprintThresholds(matchThreshold: 0.4, mergeThreshold: 0.8)
        store.thresholds = invalid

        // Old thresholds should be preserved, lastError set
        XCTAssertEqual(store.thresholds.matchThreshold, originalMatch)
        XCTAssertNotNil(store.lastError)

        // Valid update succeeds
        let valid = VoiceprintThresholds(matchThreshold: 0.7, margin: 0.1, mergeThreshold: 0.3)
        store.thresholds = valid
        XCTAssertEqual(store.thresholds.matchThreshold, 0.7, accuracy: 0.001)
        XCTAssertNil(store.lastError)
    }

    func testCentroidWeightProportions() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 1.0,
            minQuality: 0.4
        )

        // Sample 1: 20s, quality 0.9 -> weight = 18.0
        let v1 = makeUnitVector(dim: 4, activeIndex: 0) // [1, 0, 0, 0]
        let sample1 = [EnrollmentSample(embedding: v1, quality: 0.9, seconds: 20.0)]
        try store.enroll(name: "Jack", email: nil, samples: sample1, source: .live, isMe: false)

        XCTAssertEqual(store.people[0].centroids.count, 1)
        XCTAssertEqual(store.people[0].centroids[0].weight, 18.0, accuracy: 0.001)

        // Sample 2: three 2s quality 0.5 samples -> total weight = 3 * (2 * 0.5) = 3.0
        // Near v1 so it merges
        var v2 = [Float](repeating: 0, count: 4)
        v2[0] = 0.95
        v2[1] = 0.31225 // L2 norm ~ 1.0
        let sample2 = [
            EnrollmentSample(embedding: v2, quality: 0.5, seconds: 2.0),
            EnrollmentSample(embedding: v2, quality: 0.5, seconds: 2.0),
            EnrollmentSample(embedding: v2, quality: 0.5, seconds: 2.0)
        ]
        try store.enroll(name: "Jack", email: nil, samples: sample2, source: .live, isMe: false)

        XCTAssertEqual(store.people[0].centroids.count, 1)
        let mergedCentroid = store.people[0].centroids[0]
        XCTAssertEqual(mergedCentroid.n, 4)
        XCTAssertEqual(mergedCentroid.weight, 21.0, accuracy: 0.001)

        // Expected unnormalized sum: [18.0 * 1.0 + 3.0 * 0.95, 3.0 * 0.31225, 0, 0]
        // = [18.0 + 2.85, 0.93675, 0, 0] = [20.85, 0.93675, 0, 0]
        let expectedV0 = 20.85 / sqrt(20.85 * 20.85 + 0.93675 * 0.93675)
        XCTAssertEqual(mergedCentroid.v[0], Float(expectedV0), accuracy: 0.005)
    }

    func testMatchExcludingMe() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 1.0,
            minQuality: 0.5
        )

        // Query vector: [1, 0, 0, 0]
        let query: [Float] = [1.0, 0, 0, 0]

        // Me: dot = 0.90 -> distance = 0.10 (isMe: true)
        let meCentroid = [0.90, sqrt(1.0 - 0.90 * 0.90), 0, 0].map { Float($0) }
        try store.enroll(
            name: "Me",
            email: nil,
            samples: [EnrollmentSample(embedding: meCentroid, quality: 1.0, seconds: 20.0)],
            source: .live,
            isMe: true
        )

        // Alice: dot = 0.88 -> distance = 0.12 (isMe: false)
        let aliceCentroid = [0.88, sqrt(1.0 - 0.88 * 0.88), 0, 0].map { Float($0) }
        try store.enroll(
            name: "Alice",
            email: nil,
            samples: [EnrollmentSample(embedding: aliceCentroid, quality: 1.0, seconds: 20.0)],
            source: .live,
            isMe: false
        )

        // Bob: dot = 0.10 -> distance = 0.90 (isMe: false)
        let bobCentroid = [0.10, sqrt(1.0 - 0.10 * 0.10), 0, 0].map { Float($0) }
        try store.enroll(
            name: "Bob",
            email: nil,
            samples: [EnrollmentSample(embedding: bobCentroid, quality: 1.0, seconds: 20.0)],
            source: .live,
            isMe: false
        )

        // 1) When excludingMe is false: Me (0.10) and Alice (0.12) are compared.
        // Difference 0.12 - 0.10 = 0.02 < margin (0.08) -> confident is false.
        let matchWithMe = store.match(query, excludingMe: false)
        XCTAssertFalse(matchWithMe.confident)
        XCTAssertNil(matchWithMe.person)
        XCTAssertEqual(matchWithMe.d1, 0.10, accuracy: 0.001)
        XCTAssertEqual(matchWithMe.d2, 0.12, accuracy: 0.001)

        // 2) When excludingMe is true: Me is filtered BEFORE scoring.
        // Alice (0.12) and Bob (0.90) are compared.
        // Difference 0.90 - 0.12 = 0.78 >= margin (0.08) -> confident is true, Alice matched!
        let matchExcludingMe = store.match(query, excludingMe: true)
        XCTAssertTrue(matchExcludingMe.confident)
        XCTAssertEqual(matchExcludingMe.person?.name, "Alice")
        XCTAssertEqual(matchExcludingMe.d1, 0.12, accuracy: 0.001)
        XCTAssertEqual(matchExcludingMe.d2, 0.90, accuracy: 0.001)
        XCTAssertEqual(matchExcludingMe.candidates.map(\.name), ["Alice", "Bob"])
    }

    func testEnrollNormalizesInputEmbeddingsAndSkipsZeroVectors() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.15,
            minEnrollSeconds: 1.0,
            minQuality: 0.5
        )

        // 1) Test same direction with norm 1 vs norm 10
        let vNorm1: [Float] = [1.0, 0.0, 0.0, 0.0]
        let vNorm10: [Float] = [10.0, 0.0, 0.0, 0.0]

        let p1 = try store.enroll(
            name: "PersonNorm1",
            email: nil,
            samples: [EnrollmentSample(embedding: vNorm1, quality: 0.8, seconds: 5.0)],
            source: .live,
            isMe: false
        )

        let p2 = try store.enroll(
            name: "PersonNorm10",
            email: nil,
            samples: [EnrollmentSample(embedding: vNorm10, quality: 0.8, seconds: 5.0)],
            source: .live,
            isMe: false
        )

        XCTAssertEqual(p1.centroids[0].v, p2.centroids[0].v)
        XCTAssertEqual(p1.centroids[0].v[0], 1.0, accuracy: 0.0001)

        // 2) Test zero vector skipped
        let zeroVec: [Float] = [0.0, 0.0, 0.0, 0.0]
        let p3 = try store.enroll(
            name: "PersonWithZeroSample",
            email: nil,
            samples: [
                EnrollmentSample(embedding: vNorm1, quality: 0.8, seconds: 5.0),
                EnrollmentSample(embedding: zeroVec, quality: 0.8, seconds: 5.0)
            ],
            source: .live,
            isMe: false
        )

        XCTAssertEqual(p3.centroids[0].v[0], 1.0, accuracy: 0.0001)
    }

    func testMatchNormalizesStoredCentroidWhenNormDeviates() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.15,
            minEnrollSeconds: 1.0,
            minQuality: 0.5
        )

        // Manually inject a person with a non-unit centroid (norm = 2.0)
        let unnormalizedCentroid = VoiceCentroid(
            v: [2.0, 0.0, 0.0, 0.0],
            n: 1,
            quality: 0.9,
            updated: Date(),
            conflicts: 0,
            weight: 10.0
        )
        let person = Person(
            id: "p_unnorm",
            name: "David",
            centroids: [unnormalizedCentroid],
            meetings: 1,
            sources: [.live]
        )
        try store.fileWriter(try JSONEncoder().encode(VoiceprintDatabase(version: 1, people: [person])), tempDir.appendingPathComponent("voiceprints.json"))
        try store.reload()

        let query: [Float] = [1.0, 0.0, 0.0, 0.0]
        let match = store.match(query)
        XCTAssertTrue(match.confident)
        XCTAssertEqual(match.person?.name, "David")
        XCTAssertEqual(match.d1, 0.0, accuracy: 0.001)
    }

    // MARK: - DD4: Match Rejects Zero and NaN Query Embeddings

    func testMatchRejectsZeroAndNaNQueryVectors() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 2.0, // High threshold
            margin: 0.0,
            minEnrollSeconds: 1.0,
            minQuality: 0.5
        )

        _ = try store.enroll(
            name: "Alice",
            email: nil,
            samples: [EnrollmentSample(embedding: [1.0, 0.0, 0.0, 0.0], quality: 0.9, seconds: 5.0)],
            source: .live,
            isMe: false
        )

        // Zero vector query
        let zeroQuery: [Float] = [0.0, 0.0, 0.0, 0.0]
        let zeroMatch = store.match(zeroQuery)
        XCTAssertFalse(zeroMatch.confident, "Zero vector query must not match")
        XCTAssertTrue(zeroMatch.candidates.isEmpty, "Candidates must be empty for zero vector query")

        // NaN vector query
        let nanQuery: [Float] = [Float.nan, 0.0, 0.0, 0.0]
        let nanMatch = store.match(nanQuery)
        XCTAssertFalse(nanMatch.confident, "NaN vector query must not match")
        XCTAssertTrue(nanMatch.candidates.isEmpty, "Candidates must be empty for NaN vector query")
    }

    // MARK: - DD5: Merge Clamping Centroids to min(maxCentroids, 5)

    func testMergeTwoPersonsWithFiveCentroidsClampsToAtMostFive() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.01, // Very low merge threshold so distinct centroids don't merge
            minEnrollSeconds: 1.0,
            minQuality: 0.5,
            maxCentroids: 5
        )

        // Create Person 1 with 5 distinct orthogonal centroids
        var p1Centroids: [VoiceCentroid] = []
        for i in 0..<5 {
            var v = [Float](repeating: 0, count: 10)
            v[i] = 1.0
            p1Centroids.append(VoiceCentroid(v: v, n: 1, quality: 0.9, updated: Date(timeIntervalSince1970: Double(i)), conflicts: 0, weight: 1.0))
        }
        let person1 = Person(id: "p1", name: "Alice", centroids: p1Centroids, meetings: 1, sources: [.live])

        // Create Person 2 with 5 distinct orthogonal centroids (different indices)
        var p2Centroids: [VoiceCentroid] = []
        for i in 5..<10 {
            var v = [Float](repeating: 0, count: 10)
            v[i] = 1.0
            p2Centroids.append(VoiceCentroid(v: v, n: 1, quality: 0.9, updated: Date(timeIntervalSince1970: Double(i)), conflicts: 0, weight: 1.0))
        }
        let person2 = Person(id: "p2", name: "AliceAlias", centroids: p2Centroids, meetings: 1, sources: [.live])

        try store.fileWriter(try JSONEncoder().encode(VoiceprintDatabase(version: 1, people: [person1, person2])), tempDir.appendingPathComponent("voiceprints.json"))
        try store.reload()

        XCTAssertEqual(store.people.count, 2)
        XCTAssertEqual(store.people[0].centroids.count, 5)
        XCTAssertEqual(store.people[1].centroids.count, 5)

        // Merge p2 into p1
        try store.merge("p2", into: "p1")

        XCTAssertEqual(store.people.count, 1)
        let merged = store.people[0]
        XCTAssertEqual(merged.id, "p1")
        XCTAssertLessThanOrEqual(merged.centroids.count, 5, "Merged person centroids must be clamped to at most 5")
    }

    // MARK: - R10-4 Conflict Counter Preservation Tests (T11 & T12)

    func testEnrollMergePreservesConflicts() throws {
        // T11: conflictLimit 3; enroll Alice once; recordConflict twice against that centroid (count 2);
        // enroll Alice again with an embedding within mergeThreshold (same direction) ->
        // centroid count still 1 and conflicts == 2; recordConflict once more -> centroid removed (didDelete == true).
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 5.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let embedding1 = makeUnitVector(activeIndex: 0)
        let sample1 = [EnrollmentSample(embedding: embedding1, quality: 0.9, seconds: 10.0)]
        let person = try store.enroll(name: "Alice", email: nil, samples: sample1, source: .live, isMe: false)

        XCTAssertEqual(person.centroids.count, 1)
        XCTAssertEqual(person.centroids[0].conflicts, 0)

        // Record conflict twice
        let didDelete1 = try store.recordConflict(personID: person.id, embedding: embedding1)
        XCTAssertFalse(didDelete1)
        let didDelete2 = try store.recordConflict(personID: person.id, embedding: embedding1)
        XCTAssertFalse(didDelete2)

        let reloadedPerson1 = try XCTUnwrap(store.person(named: "Alice"))
        XCTAssertEqual(reloadedPerson1.centroids.count, 1)
        XCTAssertEqual(reloadedPerson1.centroids[0].conflicts, 2)

        // Enroll Alice again with embedding in same direction (within mergeThreshold)
        let sample2 = [EnrollmentSample(embedding: embedding1, quality: 0.9, seconds: 10.0)]
        let reEnrolled = try store.enroll(name: "Alice", email: nil, samples: sample2, source: .live, isMe: false)

        XCTAssertEqual(reEnrolled.centroids.count, 1)
        XCTAssertEqual(reEnrolled.centroids[0].conflicts, 2, "Conflicts count must be preserved across enroll merge")

        // Record conflict once more -> reaches conflictLimit 3 and centroid is removed
        let didDelete3 = try store.recordConflict(personID: person.id, embedding: embedding1)
        XCTAssertTrue(didDelete3, "Centroid must be removed on 3rd conflict")

        let reloadedPerson2 = try XCTUnwrap(store.person(named: "Alice"))
        XCTAssertEqual(reloadedPerson2.centroids.count, 0)
    }

    func testPersonMergePreservesMaxConflicts() throws {
        // T12: two persons whose nearest centroids merge (same direction), conflicts 2 and 1 -> merged centroid conflicts == 2.
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 5.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let vec = makeUnitVector(activeIndex: 1)
        let c1 = VoiceCentroid(v: vec, n: 1, quality: 0.9, updated: Date(), conflicts: 2, weight: 1.0)
        let p1 = Person(id: "p1", name: "Alice", centroids: [c1], meetings: 1, sources: [.live])

        let c2 = VoiceCentroid(v: vec, n: 1, quality: 0.9, updated: Date(), conflicts: 1, weight: 1.0)
        let p2 = Person(id: "p2", name: "AliceAlias", centroids: [c2], meetings: 1, sources: [.live])

        try store.fileWriter(try JSONEncoder().encode(VoiceprintDatabase(version: 1, people: [p1, p2])), tempDir.appendingPathComponent("voiceprints.json"))
        try store.reload()

        try store.merge("p2", into: "p1")

        let mergedPerson = try XCTUnwrap(store.person(named: "Alice"))
        XCTAssertEqual(mergedPerson.centroids.count, 1)
        XCTAssertEqual(mergedPerson.centroids[0].conflicts, 2, "Merged centroid conflicts must be max(2, 1) = 2")
    }

    func testEnrollMeIfAbsentIdempotent_H1a() throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 5.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let sample1 = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 1.0, seconds: 10.0)
        ]
        let sample2 = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 1), quality: 1.0, seconds: 10.0)
        ]

        let first = try store.enrollMeIfAbsent(name: "Me", samples: sample1, source: .live)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.isMe, true)
        XCTAssertEqual(first?.name, "Me")

        let second = try store.enrollMeIfAbsent(name: "MeAgain", samples: sample2, source: .live)
        XCTAssertNil(second)

        XCTAssertEqual(store.people.filter(\.isMe).count, 1)

        let diskData = try Data(contentsOf: tempDir.appendingPathComponent("voiceprints.json"))
        let diskDB = try JSONDecoder().decode(VoiceprintDatabase.self, from: diskData)
        XCTAssertEqual(diskDB.people.filter(\.isMe).count, 1)
        XCTAssertEqual(diskDB.people.first(where: { $0.isMe })?.name, "Me")
    }

    func testEnrollMeIfAbsentRaceTwoGatedTasks_H1b() async throws {
        let store = VoiceprintStore(rootURL: tempDir, defaults: testDefaults)
        store.thresholds = VoiceprintThresholds(
            matchThreshold: 0.65,
            margin: 0.08,
            mergeThreshold: 0.35,
            minEnrollSeconds: 5.0,
            minQuality: 0.5,
            maxCentroids: 5,
            conflictLimit: 3
        )

        let sample1 = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 0), quality: 1.0, seconds: 10.0)
        ]
        let sample2 = [
            EnrollmentSample(embedding: makeUnitVector(activeIndex: 1), quality: 1.0, seconds: 10.0)
        ]

        let gate1 = AsyncTestGate()
        let gate2 = AsyncTestGate()

        let preCheck1 = store.people.contains { $0.isMe } == false
        XCTAssertTrue(preCheck1)

        let preCheck2 = store.people.contains { $0.isMe } == false
        XCTAssertTrue(preCheck2)

        let task1 = Task { @MainActor in
            _ = preCheck1
            await gate1.wait()
            return try store.enrollMeIfAbsent(name: "MeTask1", samples: sample1, source: .live)
        }

        let task2 = Task { @MainActor in
            _ = preCheck2
            await gate2.wait()
            return try store.enrollMeIfAbsent(name: "MeTask2", samples: sample2, source: .live)
        }

        await gate1.open()
        let res1 = try await task1.value

        await gate2.open()
        let res2 = try await task2.value

        XCTAssertNotNil(res1)
        XCTAssertEqual(res1?.isMe, true)
        XCTAssertEqual(res1?.name, "MeTask1")

        XCTAssertNil(res2)

        XCTAssertEqual(store.people.filter(\.isMe).count, 1)
        XCTAssertEqual(store.people.first(where: { $0.isMe })?.name, "MeTask1")

        let diskData = try Data(contentsOf: tempDir.appendingPathComponent("voiceprints.json"))
        let diskDB = try JSONDecoder().decode(VoiceprintDatabase.self, from: diskData)
        XCTAssertEqual(diskDB.people.filter(\.isMe).count, 1)
        XCTAssertEqual(diskDB.people.first(where: { $0.isMe })?.name, "MeTask1")
    }
}

private actor AsyncTestGate {
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
