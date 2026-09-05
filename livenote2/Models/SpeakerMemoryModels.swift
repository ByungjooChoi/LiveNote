import Foundation

/// 화자 이름의 출처 (칩 아이콘용). zoom > voice > manual 우선순위는 SpeakerMemory가 결정.
enum NameSource: String, Codable, Sendable {
    case zoom
    case voice
    case slot
    case manual
}

/// 오프라인 다이어라이제이션 결과 (FluidAudio 타입을 밖으로 노출하지 않음)
struct SpeakerSegment: Codable, Equatable, Sendable {
    var clusterID: String
    var start: Double
    var end: Double
    var embedding: [Float]
    var quality: Float

    var duration: Double { max(0, end - start) }
}

struct OfflineDiarization: Codable, Equatable, Sendable {
    var segments: [SpeakerSegment]
    var processingSeconds: Double
    var audioSeconds: Double

    /// 발화 시간 내림차순 정렬된 클러스터 ID 목록
    var clusterIDs: [String] {
        var totals: [String: Double] = [:]
        for seg in segments {
            totals[seg.clusterID, default: 0] += seg.duration
        }
        return totals.sorted { a, b in
            if a.value != b.value {
                return a.value > b.value
            }
            return a.key < b.key
        }.map(\.key)
    }

    /// 겹침 합이 max(0.3s, 15%) 이상인 최대 클러스터
    func dominantCluster(from: Double, to: Double) -> String? {
        let targetDuration = max(0, to - from)
        guard targetDuration > 0 else { return nil }
        var overlaps: [String: Double] = [:]
        for seg in segments {
            let overlapStart = max(seg.start, from)
            let overlapEnd = min(seg.end, to)
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > 0 {
                overlaps[seg.clusterID, default: 0] += overlap
            }
        }
        let minOverlap = max(0.3, targetDuration * 0.15)
        guard let best = overlaps.max(by: { a, b in
            if a.value != b.value {
                return a.value < b.value
            }
            return a.key > b.key
        }), best.value >= minOverlap else {
            return nil
        }
        return best.key
    }

    func seconds(for clusterID: String) -> Double {
        segments
            .filter { $0.clusterID == clusterID }
            .reduce(0) { $0 + $1.duration }
    }

    /// 품질 가중 평균 임베딩(L2 정규화), 총 발화 초, 평균 품질. 세그먼트 없으면 nil.
    func centroid(for clusterID: String) -> ClusterCentroid? {
        let matching = segments.filter { $0.clusterID == clusterID && !$0.embedding.isEmpty }
        guard !matching.isEmpty else { return nil }

        let dim = matching[0].embedding.count
        guard dim > 0 else { return nil }

        var weightedSum = [Float](repeating: 0, count: dim)
        var totalWeight: Float = 0
        var totalSeconds: Double = 0
        var totalQuality: Float = 0
        var validCount = 0

        for seg in matching {
            guard seg.embedding.count == dim else { continue }
            guard seg.embedding.allSatisfy({ $0.isFinite }) else { continue }

            var sumSq: Float = 0
            for x in seg.embedding {
                sumSq += x * x
            }
            let norm = sqrt(sumSq)
            guard norm.isFinite, norm > 1e-7 else { continue }

            let weight = max(1e-4, seg.quality)
            totalWeight += weight
            totalSeconds += seg.duration
            totalQuality += seg.quality
            validCount += 1

            for i in 0..<dim {
                weightedSum[i] += (seg.embedding[i] / norm) * weight
            }
        }

        guard totalWeight > 0, validCount > 0 else { return nil }
        let avgQuality = totalQuality / Float(validCount)

        // 합 벡터 L2 정규화
        var sumSquares: Float = 0
        for i in 0..<dim {
            sumSquares += weightedSum[i] * weightedSum[i]
        }
        let sumNorm = sqrt(sumSquares)
        guard sumNorm.isFinite, sumNorm > 1e-7 else { return nil }

        let normalized = weightedSum.map { $0 / sumNorm }

        return ClusterCentroid(
            clusterID: clusterID,
            embedding: normalized,
            seconds: totalSeconds,
            quality: avgQuality
        )
    }
}

struct ClusterCentroid: Equatable, Sendable {
    var clusterID: String
    var embedding: [Float]
    var seconds: Double
    var quality: Float
}

