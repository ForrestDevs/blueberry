import { Context, Deferred, Effect, Layer, PubSub, Schema, Stream } from "effect"
import { SqlClient } from "effect/sql"
import type { Socket } from "effect/socket"
import { CommandFailed, LineNotFound, LineOffline, LineTimeout } from "../api/Api.ts"
import { type Command, decodeAgentFrame, type Event, type Hello, PROTOCOL_VERSION, type ServerFrame } from "../domain/Protocol.ts"
import { newId, sha256 } from "./Sql.ts"

export interface LineEvent {
  readonly lineId: string
  readonly event: Event
}

export interface LineRow {
  readonly id: string
  readonly name: string
  readonly lastSeenAt: number | null
  readonly hello: string | null
}

interface Connection {
  readonly write: (frame: ServerFrame) => Effect.Effect<void>
  readonly kick: Deferred.Deferred<void>
  hello: Hello | null
  lastFrameAt: number
}

class HeartbeatTimeout extends Schema.TaggedError<HeartbeatTimeout>()("HeartbeatTimeout", {}) {}

const COMMAND_TIMEOUT = "30 seconds"
const OFFLINE_AFTER_MS = 30_000
const decoder = new TextDecoder()

// Tracks connected Mac agents ("lines"), routes commands to them, and durably
// stores the events they emit before acking.
export class LineHub extends Context.Service<LineHub, {
  authenticate(token: string): Effect.Effect<string | undefined>
  connect(lineId: string, socket: Socket.Socket): Effect.Effect<void>
  command(lineId: string, command: Command, id?: string): Effect.Effect<unknown, LineOffline | LineTimeout | CommandFailed>
  resolve(line: string | undefined): Effect.Effect<string, LineNotFound | LineOffline>
  readonly list: Effect.Effect<ReadonlyArray<LineRow & { readonly online: boolean; readonly agent: Hello | null }>>
  readonly events: Stream.Stream<LineEvent>
}>()("blueberry/LineHub") {
  static readonly layer = Layer.effect(
    LineHub,
    Effect.gen(function*() {
      const sql = yield* SqlClient.SqlClient
      const connections = new Map<string, Connection>()
      const pending = new Map<string, Deferred.Deferred<unknown, CommandFailed>>()
      const pubsub = yield* PubSub.unbounded<LineEvent>()

      const allLines = sql<LineRow>`SELECT id, name, last_seen_at AS lastSeenAt, hello FROM lines ORDER BY created_at`.pipe(Effect.orDie)

      const authenticate = Effect.fn("LineHub.authenticate")(function*(token: string) {
        const rows = yield* sql<{ id: string }>`SELECT id FROM lines WHERE token_hash = ${sha256(token)}`.pipe(Effect.orDie)
        return rows[0]?.id
      })

      // Stores the event; returns false when it carries nothing new (replays after reconnect).
      const persistEvent = Effect.fn("LineHub.persistEvent")(function*(lineId: string, seq: number, event: Event) {
        return yield* sql.withTransaction(Effect.gen(function*() {
          let changed = true
          if (event.kind === "message.new" || event.kind === "message.updated") {
            const m = event.message
            const body = JSON.stringify(m)
            const existing = yield* sql<{ body: string }>`SELECT body FROM messages WHERE guid = ${m.guid}`
            changed = existing[0]?.body !== body
            if (changed) {
              yield* sql`
                INSERT INTO messages (guid, line_id, row_id, chat_guid, body, updated_at)
                VALUES (${m.guid}, ${lineId}, ${m.rowId}, ${m.chatGuid}, ${body}, ${Date.now()})
                ON CONFLICT(guid) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`
            }
            yield* sql`UPDATE lines SET last_row_id = max(last_row_id, ${m.rowId}) WHERE id = ${lineId}`
          }
          yield* sql`UPDATE lines SET last_seq = max(last_seq, ${seq}), last_seen_at = ${Date.now()} WHERE id = ${lineId}`
          return changed
        })).pipe(Effect.orDie)
      })

      const handleFrame = Effect.fn("LineHub.handleFrame")(function*(lineId: string, conn: Connection, raw: string) {
        const frame = yield* decodeAgentFrame(raw).pipe(
          Effect.tapError((e) => Effect.logWarning(`bad frame from ${lineId}`, e.message)),
          Effect.option
        )
        if (frame._tag === "None") return
        const f = frame.value
        switch (f.type) {
          case "hello": {
            if (f.protocol !== PROTOCOL_VERSION) {
              yield* Effect.logWarning(`line ${lineId} speaks protocol ${f.protocol}, expected ${PROTOCOL_VERSION}`)
              return yield* Deferred.succeed(conn.kick, undefined)
            }
            conn.hello = f
            const rows = yield* sql<{ last_row_id: number }>`
              UPDATE lines SET hello = ${JSON.stringify(f)}, last_seen_at = ${Date.now()}
              WHERE id = ${lineId} RETURNING last_row_id`.pipe(Effect.orDie)
            yield* conn.write({ type: "welcome", resumeAfterRowId: rows[0]?.last_row_id ?? 0 })
            yield* Effect.logInfo(`line ${lineId} online: ${f.accounts.map((a) => a.handle).join(", ")}`)
            return
          }
          case "result": {
            const d = pending.get(f.id)
            if (!d) return
            pending.delete(f.id)
            if (f.ok) yield* Deferred.succeed(d, f.data ?? null)
            else yield* Deferred.fail(d, new CommandFailed({ code: f.error?.code ?? "agent_error", message: f.error?.message ?? "unknown error" }))
            return
          }
          case "event": {
            const changed = yield* persistEvent(lineId, f.seq, f.event)
            // Ack only after the event is durably stored so the agent re-sends after a crash.
            yield* conn.write({ type: "ack", seq: f.seq })
            if (changed) yield* PubSub.publish(pubsub, { lineId, event: f.event })
            return
          }
          case "ping":
            return yield* conn.write({ type: "pong", t: f.t })
          case "pong":
            return
        }
      })

      const connect = Effect.fn("LineHub.connect")(function*(lineId: string, socket: Socket.Socket) {
        const writer = yield* socket.writer
        const conn: Connection = {
          write: (frame) => writer.write(JSON.stringify(frame)).pipe(Effect.ignore),
          kick: yield* Deferred.make<void>(),
          hello: null,
          lastFrameAt: Date.now()
        }
        // A newer connection from the same line wins.
        const previous = connections.get(lineId)
        if (previous) yield* Deferred.succeed(previous.kick, undefined)
        connections.set(lineId, conn)

        const readLoop = Effect.gen(function*() {
          const reader = yield* socket.reader
          while (true) {
            const chunks = yield* reader.pull
            conn.lastFrameAt = Date.now()
            for (const chunk of chunks) {
              yield* handleFrame(lineId, conn, typeof chunk === "string" ? chunk : decoder.decode(chunk))
            }
          }
        })

        const heartbeat = Effect.gen(function*() {
          while (true) {
            yield* Effect.sleep("10 seconds")
            if (Date.now() - conn.lastFrameAt > OFFLINE_AFTER_MS) return yield* new HeartbeatTimeout()
            yield* conn.write({ type: "ping", t: Date.now() })
          }
        })

        yield* Effect.raceAll([readLoop, heartbeat, Deferred.await(conn.kick)]).pipe(
          Effect.scoped,
          Effect.catchCause((cause) => Effect.logInfo(`line ${lineId} disconnected`, cause)),
          Effect.ensuring(Effect.sync(() => {
            if (connections.get(lineId) === conn) connections.delete(lineId)
          }))
        )
      }, Effect.scoped)

      const command = Effect.fn("LineHub.command")(function*(lineId: string, cmd: Command, id: string = newId("cmd")) {
        const conn = connections.get(lineId)
        if (!conn?.hello) return yield* new LineOffline({ message: `line ${lineId} is not connected` })
        const d = yield* Deferred.make<unknown, CommandFailed>()
        pending.set(id, d)
        yield* conn.write({ type: "command", id, command: cmd })
        return yield* Deferred.await(d).pipe(
          Effect.timeoutOrElse({
            duration: COMMAND_TIMEOUT,
            orElse: () => Effect.fail(new LineTimeout({ message: `line did not respond within ${COMMAND_TIMEOUT}` }))
          }),
          Effect.ensuring(Effect.sync(() => pending.delete(id)))
        )
      })

      // Picks a line: by id, name, or account handle; defaults to the first online line.
      const resolve = Effect.fn("LineHub.resolve")(function*(line: string | undefined) {
        const lines = yield* allLines
        if (line) {
          const match = lines.find((l) =>
            l.id === line || l.name === line ||
            (l.hello !== null && (JSON.parse(l.hello) as Hello).accounts.some((a) => a.handle === line))
          )
          if (!match) return yield* new LineNotFound({ line })
          return match.id
        }
        const online = lines.find((l) => connections.get(l.id)?.hello)
        if (!online) return yield* new LineOffline({ message: "no line is online" })
        return online.id
      })

      const list = allLines.pipe(
        Effect.map((rows) =>
          rows.map((l) => {
            const hello = connections.get(l.id)?.hello ?? null
            return { ...l, online: hello !== null, agent: hello }
          })
        )
      )

      return LineHub.of({ authenticate, connect, command, resolve, list, events: Stream.fromPubSub(pubsub) })
    })
  )
}
