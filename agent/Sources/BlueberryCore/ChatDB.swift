import Foundation
import SQLite3

public struct ChatDBError: Error, CustomStringConvertible {
    public var description: String
}

/// Read-only access to ~/Library/Messages/chat.db.
///
/// Column availability differs between macOS releases, so the message query is built from the
/// columns that actually exist (missing ones read as NULL) instead of assuming a schema.
public final class ChatDB: @unchecked Sendable {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    public let path: String
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let messageSelect: String

    public init(path: String = ChatDB.defaultPath) throws {
        self.path = path
        // Not immutable: Messages keeps writing; we read through the WAL.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw ChatDBError(description: "cannot open \(path): \(msg). Grant Full Disk Access to Blueberry.")
        }
        sqlite3_busy_timeout(db, 2_000)

        let columns = try Self.columns(of: "message", in: db)
        func col(_ name: String) -> String { columns.contains(name) ? "m.\(name)" : "NULL" }
        messageSelect = """
            SELECT m.ROWID, m.guid, m.text, \(col("attributedBody")), h.id, m.service, m.subject, m.is_from_me,
                   m.date, \(col("date_delivered")), \(col("date_read")), \(col("date_edited")), \(col("date_retracted")),
                   \(col("error")), \(col("associated_message_guid")), \(col("associated_message_type")),
                   \(col("expressive_send_style_id")), \(col("thread_originator_guid")), \(col("reply_to_guid")),
                   c.guid, \(col("cache_has_attachments"))
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            """
    }

    deinit { sqlite3_close(db) }

    public var maxRowId: Int64 {
        get throws {
            try query("SELECT IFNULL(MAX(ROWID), 0) FROM message") { $0.int64(0) }.first ?? 0
        }
    }

    /// Messages with ROWID > rowId, oldest first. This is the lossless cursor: no time windows.
    public func messages(afterRowId rowId: Int64, limit: Int = 500) throws -> [Message] {
        try hydrate(query("\(messageSelect) WHERE m.ROWID > ? ORDER BY m.ROWID LIMIT ?", [.int(rowId), .int(Int64(limit))], row: readMessage))
    }

    /// The most recent messages by ROWID; used to detect delivered/read/edit/unsend changes.
    public func recentMessages(limit: Int) throws -> [Message] {
        try hydrate(query("\(messageSelect) WHERE m.ROWID > (SELECT IFNULL(MAX(ROWID), 0) FROM message) - ? ORDER BY m.ROWID", [.int(Int64(limit))], row: readMessage))
    }

    public func message(guid: String) throws -> Message? {
        try hydrate(query("\(messageSelect) WHERE m.guid = ?", [.text(guid)], row: readMessage)).first
    }

    public func chats(limit: Int, offset: Int) throws -> [Chat] {
        let rows = try query(
            """
            SELECT c.ROWID, c.guid, c.display_name, c.style, c.service_name FROM chat c
            LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.ROWID ORDER BY MAX(cmj.message_date) DESC LIMIT ? OFFSET ?
            """,
            [.int(Int64(limit)), .int(Int64(offset))]
        ) { r in
            (rowId: r.int64(0), chat: Chat(guid: r.string(1) ?? "", displayName: r.string(2).flatMap { $0.isEmpty ? nil : $0 },
                                           isGroup: r.int64(3) == 43, service: r.string(4), participants: []))
        }
        return try rows.map { row in
            var chat = row.chat
            chat.participants = try query(
                "SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = ?",
                [.int(row.rowId)]
            ) { $0.string(0) ?? "" }
            return chat
        }
    }

    // MARK: - Row mapping

    private func readMessage(_ r: Row) -> Message {
        var text = r.string(2)
        if text == nil || text?.isEmpty == true || text == "\u{FFFC}", let body = r.blob(3) {
            text = AttributedBody.text(from: body) ?? text
        }
        return Message(
            rowId: r.int64(0),
            guid: r.string(1) ?? "",
            chatGuid: r.string(19),
            sender: r.int64(7) == 1 ? nil : r.string(4),
            isFromMe: r.int64(7) == 1,
            service: r.string(5),
            text: text,
            subject: r.string(6),
            replyToGuid: r.string(18),
            threadOriginatorGuid: r.string(17),
            associatedMessageGuid: r.string(14),
            associatedMessageType: Int(r.int64(15)),
            expressiveSendStyleId: r.string(16),
            dateSent: AppleDate.iso(r.int64(8)) ?? AppleDate.iso(fromDate: Date()),
            dateDelivered: AppleDate.iso(r.int64(9)),
            dateRead: AppleDate.iso(r.int64(10)),
            dateEdited: AppleDate.iso(r.int64(11)),
            dateRetracted: AppleDate.iso(r.int64(12)),
            error: Int(r.int64(13)),
            // Placeholder flag; attachments are loaded in `hydrate`.
            attachments: r.int64(20) == 1 ? [Attachment(guid: "", filename: nil, mimeType: nil, uti: nil, totalBytes: 0, isSticker: false)] : []
        )
    }

    private func hydrate(_ messages: [Message]) throws -> [Message] {
        try messages.map { message in
            guard !message.attachments.isEmpty else { return message }
            var m = message
            m.attachments = try query(
                """
                SELECT a.guid, a.filename, a.mime_type, a.uti, a.total_bytes, a.is_sticker FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                JOIN message m ON m.ROWID = maj.message_id WHERE m.ROWID = ?
                """,
                [.int(message.rowId)]
            ) { r in
                Attachment(guid: r.string(0) ?? "", filename: r.string(1), mimeType: r.string(2), uti: r.string(3),
                           totalBytes: Int(r.int64(4)), isSticker: r.int64(5) == 1)
            }
            return m
        }
    }

    // MARK: - SQLite plumbing

    enum Bind {
        case int(Int64)
        case text(String)
    }

    struct Row {
        let stmt: OpaquePointer

        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func query<T>(_ sql: String, _ binds: [Bind] = [], row: (Row) throws -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ChatDBError(description: "prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case .text(let v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, Self.transient)
            }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ChatDBError(description: "step failed: \(String(cString: sqlite3_errmsg(db)))") }
            out.append(try row(Row(stmt: stmt)))
        }
        return out
    }

    private static func columns(of table: String, in db: OpaquePointer?) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError(description: "cannot read schema: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        if names.isEmpty { throw ChatDBError(description: "table \(table) not found — is this a Messages database?") }
        return names
    }
}

/// Apple stores dates as nanoseconds (older rows: seconds) since 2001-01-01.
public enum AppleDate {
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func date(_ raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    public static func iso(_ raw: Int64) -> String? {
        date(raw).map(iso(fromDate:))
    }

    public static func iso(fromDate date: Date) -> String {
        formatter.string(from: date)
    }
}
