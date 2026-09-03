import XCTest

@testable import LiveNote

final class ChatStoreTests: XCTestCase {

    func testLegacyJSONWithoutPromptTextDecodesProperly() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "title": "Legacy chat",
            "createdAt": "2026-09-01T10:00:00Z",
            "updatedAt": "2026-09-01T10:05:00Z",
            "scopeKey": "archive",
            "messages": [
                {
                    "isUser": true,
                    "text": "Hello"
                },
                {
                    "isUser": false,
                    "text": "Hi there"
                }
            ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let chat = try decoder.decode(SavedChat.self, from: Data(json.utf8))

        XCTAssertEqual(chat.id.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(chat.title, "Legacy chat")
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].text, "Hello")
        XCTAssertNil(chat.messages[0].promptText)
        XCTAssertEqual(chat.messages[1].text, "Hi there")
        XCTAssertNil(chat.messages[1].promptText)
    }

    func testChatMessageWithPromptTextRoundTrip() throws {
        let original = SavedChat(
            id: UUID(),
            title: "Recipe Chat",
            createdAt: Date(),
            updatedAt: Date(),
            scopeKey: "archive",
            messages: [
                SavedChat.Message(
                    isUser: true,
                    text: "Recipe: Weekly Update (This week, 1 meeting)",
                    promptText: "Full expanded prompt..."
                ),
                SavedChat.Message(
                    isUser: false,
                    text: "Here is the summary.",
                    promptText: nil
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SavedChat.self, from: data)

        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[0].promptText, "Full expanded prompt...")
        XCTAssertNil(decoded.messages[1].promptText)
    }
}
