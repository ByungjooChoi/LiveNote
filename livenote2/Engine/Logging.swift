import Foundation

/// 앱 공용 파일 로거 — `~/Documents/LiveNote/logs/{카테고리}.log`
///
/// 카테고리: app(세션 수명), cloud(클라우드 번역 연결), chat(AI 채팅),
/// summary(요약), zoomtag(Zoom 화자 태그), recipe(레시피 저장·실행).
/// 원칙: 전사·번역·질문·답변의 "내용"은 기록하지 않는다 (크기·상태·오류만).
enum AppLog {

    private static let queue = DispatchQueue(label: "livenote2.applog")

    private static let dir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/LiveNote/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func write(_ category: String, _ message: String) {
        queue.async {
            let formatter = ISO8601DateFormatter()
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let url = dir.appendingPathComponent("\(category).log")
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Gemini REST 공용 전송 — 전용 세션(연결 캐시 미공유) + 네트워크 순단 자동 재시도.
///
/// 배경: 앱 내 URLSession.shared 요청이 "The network connection was lost"(-1005)로
/// 실패하는 사례 (같은 시점에 WebSocket과 curl은 정상 — QUIC/연결 재사용 계열로 추정).
/// ephemeral 세션은 Alt-Svc 캐시가 비어 있어 첫 요청이 TCP/h2로 나가고,
/// 그래도 실패하면 1초 간격 2회 재시도.
enum GeminiREST {

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest, logCategory: String) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let started = Date()
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                AppLog.write(logCategory, "HTTP \(status) \(data.count)B \(elapsed)s (시도 \(attempt))")
                guard status == 200 else {
                    let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? "?"
                    throw NSError(domain: "livenote2.gemini", code: status,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(detail)"])
                }
                return data
            } catch let error as URLError where attempt <= 2 && [
                .networkConnectionLost, .timedOut, .cannotConnectToHost, .secureConnectionFailed,
            ].contains(error.code) {
                AppLog.write(logCategory, "네트워크 오류, 재시도 \(attempt): (\(error.code.rawValue)) \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                AppLog.write(logCategory, "실패 (시도 \(attempt)): \(String(describing: error).prefix(250))")
                throw error
            }
        }
    }
}
