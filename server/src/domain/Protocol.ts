import { Schema } from "effect"

// Canonical agent <-> server protocol (see protocol/README.md).
// Mirrored in agent/Sources/BlueberryCore/Protocol.swift — change both together.

export const PROTOCOL_VERSION = 1

const NullableString = Schema.NullOr(Schema.String)

export const Account = Schema.Struct({
  service: Schema.Literals(["iMessage", "SMS", "RCS"]),
  handle: Schema.String
})

export const Attachment = Schema.Struct({
  guid: Schema.String,
  filename: NullableString,
  mimeType: NullableString,
  uti: NullableString,
  totalBytes: Schema.Number,
  isSticker: Schema.Boolean
})

export const Message = Schema.Struct({
  rowId: Schema.Number,
  guid: Schema.String,
  chatGuid: NullableString,
  sender: NullableString, // null when isFromMe
  isFromMe: Schema.Boolean,
  service: NullableString,
  text: NullableString,
  subject: NullableString,
  replyToGuid: NullableString,
  threadOriginatorGuid: NullableString,
  associatedMessageGuid: NullableString, // tapback target
  associatedMessageType: Schema.Number, // 0 normal, 2000-2007 add tapback, 3000-3007 remove
  expressiveSendStyleId: NullableString,
  dateSent: Schema.String, // ISO-8601
  dateDelivered: NullableString,
  dateRead: NullableString,
  dateEdited: NullableString,
  dateRetracted: NullableString,
  error: Schema.Number,
  attachments: Schema.Array(Attachment)
})
export type Message = typeof Message.Type

export const Chat = Schema.Struct({
  guid: Schema.String,
  displayName: NullableString,
  isGroup: Schema.Boolean,
  service: NullableString,
  participants: Schema.Array(Schema.String)
})

export const Reaction = Schema.Literals(["love", "like", "dislike", "laugh", "emphasize", "question"])

// ---- Commands (server -> agent) ----

export const Command = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal("message.send"),
    // Exactly one of chatGuid or to. `to` with >1 handle targets a group.
    chatGuid: Schema.optional(Schema.String),
    to: Schema.optional(Schema.Array(Schema.String)),
    text: Schema.optional(Schema.String),
    attachmentUrls: Schema.optional(Schema.Array(Schema.String)),
    replyToGuid: Schema.optional(Schema.String),
    effectId: Schema.optional(Schema.String),
    subject: Schema.optional(Schema.String)
  }),
  Schema.Struct({
    kind: Schema.Literal("message.react"),
    chatGuid: Schema.String,
    messageGuid: Schema.String,
    reaction: Reaction,
    remove: Schema.optional(Schema.Boolean),
    partIndex: Schema.optional(Schema.Number)
  }),
  Schema.Struct({
    kind: Schema.Literal("message.edit"),
    chatGuid: Schema.String,
    messageGuid: Schema.String,
    text: Schema.String,
    partIndex: Schema.optional(Schema.Number)
  }),
  Schema.Struct({
    kind: Schema.Literal("message.unsend"),
    chatGuid: Schema.String,
    messageGuid: Schema.String,
    partIndex: Schema.optional(Schema.Number)
  }),
  Schema.Struct({ kind: Schema.Literal("chat.typing"), chatGuid: Schema.String, typing: Schema.Boolean }),
  Schema.Struct({ kind: Schema.Literal("chat.markRead"), chatGuid: Schema.String }),
  Schema.Struct({ kind: Schema.Literal("chat.rename"), chatGuid: Schema.String, name: Schema.String }),
  Schema.Struct({
    kind: Schema.Literal("chat.participants"),
    chatGuid: Schema.String,
    add: Schema.Array(Schema.String),
    remove: Schema.Array(Schema.String)
  }),
  Schema.Struct({ kind: Schema.Literal("handle.availability"), handle: Schema.String }),
  Schema.Struct({ kind: Schema.Literal("facetime.call"), handles: Schema.Array(Schema.String), audioOnly: Schema.Boolean }),
  Schema.Struct({ kind: Schema.Literal("facetime.answer"), callId: Schema.String }),
  Schema.Struct({ kind: Schema.Literal("facetime.end"), callId: Schema.String }),
  Schema.Struct({ kind: Schema.Literal("facetime.link") }),
  Schema.Struct({ kind: Schema.Literal("sync.chats"), limit: Schema.Number, offset: Schema.Number })
])
export type Command = typeof Command.Type

// ---- Events (agent -> server) ----

export const Event = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("message.new"), message: Message }),
  Schema.Struct({ kind: Schema.Literal("message.updated"), message: Message }), // delivered/read/edited/unsent
  Schema.Struct({ kind: Schema.Literal("chat.typing"), chatGuid: Schema.String, handle: Schema.String, typing: Schema.Boolean }),
  Schema.Struct({ kind: Schema.Literal("chat.updated"), chat: Chat }),
  Schema.Struct({
    kind: Schema.Literal("facetime.incoming"),
    callId: Schema.String,
    handles: Schema.Array(Schema.String),
    audioOnly: Schema.Boolean
  }),
  Schema.Struct({
    kind: Schema.Literal("facetime.status"),
    callId: Schema.String,
    status: Schema.Literals(["ringing", "connecting", "active", "ended", "declined", "missed"])
  }),
  Schema.Struct({
    kind: Schema.Literal("agent.health"),
    privateApi: Schema.Boolean,
    messagesRunning: Schema.Boolean,
    facetimeRunning: Schema.Boolean
  })
])
export type Event = typeof Event.Type

// ---- Frames ----

export const Hello = Schema.Struct({
  type: Schema.Literal("hello"),
  protocol: Schema.Number,
  agentVersion: Schema.String,
  macOS: Schema.String,
  capabilities: Schema.Array(Schema.String),
  accounts: Schema.Array(Account)
})
export type Hello = typeof Hello.Type

export const AgentFrame = Schema.Union([
  Hello,
  Schema.Struct({
    type: Schema.Literal("result"),
    id: Schema.String,
    ok: Schema.Boolean,
    data: Schema.optional(Schema.Unknown),
    error: Schema.optional(Schema.Struct({ code: Schema.String, message: Schema.String }))
  }),
  Schema.Struct({ type: Schema.Literal("event"), seq: Schema.Number, event: Event }),
  Schema.Struct({ type: Schema.Literal("ping"), t: Schema.Number }),
  Schema.Struct({ type: Schema.Literal("pong"), t: Schema.Number })
])
export type AgentFrame = typeof AgentFrame.Type

export const decodeAgentFrame = Schema.decodeUnknownEffect(Schema.fromJsonString(AgentFrame))

export type ServerFrame =
  | { readonly type: "welcome"; readonly resumeAfterRowId: number }
  | { readonly type: "command"; readonly id: string; readonly command: Command }
  | { readonly type: "ack"; readonly seq: number }
  | { readonly type: "ping"; readonly t: number }
  | { readonly type: "pong"; readonly t: number }
