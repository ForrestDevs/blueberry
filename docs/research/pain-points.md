# Upstream pain points: what BlueBubbles users actually hit

Research date: 2026-10-03.
Sources:
- `BlueBubblesApp/bluebubbles-server`: all 102 open issues, plus closed issues created since 2024-01 sorted by comment count (about 150 reviewed by title, about 70 read in full with their comments).
- `BlueBubblesApp/bluebubbles-helper`: all 30 issues.
- The upstream code in `packages/server/src/server`, checked wherever an issue pointed at a root cause.

Notation: `#N` is a server issue and `helper#N` is a helper issue. `(Nc)` is the comment count when fetched. "Open" or "closed" is the state on the fetch date.

Caveats:
- #843 was later retracted by its author, who traced the problem to an external restart loop. It is cited only as a hypothesis.
- #765 is a maintainer's own "potential bug" note.
- Frequency is the number of distinct issues in the cluster plus the comment volume. It is a rough signal and not a user count; most support upstream happens on Discord.

---

## 1. Inbound message detection: missed, late, or duplicated events

**Frequency: very high.** This is the core reliability complaint, and webhook and bridge users feel it most.

| Issue | Title | State |
|---|---|---|
| #703 (10c) | Missing Messages | open |
| #750 (9c) | Inbound messages not being received after Mac inactivity | open |
| #758 (7c) | Webhook trigger doesn't work properly | open |
| #754 | Chat list shows new message, but actual chat doesn't | open |
| #765 | [Potential Bug] Re-emitting old messages as new-message events | open |
| #779 | Helper v0.0.22-tahoe regression: inbound iMessages delayed (APNs drops) | open |
| #843 | Private API kills Messages.app, "permanently killing the chat.db watcher" | closed, retracted |
| #656 | Server sync time getting progressively worse | closed |
| #710 | Invoke manual message DB poll after sending a message | closed |

