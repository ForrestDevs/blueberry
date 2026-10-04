import { Effect, Layer, Redacted } from "effect"
import { SqlClient } from "effect/sql"
import { Authorization, Unauthorized } from "../api/Api.ts"
import { sha256 } from "../services/Sql.ts"

export const AuthorizationLive = Layer.effect(
  Authorization,
  Effect.gen(function*() {
    const sql = yield* SqlClient.SqlClient
    return Authorization.of({
      bearer: Effect.fn(function*(httpEffect, { credential }) {
        const rows = yield* sql`SELECT 1 FROM api_keys WHERE key_hash = ${sha256(Redacted.value(credential))}`.pipe(Effect.orDie)
        if (rows.length === 0) return yield* new Unauthorized({ message: "missing or invalid API key" })
        return yield* httpEffect
      })
    })
  })
)
