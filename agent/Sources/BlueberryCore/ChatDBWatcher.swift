import Foundation

/// Turns chat.db changes into `message.new` / `message.updated` events.
///
/// - New messages: ROWID cursor, so nothing is skipped regardless of clock skew or timing.
/// - Updates (delivered/read/edited/unsent): fingerprints of the most recent rows are compared each tick.
/// - Wake-ups: a file-system source on chat.db-wal for low latency, plus a backup poll in case the
///   source misses a write or Messages swaps the file out (upstream only had the watcher).
public actor ChatDBWatcher {
    public typealias Emit = @Sendable (Event) async -> Void

    private let db: ChatDB
    private let emit: Emit
    private var cursor: Int64
    private var fingerprints: [String: String] = [:]
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pollTask: Task<Void, Never>?
    private var pendingTick = false

    private static let recentWindow = 300
    private static let pollInterval: Duration = .seconds(2)

    public init(db: ChatDB, resumeAfterRowId: Int64, emit: @escaping Emit) {
        self.db = db
        self.cursor = resumeAfterRowId
        self.emit = emit
    }

    public func start() {
        // Seed fingerprints so already-known rows don't all fire as updates on first tick.
        if let recent = try? db.recentMessages(limit: Self.recentWindow) {
            for m in recent where m.rowId <= cursor { fingerprints[m.guid] = m.fingerprint }
        }
        watchFiles()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await self?.tick()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    /// Called on every (re)connect with the server's durable cursor. New rows are replayed from
    /// there, and the recent window is re-sent as updates so changes made while offline are not lost
    /// (the server only republishes updates whose content actually changed).
    public func resync(afterRowId rowId: Int64) async {
        cursor = rowId
        do {
            for m in try db.recentMessages(limit: Self.recentWindow) where m.rowId <= cursor {
                fingerprints[m.guid] = m.fingerprint
                await emit(.messageUpdated(m))
            }
        } catch {
            Log.error("resync failed: \(error)")
        }
        await tick()
    }

    public func tick() async {
        guard !pendingTick else { return }
        pendingTick = true
        defer { pendingTick = false }
        do {
            // Drain in pages so a large backlog after downtime streams out in order.
            while true {
                let batch = try db.messages(afterRowId: cursor, limit: 500)
                for m in batch {
                    fingerprints[m.guid] = m.fingerprint
                    await emit(.messageNew(m))
                    cursor = m.rowId
                }
                if batch.count < 500 { break }
            }
            for m in try db.recentMessages(limit: Self.recentWindow) where m.rowId <= cursor {
                let fp = m.fingerprint
                if let old = fingerprints[m.guid], old != fp {
                    await emit(.messageUpdated(m))
                }
                fingerprints[m.guid] = fp
            }
            if fingerprints.count > Self.recentWindow * 4 {
                let keep = Set(try db.recentMessages(limit: Self.recentWindow).map(\.guid))
                fingerprints = fingerprints.filter { keep.contains($0.key) }
            }
        } catch {
            Log.error("chat.db tick failed: \(error)")
        }
    }

    private func watchFiles() {
        let base = db.path
        for path in [base, base + "-wal"] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events = source.data
                Task {
                    // Debounce: Messages writes in bursts.
                    try? await Task.sleep(for: .milliseconds(150))
                    await self.tick()
                    // The WAL is deleted/replaced on checkpoint; re-arm the watchers.
                    if events.contains(.delete) || events.contains(.rename) { await self.rearm() }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func rearm() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        watchFiles()
    }
}
