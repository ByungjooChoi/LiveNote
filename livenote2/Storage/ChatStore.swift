import Foundation
import Observation

/// 저장된 채팅 대화 한 건 — `~/Documents/livenote2/chats/<uuid>.json`
struct SavedChat: Identifiable, Codable {
    struct Message: Codable {
        var isUser: Bool
        var text: String
    }

    let id: UUID
    var title: String            // 첫 질문 앞 40자
    var createdAt: Date
    var updatedAt: Date
    var scopeKey: String         // 만들어질 당시 범위 (참고용)
    var messages: [Message]

    /// "12m" / "5h" / "3d" 식 상대 시각
    var ageLabel: String {
        let seconds = Int(Date().timeIntervalSince(updatedAt))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

/// 채팅 대화 저장소. 회의 저장소와 같은 루트(~/Documents/livenote2) 아래 chats/ 폴더.
/// 대화가 진행될 때마다 upsert되어 항상 최신 상태가 디스크에 남는다.
@MainActor
@Observable
final class ChatStore {

    /// updatedAt 내림차순
    private(set) var chats: [SavedChat] = []

    private let folderURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        folderURL = documents.appendingPathComponent("livenote2/chats", isDirectory: true)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [SavedChat] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let chat = try? decoder.decode(SavedChat.self, from: data) {
                found.append(chat)
            }
        }
        chats = found.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ chat: SavedChat) {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(chat) {
            try? data.write(to: fileURL(for: chat.id))
        }
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.insert(chat, at: 0)
        }
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ chat: SavedChat) {
        try? FileManager.default.removeItem(at: fileURL(for: chat.id))
        chats.removeAll { $0.id == chat.id }
    }

    private func fileURL(for id: UUID) -> URL {
        folderURL.appendingPathComponent("\(id.uuidString).json")
    }
}
