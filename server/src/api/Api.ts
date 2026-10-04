import { Schema } from "effect"
import { HttpApi, HttpApiEndpoint, HttpApiGroup, HttpApiMiddleware, HttpApiSchema, HttpApiSecurity, OpenApi } from "effect/http-api"
import { Chat, Hello, Message, Reaction } from "../domain/Protocol.ts"

// Public HTTP API. Kept free of server code so the client can import it and get a
// fully typed HttpApiClient.

// ---- Errors ----

export class Unauthorized extends Schema.TaggedError<Unauthorized>()("Unauthorized", {
  message: Schema.String
}, { httpApiStatus: 401 }) {}

export class LineNotFound extends Schema.TaggedError<LineNotFound>()("LineNotFound", {
  line: Schema.String
}, { httpApiStatus: 404 }) {}

export class LineOffline extends Schema.TaggedError<LineOffline>()("LineOffline", {
  message: Schema.String
}, { httpApiStatus: 503 }) {}

export class LineTimeout extends Schema.TaggedError<LineTimeout>()("LineTimeout", {
  message: Schema.String
}, { httpApiStatus: 504 }) {}

// The Mac executed the command and it failed (e.g. handle not on iMessage).
export class CommandFailed extends Schema.TaggedError<CommandFailed>()("CommandFailed", {
  code: Schema.String,
  message: Schema.String
}, { httpApiStatus: 422 }) {}

export class InvalidRequest extends Schema.TaggedError<InvalidRequest>()("InvalidRequest", {
  message: Schema.String
}, { httpApiStatus: 400 }) {}

const LineErrors = [LineNotFound, LineOffline, LineTimeout, CommandFailed] as const

// ---- Auth ----

export class Authorization extends HttpApiMiddleware.Service<Authorization>()("blueberry/Authorization", {
  requiredForClient: true,
  security: { bearer: HttpApiSecurity.bearer },
  error: Unauthorized
}) {}

// ---- Shared shapes ----

const LineSelector = { line: Schema.optional(Schema.String) }

export const CommandResult = Schema.Struct({
  line: Schema.String,
  data: Schema.Unknown
})

export const Line = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  online: Schema.Boolean,
  lastSeenAt: Schema.NullOr(Schema.Number),
  agent: Schema.NullOr(Hello)
})

export const Webhook = Schema.Struct({
  id: Schema.String,
  url: Schema.String,
  events: Schema.Array(Schema.String)
})

// ---- Groups ----

export class LinesApi extends HttpApiGroup.make("lines").add(
  HttpApiEndpoint.get("list", "/lines", { success: Schema.Array(Line) })
).middleware(Authorization) {}

