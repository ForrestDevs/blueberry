import Foundation

/// Wires chat.db, the senders, and the server connection together.
public actor Agent {
    public struct Status: Sendable {
        public var connection: ServerConnection.State = .disconnected(reason: nil)
        public var privateApi = false
        public var lastError: String?
    }

    private let db: ChatDB
    private let sender = AppleScriptSender()
    private let watcher: ChatDBWatcher
    private let connection: ServerConnection
    private var status = Status()
    private var onStatus: (@Sendable (Status) -> Void)?

    // Command id -> result, so a retried command is never executed twice.
    private var completed: [String: Result<JSONValue, CommandError>] = [:]
    private var completedOrder: [String] = []
    private var inFlight: [String: Task<Result<JSONValue, CommandError>, Never>] = [:]

    public init(config: ServerConnection.Config, chatDBPath: String = ChatDB.defaultPath) throws {
        let db = try ChatDB(path: chatDBPath)
        // Callbacks reach the agent through a weak reference, since `self` isn't usable until init finishes.
        let ref = WeakAgent()
        let conn = ServerConnection(
            config: config,
            hello: { await ref.agent?.helloInfo() ?? ([], []) },
            onWelcome: { rowId in await ref.agent?.welcomed(resumeAfterRowId: rowId) },
            onCommand: { id, command in
                await ref.agent?.execute(id: id, command: command) ?? .failure(CommandError("agent_stopping", "agent is shutting down"))
            },
            onState: { state in await ref.agent?.update { $0.connection = state } }
        )
        self.db = db
        connection = conn
        watcher = ChatDBWatcher(db: db, resumeAfterRowId: try db.maxRowId) { event in await conn.send(event) }
        ref.agent = self
    }

    public func observe(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
        handler(status)
    }

    public func start() async {
        await watcher.start()
        await connection.start()
    }

    public func stop() async {
        await watcher.stop()
        await connection.stop()
    }

    private func update(_ change: @Sendable (inout Status) -> Void) {
        change(&status)
        onStatus?(status)
    }

    private func welcomed(resumeAfterRowId: Int64) async {
        await watcher.resync(afterRowId: resumeAfterRowId)
    }

    private func helloInfo() -> (capabilities: [String], accounts: [Account]) {
        var capabilities = ["send.applescript", "sync.chats"]
        if status.privateApi { capabilities += ["privateApi", "reactions", "edit", "unsend", "typing", "facetime"] }
        // The handles this Mac sends from, taken from its own recent outgoing messages.
        let accounts = (try? db.query(
            "SELECT DISTINCT account FROM (SELECT account FROM message WHERE is_from_me = 1 AND account IS NOT NULL ORDER BY ROWID DESC LIMIT 200)"
        ) { $0.string(0) }) ?? []
        return (capabilities, accounts.compactMap { $0 }.compactMap { raw in
            // "E:me@icloud.com" / "P:+15551234567"
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Account(service: "iMessage", handle: String(parts[1]))
        })
    }

    // MARK: - Commands

    func execute(id: String, command: Command) async -> Result<JSONValue, CommandError> {
        if let done = completed[id] { return done }
        if let running = inFlight[id] { return await running.value }
        let task = Task { await self.run(command) }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        completed[id] = result
        completedOrder.append(id)
        if completedOrder.count > 1_000 { completed[completedOrder.removeFirst()] = nil }
        return result
    }

    private func run(_ command: Command) async -> Result<JSONValue, CommandError> {
        do {
            switch command.kind {
            case "message.send":
                return .success(try await send(command))
            case "sync.chats":
                return .success(try JSONValue.from(db.chats(limit: command.limit ?? 100, offset: command.offset ?? 0)))
            default:
                // Reactions, edit/unsend, typing, read receipts, group management, availability and
                // FaceTime all go through the Private API helper, which isn't wired in yet.
                // Fail fast with a clear error rather than pretending (upstream #842).
                return .failure(CommandError("requires_private_api", "\(command.kind) requires the Private API helper"))
            }
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError("internal", String(describing: error)))
        }
    }

    private func send(_ command: Command) async throws -> JSONValue {
        if command.effectId != nil || command.replyToGuid != nil || command.subject != nil {
            throw CommandError("requires_private_api", "effects, replies and subjects require the Private API helper")
        }
        let paths = try await downloadAttachments(command.attachmentUrls ?? [])
        let before = try db.maxRowId
        let sender = self.sender
        try await Task.detached {
            try sender.send(chatGuid: command.chatGuid, to: command.to, text: command.text, attachmentPaths: paths)
        }.value

        // AppleScript gives no message id back, so confirm by finding our outgoing row in chat.db.
        // (The Private API path returns the guid directly.)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let sent = try db.messages(afterRowId: before, limit: 50).filter(\.isFromMe)
            if let match = sent.first(where: { command.text == nil || $0.text == command.text }) {
                return try JSONValue.from(match)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CommandError("unconfirmed", "Messages accepted the send but it did not appear in chat.db within 15s")
    }

    private func downloadAttachments(_ urls: [String]) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        // Messages can read from its own Attachments directory.
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/Attachments/Blueberry/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var paths: [String] = []
        for raw in urls {
            guard let url = URL(string: raw) else { throw CommandError("invalid_attachment", "bad URL: \(raw)") }
            let (tmp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CommandError("attachment_download_failed", "\(raw) returned HTTP \(http.statusCode)")
            }
            let name = response.suggestedFilename ?? url.lastPathComponent
            let dest = dir.appendingPathComponent(name.isEmpty ? "attachment" : name)
            try FileManager.default.moveItem(at: tmp, to: dest)
            paths.append(dest.path)
        }
        return paths
    }
}

private final class WeakAgent: @unchecked Sendable {
    weak var agent: Agent?
}
