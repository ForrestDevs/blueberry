import { BunRuntime } from "@effect/platform-bun"
import { Effect } from "effect"
import { SqlClient } from "effect/sql"
import { newId, randomToken, sha256, SqlLive } from "./services/Sql.ts"

// Admin CLI: `bun run cli create-line <name>` / `bun run cli create-api-key [name]`
const [cmd, name] = process.argv.slice(2)

const program = Effect.gen(function*() {
  const sql = yield* SqlClient.SqlClient
  switch (cmd) {
    case "create-line": {
      if (!name) return yield* Effect.die("usage: create-line <name>")
      const token = randomToken("bbline")
      const id = newId("line")
      yield* sql`INSERT INTO lines (id, name, token_hash, created_at) VALUES (${id}, ${name}, ${sha256(token)}, ${Date.now()})`
      console.log(`line:  ${id}\ntoken: ${token}\n\nPaste the token into the Blueberry agent on the Mac. It is shown only once.`)
      return
    }
    case "create-api-key": {
      const key = randomToken("bb")
      yield* sql`INSERT INTO api_keys (id, name, key_hash, created_at) VALUES (${newId("key")}, ${name ?? "default"}, ${sha256(key)}, ${Date.now()})`
      console.log(`api key: ${key}\n\nShown only once.`)
      return
    }
    default:
      console.log("usage: bun run cli <create-line <name> | create-api-key [name]>")
  }
})

program.pipe(Effect.provide(SqlLive), BunRuntime.runMain)
