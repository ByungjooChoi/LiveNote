import Foundation

/// 개별 전사 행 편집 전후 기록.
struct RowEdit: Codable, Equatable, Sendable {
    let rowID: UUID
    let before: String
    let after: String

    init(rowID: UUID, before: String, after: String) {
        self.rowID = rowID
        self.before = before
        self.after = after
    }
}

/// 편집 종류: 인라인 텍스트 수정 또는 일괄 찾아바꾸기.
enum TranscriptEditKind: String, Codable, Sendable {
    case inline
    case replaceAll
}

/// 단일 트랜잭션 편집 배치.
struct TranscriptEditBatch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let at: Date
    let kind: TranscriptEditKind
    let find: String?
    let replacement: String?
    let caseSensitive: Bool?
    let wholeWord: Bool?   // replaceAll 전용
    let rowEdits: [RowEdit]                     // 변경된 행 목록 (행 순서 유지, 요약 전용 배치일 때만 비어있을 수 있음)
    let summaryBefore: String?
    let summaryAfter: String?   // 요약에도 적용 옵션으로 요약이 변경된 경우만 설정

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        kind: TranscriptEditKind,
        find: String? = nil,
        replacement: String? = nil,
        caseSensitive: Bool? = nil,
        wholeWord: Bool? = nil,
        rowEdits: [RowEdit],
        summaryBefore: String? = nil,
        summaryAfter: String? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.find = find
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.rowEdits = rowEdits
        self.summaryBefore = summaryBefore
        self.summaryAfter = summaryAfter
    }
}

/// 회의 전사 편집 이력 로그 (edits.json).
struct TranscriptEditLog: Codable, Equatable, Sendable {
    var version: Int = 1
    var editsAtLastSummary: Int = 0             // 요약이 마지막으로 생성/재생성되었을 때의 revision
    var batches: [TranscriptEditBatch] = []
    var revisionOffset: Int = 0

    var editCount: Int {
        batches.reduce(0) { $0 + $1.rowEdits.count + ($1.summaryAfter != nil ? 1 : 0) }
    }

    /// 단조 증가하는 전체 개정 번호: 편집마다 배치 가중치만큼 증가하고, 되돌리기(Undo)마다 정확히 1씩 증가.
    var revision: Int {
        editCount + revisionOffset
    }

    var editedRowIDs: Set<UUID> {
        Set(batches.flatMap { $0.rowEdits.map(\.rowID) })
    }

    /// 특정 행의 최초 원본 텍스트 (툴팁용).
    func originalText(for rowID: UUID) -> String? {
        for batch in batches {
            if let edit = batch.rowEdits.first(where: { $0.rowID == rowID }) {
                return edit.before
            }
        }
        return nil
    }

    var pendingEditsSinceSummary: Int {
        max(0, revision - editsAtLastSummary)
    }

    init(
        version: Int = 1,
        editsAtLastSummary: Int = 0,
        batches: [TranscriptEditBatch] = [],
        revisionOffset: Int = 0
    ) {
        self.version = version
        self.editsAtLastSummary = editsAtLastSummary
        self.batches = batches
        self.revisionOffset = revisionOffset
    }

    enum CodingKeys: String, CodingKey {
        case version
        case editsAtLastSummary
        case batches
        case revisionOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.editsAtLastSummary = try container.decodeIfPresent(Int.self, forKey: .editsAtLastSummary) ?? 0
        self.batches = try container.decodeIfPresent([TranscriptEditBatch].self, forKey: .batches) ?? []
        self.revisionOffset = try container.decodeIfPresent(Int.self, forKey: .revisionOffset) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(editsAtLastSummary, forKey: .editsAtLastSummary)
        try container.encode(batches, forKey: .batches)
        try container.encode(revisionOffset, forKey: .revisionOffset)
    }

    /// JSON 데이터로부터 편집 로그 디코딩.
    static func load(from data: Data) throws -> TranscriptEditLog {
        guard !data.isEmpty else {
            throw MeetingStoreError.editLogCorrupt("empty file")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let log = try decoder.decode(TranscriptEditLog.self, from: data)
            if log.version > 1 {
                throw MeetingStoreError.editLogCorrupt("Unsupported version \(log.version)")
            }
            return log
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.editLogCorrupt(error.localizedDescription)
        }
    }
}
