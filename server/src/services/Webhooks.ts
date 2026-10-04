import { Context, Effect, Layer, Schedule, Stream } from "effect"
import { SqlClient } from "effect/sql"
import { LineHub, type LineEvent } from "./LineHub.ts"
import { newId, randomToken } from "./Sql.ts"

const MAX_ATTEMPTS = 12

export interface WebhookRow {
  readonly id: string
  readonly url: string
  readonly events: ReadonlyArray<string>
}

interface Due {
  readonly id: string
  readonly payload: string
  readonly attempts: number
  readonly url: string
  readonly secret: string
}

// Durable, signed webhook delivery with exponential backoff (up to ~1h between tries).
// Header: `Blueberry-Signature: t=<unix ms>,v1=<hex hmac-sha256(secret, "<t>.<body>")>`
export class Webhooks extends Context.Service<Webhooks, {
  readonly list: Effect.Effect<ReadonlyArray<WebhookRow>>
  create(url: string, events: ReadonlyArray<string>): Effect.Effect<WebhookRow & { readonly secret: string }>
  remove(id: string): Effect.Effect<void>
}>()("blueberry/Webhooks") {
  static readonly layer = Layer.effect(
    Webhooks,
    Effect.gen(function*() {
      const sql = yield* SqlClient.SqlClient
      const hub = yield* LineHub

      const enqueue = Effect.fn("Webhooks.enqueue")(function*({ lineId, event }: LineEvent) {
        const hooks = yield* sql<{ id: string; events: string }>`SELECT id, events FROM webhooks`
        const payload = JSON.stringify({ id: newId("evt"), type: event.kind, lineId, createdAt: new Date().toISOString(), data: event })
        for (const hook of hooks) {
          const events = JSON.parse(hook.events) as Array<string>
          if (!events.includes("*") && !events.includes(event.kind)) continue
          yield* sql`INSERT INTO webhook_deliveries (id, webhook_id, payload, next_attempt_at)
                     VALUES (${newId("dlv")}, ${hook.id}, ${payload}, ${Date.now()})`
        }
      }, Effect.orDie)

      const deliver = Effect.fn("Webhooks.deliver")(function*(d: Due) {
        const t = Date.now()
        const sig = new Bun.CryptoHasher("sha256", d.secret).update(`${t}.${d.payload}`).digest("hex")
        const result = yield* Effect.tryPromise(async () => {
          const res = await fetch(d.url, {
            method: "POST",
            headers: { "content-type": "application/json", "blueberry-signature": `t=${t},v1=${sig}` },
            body: d.payload,
            signal: AbortSignal.timeout(10_000)
          })
          if (!res.ok) throw new Error(`HTTP ${res.status}`)
        }).pipe(Effect.result)
        if (result._tag === "Success") {
          yield* sql`UPDATE webhook_deliveries SET delivered_at = ${Date.now()}, attempts = attempts + 1 WHERE id = ${d.id}`
        } else {
          const backoff = Math.min(2 ** d.attempts * 1_000, 60 * 60_000)
          yield* sql`UPDATE webhook_deliveries
                     SET attempts = attempts + 1, next_attempt_at = ${Date.now() + backoff}, last_error = ${String(result.failure.cause)}
                     WHERE id = ${d.id}`
        }
      }, Effect.orDie)

      const drain = Effect.gen(function*() {
        const due = yield* sql<Due>`
          SELECT d.id, d.payload, d.attempts, w.url, w.secret FROM webhook_deliveries d
          JOIN webhooks w ON w.id = d.webhook_id
          WHERE d.delivered_at IS NULL AND d.attempts < ${MAX_ATTEMPTS} AND d.next_attempt_at <= ${Date.now()}
          ORDER BY d.next_attempt_at LIMIT 50`
        yield* Effect.forEach(due, deliver, { concurrency: 10 })
      }).pipe(Effect.orDie)

      yield* hub.events.pipe(Stream.runForEach(enqueue), Effect.forkScoped)
      yield* drain.pipe(Effect.repeat(Schedule.spaced("1 second")), Effect.forkScoped)

      const list = sql<{ id: string; url: string; events: string }>`SELECT id, url, events FROM webhooks ORDER BY created_at`.pipe(
        Effect.map((rows) => rows.map((r) => ({ ...r, events: JSON.parse(r.events) as Array<string> }))),
        Effect.orDie
      )

      const create = Effect.fn("Webhooks.create")(function*(url: string, events: ReadonlyArray<string>) {
        const id = newId("wh")
        const secret = randomToken("whsec")
        yield* sql`INSERT INTO webhooks (id, url, secret, events, created_at)
                   VALUES (${id}, ${url}, ${secret}, ${JSON.stringify(events)}, ${Date.now()})`
        return { id, url, events, secret }
      }, Effect.orDie)

      const remove = Effect.fn("Webhooks.remove")(function*(id: string) {
        yield* sql`DELETE FROM webhooks WHERE id = ${id}`
      }, Effect.orDie)

      return Webhooks.of({ list, create, remove })
    })
  )
}
