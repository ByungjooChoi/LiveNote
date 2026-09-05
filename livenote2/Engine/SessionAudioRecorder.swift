import Foundation

/// 세션 한정 오디오 보관 — 2-pass 재디코딩용.
///
/// 회의 중 16kHz mono 샘플을 채널별 WAV(16-bit PCM)로 임시 폴더에 흘려 두었다가,
/// stop 시점의 전체 문맥 재디코딩(TranscriptRefiner)에 쓰고 즉시 삭제한다.
/// 오디오는 회의 저장 폴더에 절대 남지 않는다 (전사 후 폐기 정책, Granola와 동일).
/// 용량: 시간당 채널별 약 115MB.
actor SessionAudioRecorder {

    private final class ActiveFolderRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var folders = Set<String>()

        func register(_ name: String) {
            lock.lock()
            folders.insert(name)
            lock.unlock()
        }

        func unregister(_ name: String) {
            lock.lock()
            folders.remove(name)
            lock.unlock()
        }

        func contains(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return folders.contains(name)
        }

        func snapshot() -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return folders
        }
    }

    private static let activeFolders = ActiveFolderRegistry()

    private let sampleRate: Int = 16_000
    private var handles: [AudioChannel: FileHandle] = [:]
    private var dataBytes: [AudioChannel: UInt32] = [:]
    private var urls: [AudioChannel: URL] = [:]

    private let folder: URL

    init(rootDirectory: URL = FileManager.default.temporaryDirectory) {
        folder = rootDirectory
            .appendingPathComponent("livenote2-session-\(UUID().uuidString)", isDirectory: true)
    }

    /// 세션 임시 폴더 URL
    nonisolated var sessionFolder: URL { folder }
    var folderURL: URL { folder }

    /// 세션 폴더에 retained-until-restart 마커 파일 작성. 세션 오디오는 화자 인식이 완료될 때까지 유지되며 완료 후 삭제되고, 영구 미완료 시 다음 앱 실행 시 삭제됩니다.
    func markRetainedUntilRestart() {
        let marker = folder.appendingPathComponent("retained-until-restart")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    /// 채널별 WAV 파일 생성 (헤더는 finish에서 확정)
    func start() {
        Self.activeFolders.register(folder.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for channel in [AudioChannel.me, .them] {
                let url = folder.appendingPathComponent("\(channel.rawValue).wav")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                handle.write(Self.wavHeader(dataBytes: 0, sampleRate: sampleRate))
                handles[channel] = handle
                dataBytes[channel] = 0
                urls[channel] = url
            }
            AppLog.write("app", "세션 오디오 임시 기록 시작 (2-pass용)")
        } catch {
            Self.activeFolders.unregister(folder.lastPathComponent)
            AppLog.write("app", "세션 오디오 기록 시작 실패: \(error.localizedDescription)")
            handles = [:]
        }
    }

    func append(_ samples: [Float], channel: AudioChannel) {
        guard let handle = handles[channel], !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        dataBytes[channel, default: 0] += UInt32(data.count)
    }

    /// 헤더 확정 후 파일 URL 반환. 데이터가 거의 없는 채널은 제외.
    func finish() -> [AudioChannel: URL] {
        var result: [AudioChannel: URL] = [:]
        for (channel, handle) in handles {
            let bytes = dataBytes[channel] ?? 0
            handle.seek(toFileOffset: 0)
            handle.write(Self.wavHeader(dataBytes: bytes, sampleRate: sampleRate))
            try? handle.close()
            // 2초 미만 오디오는 재디코딩 가치 없음
            if bytes > UInt32(sampleRate * 2 * 2), let url = urls[channel] {
                result[channel] = url
            }
        }
        handles = [:]
        return result
    }

    /// 임시 오디오 완전 삭제 (재디코딩 후 반드시 호출)
    func deleteFiles() {
        for handle in handles.values { try? handle.close() }
        handles = [:]
        do {
            try FileManager.default.removeItem(at: folder)
            AppLog.write("app", "세션 오디오 임시 파일 삭제")
        } catch {
            AppLog.write("app", "세션 오디오 임시 파일 삭제 실패: \(error.localizedDescription)")
        }
        Self.activeFolders.unregister(folder.lastPathComponent)
    }

    /// 이전 세션이 비정상 종료로 남긴 임시 폴더 청소 (앱 시작 시 호출)
    nonisolated static func purgeStale(
        in tmp: URL = FileManager.default.temporaryDirectory,
        excluding active: Set<String>? = nil
    ) {
        let activeSet = active ?? activeFolders.snapshot()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)) ?? []
        var skippedCount = 0
        for item in items where item.lastPathComponent.hasPrefix("livenote2-session-") {
            if activeSet.contains(item.lastPathComponent) {
                skippedCount += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: item)
                AppLog.write("app", "purgeStale removed: \(item.lastPathComponent)")
            } catch {
                AppLog.write("app", "purgeStale failed to remove \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if skippedCount > 0 {
            AppLog.write("app", "purgeStale skipped \(skippedCount) active session folders")
        }
    }

    nonisolated static func isActiveFolder(_ url: URL) -> Bool {
        activeFolders.contains(url.lastPathComponent)
    }

    // MARK: - WAV 헤더 (16kHz mono 16-bit PCM)

    private static func wavHeader(dataBytes: UInt32, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let rate = UInt32(sampleRate)
        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16)
        append16(1)                    // PCM
        append16(1)                    // mono
        append32(rate)
        append32(rate * 2)             // byte rate (16-bit mono)
        append16(2)                    // block align
        append16(16)                   // bits per sample
        append("data"); append32(dataBytes)
        return data
    }
}
