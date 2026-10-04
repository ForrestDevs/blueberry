import { Effect, Layer } from "effect"
import { HttpApiBuilder } from "effect/http-api"
import { SqlClient } from "effect/sql"
import { Api, InvalidRequest } from "../api/Api.ts"
import type { Command, Message } from "../domain/Protocol.ts"
import { LineHub } from "../services/LineHub.ts"
import { sha256 } from "../services/Sql.ts"

const toArray = (value: string | ReadonlyArray<string>) => (typeof value === "string" ? [value] : value)

const LinesHandlers = HttpApiBuilder.group(Api, "lines", Effect.fn(function*(handlers) {
  const hub = yield* LineHub
  return handlers.handleAll({ list: () => hub.list })
}))

const MessagesHandlers = HttpApiBuilder.group(Api, "messages", Effect.fn(function*(handlers) {
  const hub = yield* LineHub
  const sql = yield* SqlClient.SqlClient

  // Runs a command on the selected line and wraps the result.
  const run = Effect.fn(function*(line: string | undefined, command: Command, idempotencyKey?: string) {
    const lineId = yield* hub.resolve(line)
    // The agent dedupes by command id, so a retried request with the same key never double-sends.
    const id = idempotencyKey ? `cmd_${sha256(`${lineId}:${idempotencyKey}`).slice(0, 32)}` : undefined
    const data = yield* hub.command(lineId, command, id)
    return { line: lineId, data }
  })

  return handlers.handleAll({
    send: ({ payload: { line, to, ...rest }, headers }) => {
      if (!rest.chatGuid === !to) return Effect.fail(new InvalidRequest({ message: "provide exactly one of chatGuid or to" }))
      if (!rest.text && !rest.attachmentUrls?.length) return Effect.fail(new InvalidRequest({ message: "provide text or attachmentUrls" }))
      return run(line, { kind: "message.send", ...rest, ...(to ? { to: toArray(to) } : {}) }, headers["idempotency-key"])
    },
    list: Effect.fn(function*({ query }) {
      const before = query.beforeRowId ?? Number.MAX_SAFE_INTEGER
      const limit = Math.min(query.limit ?? 50, 200)
      const rows = yield* (query.chatGuid
        ? sql<{ body: string }>`SELECT body FROM messages WHERE chat_guid = ${query.chatGuid} AND row_id < ${before} ORDER BY row_id DESC LIMIT ${limit}`
        : sql<{ body: string }>`SELECT body FROM messages WHERE row_id < ${before} ORDER BY row_id DESC LIMIT ${limit}`
      ).pipe(Effect.orDie)
      return rows.map((r) => JSON.parse(r.body) as Message)
    }),
    react: ({ params, payload: { line, ...rest } }) => run(line, { kind: "message.react", messageGuid: params.guid, ...rest }),
    edit: ({ params, payload: { line, ...rest } }) => run(line, { kind: "message.edit", messageGuid: params.guid, ...rest }),
    unsend: ({ params, payload: { line, ...rest } }) => run(line, { kind: "message.unsend", messageGuid: params.guid, ...rest })
  })
}))

const ChatsHandlers = HttpApiBuilder.group(Api, "chats", Effect.fn(function*(handlers) {
  const hub = yield* LineHub

  const run = Effect.fn(function*(line: string | undefined, command: Command) {
    const lineId = yield* hub.resolve(line)
    return { line: lineId, data: yield* hub.command(lineId, command) }
  })

  return handlers.handleAll({
    list: ({ query }) =>
      run(query.line, { kind: "sync.chats", limit: query.limit ?? 100, offset: query.offset ?? 0 }).pipe(
        Effect.map(({ line, data }) => ({ line, data: data as never }))
      ),
    typing: ({ params, payload }) => run(payload.line, { kind: "chat.typing", chatGuid: params.guid, typing: payload.typing }),
    markRead: ({ params, payload }) => run(payload.line, { kind: "chat.markRead", chatGuid: params.guid }),
    update: Effect.fn(function*({ params, payload }) {
      const lineId = yield* hub.resolve(payload.line)
      if (payload.name !== undefined) {
        yield* hub.command(lineId, { kind: "chat.rename", chatGuid: params.guid, name: payload.name })
      }
      if (payload.addParticipants?.length || payload.removeParticipants?.length) {
        yield* hub.command(lineId, {
          kind: "chat.participants",
          chatGuid: params.guid,
          add: payload.addParticipants ?? [],
          remove: payload.removeParticipants ?? []
        })
      }
      return { line: lineId, data: { ok: true } }
    }),
    availability: ({ params, query }) => run(query.line, { kind: "handle.availability", handle: params.handle })
  })
}))

const FaceTimeHandlers = HttpApiBuilder.group(Api, "facetime", Effect.fn(function*(handlers) {
  const hub = yield* LineHub

  const run = Effect.fn(function*(line: string | undefined, command: Command) {
    const lineId = yield* hub.resolve(line)
    return { line: lineId, data: yield* hub.command(lineId, command) }
  })

  return handlers.handleAll({
    call: ({ payload }) => run(payload.line, { kind: "facetime.call", handles: toArray(payload.to), audioOnly: payload.audioOnly ?? false }),
    answer: ({ params, payload }) => run(payload.line, { kind: "facetime.answer", callId: params.id }),
    end: ({ params, payload }) => run(payload.line, { kind: "facetime.end", callId: params.id }),
    link: ({ payload }) => run(payload.line, { kind: "facetime.link" })
  })
}))

import { Webhooks } from "../services/Webhooks.ts"

const WebhooksHandlers = HttpApiBuilder.group(Api, "webhooks", Effect.fn(function*(handlers) {
  const webhooks = yield* Webhooks
  return handlers.handleAll({
    list: () => webhooks.list,
    create: ({ payload }) => webhooks.create(payload.url, payload.events ?? ["*"]),
    remove: ({ params }) => webhooks.remove(params.id)
  })
}))

const SystemHandlers = HttpApiBuilder.group(Api, "system", Effect.fn(function*(handlers) {
  return handlers.handleAll({ health: () => Effect.void })
}))

export const HandlersLive = Layer.mergeAll(
  LinesHandlers,
  MessagesHandlers,
  ChatsHandlers,
  FaceTimeHandlers,
  WebhooksHandlers,
  SystemHandlers
)