export class MessagesApi extends HttpApiGroup.make("messages").add(
  HttpApiEndpoint.post("send", "/messages", {
    payload: Schema.Struct({
      ...LineSelector,
      chatGuid: Schema.optional(Schema.String),
      to: Schema.optional(Schema.Union([Schema.String, Schema.Array(Schema.String)])),
      text: Schema.optional(Schema.String),
      attachmentUrls: Schema.optional(Schema.Array(Schema.String)),
      replyToGuid: Schema.optional(Schema.String),
      effectId: Schema.optional(Schema.String),
      subject: Schema.optional(Schema.String)
    }),
    headers: { "idempotency-key": Schema.optional(Schema.String) },
    success: CommandResult,
    error: [...LineErrors, InvalidRequest]
  }),
  HttpApiEndpoint.get("list", "/messages", {
    query: {
      chatGuid: Schema.optional(Schema.String),
      beforeRowId: Schema.optional(Schema.NumberFromString),
      limit: Schema.optional(Schema.NumberFromString)
    },
    success: Schema.Array(Message)
  }),
  HttpApiEndpoint.post("react", "/messages/:guid/reactions", {
    params: { guid: Schema.String },
    payload: Schema.Struct({
      ...LineSelector,
      chatGuid: Schema.String,
      reaction: Reaction,
      remove: Schema.optional(Schema.Boolean),
      partIndex: Schema.optional(Schema.Number)
    }),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.post("edit", "/messages/:guid/edit", {
    params: { guid: Schema.String },
    payload: Schema.Struct({ ...LineSelector, chatGuid: Schema.String, text: Schema.String, partIndex: Schema.optional(Schema.Number) }),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.post("unsend", "/messages/:guid/unsend", {
    params: { guid: Schema.String },
    payload: Schema.Struct({ ...LineSelector, chatGuid: Schema.String, partIndex: Schema.optional(Schema.Number) }),
    success: CommandResult,
    error: LineErrors
  })
).middleware(Authorization) {}

export class ChatsApi extends HttpApiGroup.make("chats").add(
  HttpApiEndpoint.get("list", "/chats", {
    query: { ...LineSelector, limit: Schema.optional(Schema.NumberFromString), offset: Schema.optional(Schema.NumberFromString) },
    success: Schema.Struct({ line: Schema.String, data: Schema.Array(Chat) }),
    error: LineErrors
  }),
  HttpApiEndpoint.post("typing", "/chats/:guid/typing", {
    params: { guid: Schema.String },
    payload: Schema.Struct({ ...LineSelector, typing: Schema.Boolean }),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.post("markRead", "/chats/:guid/read", {
    params: { guid: Schema.String },
    payload: Schema.Struct(LineSelector),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.patch("update", "/chats/:guid", {
    params: { guid: Schema.String },
    payload: Schema.Struct({
      ...LineSelector,
      name: Schema.optional(Schema.String),
      addParticipants: Schema.optional(Schema.Array(Schema.String)),
      removeParticipants: Schema.optional(Schema.Array(Schema.String))
    }),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.get("availability", "/handles/:handle/availability", {
    params: { handle: Schema.String },
    query: LineSelector,
    success: CommandResult,
    error: LineErrors
  })
).middleware(Authorization) {}

export class FaceTimeApi extends HttpApiGroup.make("facetime").add(
  HttpApiEndpoint.post("call", "/facetime/calls", {
    payload: Schema.Struct({
      ...LineSelector,
      to: Schema.Union([Schema.String, Schema.Array(Schema.String)]),
      audioOnly: Schema.optional(Schema.Boolean)
    }),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.post("answer", "/facetime/calls/:id/answer", {
    params: { id: Schema.String },
    payload: Schema.Struct(LineSelector),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.post("end", "/facetime/calls/:id/end", {
    params: { id: Schema.String },
    payload: Schema.Struct(LineSelector),
    success: CommandResult,
    error: LineErrors
  }),
  HttpApiEndpoint.post("link", "/facetime/links", {
    payload: Schema.Struct(LineSelector),
    success: CommandResult,
    error: LineErrors
  })
).middleware(Authorization) {}

export class WebhooksApi extends HttpApiGroup.make("webhooks").add(
  HttpApiEndpoint.get("list", "/webhooks", { success: Schema.Array(Webhook) }),
  HttpApiEndpoint.post("create", "/webhooks", {
    payload: Schema.Struct({ url: Schema.String, events: Schema.optional(Schema.Array(Schema.String)) }),
    // The signing secret is only returned on creation.
    success: Schema.Struct({ ...Webhook.fields, secret: Schema.String })
  }),
  HttpApiEndpoint.delete("remove", "/webhooks/:id", {
    params: { id: Schema.String },
    success: HttpApiSchema.NoContent
  })
).middleware(Authorization) {}

export class SystemApi extends HttpApiGroup.make("system", { topLevel: true }).add(
  HttpApiEndpoint.get("health", "/health", { success: HttpApiSchema.NoContent })
) {}

export class Api extends HttpApi.make("blueberry")
  .add(LinesApi)
  .add(MessagesApi)
  .add(ChatsApi)
  .add(FaceTimeApi)
  .add(WebhooksApi)
  .prefix("/v1")
  .add(SystemApi)
  .annotateMerge(OpenApi.annotations({ title: "Blueberry API" }))
{}
