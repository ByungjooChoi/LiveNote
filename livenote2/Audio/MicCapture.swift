import AVFoundation

/// 마이크 캡처. AVAudioEngine 탭 → 16kHz 모노 Float 스트림.
/// 이 채널의 모든 음성은 "나"로 확정 라벨링됩니다.
///
/// 에코 처리 참고:
/// macOS voice processing(AEC)은 장치 조합에 따라 초기화 실패(-10875)나 입력 침묵을
/// 일으켜 사용하지 않습니다. 스피커 에코는 TranscriptionEngine의 에코 게이트
/// (시스템 채널 에너지와 비교해 마이크 발화 판정)와 텍스트 중복 필터가 처리합니다.
/// Granola/Alt 계열 노트테이커와 같은 접근입니다.
final class MicCapture {

    private let engine = AVAudioEngine()
    private var converter: AudioConverter16k?

    // 레벨 미터 스로틀링
    private var levelChunkCount = 0
    private var levelPeak: Float = 0

    /// 16kHz 모노 샘플 콜백. 오디오 스레드에서 호출되므로 가볍게 유지할 것.
    var onSamples: (([Float]) -> Void)?
    /// 입력 레벨(0.0~1.0) 콜백, 약 4Hz. UI 미터용.
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw NSError(domain: "livenote2.mic", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "마이크 입력 포맷을 읽을 수 없습니다. 시스템 설정 > 사운드에서 입력 장치를 확인하세요."
            ])
        }
        guard let conv = AudioConverter16k(inputFormat: nativeFormat) else {
            throw NSError(domain: "livenote2.mic", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "오디오 컨버터 생성 실패 (입력 포맷: \(nativeFormat))"
            ])
        }
        converter = conv
        levelChunkCount = 0
        levelPeak = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = conv.convert(buffer: buffer)
            guard !samples.isEmpty else { return }
            self.reportLevel(samples)
            self.onSamples?(samples)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        onLevel?(0)
    }

    // MARK: - 레벨 미터

    private func reportLevel(_ samples: [Float]) {
        levelPeak = max(levelPeak, Self.rms(samples))
        levelChunkCount += 1
        if levelChunkCount >= 3 {   // 약 0.25초마다
            let level = min(1.0, levelPeak * 8.0)
            levelChunkCount = 0
            levelPeak = 0
            onLevel?(level)
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
