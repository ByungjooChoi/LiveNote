import Foundation

@testable import LiveNote

/// 테스트용 임시 루트 MeetingStore 헬퍼.
@MainActor
enum MeetingStoreFixture {

    static func makeStore() throws -> MeetingStore {
        TestLogSandbox.activate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MeetingStore(rootURL: root)
    }

    static func cleanUp(_ store: MeetingStore) {
        try? FileManager.default.removeItem(at: store.rootURL)
    }

    static func row(text: String, start: Double = 0, end: Double = 5) -> TranscriptRow {
        TranscriptRow(
            id: UUID(),
            channel: .them,
            speakerSlot: 0,
            speakerName: nil,
            english: text,
            korean: nil,
            startSeconds: start,
            endSeconds: end
        )
    }

    /// 폴더 이름이 결정적이도록 고정 날짜 사용 (2026-09-01, 로컬 타임존).
    static func date(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
