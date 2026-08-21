import AVFoundation

/// 임의 포맷의 오디오를 ASR이 요구하는 16kHz 모노 Float32로 변환.
/// 마이크(보통 48kHz)와 시스템 오디오 탭(보통 48kHz 스테레오) 양쪽에서 사용.
/// 인스턴스는 스트림 하나당 하나 — AVAudioConverter가 내부 리샘플링 상태를 유지합니다.
final class AudioConverter16k {

    static let targetSampleRate: Double = 16_000

    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        outputFormat = out
        converter = AVAudioConverter(from: inputFormat, to: out)
        if converter == nil { return nil }
    }

    /// 버퍼 하나를 16kHz 모노 Float 배열로 변환. 실패 시 빈 배열.
    func convert(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, buffer.frameLength > 0 else { return [] }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil,
              outBuffer.frameLength > 0,
              let channelData = outBuffer.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}
