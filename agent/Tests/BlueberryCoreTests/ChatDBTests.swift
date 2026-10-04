import Foundation
import Testing
@testable import BlueberryCore

/// Builds a throwaway chat.db with the subset of the Messages schema Blueberry reads.
struct Fixture {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).db").path
        try sql("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, style INTEGER, service_name TEXT, chat_identifier TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
              service TEXT, subject TEXT, is_from_me INTEGER, date INTEGER, date_delivered INTEGER, date_read INTEGER,
              date_edited INTEGER, error INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
              expressive_send_style_id TEXT, thread_originator_guid TEXT, reply_to_guid TEXT, cache_has_attachments INTEGER DEFAULT 0,
              account TEXT);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, total_bytes INTEGER, is_sticker INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO handle VALUES (1, '+15552223333', 'iMessage'), (2, 'friend@icloud.com', 'iMessage');
            INSERT INTO chat VALUES (1, 'iMessage;-;+15552223333', '', 45, 'iMessage', '+15552223333'),
                                    (2, 'iMessage;+;chat123', 'Crew', 43, 'iMessage', 'chat123');
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2);
            """)
    }

    // 2026-01-01T00:00:00Z in Apple nanoseconds.
    static let jan1: Int64 = 788_918_400 * 1_000_000_000

    func insertMessage(rowId: Int, chat: Int, handle: Int, fromMe: Bool, text: String?, body: Data? = nil,
                       attachment: Bool = false, dateRead: Int64 = 0) throws {
        let textSQL = text.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        let bodySQL = body.map { "X'\($0.map { String(format: "%02x", $0) }.joined())'" } ?? "NULL"
        var statements = """
            INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, service, is_from_me, date, date_read, cache_has_attachments, account)
            VALUES (\(rowId), 'guid-\(rowId)', \(textSQL), \(bodySQL), \(handle), 'iMessage', \(fromMe ? 1 : 0),
                    \(Self.jan1 + Int64(rowId) * 1_000_000_000), \(dateRead), \(attachment ? 1 : 0), \(fromMe ? "'P:+15550001111'" : "NULL"));
            INSERT INTO chat_message_join VALUES (\(chat), \(rowId), \(Self.jan1 + Int64(rowId)));
            """
        if attachment {
            statements += """
                INSERT INTO attachment VALUES (\(rowId), 'att-\(rowId)', '~/Library/Messages/Attachments/x.heic', 'image/heic', 'public.heic', 1234, 0);
                INSERT INTO message_attachment_join VALUES (\(rowId), \(rowId));
                """
        }
        try sql(statements)
    }

    func sql(_ statements: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, statements]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    static func attributedBody(_ string: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: string))
    }
}

@Suite struct ChatDBTests {
    @Test func readsMessagesAfterCursorInOrder() throws {
        let f = try Fixture()
        try f.insertMessage(rowId: 1, chat: 1, handle: 1, fromMe: false, text: "one")
        try f.insertMessage(rowId: 2, chat: 1, handle: 1, fromMe: true, text: "two")
        try f.insertMessage(rowId: 3, chat: 2, handle: 2, fromMe: false, text: "three")
        let db = try ChatDB(path: f.path)

        #expect(try db.maxRowId == 3)
        let after1 = try db.messages(afterRowId: 1)
        #expect(after1.map(\.rowId) == [2, 3])
        #expect(after1[0].isFromMe && after1[0].sender == nil)
        #expect(after1[1].sender == "friend@icloud.com")
        #expect(after1[1].chatGuid == "iMessage;+;chat123")
        #expect(after1[1].dateSent == "2026-01-01T00:00:03.000Z")
    }

    @Test func decodesTextFromAttributedBodyWhenTextIsNull() throws {
        let f = try Fixture()
        try f.insertMessage(rowId: 1, chat: 1, handle: 1, fromMe: false, text: nil, body: Fixture.attributedBody("hidden in typedstream 🫐"))
        let m = try #require(try ChatDB(path: f.path).messages(afterRowId: 0).first)
        #expect(m.text == "hidden in typedstream 🫐")
    }

    @Test func loadsAttachments() throws {
        let f = try Fixture()
        try f.insertMessage(rowId: 1, chat: 1, handle: 1, fromMe: false, text: "\u{FFFC}", attachment: true)
        let m = try #require(try ChatDB(path: f.path).messages(afterRowId: 0).first)
        #expect(m.attachments.count == 1)
        #expect(m.attachments[0].mimeType == "image/heic")
        #expect(m.attachments[0].totalBytes == 1234)
    }

    @Test func toleratesMissingColumns() throws {
        // date_retracted is absent from the fixture schema, like on older macOS releases.
        let f = try Fixture()
        try f.insertMessage(rowId: 1, chat: 1, handle: 1, fromMe: false, text: "hi")
        let m = try #require(try ChatDB(path: f.path).messages(afterRowId: 0).first)
        #expect(m.dateRetracted == nil)
    }

    @Test func listsChatsWithParticipants() throws {
        let f = try Fixture()
        try f.insertMessage(rowId: 1, chat: 1, handle: 1, fromMe: false, text: "a")
        try f.insertMessage(rowId: 2, chat: 2, handle: 2, fromMe: false, text: "b")
        let chats = try ChatDB(path: f.path).chats(limit: 10, offset: 0)
        #expect(chats.map(\.guid) == ["iMessage;+;chat123", "iMessage;-;+15552223333"])
        #expect(chats[0].isGroup && chats[0].displayName == "Crew")
        #expect(Set(chats[0].participants) == ["+15552223333", "friend@icloud.com"])
        #expect(chats[1].displayName == nil)
    }
}

actor Collector {
    var events: [String] = []
    func add(_ e: Event) {
        switch e {
        case .messageNew(let m): events.append("new:\(m.rowId)")
        case .messageUpdated(let m): events.append("updated:\(m.rowId)")
        default: break
        }
    }
}

@Suite struct ChatDBWatcherTests {
    @Test func emitsNewMessagesAndUpdatesFromCursor() async throws {
        let f = try Fixture()
        try f.insertMessage(rowId: 1, chat: 1, handle: 1, fromMe: false, text: "old")
        let db = try ChatDB(path: f.path)
        let collector = Collector()
        let watcher = ChatDBWatcher(db: db, resumeAfterRowId: 1) { await collector.add($0) }
        await watcher.start()
        defer { Task { await watcher.stop() } }

        try f.insertMessage(rowId: 2, chat: 1, handle: 1, fromMe: false, text: "new one")
        await watcher.tick()
        #expect(await collector.events == ["new:2"])

        // A read receipt changes the row without changing its ROWID.
        try f.sql("UPDATE message SET date_read = \(Fixture.jan1 + 99) WHERE ROWID = 1")
        await watcher.tick()
        #expect(await collector.events == ["new:2", "updated:1"])

        // Nothing changed: nothing emitted.
        await watcher.tick()
        #expect(await collector.events.count == 2)
    }

    @Test func resyncReplaysFromServerCursor() async throws {
        let f = try Fixture()
        for i in 1...3 { try f.insertMessage(rowId: i, chat: 1, handle: 1, fromMe: false, text: "m\(i)") }
        let collector = Collector()
        let watcher = ChatDBWatcher(db: try ChatDB(path: f.path), resumeAfterRowId: 3) { await collector.add($0) }
        // Server says it only durably has up to ROWID 1.
        await watcher.resync(afterRowId: 1)
        let events = await collector.events
        #expect(events.contains("updated:1"))
        #expect(events.suffix(2) == ["new:2", "new:3"])
    }
}

@Suite struct AppleScriptSenderTests {
    @Test func extractsDirectHandleFromChatGuid() {
        #expect(AppleScriptSender.directHandle(from: "iMessage;-;+15551234567") == "+15551234567")
        #expect(AppleScriptSender.directHandle(from: "any;-;me@icloud.com") == "me@icloud.com")
        #expect(AppleScriptSender.directHandle(from: "iMessage;+;chat123") == nil)
    }
}

@Suite struct ProtocolTests {
    @Test func decodesParticipantRemovalAndReactionRemove() throws {
        let participants = try JSONDecoder().decode(Command.self, from: Data(#"{"kind":"chat.participants","chatGuid":"c","add":["a"],"remove":["b"]}"#.utf8))
        #expect(participants.removeHandles == ["b"] && participants.remove == nil)
        let reaction = try JSONDecoder().decode(Command.self, from: Data(#"{"kind":"message.react","chatGuid":"c","messageGuid":"m","reaction":"love","remove":true}"#.utf8))
        #expect(reaction.remove == true)
    }

    @Test func encodesNullsExplicitly() throws {
        let m = Message(rowId: 1, guid: "g", chatGuid: nil, sender: nil, isFromMe: true, service: nil, text: "hi", subject: nil,
                        replyToGuid: nil, threadOriginatorGuid: nil, associatedMessageGuid: nil, associatedMessageType: 0,
                        expressiveSendStyleId: nil, dateSent: "2026-01-01T00:00:00.000Z", dateDelivered: nil, dateRead: nil,
                        dateEdited: nil, dateRetracted: nil, error: 0, attachments: [])
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(json.contains(#""chatGuid":null"#))
        #expect(json.contains(#""dateRetracted":null"#))
    }
}
