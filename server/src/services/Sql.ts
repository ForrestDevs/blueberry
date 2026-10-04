import { SqliteClient, SqliteMigrator } from "@effect/sql-sqlite-bun"
import { Config, Effect, Layer } from "effect"
import { SqlClient } from "effect/sql"

const migrations = SqliteMigrator.fromRecord({
  "0001_init": Effect.gen(function*() {
    const sql = yield* SqlClient.SqlClient
    yield* sql`
      CREATE TABLE lines (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        token_hash TEXT NOT NULL UNIQUE,
        last_row_id INTEGER NOT NULL DEFAULT 0,
        last_seq INTEGER NOT NULL DEFAULT 0,
        last_seen_at INTEGER,
        hello TEXT,
        created_at INTEGER NOT NULL
      )`
    yield* sql`
      CREATE TABLE api_keys (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        key_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
      )`
    yield* sql`
      CREATE TABLE messages (
        guid TEXT PRIMARY KEY,
        line_id TEXT NOT NULL REFERENCES lines(id),
        row_id INTEGER NOT NULL,
        chat_guid TEXT,
        body TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )`
    yield* sql`CREATE INDEX messages_chat ON messages(chat_guid, row_id)`
    yield* sql`
      CREATE TABLE webhooks (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        secret TEXT NOT NULL,
        events TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )`
    yield* sql`
      CREATE TABLE webhook_deliveries (
        id TEXT PRIMARY KEY,
        webhook_id TEXT NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL,
        last_error TEXT,
        delivered_at INTEGER
      )`
    yield* sql`CREATE INDEX deliveries_pending ON webhook_deliveries(delivered_at, next_attempt_at)`
  })
})

const ClientLayer = Layer.unwrap(
  Effect.gen(function*() {
    const filename = yield* Config.String("BLUEBERRY_DB").pipe(Config.withDefault("blueberry.sqlite"))
    return SqliteClient.layer({ filename })
  })
)

export const SqlLive = SqliteMigrator.layer({ loader: migrations }).pipe(Layer.provideMerge(ClientLayer))

export const sha256 = (value: string) => new Bun.CryptoHasher("sha256").update(value).digest("hex")

export const newId = (prefix: string) => `${prefix}_${Bun.randomUUIDv7().replaceAll("-", "")}`

export const randomToken = (prefix: string) =>
  `${prefix}_${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url")}`