**Symptoms**
- Messages never get emitted (#703: "no logs at all for most messages and they're simply missed").
- Messages arrive 5 to 15 minutes late, then all at once (#750, #779, #758: "triggers for all at once").
- Messages show up only after someone opens Messages.app and clicks the conversation (#750, #758).
- On the same Mac, webhooks fire for user account A but not for account B (#758). A comment on #750 ties the problem to Fast User Switching with two logged-in users.

**Root causes**

The first three come from the code:
- **The watcher is the only trigger.** `IMessageListener` (`databases/imessage/listeners/IMessageListener.ts`) polls only when `MultiFileWatcher` (`lib/MultiFileWatcher.ts`) emits a change. `MultiFileWatcher` uses `fs.watch` and ignores every event type except `"change"`. Its `error` handler re-emits the error but never re-arms the watcher. There is no periodic poll as a fallback, so a missed or dead FS event means nothing gets emitted.
- **The poll window is computed from wall-clock time.** It uses `lastCheck - 30s` with a 24-hour clamp, then filters rows by `dateCreated`, `dateDelivered`, and other timestamps. It does not use a ROWID cursor. Clock skew therefore shows up as missed messages. In #703, maintainers asked users to check `time.is`, and #656 is about time sync.
- **Duplicate suppression lives only in memory and is time-limited.** `EventCache` is a linear array that is trimmed after 1 hour (`pollers/index.ts trimEventCache`). `MessagePoller` looks back a full week on every poll. #765 points out that this lets old events be re-emitted.

The last one is in the operating system:
- **macOS idles Messages.app or imagent.** On Apple Silicon running Sequoia, after about 10 to 15 minutes of inactivity, nothing is written to chat.db, so a pure chat.db watcher has nothing to see (#750). The workarounds people report: Caffeine's "keep apps active", disabling the screensaver, and an AppleScript "poke" of Messages every few minutes.

**How Blueberry avoids this**
1. Use a **monotonic ROWID cursor**, persisted to disk, as the primary ingest mechanism for new messages. Run a separate bounded scan for mutations: `date_edited`, `date_read`, `date_delivered`, and `date_retracted`, plus `message_summary_info` for unsends. Never use wall-clock windows.
2. Use **two triggers**: DispatchSource or FSEvents on `chat.db` and `chat.db-wal`, re-armed whenever a rename or delete is seen, **plus** a 1 to 2 second timer poll. A `SELECT max(ROWID)` query costs very little.
3. **Treat the in-process IMCore hook as a second ingest source.** It should subscribe to IMChat and IMMessage notifications and push a "something changed" nudge, with the GUID, to the agent. Then chat.db reconciliation is the source of truth, but delivery does not depend on it. Dedupe on message GUID with a persistent seen-set or the server's own DB, never with a time-limited cache.
4. **Keep the service awake.** The agent holds a `ProcessInfo` activity assertion and runs a periodic lightweight IMCore keep-alive, such as querying the account or connection state, to keep imagent hot. It also measures and exports "time since the last inbound message", so idling becomes visible.
5. **Detect the multi-user case.** If the agent's user is not the console user, or another user session owns Messages, warn about it in health output.

---

## 2. Outbound send confirmation, timeouts, and duplicates

**Frequency: very high.** #616 is the most-commented issue reviewed (41c) and comes from the Beeper bridge author.

| Issue | Title | State |
|---|---|---|
| #616 (41c) | Sending Replies using the REST API times out for some | closed |
| #814 | Tahoe: Private-API reply-threaded sends (selectedMessageGuid) stall and never deliver | open |
| #771 | Threaded replies via REST API time out (selectedMessageGuid) | open |
| #842 | Private API requests return HTTP 200 "success" after the helper has died mid-call | open |
| #782 | Image attachments sent via Private API are duplicated (2x) | open |
| #800 | Reply API throws "guid.startsWith" on text containing mc-prefix patterns | open |
| #756 / #685 | Enable SMS fallback / Create chat to SMS target | open |
| #609 | Can't send multipart message with attachment GUID | closed (docs) |
| #643 | App won't send messages at all | closed |

**Symptoms**
- `"Transaction timeout"` errors on threaded replies (#616, #771, #814). The message is never sent, and the client is not told until 40 to 120 seconds have passed.
- HTTP 200 returned for edits that never happened, because the helper crashed mid-call (#842).
- Images delivered twice (#782).
- Sending to `sms;-;` succeeds but the API never returns a response body (#756).

**Root causes, from the code**
- `TransactionPromise` (`managers/transactionManager/transactionPromise.ts`) has one fixed timeout of 120 seconds. It is not tied to helper liveness: when the helper socket disconnects, pending transactions are not failed (#842).
- The REST API decides a send succeeded by **matching the sent text against new chat.db rows**. `MessagePromise.isSame` in `managers/outgoingMessageManager/messagePromise.ts` compares `onlyAlphaNumeric(text)`, or the attachment filename, plus the chat GUID, with a 2-minute timeout for text and 20 minutes for attachments. This is fragile:
  - Identical texts can be confused with each other.
  - URLs and rich text are rewritten by Messages.
  - If ingest misses the row (cluster 1), the send "fails" even though it went out.
- The send path is not idempotent, so a client retrying after a timeout produces duplicate sends.

**How Blueberry avoids this**
1. **The helper returns the created `IMMessage` GUID synchronously** from the IMCore send call. The agent correlates on that GUID, never on text.
2. **Every send has a client-supplied `idempotency_key`**, persisted on the server. A retry returns the original result.
3. **Sends follow an explicit state machine**: `accepted → dispatched → sent → delivered | failed`. Each transition emits a webhook (Sendblue-style `status` callbacks). The REST call returns `202 accepted` immediately and does not hold the HTTP request open for minutes.
4. **Calls fail fast when the helper dies.** All in-flight commands for a helper connection are rejected the moment the IPC channel closes, using the same ID-keyed pending map. A success response requires an explicit ack from the helper.
5. **Use per-operation timeouts** (text 15s, attachment upload dependent on size, reply/edit/tapback 15s), and turn each timeout into a terminal `failed` state with a reason code.
6. **Service selection is first-class** (`imessage`, `sms`, `rcs`, `auto`). `auto` checks availability before sending, so the SMS path is designed in rather than discovered by accident.

---

## 3. macOS version breakage: Sequoia 15 and Tahoe 26

**Frequency: very high and recurring.** Every major macOS release produced a wave of issues.

| Issue | Title |
|---|---|
| #669 (9c) | macOS Sequoia 15 Beta 3: lots of crashes & bugs |
| #700 (9c) | macOS 15 Server Update 2.0.0? |
| #694 | Private API attachment send broken on Sequoia, crashes Messages |
| #755 (9c) | macOS 26 beta, Private API not working |
| #776 (5c) | Private API helper not connecting on macOS 26 Tahoe |
| #777 (4c) | Tahoe: AppleScript sendMessage fails with -1700 due to 'any' service type |
| #814 | Tahoe: threaded sends stall; outbound typing indicators don't transmit |
| #779 | Tahoe helper regression: inbound delays |
| #761 | Server crashes on Tahoe when a client connects (V8 OOM) |
| #791 | "Message does not exist" on macOS 15.7.4 Intel |
| #676 | RCS messages (iOS 18 / macOS 15) not shown properly, can't reply |
| #695 / #700 | Integrate new macOS 15 features (custom emoji tapbacks, RCS) |
| helper#58 | Crash: `-[IMMessageAcknowledgmentChatItem index]` (reply-to-tapback, Tahoe) |
| helper#56 | macOS 14, 15, 26 feature/bug tracker (polls, stickers, effects, etc.) |
| #720 / #826 | JS exception on High Sierra after 1.9.8; dropped OS support |

**Root causes**, as stated in the issues:
- **The chat GUID prefix changed.** On Tahoe, chat GUIDs start with `any;-;` instead of `iMessage;-;`. Upstream derives the service from the GUID prefix (`getServiceFromInput` in `api/apple/scripts.ts`) and then builds invalid AppleScript (#777).
- **Apple changed the chat item classes.** `_newChatItems` now returns `IMMessageAcknowledgmentChatItem`, which has no `-index`, and the helper calls it unconditionally (#776, helper#58).
- **The helper fails at load time on Tahoe 26.5.** It references ChatKit classes as flat-namespace undefined symbols, so dyld binding aborts before any helper code runs (#776, comment by Austin519).
- **imagent enforces private entitlements on Tahoe** for its XPC auth service, so `setLocalUserIsTyping:` silently does nothing (#814 comments).
- **The arm64e ABI and AMFI need boot-args.** Users must set `amfi_get_out_of_my_way=1 ... -arm64e_preview_abi` before injection works (#755, #776).
- **Testing was not systematic.** "I do not think the devs are testing at all on Sequoia" (#669). "I don't have an m1 Mac to test against" (#668).

**How Blueberry avoids this**
1. **Treat chat GUIDs as opaque.** Take the service from `chat.service_name`, `message.service`, and `handle.service`, never by parsing the GUID.
2. **The helper must never assume a selector or class exists.**
   - Every IMCore call goes through a `respondsToSelector:` or `NSClassFromString` guard.
   - Classes are resolved at runtime with `objc_getClass`, never linked as symbols. This avoids the dyld failure in #776.
   - Each capability (typing, reply, edit, unsend, tapback, effects, polls) is probed at startup and published as a **capability matrix** at `GET /v1/health`.
   - The API returns `501 capability_unavailable` rather than a fake 200.
3. **Use per-OS adapter modules** (`IMCoreAdapter_14`, `_15`, `_26`) behind one Swift protocol, so Tahoe-specific code paths are isolated.
4. **Add a compatibility test lane.**
   - Keep a matrix of real or virtualized Macs (macOS 14, 15, 26, plus the current beta).
   - Run an automated smoke suite (send, receive, reply, tapback, attachment, edit, typing) on every helper build and on every new macOS beta drop.
   - Publish a support table and refuse to enable unverified OS versions by default.
5. **Model RCS** as a service, and reactions as arbitrary emoji (iOS 18 custom tapbacks), from day one.

---

## 4. Private API injection, SIP, and Messages.app crash loops

**Frequency: high.** Crashes take down Messages and therefore everything else.

| Issue | Title |
|---|---|
| #719 (6c) / #722 | Messages crashes on server when a URL is sent (link preview) |
| #668 (6c) | Errors updating to 1.9.8 arm64: Messages & FaceTime quit unexpectedly |
| #683 (11c) | Messages and FindMy apps popping up and down |
| #843 | Private API kills Messages.app ~40ms after chat listeners arm (retracted) |
| #796 | Message crash when sharing contact to chat |
| helper#72 | Messages crashes on typing indicator / read receipt: nil `transaction` in NSDictionary literal (13 sites) |
| helper#67 | Crash loop: `handleReadStatusForChat` ack without nil-guard (regression) |
| helper#74 / helper#73 | remove-participant silently removes nothing; handle guard can't fail (`imHandleWithID` mints) |
| helper#31 | Private API v0.0.14 crashes iMessage whenever used |
| helper#36 / helper#37 | "Killed my bluetooth and wifi"; huge intermittent CPU from helper renderer |

**Root causes**
- **Obj-C exceptions from nil values.** A nil value inside an `@{}` literal throws `NSInvalidArgumentException` inside Messages.app. 13 unguarded call sites exist alongside 28 guarded ones (helper#72, helper#67).
- **IMCore calls fail silently.** `imHandleWithID` mints a handle instead of failing, so guards that check for nil never fire and a no-op reports success (helper#73, helper#74).
- **Injection starts by killing Messages**, and a failure is retried "5 tries" and "3 times in a row, giving up" (`api/privateApi/modes/dylibPlugins/index.ts`). A helper crash therefore becomes a Messages crash loop that the user has to notice and fix.
- **The link-preview path crashes Messages** on Sonoma and Sequoia when it is triggered from the API (#719). A maintainer said the fix "requires a private api change" with "differences in macOS 13-15". The only workaround is putting an emoji before the URL. #822 is the opposite problem: URLs arrive as plain, non-tappable text.
- **Apps cannot be minimized programmatically**, so Messages, FaceTime, and FindMy keep popping into focus (#683).

**How Blueberry avoids this**
1. **Wrap every command in the Swift/ObjC helper** in an `@try/@catch` Obj-C trampoline. A failure in one command returns an error instead of aborting Messages.
2. **Validate all IPC payloads** (Codable with required fields) before touching IMCore, and never build dictionaries from optionals without unwrapping them.
3. **Detect crash loops in the agent.** If Messages crashes N times within M minutes after command X, quarantine that command type: it returns `capability_unavailable` and raises a health alert, and injection does not keep looping.
4. **Treat link previews as an explicit option** (`rich_link: true|false`). When it is enabled, generate an `LPLinkMetadata` payload safely, and fall back to a plain-text send with the link detection attribute set. That fallback also fixes #822.
5. **Don't launch FindMy at all.** Keep the windows of Messages and FaceTime hidden. Document that "apps popping" is cosmetic, and avoid AppleScript UI paths entirely.
6. **Ship the helper** as a separately versioned and signed artifact with a stable IPC protocol version. The agent refuses to inject a helper whose protocol version doesn't match. Compare #779, where users installed an unofficial "v0.0.22-tahoe" dylib of unknown origin.
7. **Run a preflight checker for SIP and boot-args.** It reads `csrutil status` and `nvram boot-args` and says exactly what is missing, instead of leaving users to work it out from GitHub comments (#755, #776).

---

## 5. FaceTime

**Frequency: moderate**, but the failures are severe: kernel panics.

| Issue | Title |
|---|---|
| #635 (6c) | FaceTime crash, then full system crash (kernel panic) |
| #729 | FaceTime service crashes WindowServer |
| #601 (5c) | FaceTime links don't generate but the call answers on the laptop |
| helper#38 | FaceTime Private API joins the call and immediately leaves, so the link is useless |
| #700 | "FaceTime API notification is NOT working at all" (macOS 15) |
| #581 | API for fetching FaceTime call history |

**Root causes**
- **The server leaves the call too early.** It answers, creates a link, and then leaves, so the caller is alone before the client joins through the link (helper#38).
- **Link creation takes about 60 seconds** (#601).
- **The panics went undiagnosed.** Kernel panics and WindowServer crashes happened only when the FaceTime Private API was enabled (#635, #729), and the maintainer had "no idea" of the cause.

**How Blueberry avoids this**
1. **Treat FaceTime as an opt-in, isolated module**: a separate injected helper in FaceTime or `avconferenced`, a separate IPC channel, and its own crash quarantine (see cluster 4). It must never share fate with the Messages helper.
2. **Model the call as a state machine**: `ringing → answered_by_host → link_ready → remote_joined → host_left`. The host stays in the call until `remote_joined` or a configurable timeout. Every transition is emitted as a webhook.
3. **Pre-generate or reuse FaceTime links** where possible, so answering does not block on a roughly 60 second link generation.
4. **Ship call history** (`/v1/facetime/calls`) by reading `CallHistory.storedata`, which needs no injection.
5. **Gate GUI-heavy paths behind a WindowServer health watchdog.** If WindowServer crashes are correlated with FaceTime activity, disable the module automatically.

---

## 6. Attachments and media: voice memos, video, HEIC, Live Photos, iCloud

**Frequency: high**, spread across many small issues.

| Issue | Title |
|---|---|
| #773 | Voice memos (isAudioMessage) produce broken 0-second unplayable audio |
| #799 | Voice memo CAF→MP3 conversion race; AAC served as `.mp3` |
| #674 | Attachments with isAudioMessage:true not playable on iOS |
| #778 | new-message webhook fires with a UUID body when an audio note is played |
| #477 / #189 | Sent videos are poor quality / properly sending HEVC videos |
| #644 / #671 | Videos not sending (VM Mac); some MP4s never deliver |
| #669 / #694 | Private API attachment send crashes Messages on Sequoia |
| #782 | Image attachments sent via Private API duplicated |
| #847 | HEIC Live Photos not detected |
| #787 | HEIC conversion to JPEG loses alpha |
| #749 | Failed to download image: not on disk (iCloud-offloaded) |
| #816 | APIs omit attachments referenced only in attributedBody |
| #637 | Unsent attachments aren't updated |
| #804 | Attachment API: formidable truncates chatGuid containing semicolons |
| #557 | Attachments for scheduled messages |
| #565 / #692 / #660 / #654 | Image group repeats; embedded media parsing; filename overlap; double-extension breaking live photo |

**Root causes, from the issues and the code**

`fileSystem/index.ts`:
- **Voice memos are encoded wrongly.** The code uses `afconvert -f caff -d LEI16@44100`, which is PCM, while iMessage voice memos need Opus at 24 kHz in CAF (#773).
- **The m4a path is mislabelled.** It writes AAC in M4A (`-f m4af -d aac`) but labels and serves the result as MP3 (#799).
- **HEIC is converted with `sips` to JPEG**, which drops alpha (#787).

Other code and design causes:
- **Conversion starts before the upload is complete.** It begins about 27 ms after the upload starts, before the multipart write has finished (#799).
- **The Live Photo lookup uses the wrong path.** The companion `.mov` is looked up beside the *converted* file in `Convert/`, not beside the original (#847).
- **Attachment discovery relies only on the `message_attachment_join` table.** It does not parse `attributedBody` for `__kIMFileTransferGUIDAttributeName` (#816).
- **Unsends are not detected.** The code did not check `message_summary_info.retractedParts` (#637, fixed on a dev branch).
- **iCloud-offloaded files are missing locally.** Downloading them needs an IMCore request, which is only available when the Private API is on (#749).
- **iMessage recompresses video** and rejects codecs that QuickTime can't play (#477, #671).

**How Blueberry avoids this**
1. **Uploads go to the Linux server first** as content-addressed blobs (sha256, size verified, with resumable/tus or multipart support). The server pushes a finished, fsynced file to the agent. No processing starts until the hash matches.
2. **Use one media pipeline in the agent, built on AVFoundation**, not shell tools:
   - Voice memos are transcoded to **Opus 24 kHz mono in CAF**, and the `IMFileTransfer` gets the audio-message flags.
   - Video is checked with `AVAsset.isPlayable`. Anything not playable is transcoded to H.264/HEVC in MOV with AAC audio, and there is an optional passthrough mode.
   - HEIC stays HEIC, served as-is or converted on demand on the Linux server with libheif, keeping alpha by using PNG.
3. **Resolve attachments from both sources**: the `message_attachment_join` table **and** the `attributedBody` file-transfer GUIDs. Detect Live Photo pairs from the original `transfer_name` and the sibling `.MOV`.
4. **Request iCloud-offloaded attachments through IMCore** (`IMFileTransferCenter` download), with an `attachment.downloaded` event when the file arrives.
5. **Emit a typed event for "message played"** (`message.played`), never a `message.received` (#778).
6. **Never put identifiers in multipart form fields** that parsers mangle. Chat IDs go in the URL path and are URL-encoded, or use our own short IDs (#804).

---

## 7. Push notifications, Firebase, and Google Cloud setup

**Frequency: very high in setup.** #714 has 23 comments and #745 has 8.

| Issue | Title |
|---|---|
| #714 (23c) | Setup error: Failed to create project: Failed to provision Android App |
| #745 (8c) | [OauthService] Failed to create project: 403 |
| #751 | Quota exceeded (won't configure Firebase) |
| #760 | 403 when trying to create new database |
| #661 / #649 / #651 | Automatic Google setup failing / `.find on undefined` / manual step not visible |
| #698 | FCM: SenderId mismatch |
| #783 / #725 | Manual Firebase setup rule is insecure (`allow read, write: if true`) / RTDB open to anyone |
| #823 / #606 | Manual Firestore instructions outdated / doc issue |
| #604 / #432 | Re-check the Firebase server URL periodically; retry Firebase sends on failure |
| #734 | Swap Firebase for a Supabase backend |
| #808 | Persistent badge count of "1" on Android (no Firebase / background service) |
| #421 (19c) | Enable end-to-end encryption, so Google push servers can't read messages |

**Root causes**
- The server automates creating a GCP project, an Android app, and a Firestore database for each user. This keeps breaking as Google changes requirements. A billing account is now required (#745), and provisioning fails intermittently (#714).
- Firebase does two jobs: it is the push transport, and it acts as a discovery mechanism for the dynamic tunnel URL (Firestore or RTDB holding the server URL). The second role is what forces public-read database rules (#783, #725).
- Push payloads go through Google, so messages are readable by Google (#421).

**How Blueberry avoids this**
1. **Don't create Firebase or GCP resources per user.** The Linux server has a stable URL that the operator controls, so URL discovery through Firestore is unnecessary.
2. **Push goes through our own client.** Options, in order:
   - a long-lived WebSocket or SSE connection when the app is in the foreground;
   - a single project-owned APNs/FCM relay that carries only an **encrypted, content-free wake payload** (event ID plus ciphertext). Users never create cloud projects;
   - UnifiedPush or webhooks for self-hosters.
3. **Encrypt end to end** between the Blueberry server and the client for any payload that passes through a third-party push relay. Use per-device keys exchanged during device pairing (#421).

---

## 8. Connectivity: tunnels, proxies, and custom URLs

**Frequency: high.**

| Issue | Title |
|---|---|
| #687 (8c) | "Failed To Connect" and socket connection error (Cloudflare) |
| #613 (15c) | Can't connect to server using custom URLs (Tailscale IP picked as LAN IP) |
| #763 | Cannot connect via web app (zrok interstitial header) |
| #678 / #716 / #717 / #769 / #731 | zrok: 401 shareUnauthorized, 409 conflict, disable/re-enable issues, null `.length`, binary upgrade |
| #602 | Increase Cloudflare connection timeout (inconsistent URL updates after reboot) |
| #620 / #713 | no-ip + Let's Encrypt unreachable; AdGuard DNS conflict |
| #441 | Monitor Cloudflare status and notify on downtime |
| #697 | Increase PingInterval to 1 minute |
| #784 | All REST routes return 404: another service was bound to the same port |

**Root causes**
- The Mac is the server, so it must be reachable from the internet. That needs bundled tunnel binaries (Cloudflare quick tunnels, ngrok, zrok), each with its own failure modes.
- Quick-tunnel URLs change on every restart and are "deprioritized" by Cloudflare; maintainers recommended moving to zrok (#687).
- LAN IP auto-detection picks the wrong interface (#613).
- A port conflict produces no clear error (#784).

**How Blueberry avoids this**
1. **Invert the topology.** The Mac agent makes one **outbound**, mutually authenticated WebSocket (or gRPC stream) to the Linux server. The Mac needs no inbound ports and no tunnels. The agent reconnects with backoff and resumes from the last acked event ID.
2. **The public endpoint is the Linux server.** It sits behind any standard reverse proxy (Caddy or nginx) with a stable domain. Document Tailscale or Cloudflare Tunnel as optional and operator-managed, not bundled.
3. **Fail loudly when the port is in use.** Bind explicitly, and on `EADDRINUSE` refuse to start with a clear error (#784).
4. **Health is first-class.** `GET /v1/health` reports agent connection state, helper state, last inbound timestamp, and the capability matrix.

---

## 9. Performance: event-loop blocking, memory, CPU

**Frequency: moderate.** It shows up to users as "connecting…" loops.

| Issue | Title |
|---|---|
| #617 (17c) | Out of memory crash (Electron, macOS 14) |
| #761 | Crash on Tahoe when a client connects (V8 OOM) |
| #811 | Contact fetch with avatars blocks the Node event loop ~5s, causing reconnect loops |
| #812 | statistics/totals & /media: synchronous `COUNT(*)` on the main thread, no caching |
| #476 | `/api/v1/contacts` with avatars takes 30+ seconds |
| helper#37 | Huge intermittent CPU from helper renderer |

**Root causes**
- **The chat.db DataSource uses synchronous `better-sqlite3`** on the Electron main process (`databases/imessage/index.ts`). Large `COUNT(*)` queries and contact or avatar reads block every other request, including health probes (#811, #812).
- **Avatars are returned at full resolution** because the thumbnail path is broken (#811).
- **A memory leak** that "compounded when receiving tons of messages" (#617 maintainer comment).

**How Blueberry avoids this**
1. **The Linux server never queries chat.db live.** The agent streams normalized events into the server's own DB (Postgres or SQLite), and the API serves from there, with indexes and pagination by cursor. Statistics are maintained incrementally.
2. **The agent reads chat.db read-only** (`SQLITE_OPEN_READONLY`, WAL-aware) on a background queue with bounded batch sizes, and never on the main thread.
3. **Avatars** are thumbnailed once (for example 128px), content-hashed, cached, and fetched separately by hash. They are never inlined in bulk contact responses.
4. **No Electron.** The native Swift agent has a bounded memory footprint. Export RSS and event-loop or queue lag as metrics.

---

## 10. Distribution, code signing, and auto-update

**Frequency: high, and it can block installs entirely.**

| Issue | Title |
|---|---|
| #715 (5c) | "Apple cannot check it for malicious software" |
| #727 | BlueBubbles flagged as malware by macOS (Homebrew) |
| #790 | Homebrew will stop working unless BlueBubbles is signed again (disabled 2026-09-01) |
| #653 / #817 | Autoupdate errors (missing `latest-mac.yml`) / include `latest-mac.yml` one last time |
| #668 / #688 | 1.9.8 arm64 prerelease errors |
| #772 / #686 | npm install error / can't install dev deps (`node-mac-contacts`) |
| #732 (6c) | "Is this project dead?" |

**Root causes**
- **The signing certificate was revoked.** Apple restricted the maintainer's developer account, so releases since 1.9.8 are unsigned and unnotarized (#715, #653).
- **The revocation also broke the update chain.** It broke electron-updater (`latest-mac.yml` is no longer published), and Homebrew deprecated the cask (#790).
- **Releases depend on one maintainer.** One person's certificate and one person's spare time gate every release (#732).

**How Blueberry avoids this**
1. **Ship a Developer ID-signed, notarized DMG** under an **organization** Apple Developer account with more than one admin. Signing runs in CI with keys in a managed secret store.
2. **Use Sparkle 2 with EdDSA-signed appcasts**, so update integrity does not depend on the Apple certificate alone.
3. **Never let the update feed break silently.** CI asserts that the appcast and artifacts exist before a release is published.
4. **Keep the injected helper separate from the notarized app bundle.** The helper must be ad-hoc-signed or loaded with library validation disabled, so the notarized app must not need to embed it in a way that fails notarization. Document this clearly.
5. **The Linux server is a container image** (`ghcr.io/...`) plus an npm package. It is not tied to macOS distribution at all.

---

## 11. Lifecycle: headless mode, autostart, and crash recovery

**Frequency: moderate.**

| Issue | Title |
|---|---|
| #648 (10c) | Auto restart if the server crashes |
| #733 / #789 | Headless + "Always Start via Terminal" broken; headless crashes with a null window in preChecks |
| #743 | Functionality fails after a system crash or reboot (Private API "Connected: No") |
| #726 | Don't relaunch when disable-GPU is enabled with a launch agent |
| #512 / caffeinate | Switch to pmset (sleep prevention) |

**Root causes**
- An Electron GUI app is acting as a daemon: headless code paths still touch `window` (#789).
- Crash restart was added late, as an opt-in launch agent (#648).
- Ordering after a reboot (Messages ready, then the helper injected) is not robust (#743).

**How Blueberry avoids this**
1. **The agent is a background-only app**, an `LSUIElement` with an optional menu bar UI, registered with `SMAppService` as a LaunchAgent with `KeepAlive`. The UI is a separate process and is never required.
2. **Startup is an explicit dependency graph**: user session, then chat.db readable, then Messages running, then helper injected, then helper handshake OK, then connected to the server. Each step retries with backoff and is reported in health.
3. **Prevent sleep** with an IOPMAssertion held by the agent, not a `caffeinate` subprocess. Document the auto-login requirement.

---

## 12. macOS permissions and onboarding

**Frequency: moderate.**

| Issue | Title |
|---|---|
| #612 (8c) / #704 | Server unable to request Contacts permission (OpenCore / TCC) |
| #792 | Setup wizard: Accessibility check stuck on Fail regardless of toggle |
| #642 / #672 / #759 | No error for weak password; passwords with `$` break login; login fails with JS disabled |
| #757 / #650 | iMessage authentication doom loop (Apple flags the account) / continuously kicked out of iMessage (VM) |
| #826 / #720 | Old macOS support dropped without a clear message |

**How Blueberry avoids this**
1. **Ship a native onboarding checklist** that uses the real APIs:
   - Full Disk Access: try opening chat.db.
   - Contacts: `CNContactStore.authorizationStatus`.
   - Accessibility: `AXIsProcessTrusted`, and only if something actually needs it. Prefer not needing it.
   - Automation, SIP, boot-args, and the macOS version against the support matrix.

   Each step gets a deep link to the right System Settings pane.
2. **Pair the Mac agent with the Linux server** using a one-time pairing code or QR code that produces a device keypair. There are no user-chosen shared passwords, so there are no escaping bugs (#672).
3. **Warn users about Apple account risk**: new Apple IDs, VMs, and high send rates trigger Apple anti-spam lockouts (#757, #650). Enforce rate limits by default (cluster 15).

---

## 13. Contacts

**Frequency: moderate.**

| Issue | Title |
|---|---|
| #634 (15c) | Manual and automatic refresh of contacts non-functional; only a restart picks up new contacts |
| #614 | Contacts with middle names displayed incorrectly |
| #811 / #476 | Avatar fetch slow and blocking |
| #647 / #677 / #721 | Sync with Google Contacts directly / import logging / Family Link accounts |
| #701 / #684 | Contacts API improvements / create contact method |
| #670 | Combine different threads under a single contact |

**Root cause:** contacts were loaded at startup, and Refresh did not re-read the Address Book until a restart (#634). No `CNContactStoreDidChange` observer exists in the upstream server.

**How Blueberry avoids this**
1. **Observe `CNContactStoreDidChangeNotification`** in the agent and push incremental contact deltas to the server, using a change-history token where available.
2. **Normalize handles** to E.164 or lowercase email, and keep a contact-to-handles mapping on the server, so clients can merge threads per person (#670).
3. **Treat contacts as read-only from the Mac.** Additional sources (CardDAV or Google) are optional server-side connectors and do not depend on the Mac.

---

## 14. Webhooks, the API surface, and security

**Frequency: high among integrators** (Beeper or mautrix bridge, OpenClaw, n8n, Matrix).

| Issue | Title |
|---|---|
| #758 (7c) | Webhook trigger doesn't work properly |
| #738 / #519 | Webhook configuration via CLI or YAML / API endpoints for managing webhooks |
| #795 | Add HMAC-SHA256 signing to outbound webhooks |
| #797 | Webhook documentation |
| #673 | Deduping requests |
| #778 / #765 | Played-receipt emitted as new-message / re-emitting old messages |
| #798 | No brute-force protection on client connections |
| #747 | CLI/YAML secrets written to stdout/log |
| #293 / #421 | 2FA login / end-to-end encryption |
| #681 (8c) | "chatGuid + and - meaning", an undocumented identifier format |
| #609 / #801 | Multipart send docs / "Send Text API" |
| #804 / #800 | chatGuid truncated by multipart parser; text containing GUID-like patterns breaks reply |

**Root causes, from the code**
- `WebhookService.dispatch` (`services/webhookService/index.ts`) does a fire-and-forget `axios.post`. It has no retry, no persistence, no signature, no event ID, and no ordering. Failures are only logged at debug level.
- **Auth is a single shared password**, passed as a `?password=` query parameter, with no rate limiting (#798).
- **Leaked identifiers.** Apple's internal identifiers (`iMessage;-;+1…`, `p:0/…`) are exposed directly as API identifiers.

**How Blueberry avoids this** (a Sendblue-style API)
1. **Webhooks use a durable outbox.**
   - Every event gets a ULID `event_id` and a monotonic `sequence`.
   - Delivery is at least once, with exponential backoff and a dead-letter queue.
   - Each request carries an `X-Blueberry-Signature` (HMAC-SHA256 with a timestamp) and is replayable from the dashboard and API.
   - Webhooks are managed through the REST API and a config file.
2. **Use a typed event taxonomy**: `message.received`, `message.sent`, `message.delivered`, `message.read`, `message.played`, `message.edited`, `message.unsent`, `reaction.added`, `typing.started`, `chat.participant_added`, `facetime.*`, `agent.disconnected`, and so on. A read or played receipt can never surface as a new message.
3. **Own the identifiers.** Use our own stable IDs for chats, messages, and handles, keep Apple GUIDs as attributes, and document the format.
4. **Auth uses scoped API keys** (hashed at rest) sent in the `Authorization` header and never in query strings.
   - Rate-limit and lock out failed auth attempts.
   - Redact secrets in all logs.
   - Optionally add OIDC or passkeys for the dashboard.
5. **Publish an OpenAPI spec** as the source of truth, generate client SDKs, and ship contract tests.

---

## 15. Typing indicators, receipts, tapbacks, and newer iMessage features

| Issue | Title |
|---|---|
| #645 | Typing indicators still broken (stuck on or missing) |
| #814 | Tahoe: outbound typing doesn't transmit (imagent entitlement) |
| #700 / #695 / #676 | Custom emoji tapbacks, RCS, macOS 15 features |
| helper#56 | Tracker: stickers, text effects, polls, backgrounds, GamePigeon |
| helper#8 / helper#5 / helper#51 | Per-part reactions, mentions, rich text formatting |
| #775 / #446 | Expose Focus / DND status |
| #655 / #632 / #41 | Away message; block/unblock handles |

**How Blueberry avoids this**
1. **Typing state has a TTL.** Auto-expire `typing.started` after about 60 seconds without a refresh, so the client never shows a typing indicator that is stuck on.
2. **Reactions are generic**: `{emoji | classic_type, part_index}`. Message bodies support `attributedBody` formatting and mentions as structured ranges.
3. **The capability matrix (cluster 3) gates each feature per OS.** Unsupported features fail explicitly.

---

## 16. Scheduled messages

| Issue | Title |
|---|---|
| #639 | Scheduled messages for 4+ weeks out send immediately |
| #557 | Support attachments for scheduled messages |

**Root cause:** `setTimeout` with a delay larger than 2^31-1 ms (about 24.8 days) overflows to about 1 ms. The maintainer confirmed this in #639.

**How Blueberry avoids this:** schedules are DB rows on the Linux server, picked up by a durable job runner that polls `due_at <= now()`. They run through the normal send pipeline with an idempotency key, so attachments work and the schedule survives restarts. Schedules never use in-memory timers.

---

## 17. Handle availability and Apple anti-abuse

| Issue | Title |
|---|---|
| #699 (5c) | Get iMessage availability broken (false negatives when bulk-checking) |
| #757 / #650 | Apple account lockouts or "doom loop" |
| #644 / #671 | Video send failures initially suspected as bans |

**Root cause:** Apple's IDS lookups are rate-limited and return `false` under load. A maintainer advised spacing requests 5 to 10 seconds apart (#699).

**How Blueberry avoids this**
- Cache availability per handle with a TTL, and coalesce concurrent lookups.
- Rate-limit IDS queries globally with jitter, and return `unknown` rather than `false` when throttled.
- Apply configurable per-account send rate limits by default.

---

## 18. Find My (out of scope, noted for completeness)

#683, #652, #724, #752, #679, #827, helper#40 (friends not working since Sonoma), and #748 (a BeaconStore key method). Find My is fragile and keeps breaking with each OS release.

**Recommendation:** leave it out of v1. Above all, **don't auto-launch the Find My app** (#652, #683).

---

# Top 15 design requirements, ranked

Ranking weighs frequency × severity × how directly the architecture can prevent the problem.

1. **Lossless, cursor-based inbound ingest.** Use a persisted ROWID high-water mark, FS events plus a 1 to 2 second fallback poll, re-armed watchers, and an IMCore notification nudge. Dedupe by GUID persistently. Never use wall-clock windows or time-limited caches. (#703, #750, #758, #754, #765, #779, #656)
2. **Deterministic send confirmation.** The helper returns the message GUID, every send has an idempotency key, status follows a state machine with webhooks (`accepted→sent→delivered|failed`), and there is no text matching and no HTTP request held open for 2 minutes. (#616, #771, #814, #782, #842)
3. **Fail fast and tell the truth.** Helper disconnect rejects all in-flight calls immediately. A feature that isn't supported returns `501 capability_unavailable`, never a fake 200. (#842, #814, #645)
4. **Runtime capability probing and per-OS adapters.** No hard-linked private symbols, `respondsToSelector` guards everywhere, chat GUIDs treated as opaque, and the service taken from DB columns. Publish the capability matrix in `/health`. (#777, #776, helper#58, #755, #669)
5. **A crash-proof helper.** Wrap every command in an exception trampoline, validate payloads, never put nil in collections, and quarantine any command that crashes Messages repeatedly. (helper#72, helper#67, #719, #668)
6. **Outbound-only Mac agent and Linux public server.** No tunnels, inbound ports, or URL discovery on the Mac. The agent resumes from the last acked event. (#687, #613, #763, #678, #769, #602)
7. **No Firebase or per-user cloud provisioning.** Push goes through our own client: a socket, a content-free encrypted wake relay, or UnifiedPush. (#714, #745, #751, #760, #783, #421)
8. **Durable, signed webhooks.** Use an outbox with retries, a DLQ, event IDs and sequence numbers, HMAC signatures, API- and config-managed endpoints, and a typed event taxonomy. (#758, #795, #738, #519, #778, #673)
9. **A continuous compatibility test lane** across macOS 14, 15, 26, and the current beta, with an automated send/receive/reply/tapback/attachment smoke suite gating every release. (#669, #700, #755, #668 "no M1 to test")
10. **Org-owned signing, notarization, and Sparkle updates** with CI-verified appcasts. The server ships as a container. (#715, #727, #790, #653, #817, #732)
11. **A correct media pipeline using AVFoundation.** Opus-in-CAF voice memos, video playability checks and transcoding, HEIC preserved, Live Photo pairing from the originals, `attributedBody` attachment discovery, iCloud download through IMCore, and uploads hash-verified before processing. (#773, #799, #477, #671, #847, #816, #749, #782)
12. **The API never touches chat.db synchronously.** The server serves from its own indexed mirror with cursor pagination, avatars are thumbnailed and fetched by hash, and statistics are maintained incrementally. (#811, #812, #476, #617, #761)
13. **Daemon-grade lifecycle.** An `SMAppService` LaunchAgent with KeepAlive, no GUI dependency, an explicit startup dependency graph, and an IOPM sleep assertion. (#648, #733, #789, #743)
14. **Secure, simple auth.** Device pairing with keypairs, scoped hashed API keys in headers, rate limiting and lockout, secret redaction, and optional E2E encryption for relayed payloads. (#798, #747, #672, #421, #293)
15. **Guided onboarding and safety rails.** A native preflight for FDA, Contacts, SIP, boot-args, and the OS support matrix, live contact change observation, a durable scheduler (no `setTimeout`), and availability-check and send rate limits that protect the Apple account. (#612, #792, #634, #639, #699, #757)
