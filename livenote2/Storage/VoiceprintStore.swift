import Foundation
import Accelerate

/// 성문 데이터베이스 파일 영속성 및 화자 인식/등록 관리 저장소
@MainActor
final class VoiceprintStore: VoiceprintStoring {

    private let rootURL: URL
    private let fileURL: URL
    private let defaults: UserDefaults

    private(set) var people: [Person] = []
    private(set) var lastError: String?
    private(set) var isReadOnly: Bool = false

    /// 디스크 쓰기 주입용 (테스트에서 실패 주입 가능)
    var fileWriter: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }

    private var _thresholds: VoiceprintThresholds

    var thresholds: VoiceprintThresholds {
        get { _thresholds }
        set {
            let errors = newValue.validate()
            if !errors.isEmpty {
                let msg = "Invalid thresholds: \(errors.joined(separator: ", "))"
                self.lastError = msg
                AppLog.write("voice", msg)
                return
            }
            _thresholds = newValue
            do {
                try _thresholds.save(defaults: defaults)
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
                AppLog.write("voice", "Failed to save thresholds: \(error.localizedDescription)")
            }
        }
    }

    init(rootURL: URL, defaults: UserDefaults = .standard) {
        self.rootURL = rootURL
        self.fileURL = rootURL.appendingPathComponent("voiceprints.json")
        self.defaults = defaults
        self._thresholds = VoiceprintThresholds.load(defaults: defaults)

        do {
            try reload()
        } catch {
            self.isReadOnly = true
            self.lastError = error.localizedDescription
            AppLog.write("voice", "Failed to load voiceprints: \(error.localizedDescription)")
        }
    }

    convenience init(defaults: UserDefaults = .standard) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let root = documents.appendingPathComponent("LiveNote", isDirectory: true)
        self.init(rootURL: root, defaults: defaults)
    }

    /// 파일로부터 성문 데이터베이스를 다시 로드
    func reload() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.people = []
            self.isReadOnly = false
            self.lastError = nil
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            self.people = []
            self.isReadOnly = true
            self.lastError = error.localizedDescription
            AppLog.write("voice", "Unreadable voiceprints.json: \(error.localizedDescription)")
            throw VoiceprintError.unreadable(error.localizedDescription)
        }

        do {
            let db = try JSONDecoder().decode(VoiceprintDatabase.self, from: data)
            self.people = db.people
            self.isReadOnly = false
            self.lastError = nil
        } catch {
            let baseTimestamp = Int(Date().timeIntervalSince1970)
            var corruptURL = rootURL.appendingPathComponent("voiceprints.json.corrupt-\(baseTimestamp)")
            var counter = 1
            while FileManager.default.fileExists(atPath: corruptURL.path) {
                corruptURL = rootURL.appendingPathComponent("voiceprints.json.corrupt-\(baseTimestamp)-\(counter)")
                counter += 1
            }

            do {
                try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            } catch let moveError {
                self.people = []
                self.isReadOnly = true
                let msg = "Failed to move corrupted voiceprints.json: \(moveError.localizedDescription) (original decode error: \(error.localizedDescription))"
                self.lastError = msg
                AppLog.write("voice", msg)
                throw VoiceprintError.readOnly(msg)
            }

            self.people = []
            self.isReadOnly = true
            self.lastError = error.localizedDescription
            AppLog.write("voice", "Corrupted voiceprints.json moved to \(corruptURL.lastPathComponent): \(error.localizedDescription)")
            throw VoiceprintError.corrupt(error.localizedDescription)
        }
    }

    /// 후보 상태를 디스크에 원자적으로 저장
    private func save(_ candidate: [Person]) throws {
        let db = VoiceprintDatabase(version: 1, people: candidate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(db)
            try fileWriter(data, fileURL)
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            AppLog.write("voice", "Failed to write voiceprints.json: \(error.localizedDescription)")
            throw VoiceprintError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - 코사인 거리 & 벡터 연산 (vDSP)

    /// L2 정규화된 두 벡터 간의 코사인 거리 (1 - dot_product)
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return max(0, 1.0 - dot)
    }

    /// 벡터 L2 정규화
    static func l2Normalize(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        guard v.allSatisfy({ $0.isFinite }) else { return [Float](repeating: 0, count: v.count) }
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm.isFinite, norm > 1e-7 else { return [Float](repeating: 0, count: v.count) }
        var result = [Float](repeating: 0, count: v.count)
        var scale = 1.0 / norm
        vDSP_vsmul(v, 1, &scale, &result, 1, vDSP_Length(v.count))
        return result
    }

    /// 벡터가 유한한 단위 벡터(L2 norm 1.0 ± 1e-3)인지 확인
    static func isFiniteUnitVector(_ v: [Float]) -> Bool {
        guard !v.isEmpty, v.allSatisfy({ $0.isFinite }) else { return false }
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm.isFinite else { return false }
        return abs(norm - 1.0) <= 1e-3
    }

    private static var didLogInvalidCentroid = false
    private static var didLogUnnormalizedCentroid = false

    // MARK: - VoiceprintStoring 인터페이스 구현

    /// 임베딩과 가장 가까운 등록 화자 매칭 (excludingMe 옵션 지원)
    func match(_ embedding: [Float], excludingMe: Bool) -> VoiceMatch {
        let targetPeople = excludingMe ? people.filter { !$0.isMe } : people
        guard !targetPeople.isEmpty, !embedding.isEmpty else {
            return VoiceMatch(person: nil, candidates: [], d1: .infinity, d2: .infinity, confident: false)
        }

        let normalizedEmbedding = Self.l2Normalize(embedding)
        guard Self.isFiniteUnitVector(normalizedEmbedding) else {
            return VoiceMatch(person: nil, candidates: [], d1: .infinity, d2: .infinity, confident: false)
        }

        // 각 person별 최소 거리 계산
        var scoredPeople: [(person: Person, distance: Float)] = []
        for person in targetPeople {
            var minPersonDist: Float = .infinity
            for centroid in person.centroids {
                var centroidVec = centroid.v
                guard centroidVec.count == normalizedEmbedding.count else { continue }
                guard centroidVec.allSatisfy({ $0.isFinite }) else {
                    if !Self.didLogInvalidCentroid {
                        Self.didLogInvalidCentroid = true
                        AppLog.write("voice", "Stored centroid contains non-finite values; skipped")
                    }
                    continue
                }

                var sumSquares: Float = 0
                vDSP_svesq(centroidVec, 1, &sumSquares, vDSP_Length(centroidVec.count))
                let norm = sqrt(sumSquares)
                guard norm.isFinite, norm > 1e-7 else {
                    if !Self.didLogInvalidCentroid {
                        Self.didLogInvalidCentroid = true
                        AppLog.write("voice", "Stored centroid has non-positive norm; skipped")
                    }
                    continue
                }

                if abs(norm - 1.0) > 1e-3 {
                    if !Self.didLogUnnormalizedCentroid {
                        Self.didLogUnnormalizedCentroid = true
                        AppLog.write("voice", "Stored centroid norm deviated from 1 by \(norm); normalized before scoring")
                    }
                    var scale = 1.0 / norm
                    var normalizedV = [Float](repeating: 0, count: centroidVec.count)
                    vDSP_vsmul(centroidVec, 1, &scale, &normalizedV, 1, vDSP_Length(centroidVec.count))
                    centroidVec = normalizedV
                }

                guard Self.isFiniteUnitVector(centroidVec) else {
                    if !Self.didLogInvalidCentroid {
                        Self.didLogInvalidCentroid = true
                        AppLog.write("voice", "Stored centroid is not a finite unit vector; skipped")
                    }
                    continue
                }

                let d = Self.cosineDistance(normalizedEmbedding, centroidVec)
                if d < minPersonDist {
                    minPersonDist = d
                }
            }
            if minPersonDist < .infinity {
                scoredPeople.append((person: person, distance: minPersonDist))
            }
        }

        guard !scoredPeople.isEmpty else {
            return VoiceMatch(person: nil, candidates: [], d1: .infinity, d2: .infinity, confident: false)
        }

        scoredPeople.sort { $0.distance < $1.distance }

        let d1 = scoredPeople[0].distance
        let d2 = scoredPeople.count > 1 ? scoredPeople[1].distance : .infinity
        let candidates = Array(scoredPeople.prefix(2).map(\.person))

        let isConfident = d1 <= thresholds.matchThreshold && (d2 - d1) >= thresholds.margin
        let matchedPerson = isConfident ? scoredPeople[0].person : nil

        return VoiceMatch(
            person: matchedPerson,
            candidates: candidates,
            d1: d1,
            d2: d2,
            confident: isConfident
        )
    }

    /// 임베딩과 가장 가까운 등록 화자 매칭 (기본값: excludingMe = false)
    func match(_ embedding: [Float]) -> VoiceMatch {
        match(embedding, excludingMe: false)
    }

    /// 본인(isMe) 성문 등록: 이미 isMe 프로필이 존재하면 아무 변경 없이 nil 반환, 부재 시 신규 등록 후 Person 반환
    @discardableResult
    func enrollMeIfAbsent(
        name: String,
        samples: [EnrollmentSample],
        source: VoiceSource
    ) throws -> Person? {
        if people.contains(where: { $0.isMe }) {
            return nil
        }
        return try enroll(
            name: name,
            email: nil,
            samples: samples,
            source: source,
            isMe: true
        )
    }

    /// 이름(+email)으로 기존 person을 찾거나 새로 만들고 중심을 갱신
    @discardableResult
    func enroll(
        name: String,
        email: String?,
        samples: [EnrollmentSample],
        source: VoiceSource,
        isMe: Bool
    ) throws -> Person {
        if isReadOnly {
            throw VoiceprintError.readOnly(lastError ?? "Voiceprint store is read-only")
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw VoiceprintError.personNotFound("Name cannot be empty")
        }

        // 유효 샘플 선별 및 임베딩 L2 정규화
        struct ValidSample {
            let normalizedEmbedding: [Float]
            let quality: Float
            let seconds: Double
        }

        var validSamples: [ValidSample] = []
        var expectedDim: Int? = nil

        for sample in samples {
            guard sample.seconds.isFinite, sample.seconds > 0 else { continue }
            guard sample.quality.isFinite, (0.0...1.0).contains(sample.quality) else { continue }
            guard !sample.embedding.isEmpty, sample.embedding.allSatisfy({ $0.isFinite }) else { continue }

            let dim = sample.embedding.count
            var sumSq: Float = 0
            vDSP_svesq(sample.embedding, 1, &sumSq, vDSP_Length(dim))
            let norm = sqrt(sumSq)
            guard norm.isFinite, norm > 1e-7 else { continue }

            if let exp = expectedDim {
                guard dim == exp else {
                    throw VoiceprintError.sameDimensionRequired
                }
            } else {
                expectedDim = dim
            }

            var normSample = [Float](repeating: 0, count: dim)
            var scale = 1.0 / norm
            vDSP_vsmul(sample.embedding, 1, &scale, &normSample, 1, vDSP_Length(dim))

            validSamples.append(ValidSample(
                normalizedEmbedding: normSample,
                quality: sample.quality,
                seconds: sample.seconds
            ))
        }

        guard !validSamples.isEmpty else {
            throw VoiceprintError.noValidSamples
        }

        guard let dim = expectedDim, dim > 0 else {
            throw VoiceprintError.sameDimensionRequired
        }

        let totalSeconds = validSamples.reduce(0.0) { $0 + $1.seconds }
        guard totalSeconds >= thresholds.minEnrollSeconds else {
            throw VoiceprintError.tooLittleAudio(seconds: totalSeconds)
        }

        let meanQuality = validSamples.reduce(0.0) { $0 + $1.quality } / Float(validSamples.count)
        guard meanQuality >= thresholds.minQuality else {
            throw VoiceprintError.lowQuality(meanQuality)
        }

        // 가중치 = 품질 * 초의 합
        var totalWeight: Float = 0
        var weightedSum = [Float](repeating: 0, count: dim)

        for sample in validSamples {
            let w = sample.quality * Float(sample.seconds)
            totalWeight += w
            for i in 0..<dim {
                weightedSum[i] += sample.normalizedEmbedding[i] * w
            }
        }

        guard totalWeight > 0 else {
            throw VoiceprintError.lowQuality(0)
        }

        let newEmbedding = Self.l2Normalize(weightedSum)
        guard newEmbedding.contains(where: { $0 != 0 }) else {
            throw VoiceprintError.lowQuality(0)
        }

        let newCentroid = VoiceCentroid(
            v: newEmbedding,
            n: validSamples.count,
            quality: meanQuality,
            updated: Date(),
            conflicts: 0,
            weight: totalWeight
        )

        var candidatePeople = people
        let targetPerson: Person

        if let existingIdx = candidatePeople.firstIndex(where: { p in
            if p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedName.lowercased() {
                return true
            }
            return p.aliases.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedName.lowercased() }
        }) {
            var updated = candidatePeople[existingIdx]

            // 별칭 및 이메일 갱신
            if updated.name.lowercased() == trimmedName.lowercased() && updated.name != trimmedName {
                if !updated.aliases.contains(trimmedName) {
                    updated.aliases.append(trimmedName)
                }
            } else if updated.name != trimmedName && !updated.aliases.contains(trimmedName) {
                updated.aliases.append(trimmedName)
            }

            if let email = email, updated.email == nil {
                updated.email = email
            }

            if isMe {
                updated.isMe = true
            }

            if !updated.sources.contains(source) {
                updated.sources.append(source)
            }

            updated.meetings += 1
            updated.lastSeen = Date()

            // 중심 병합 또는 추가
            if updated.centroids.isEmpty {
                updated.centroids = [newCentroid]
            } else {
                var minCentroidDist: Float = .infinity
                var nearestIdx = 0

                for (idx, centroid) in updated.centroids.enumerated() {
                    let d = Self.cosineDistance(newEmbedding, centroid.v)
                    if d < minCentroidDist {
                        minCentroidDist = d
                        nearestIdx = idx
                    }
                }

                if minCentroidDist < thresholds.mergeThreshold {
                    // 가중 평균 병합
                    let existingCentroid = updated.centroids[nearestIdx]
                    let mergedN = existingCentroid.n + newCentroid.n
                    let w1 = existingCentroid.weight
                    let w2 = newCentroid.weight
                    let mergedWeight = w1 + w2

                    var mergedVec = [Float](repeating: 0, count: dim)
                    for i in 0..<dim {
                        mergedVec[i] = existingCentroid.v[i] * w1 + newEmbedding[i] * w2
                    }
                    let normalizedMerged = Self.l2Normalize(mergedVec)
                    let mergedQuality = (existingCentroid.quality * w1 + meanQuality * w2) / max(1e-6, mergedWeight)

                    // 정상 등록은 충돌 증거를 지우지 않는다
                    updated.centroids[nearestIdx] = VoiceCentroid(
                        v: normalizedMerged,
                        n: mergedN,
                        quality: mergedQuality,
                        updated: Date(),
                        conflicts: existingCentroid.conflicts,
                        weight: mergedWeight
                    )
                } else {
                    // 새 중심 추가
                    updated.centroids.append(newCentroid)
                    let maxAllowed = min(thresholds.maxCentroids, 5)
                    if updated.centroids.count > maxAllowed {
                        // 가장 오래된 중심 제거
                        updated.centroids.sort { $0.updated < $1.updated }
                        while updated.centroids.count > maxAllowed {
                            updated.centroids.removeFirst()
                        }
                    }
                }
            }

            candidatePeople[existingIdx] = updated
            targetPerson = updated
        } else {
            // 신규 인물 생성
            let newPerson = Person(
                id: UUID().uuidString,
                name: trimmedName,
                aliases: [],
                email: email,
                centroids: [newCentroid],
                meetings: 1,
                lastSeen: Date(),
                sources: [source],
                isMe: isMe
            )
            candidatePeople.append(newPerson)
            targetPerson = newPerson
        }

        try save(candidatePeople)
        self.people = candidatePeople
        return targetPerson
    }

    /// 성문 이름 != 확정 이름 충돌 기록: conflictLimit 도달 시 해당 중심 삭제
    @discardableResult
    func recordConflict(personID: String, embedding: [Float]) throws -> Bool {
        if isReadOnly {
            throw VoiceprintError.readOnly(lastError ?? "Voiceprint store is read-only")
        }

        guard let pIndex = people.firstIndex(where: { $0.id == personID }) else {
            throw VoiceprintError.personNotFound(personID)
        }

        var candidatePeople = people
        var person = candidatePeople[pIndex]
        guard !person.centroids.isEmpty, !embedding.isEmpty else {
            return false
        }

        let normalized = Self.l2Normalize(embedding)
        var nearestIdx = 0
        var minDistance: Float = .infinity

        for (idx, centroid) in person.centroids.enumerated() {
            let d = Self.cosineDistance(normalized, centroid.v)
            if d < minDistance {
                minDistance = d
                nearestIdx = idx
            }
        }

        person.centroids[nearestIdx].conflicts += 1
        var didDelete = false

        if person.centroids[nearestIdx].conflicts >= thresholds.conflictLimit {
            person.centroids.remove(at: nearestIdx)
            didDelete = true
            AppLog.write("voice", "Centroid for person \(person.name) reached conflict limit (\(thresholds.conflictLimit)) and was removed")
        }

        candidatePeople[pIndex] = person
        try save(candidatePeople)
        self.people = candidatePeople
        return didDelete
    }

    /// 두 인물 병합
    func merge(_ sourceID: String, into targetID: String) throws {
        if isReadOnly {
            throw VoiceprintError.readOnly(lastError ?? "Voiceprint store is read-only")
        }

        guard sourceID != targetID else { return }

        guard let sIdx = people.firstIndex(where: { $0.id == sourceID }) else {
            throw VoiceprintError.personNotFound(sourceID)
        }
        guard let tIdx = people.firstIndex(where: { $0.id == targetID }) else {
            throw VoiceprintError.personNotFound(targetID)
        }

        var candidatePeople = people
        let source = candidatePeople[sIdx]
        var target = candidatePeople[tIdx]

        if source.name != target.name && !target.aliases.contains(source.name) {
            target.aliases.append(source.name)
        }
        for alias in source.aliases {
            if !target.aliases.contains(alias) && alias != target.name {
                target.aliases.append(alias)
            }
        }

        if target.email == nil {
            target.email = source.email
        }

        target.meetings += source.meetings
        if let sLast = source.lastSeen {
            if let tLast = target.lastSeen {
                target.lastSeen = max(sLast, tLast)
            } else {
                target.lastSeen = sLast
            }
        }

        target.isMe = target.isMe || source.isMe
        for src in source.sources {
            if !target.sources.contains(src) {
                target.sources.append(src)
            }
        }

        // 중심 병합
        for sCentroid in source.centroids {
            var minD: Float = .infinity
            var nearestIdx = 0
            for (idx, tCentroid) in target.centroids.enumerated() {
                let d = Self.cosineDistance(sCentroid.v, tCentroid.v)
                if d < minD {
                    minD = d
                    nearestIdx = idx
                }
            }

            if minD < thresholds.mergeThreshold && !target.centroids.isEmpty {
                let existing = target.centroids[nearestIdx]
                let mergedN = existing.n + sCentroid.n
                let w1 = existing.weight
                let w2 = sCentroid.weight
                let mergedWeight = w1 + w2
                let dim = existing.v.count

                var mergedVec = [Float](repeating: 0, count: dim)
                for i in 0..<dim {
                    mergedVec[i] = existing.v[i] * w1 + sCentroid.v[i] * w2
                }
                let normalized = Self.l2Normalize(mergedVec)
                let mergedQuality = (existing.quality * w1 + sCentroid.quality * w2) / max(1e-6, mergedWeight)
                target.centroids[nearestIdx] = VoiceCentroid(
                    v: normalized,
                    n: mergedN,
                    quality: mergedQuality,
                    updated: max(existing.updated, sCentroid.updated),
                    conflicts: max(existing.conflicts, sCentroid.conflicts),
                    weight: mergedWeight
                )
            } else {
                target.centroids.append(sCentroid)
            }
        }

        let maxAllowed = min(thresholds.maxCentroids, 5)
        if target.centroids.count > maxAllowed {
            target.centroids.sort { $0.updated < $1.updated }
            while target.centroids.count > maxAllowed {
                target.centroids.removeFirst()
            }
        }

        // 갱신 및 소스 제거
        candidatePeople[tIdx] = target
        candidatePeople.removeAll { $0.id == sourceID }

        try save(candidatePeople)
        self.people = candidatePeople
    }

    /// 이름 변경
    func rename(id: String, to name: String) throws {
        if isReadOnly {
            throw VoiceprintError.readOnly(lastError ?? "Voiceprint store is read-only")
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceprintError.personNotFound("Name cannot be empty")
        }

        guard let idx = people.firstIndex(where: { $0.id == id }) else {
            throw VoiceprintError.personNotFound(id)
        }

        var candidatePeople = people
        if candidatePeople[idx].name != trimmed {
            if !candidatePeople[idx].aliases.contains(candidatePeople[idx].name) {
                candidatePeople[idx].aliases.append(candidatePeople[idx].name)
            }
            candidatePeople[idx].name = trimmed
        }

        try save(candidatePeople)
        self.people = candidatePeople
    }

    /// 인물 삭제
    func delete(id: String) throws {
        if isReadOnly {
            throw VoiceprintError.readOnly(lastError ?? "Voiceprint store is read-only")
        }

        guard let idx = people.firstIndex(where: { $0.id == id }) else {
            throw VoiceprintError.personNotFound(id)
        }

        var candidatePeople = people
        candidatePeople.remove(at: idx)
        try save(candidatePeople)
        self.people = candidatePeople
    }

    /// 전체 성문 데이터 삭제 및 손상 백업 파일 정리
    func forgetAll() throws {
        if isReadOnly {
            throw VoiceprintError.readOnly(lastError ?? "Voiceprint store is read-only")
        }

        let candidatePeople: [Person] = []
        try save(candidatePeople)
        self.people = candidatePeople

        do {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                let items = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                for item in items {
                    if item.lastPathComponent.hasPrefix("voiceprints.json.corrupt-") {
                        try FileManager.default.removeItem(at: item)
                    }
                }
            }
        } catch {
            self.lastError = error.localizedDescription
            AppLog.write("voice", "Failed to remove corrupt backup files in forgetAll: \(error.localizedDescription)")
            throw VoiceprintError.writeFailed(error.localizedDescription)
        }
    }

    /// 이름 또는 별칭으로 인물 검색 (대소문자 무시)
    func person(named name: String) -> Person? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }

        return people.first { person in
            if person.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target {
                return true
            }
            return person.aliases.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target }
        }
    }
}