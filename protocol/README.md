# Blueberry agent protocol (v1)

The Mac **agent** dials out to the **server** over a WebSocket (`wss://<server>/v1/agent/connect`),
authenticating with `Authorization: Bearer <agent token>`. The Mac never accepts inbound connections,
so no port forwarding, ngrok, or Cloudflare tunnels are needed on the Mac side.

Every frame is a single JSON object with a `type` field.

## Handshake

```
agent  → server  {"type":"hello","protocol":1,"agentVersion":"0.1.0","macOS":"26.6.2",
                  "capabilities":["send.applescript","privateApi","facetime"],
                  "accounts":[{"service":"iMessage","handle":"+15551234567"}]}
server → agent   {"type":"welcome","resumeAfterRowId":12345}
```

`resumeAfterRowId` is the highest `message.ROWID` the server has durably stored for this agent.
The agent replays everything after it from `chat.db`, so a server outage, network blip, or agent
restart never loses messages (no time-window polling, no "missed message" class of bugs).

## Commands (server → agent) and results (agent → server)

```
server → agent   {"type":"command","id":"cmd_01J...","command":{"kind":"message.send", ...}}
agent  → server  {"type":"result","id":"cmd_01J...","ok":true,"data":{...}}
agent  → server  {"type":"result","id":"cmd_01J...","ok":false,"error":{"code":"no_imessage","message":"..."}}
```

Commands are idempotent by `id`: the agent remembers recently executed ids and returns the cached
result for a duplicate instead of sending twice.

## Events (agent → server) with acks

```
agent  → server  {"type":"event","seq":42,"event":{"kind":"message.new", ...}}
server → agent   {"type":"ack","seq":42}
```

`seq` is monotonic per agent. Events stay in the agent's on-disk outbox until acked and are
re-sent after reconnect.

## Heartbeat

Either side sends `{"type":"ping","t":<ms>}` and expects `{"type":"pong","t":<same>}`.
The server marks a line offline after 30s without traffic.

The canonical schema lives in `server/src/protocol.ts` (zod) and is mirrored by
`agent/Sources/BlueberryCore/Protocol.swift`. Change both together.
