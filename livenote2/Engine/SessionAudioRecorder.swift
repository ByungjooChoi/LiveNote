import Foundation

/// 세션 한정 오디오 보관 — 2-pass 재디코딩용.
///
/// 회의 중 16kHz mono 샘플을 채널별 WAV(16-bit PCM)로 임시 폴더에 흘려 두었다가,
/// stop 시점의 전체 문맥 재디코딩(TranscriptRefiner)에 쓰고 즉시 삭제한다.
/// 오디오는 회의 저장 폴더에 절대 남지 않는다 (전사 후 폐기 정책, Granola와 동일).
/// 용량: 시간당 채널별 약 115MB.
actor SessionAudioRecorder {

    private let sampleRate: Int = 16_000
    private var handles: [AudioChannel: FileHandle] = [:]
    private var dataBytes: [AudioChannel: UInt32] = [:]
    private var urls: [AudioChannel: URL] = [:]

    private let folder: URL

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("livenote2-session-\(UUID().uuidString)", isDirectory: true)
    }

    /// 채널별 WAV 파일 생성 (헤더는 finish에서 확정)
    func start() {
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
        try? FileManager.default.removeItem(at: folder)
        AppLog.write("app", "세션 오디오 임시 파일 삭제")
    }

    /// 이전 세션이 비정상 종료로 남긴 임시 폴더 청소 (앱 시작 시 호출)
    nonisolated static func purgeStale() {
        let tmp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("livenote2-session-") {
            try? FileManager.default.removeItem(at: item)
        }
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