/// 성문 저장소 모델 (voiceprints.json)
struct VoiceCentroid: Codable, Equatable, Sendable {
    var v: [Float]
    var n: Int
    var quality: Float
    var updated: Date
    var conflicts: Int = 0
    var weight: Float

    enum CodingKeys: String, CodingKey {
        case v, n, quality, updated, conflicts, weight
    }

    init(v: [Float], n: Int, quality: Float, updated: Date, conflicts: Int = 0, weight: Float? = nil) {
        self.v = v
        self.n = n
        self.quality = quality
        self.updated = updated
        self.conflicts = conflicts
        self.weight = weight ?? Float(n)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try container.decode([Float].self, forKey: .v)
        self.n = try container.decode(Int.self, forKey: .n)
        self.quality = try container.decode(Float.self, forKey: .quality)
        self.updated = try container.decode(Date.self, forKey: .updated)
        self.conflicts = try container.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        self.weight = try container.decodeIfPresent(Float.self, forKey: .weight) ?? Float(self.n)
    }
}

enum VoiceSource: String, Codable, Sendable {
    case zoom
    case manual
    case fallback
    case live
}

struct Person: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var aliases: [String] = []
    var email: String? = nil
    var centroids: [VoiceCentroid] = []
    var meetings: Int = 0
    var lastSeen: Date? = nil
    var sources: [VoiceSource] = []
    var isMe: Bool = false
    var totalSamples: Int { centroids.reduce(0) { $0 + $1.n } }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, email, centroids, meetings, lastSeen, sources, isMe
    }

    init(
        id: String,
        name: String,
        aliases: [String] = [],
        email: String? = nil,
        centroids: [VoiceCentroid] = [],
        meetings: Int = 0,
        lastSeen: Date? = nil,
        sources: [VoiceSource] = [],
        isMe: Bool = false
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.email = email
        self.centroids = centroids
        self.meetings = meetings
        self.lastSeen = lastSeen
        self.sources = sources
        self.isMe = isMe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.centroids = try container.decodeIfPresent([VoiceCentroid].self, forKey: .centroids) ?? []
        self.meetings = try container.decodeIfPresent(Int.self, forKey: .meetings) ?? 0
        self.lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        self.sources = try container.decodeIfPresent([VoiceSource].self, forKey: .sources) ?? []
        self.isMe = try container.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
    }
}

struct VoiceprintDatabase: Codable, Equatable, Sendable {
    var version: Int = 1
    var people: [Person] = []
}

struct VoiceprintThresholds: Codable, Equatable, Sendable {
    var matchThreshold: Float = 0.65
    var margin: Float = 0.08
    var mergeThreshold: Float = 0.35
    var minEnrollSeconds: Double = 20
    var minQuality: Float = 0.6
    var maxCentroids: Int = 5
    var conflictLimit: Int = 3

    static let defaultsKey = "voiceprintThresholds"

    /// 임계값 유효성 검사 (오류 메시지 목록 반환, 비어있으면 유효)
    func validate() -> [String] {
        var errors: [String] = []
        if matchThreshold < 0.0 || matchThreshold > 2.0 {
            errors.append("matchThreshold must be between 0.0 and 2.0")
        }
        if mergeThreshold < 0.0 || mergeThreshold > 2.0 || mergeThreshold > matchThreshold {
            errors.append("mergeThreshold must be between 0.0 and 2.0 and <= matchThreshold")
        }
        if margin < 0.0 || margin > 2.0 {
            errors.append("margin must be between 0.0 and 2.0")
        }
        if minQuality < 0.0 || minQuality > 1.0 {
            errors.append("minQuality must be between 0.0 and 1.0")
        }
        if minEnrollSeconds <= 0.0 {
            errors.append("minEnrollSeconds must be > 0.0")
        }
        if maxCentroids < 1 || maxCentroids > 5 {
            errors.append("maxCentroids must be between 1 and 5")
        }
        if conflictLimit < 1 {
            errors.append("conflictLimit must be >= 1")
        }
        return errors
    }

