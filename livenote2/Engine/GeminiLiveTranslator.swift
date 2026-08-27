import Foundation
import Security

/// 클라우드 번역 — Gemini Live API `gemini-3.5-live-translate-preview` (WebSocket).
///
/// 모델 특성 (2026-07 공식 문서 기준):
/// - 오디오 입력 전용 (텍스트 입력 미지원) → 확정 문장 텍스트를 보낼 수 없고 오디오를 스트리밍해야 함
/// - 입력: 16kHz 16bit PCM mono little-endian, 100ms 청크 / 출력: 번역 오디오(24kHz, 우리는 버림) + 입/출력 전사 텍스트
/// - 연속 스트림 처리 (턴 없음), 도구/지시 미지원, translationConfig.targetLanguageCode로 대상 언어 지정
///
/// 통합 설계: 채널(나/상대방)별로 세션을 하나씩 열고 해당 채널 오디오를 스트리밍한다.
/// outputTranscription(한국어) 조각을 채널별로 누적하고, Parakeet 확정 행이 생기면
/// AppState가 지연(linger) 후 `claimKorean`으로 그때까지 쌓인 번역을 가져가 행에 붙인다.
/// 한계(문서화): Gemini의 문장 분할과 우리 행 분할이 다르므로 경계에서 번역이 이웃 행으로
/// 번질 수 있다. 실험적 기능으로 표시하고, 기본은 로컬(Apple) 번역을 유지한다.
///
/// 비용 절약: 무음 구간은 전송하지 않는다 (RMS 게이트 + 1초 hangover).
actor GeminiLiveTranslator {

    static let model = "gemini-3.5-live-translate-preview"

    // MARK: - 상태

    private var apiKey: String?
    private var running = false
    private var micMuted = false
    private var issueHandler: (@Sendable (String?) -> Void)?
    private var statusHandler: (@Sendable (CloudStatus?) -> Void)?
    /// 채널별 수신한 번역 조각 수 (로그용)
    private var outputCounts: [AudioChannel: Int] = [.me: 0, .them: 0]

    private var sockets: [AudioChannel: URLSessionWebSocketTask] = [:]
    private var ready: [AudioChannel: Bool] = [.me: false, .them: false]
    private var receiveTasks: [AudioChannel: Task<Void, Never>] = [:]
    private var keepaliveTasks: [AudioChannel: Task<Void, Never>] = [:]
    private var rotationTasks: [AudioChannel: Task<Void, Never>] = [:]
    private var reconnectCounts: [AudioChannel: Int] = [.me: 0, .them: 0]

    /// 전송 대기 PCM (채널별 100ms = 1600샘플 단위로 전송)
    private var pcmPending: [AudioChannel: [Int16]] = [.me: [], .them: []]
    /// 무음 게이트: 마지막으로 소리가 있던 시각
    private var lastLoudAt: [AudioChannel: Date] = [:]

    /// 도착한 한국어 번역 조각 (claim 대기)
    private var pendingKorean: [AudioChannel: [String]] = [.me: [], .them: []]

    private static let chunkSamples = 1600            // 100ms @16kHz
    private static let silenceRMS: Float = 0.004      // 이보다 조용하면 무음 후보
    private static let silenceHangover: TimeInterval = 1.0
    /// 이 횟수 이상 연속 실패하면 배너로 알림 (재연결은 세션이 사는 동안 무제한 계속 —
    /// 2026-08 실사용에서 5회 제한 소진 후 영구 중단되는 문제로 정책 변경)
    private static let reconnectWarnThreshold = 5
    /// 핸드셰이크·로테이션 중 보관할 오디오 상한 (3초) — 첫 문장 유실 방지 (ALAD 패턴)
    private static let preReadyCapSamples = 3 * 16_000
    /// 선제 세션 로테이션 주기 — Live 세션 수명 한계(수 분~15분)에 걸리기 전에 미리 교체
    /// (Voxis session_rotate / vtuber-live-translate 主動輪換 패턴, LiveNote1 실측 8~10분 리셋)
    private static let rotationSeconds: UInt64 = 8 * 60

    // MARK: - 설정

    func setIssueHandler(_ handler: @escaping @Sendable (String?) -> Void) {
        issueHandler = handler
    }

    func setStatusHandler(_ handler: @escaping @Sendable (CloudStatus?) -> Void) {
        statusHandler = handler
    }

    /// 두 채널의 ready 상태로 연결 상태를 계산해 UI에 전달.
    private func publishStatus() {
        guard running else {
            statusHandler?(nil)
            return
        }
        if ready[.me] == true, ready[.them] == true {
            statusHandler?(.connected)
        } else if (reconnectCounts[.me] ?? 0) > 0 || (reconnectCounts[.them] ?? 0) > 0 {
            statusHandler?(.reconnecting)
        } else {
            statusHandler?(.connecting)
        }
    }

    // MARK: - 진단 로그 (~/Documents/livenote2/logs/cloud.log)
    // "갑자기 안 된다"를 소급 진단할 수 없던 문제로 도입 (2026-08). 텍스트 내용은 기록하지 않음.

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/livenote2/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cloud.log")
    }()

    private func log(_ event: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(event)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    func configure(apiKey: String?) {
        self.apiKey = apiKey
    }

    func setMicMuted(_ muted: Bool) {
        micMuted = muted
    }

    // MARK: - 시작/중지

    func start() async {
        guard !running else { return }
        guard let apiKey, !apiKey.isEmpty else {
            issueHandler?("Gemini API 키가 없어 클라우드 번역을 시작하지 못했습니다.")
            return
        }
        running = true
        reconnectCounts = [.me: 0, .them: 0]
        outputCounts = [.me: 0, .them: 0]
        pendingKorean = [.me: [], .them: []]
        issueHandler?(nil)
        log("session start")
        for channel in [AudioChannel.me, .them] {
            connect(channel: channel, apiKey: apiKey)
        }
        publishStatus()
    }

    func stop() {
        guard running else { return }
        running = false
        log("session stop (출력 조각 me=\(outputCounts[.me] ?? 0) them=\(outputCounts[.them] ?? 0))")
        for channel in [AudioChannel.me, .them] {
            teardown(channel: channel)
        }
        pcmPending = [.me: [], .them: []]
        statusHandler?(nil)
    }

    private func teardown(channel: AudioChannel) {
        receiveTasks[channel]?.cancel()
        receiveTasks[channel] = nil
        keepaliveTasks[channel]?.cancel()
        keepaliveTasks[channel] = nil
        rotationTasks[channel]?.cancel()
        rotationTasks[channel] = nil
        sockets[channel]?.cancel(with: .normalClosure, reason: nil)
        sockets[channel] = nil
        ready[channel] = false
    }

    // MARK: - 연결

    private func connect(channel: AudioChannel, apiKey: String) {
        teardown(channel: channel)
        guard let url = URL(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        ) else { return }

        log("connect \(channel)")
        let socket = URLSession.shared.webSocketTask(with: url)
        sockets[channel] = socket
        socket.resume()

        // Setup 메시지.
        // ⚠️ 전사 설정 2개는 setup "루트"에 둬야 한다 — 공식 문서의 WebSocket 예제는
        // generationConfig 안에 넣고 있지만 실제 v1beta는 CloseCode 1007
        // ("Unknown name at 'setup.generation_config'")로 거부함.
        // (kkdai/gemini-live-translate-macos 실전 검증 + LiveNote1 S2ST 시절의 동일 배치)
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(Self.model)",
                "inputAudioTranscription": [String: String](),
                "outputAudioTranscription": [String: String](),
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "translationConfig": [
                        "targetLanguageCode": "ko",
                        // 입력이 이미 한국어면 침묵 (한국어 혼잣말이 다시 번역되어 나오는 것 방지)
                        "echoTargetLanguage": false,
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        sendJSON(setup, channel: channel)

        receiveTasks[channel] = Task { [weak self] in
            await self?.receiveLoop(channel: channel, socket: socket)
        }
        keepaliveTasks[channel] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.ping(channel: channel)
            }
        }
    }

    private func ping(channel: AudioChannel) {
        sockets[channel]?.sendPing { _ in }
    }

    /// 수신 루프. 재연결로 소켓이 교체되면(아이덴티티 불일치) 옛 루프는 조용히 종료
    /// (이중 수신 방지).
    private func receiveLoop(channel: AudioChannel, socket: URLSessionWebSocketTask) async {
        while running, sockets[channel] === socket {
            do {
                let message = try await socket.receive()
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let raw): data = raw
                @unknown default: data = nil
                }
                if let data { handleServerMessage(data, channel: channel, socket: socket) }
            } catch {
                guard running, sockets[channel] === socket else { return }
                handleDisconnect(channel: channel, error: error)
                return
            }
        }
    }

    private func handleServerMessage(_ data: Data, channel: AudioChannel, socket: URLSessionWebSocketTask) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            ready[channel] = true
            reconnectCounts[channel] = 0
            issueHandler?(nil)   // 재연결 성공 시 경고 배너 해제
            log("setupComplete \(channel)")
            publishStatus()
            // 핸드셰이크 동안 버퍼된 오디오 방출 (첫 문장 유실 방지)
            flushPending(channel: channel)
            // 선제 로테이션: 세션 수명 한계 전에 미리 재연결 (버퍼링이 공백을 메움)
            rotationTasks[channel]?.cancel()
            rotationTasks[channel] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.rotationSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.rotateIfCurrent(channel: channel, socket: socket)
            }
            return
        }

        // 서버가 연결 종료를 예고하면 선제 재연결
        if json["goAway"] != nil {
            log("goAway \(channel) → 재연결")
            if let apiKey { connect(channel: channel, apiKey: apiKey) }
            return
        }

        guard let serverContent = json["serverContent"] as? [String: Any] else { return }
        if let output = serverContent["outputTranscription"] as? [String: Any],
           let text = output["text"] as? String, !text.isEmpty {
            pendingKorean[channel, default: []].append(text)
            let count = (outputCounts[channel] ?? 0) + 1
            outputCounts[channel] = count
            if count == 1 || count % 50 == 0 {
                log("output \(channel) 조각 \(count)개째")
            }
        }
        // inputTranscription과 번역 오디오(inlineData)는 사용하지 않음 (EN은 Parakeet이 담당)
    }

    /// 로테이션 시점에 소켓이 여전히 현역이면 재연결 (교체됐으면 no-op).
    private func rotateIfCurrent(channel: AudioChannel, socket: URLSessionWebSocketTask) {
        guard running, sockets[channel] === socket, let apiKey else { return }
        connect(channel: channel, apiKey: apiKey)
    }

    private func handleDisconnect(channel: AudioChannel, error: Error) {
        ready[channel] = false
        let count = (reconnectCounts[channel] ?? 0) + 1
        reconnectCounts[channel] = count
        log("disconnect \(channel) #\(count): \(error.localizedDescription.prefix(160))")
        publishStatus()
        guard let apiKey else { return }
        // 연속 실패가 쌓이면 배너로 알리되, 재연결은 세션이 사는 동안 계속 시도
        // (과거: 5회 후 영구 중단 → 네트워크 순단 한 번에 세션이 죽는 문제)
        if count == Self.reconnectWarnThreshold {
            issueHandler?("클라우드 번역 연결이 불안정해 재연결을 계속 시도 중입니다. 네트워크를 확인해 주세요. (\(error.localizedDescription))")
        }
        // 지수 백오프: 2s, 4s, … 상한 30s
        let delaySeconds = min(Double(count) * 2.0, 30.0)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, await self.isRunning else { return }
            await self.connect(channel: channel, apiKey: apiKey)
        }
    }

    var isRunning: Bool { running }

    // MARK: - 오디오 유입 (AppState 소비 루프에서 호출)

    func ingest(_ samples: [Float], channel: AudioChannel) {
        guard running, !samples.isEmpty else { return }
        if channel == .me, micMuted { return }

        // 무음 게이트: 조용한 구간은 전송하지 않아 쿼터를 아낌 (1초 hangover로 어절 잘림 방지)
        let rms = Self.rms(samples)
        let now = Date()
        if rms > Self.silenceRMS {
            lastLoudAt[channel] = now
        } else if let last = lastLoudAt[channel], now.timeIntervalSince(last) > Self.silenceHangover {
            return
        } else if lastLoudAt[channel] == nil {
            return
        }

        // Float32 [-1,1] → Int16 LE 누적
        var pending = pcmPending[channel] ?? []
        pending.reserveCapacity(pending.count + samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            pending.append(Int16(clamped * 32767.0))
        }

        // 핸드셰이크·로테이션 중엔 전송하지 않고 최근 3초만 보관 —
        // setupComplete에서 flushPending으로 방출 (첫 문장 유실 방지, ALAD 패턴)
        guard ready[channel] == true else {
            if pending.count > Self.preReadyCapSamples {
                pending.removeFirst(pending.count - Self.preReadyCapSamples)
            }
            pcmPending[channel] = pending
            return
        }

        pcmPending[channel] = pending
        flushPending(channel: channel)
    }

    /// 누적 PCM을 100ms 단위로 전송.
    private func flushPending(channel: AudioChannel) {
        guard ready[channel] == true else { return }
        var pending = pcmPending[channel] ?? []
        while pending.count >= Self.chunkSamples {
            let chunk = Array(pending.prefix(Self.chunkSamples))
            pending.removeFirst(Self.chunkSamples)
            sendAudioChunk(chunk, channel: channel)
        }
        pcmPending[channel] = pending
    }

    private func sendAudioChunk(_ chunk: [Int16], channel: AudioChannel) {
        let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }  // 리틀 엔디안 (Apple Silicon native)
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": data.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ]
            ]
        ]
        sendJSON(message, channel: channel)
    }

    private func sendJSON(_ object: [String: Any], channel: AudioChannel) {
        guard let socket = sockets[channel],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: - 번역 회수

    /// 지금까지 쌓인 한국어 번역 조각을 합쳐서 반환하고 비움. 없으면 nil.
    func claimKorean(channel: AudioChannel) -> String? {
        let fragments = pendingKorean[channel] ?? []
        guard !fragments.isEmpty else { return nil }
        pendingKorean[channel] = []
        let joined = fragments.joined()
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    // MARK: - 헬퍼

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Gemini API 키 보관 (Keychain)

enum GeminiKeychain {
    private static let service = "com.byungjoo.livenote2.gemini"
    private static let account = "apiKey"

    static func save(_ key: String) {
        delete()
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
