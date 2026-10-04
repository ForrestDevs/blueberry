import Foundation

/// The outbound WebSocket to the Blueberry server. Reconnects forever with capped backoff.
public actor ServerConnection {
    public struct Config: Sendable {
        public var url: URL
        public var token: String

        public init(url: URL, token: String) {
            self.url = url
            self.token = token
        }
    }

    public enum State: Sendable, Equatable {
        case disconnected(reason: String?)
        case connecting
        case connected
    }

    public typealias HelloProvider = @Sendable () async -> (capabilities: [String], accounts: [Account])
    public typealias OnWelcome = @Sendable (_ resumeAfterRowId: Int64) async -> Void
    public typealias OnCommand = @Sendable (_ id: String, _ command: Command) async -> Result<JSONValue, CommandError>
    public typealias OnState = @Sendable (State) async -> Void

    private let config: Config
    private let hello: HelloProvider
    private let onWelcome: OnWelcome
    private let onCommand: OnCommand
    private let onState: OnState
    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var seq = 0
    private var ready = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(config: Config, hello: @escaping HelloProvider, onWelcome: @escaping OnWelcome,
                onCommand: @escaping OnCommand, onState: @escaping OnState) {
        self.config = config
        self.hello = hello
        self.onWelcome = onWelcome
        self.onCommand = onCommand
        self.onState = onState
    }

    public func start() {
        guard runLoop == nil else { return }
        runLoop = Task { await self.loop() }
    }

    public func stop() {
        runLoop?.cancel()
        runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// Sends an event if connected. Dropped events are recovered on reconnect via `resync`,
    /// because chat.db itself is the durable outbox.
    public func send(_ event: Event) async {
        guard ready else { return }
        seq += 1
        await write(EventFrame(seq: seq, event: event))
    }

    // MARK: - Internals

    private func loop() async {
        var attempt = 0
        while !Task.isCancelled {
            await onState(.connecting)
            var request = URLRequest(url: config.url)
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()

            let (capabilities, accounts) = await hello()
            let macOS = ProcessInfo.processInfo.operatingSystemVersion
            await write(HelloFrame(agentVersion: Self.version,
                                   macOS: "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)",
                                   capabilities: capabilities, accounts: accounts))

            let reason = await receiveUntilClosed(task)
            ready = false
            if case .connected = lastState { attempt = 0 }
            await setState(.disconnected(reason: reason))
            attempt += 1
            let delay = min(pow(2.0, Double(attempt)), 30) * Double.random(in: 0.8...1.2)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private var lastState: State = .disconnected(reason: nil)

    private func setState(_ state: State) async {
        lastState = state
        await onState(state)
    }

    private func receiveUntilClosed(_ task: URLSessionWebSocketTask) async -> String {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if let response = task.response as? HTTPURLResponse, response.statusCode == 401 {
                    return "server rejected the line token"
                }
                return error.localizedDescription
            }
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let frame = try? decoder.decode(ServerFrame.self, from: data) else {
                Log.error("undecodable server frame: \(String(decoding: data, as: UTF8.self))")
                continue
            }
            await handle(frame)
        }
    }

    private func handle(_ frame: ServerFrame) async {
        switch frame.type {
        case "welcome":
            seq = 0
            ready = true
            await setState(.connected)
            Log.info("connected; resuming after ROWID \(frame.resumeAfterRowId ?? 0)")
            await onWelcome(frame.resumeAfterRowId ?? 0)
        case "command":
            guard let id = frame.id, let command = frame.command else { return }
            // Run concurrently so a slow command (e.g. attachment download) doesn't block others.
            Task {
                let result = await onCommand(id, command)
                switch result {
                case .success(let data): await write(ResultFrame(id: id, ok: true, data: data))
                case .failure(let e): await write(ResultFrame(id: id, ok: false, error: .init(code: e.code, message: e.message)))
                }
            }
        case "ping":
            await write(PingFrame(type: "pong", t: frame.t ?? 0))
        default:
            break // ack, pong, and future frame types
        }
    }

    private func write<T: Encodable>(_ frame: T) async {
        guard let task, let data = try? encoder.encode(frame) else { return }
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            Log.error("send failed: \(error.localizedDescription)")
        }
    }

    public static let version = "0.1.0"
}
