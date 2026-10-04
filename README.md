# Blueberry

Self-hosted iMessage + FaceTime API. A fork and rewrite of [BlueBubbles Server](https://github.com/BlueBubblesApp/bluebubbles-server).

```
┌──────────────┐  HTTPS + webhooks   ┌──────────────────────┐  outbound WSS   ┌────────────────────────┐
│ your clients │ ──────────────────▶ │ server/ (Linux, Bun, │ ◀────────────── │ agent/ (macOS, Swift)  │
│ & AI agents  │ ◀────────────────── │ Effect v4, SQLite)   │ ──────────────▶ │ chat.db · Messages ·   │
└──────────────┘                     └──────────────────────┘    commands     │ FaceTime · Private API │
                                                                               └────────────────────────┘
```

- **`agent/`**: a native Swift menu bar app, signed and notarized as a DMG. It runs on each Mac ("line"), reads `chat.db` and sends through Messages. It only ever dials *out*, so you need no port forwarding, ngrok, or Firebase.
- **`server/`**: a TypeScript service on [Effect v4](https://effect.website) that runs anywhere, including Linux. It provides a Sendblue-style REST API, durable signed webhooks, message storage, and routing across lines.
- **`protocol/`**: the agent ↔ server wire protocol.
- **`docs/research/`**: upstream pain points mined from GitHub issues, and Private API / FaceTime notes for macOS 26.
- **`legacy/`**: the original BlueBubbles server, kept as a reference while porting.

## Status

| Capability | Status |
|---|---|
| Receive messages (lossless ROWID cursor, resync on reconnect) | ✅ |
| Delivered / read / edited / unsent updates | ✅ |
| Send text + attachments (AppleScript) | ✅ |
| Chats list, message history, webhooks, idempotent sends | ✅ |
| Tapbacks, edit, unsend, typing, read receipts, effects, replies, groups | 🚧 Private API helper |
| FaceTime: call (video/audio), answer, end, links, incoming events | 🚧 Private API helper |

## Quick start

```sh
# Server (any OS)
cd server && bun install
bun run cli create-api-key me          # → bb_...
bun run cli create-line mac-mini       # → line token
bun run dev                            # :8787, API docs at /docs

# Agent (on the Mac signed into iMessage)
cd agent && swift build
BLUEBERRY_URL=ws://<server>:8787/v1/agent/connect BLUEBERRY_LINE_TOKEN=<token> \
  .build/debug/blueberry-agent --headless
```

The agent needs **Full Disk Access** (to read `chat.db`) and **Automation → Messages** permission.

```sh
curl -X POST localhost:8787/v1/messages -H "authorization: Bearer $KEY" -H 'content-type: application/json' \
  -H 'idempotency-key: 7f1c' -d '{"to":"+15551234567","text":"hello from blueberry 🫐"}'
```

## Signed DMG

```sh
cd agent
DEVELOPMENT_TEAM=<TEAMID> xcodegen generate && open Blueberry.xcodeproj   # dev
DEVELOPMENT_TEAM=<TEAMID> scripts/release.sh                              # signed + notarized DMG
```

## License

Apache-2.0, like upstream. Portions derived from BlueBubbles Server © BlueBubbles Development Team.