    static func load(defaults: UserDefaults = .standard) -> VoiceprintThresholds {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return VoiceprintThresholds()
        }
        do {
            let decoded = try JSONDecoder().decode(VoiceprintThresholds.self, from: data)
            let errors = decoded.validate()
            if !errors.isEmpty {
                AppLog.write("voice", "Invalid voiceprintThresholds in defaults (\(errors.joined(separator: ", "))), using defaults")
                return VoiceprintThresholds()
            }
            return decoded
        } catch {
            AppLog.write("voice", "Failed to decode voiceprintThresholds, using defaults: \(error.localizedDescription)")
            return VoiceprintThresholds()
        }
    }

    func save(defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(self)
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

struct VoiceMatch: Equatable, Sendable {
    var person: Person?          // confident일 때만 non-nil
    var candidates: [Person]     // 거리 순 상위 2명 (마진 미달 제안용)
    var d1: Float                // 최근접 (없으면 .infinity)
    var d2: Float                // 차근접 (없으면 .infinity)
    var confident: Bool
}

struct EnrollmentSample: Equatable, Sendable {
    var embedding: [Float]
    var quality: Float
    var seconds: Double
}

enum VoiceprintError: LocalizedError, Equatable {
    case unreadable(String)
    case corrupt(String)
    case writeFailed(String)
    case readOnly(String)
    case personNotFound(String)
    case tooLittleAudio(seconds: Double)
    case lowQuality(Float)
    case sameDimensionRequired
    case noValidSamples

    var errorDescription: String? {
        switch self {
        case .unreadable(let msg): return "Unreadable voiceprint file: \(msg)"
        case .corrupt(let msg): return "Corrupted voiceprint database: \(msg)"
        case .writeFailed(let msg): return "Failed to write voiceprint database: \(msg)"
        case .readOnly(let msg): return "Voiceprint database is read-only: \(msg)"
        case .personNotFound(let id): return "Person not found: \(id)"
        case .tooLittleAudio(let seconds): return "Too little speech audio for enrollment: \(String(format: "%.1f", seconds))s"
        case .lowQuality(let q): return "Audio quality too low for enrollment: \(String(format: "%.2f", q))"
        case .sameDimensionRequired: return "Embedding dimensions must match"
        case .noValidSamples: return "No valid audio samples for enrollment"
        }
    }
}

/// 저장소 인터페이스 (worker-1 구현, worker-2 소비; 테스트는 in-memory fake)
@MainActor protocol VoiceprintStoring: AnyObject {
    var people: [Person] { get }
    var thresholds: VoiceprintThresholds { get set }
    var lastError: String? { get }
    func reload() throws
    func match(_ embedding: [Float]) -> VoiceMatch
    func match(_ embedding: [Float], excludingMe: Bool) -> VoiceMatch
    /// 이름(+email)으로 기존 person을 찾거나 새로 만들고 중심을 갱신. 최소 발화·품질 미달이면 throw. 반환: 갱신된 Person.
    @discardableResult func enroll(name: String, email: String?, samples: [EnrollmentSample], source: VoiceSource, isMe: Bool) throws -> Person
    /// 본인(isMe) 성문 등록: 이미 isMe 프로필이 존재하면 아무 변경 없이 nil 반환, 부재 시 신규 등록 후 Person 반환
    @discardableResult func enrollMeIfAbsent(name: String, samples: [EnrollmentSample], source: VoiceSource) throws -> Person?
    /// 성문 이름 != 확정 이름 충돌: 해당 person의 최근접 중심 conflicts += 1, conflictLimit 도달 시 그 중심 삭제. 반환: 삭제 여부.
    @discardableResult func recordConflict(personID: String, embedding: [Float]) throws -> Bool
    func merge(_ sourceID: String, into targetID: String) throws
    func rename(id: String, to name: String) throws
    func delete(id: String) throws
    func forgetAll() throws
    func person(named name: String) -> Person?   // name 또는 alias, case-insensitive
}

extension VoiceprintStoring {
    /// 기본 match(_:)는 isMe 화자를 포함하여 매칭 (excludingMe: false)
    func match(_ embedding: [Float]) -> VoiceMatch {
        match(embedding, excludingMe: false)
    }

    /// 본인(isMe) 성문 등록 (부재 시에만)
    @discardableResult
    func enrollMeIfAbsent(name: String, samples: [EnrollmentSample], source: VoiceSource) throws -> Person? {
        if people.contains(where: { $0.isMe }) {
            return nil
        }
        return try enroll(name: name, email: nil, samples: samples, source: source, isMe: true)
    }
}
