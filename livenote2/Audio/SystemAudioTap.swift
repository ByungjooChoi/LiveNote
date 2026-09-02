import AVFoundation
import AudioToolbox
import CoreAudio

/// 시스템 오디오 캡처 — Core Audio Process Tap (macOS 14.4+).
/// Zoom/Meet/브라우저 등 Mac에서 재생되는 모든 소리를 잡습니다.
/// BlackHole 같은 가상 드라이버 설치가 필요 없습니다.
/// 최초 실행 시 "시스템 오디오 녹음" 권한 프롬프트가 뜹니다.
///
/// 구조: 전역 탭 생성 → 탭을 물린 비공개 집계(aggregate) 장치 생성
///       → IOProc으로 오디오 수신 → 16kHz 모노 변환 → 콜백.
final class SystemAudioTap {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AudioConverter16k?
    private var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "livenote2.systemtap")

    /// 16kHz 모노 샘플 콜백 (오디오 큐에서 호출).
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        // 1) 전역 프로세스 탭 기술서 — 모든 프로세스, 자신은 제외 대상 없음(우리는 소리를 안 냄)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "livenote2-system-tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // 2) 탭 생성 — 여기서 시스템 오디오 녹음 권한 프롬프트가 발생
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw Self.error("프로세스 탭 생성 실패", status,
                             hint: "시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 LiveNote를 허용했는지 확인하세요.")
        }
        tapID = newTapID

        // 3) 탭의 스트림 포맷 읽기
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            cleanup()
            throw Self.error("탭 포맷 읽기 실패", status)
        }
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let conv = AudioConverter16k(inputFormat: format) else {
            cleanup()
            throw Self.error("탭 포맷 변환기 생성 실패", noErr)
        }
        tapFormat = format
        converter = conv

        // 4) 탭을 물린 비공개 집계 장치 생성
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "livenote2 Tap Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanup()
            throw Self.error("집계 장치 생성 실패", status)
        }
        aggregateID = newAggregateID

        // 5) IOProc 등록 및 시작
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handleIncoming(bufferList: inInputData)
        }
        guard status == noErr, ioProcID != nil else {
            cleanup()
            throw Self.error("IOProc 생성 실패", status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            throw Self.error("장치 시작 실패", status)
        }
    }

    func stop() {
        cleanup()
    }

    // MARK: - 내부

    private func handleIncoming(bufferList: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat, let conv = converter else { return }

        // AudioBufferList를 복사 없이 AVAudioPCMBuffer로 래핑
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: bufferList,
            deallocator: nil
        ), pcm.frameLength > 0 else { return }

        let samples = conv.convert(buffer: pcm)
        if !samples.isEmpty {
            onSamples?(samples)
        }
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        tapFormat = nil
    }

    private static func error(_ message: String, _ status: OSStatus, hint: String? = nil) -> NSError {
        var full = "\(message) (OSStatus: \(status))"
        if let hint { full += "\n\(hint)" }
        return NSError(domain: "livenote2.systemtap", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: full
        ])
    }
}
