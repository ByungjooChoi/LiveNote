import Foundation
@testable import LiveNote

enum TestLogSandbox {
    static let directory: URL = {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveNoteTests-logs-\(pid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func activate() {
        _ = directory
        if AppLog.directoryOverride == nil {
            AppLog.directoryOverride = directory
        }
    }
}
