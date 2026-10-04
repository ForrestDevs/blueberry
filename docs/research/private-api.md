# Blueberry Private API Helper: Research & Design

Status: research / design proposal, 2026-10-03
Target: macOS 15–26, Apple Silicon. Dev machine: macOS 26.6.2 (25G83), Xcode 26.6.

Sources studied:
- Upstream server, cloned at `/Users/forrestdevs/dev/blueberry` (BlueBubbles server). Paths below are relative to `packages/server/src/server/` unless they are absolute.
- `bluebubbles-helper`, cloned to the scratchpad. `master` @ `1ee57f3` (2026-05-06), plus the `development` branch @ `a896191` (2026-07-11, "Huge refactor…"). The development branch is the first one with real macOS 26 work. Below, `helper/` means master and `helper-dev/` means development:
  - `helper*/Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m` (Messages dylib)
  - `helper*/FaceTime/MacOS-11+/BlueBubblesFaceTimeHelper/BlueBubblesFaceTimeHelper.m` (FaceTime dylib)
  - `helper*/…/NetworkController.m` (socket transport)
- Runtime probes on this Mac (`probe*.m` in the scratchpad). They `dlopen` the private frameworks and check `respondsToSelector:`. They run without SIP changes because nothing is injected.

---

## 1. How upstream works (summary)

```
TS server (Node)                       Messages.app (com.apple.MobileSMS)    FaceTime.app (com.apple.FaceTime)
  net.Server  TCP localhost:45670+uid-501  <── BlueBubblesHelper.dylib          <── BlueBubblesFaceTimeHelper.dylib
  newline-delimited JSON                  (DYLD_INSERT_LIBRARIES)             (DYLD_INSERT_LIBRARIES)
  chat.db watcher (fs.watch on db + wal)
```

- **Injection ("process-dylib" mode)** is in `api/privateApi/modes/dylibPlugins/index.ts`. The server kills the app, then spawns `/System/Applications/Messages.app/Contents/MacOS/Messages` directly with `env: { DYLD_INSERT_LIBRARIES: <dylib> }`. It does not use `open` or LaunchServices, because LaunchServices would drop the env var. After 5 s it hides the window with AppleScript (`hideApp`). It waits for the process to exit and respawns. After 5 crashes within 15 s of each other it gives up. FaceTime uses the same code (`FaceTimeDylibPlugin.ts`, gated by `enable_ft_private_api`).
- **MacForge mode** is legacy (`modes/MacForgeMode.ts`). It copied a `.bundle` into the MacForge/mySIMBL plugin dirs. `ProcessDylibMode.install()` now *uninstalls* that bundle. Ignore this mode.
- **Dylib entry point**: `+load`. The dylib checks `NSBundle.mainBundle.bundleIdentifier` (`com.apple.MobileSMS`, or `com.apple.FaceTime` / `com.apple.TelephonyUtilities` for the FaceTime helper). It then waits 5 s and connects back to the server (`helper-dev/.../BlueBubblesHelper.m:82-109`).
- **System requirements** that upstream checks or documents:
  - `checkPrivateApiRequirements()` (`index.ts:1224`) checks only `csrutil status` (it must not end in "enabled.") (`fileSystem/index.ts:558`).
  - The BlueBubbles docs (https://docs.bluebubbles.app/private-api/installation) list two steps: `csrutil disable` in Recovery, and `sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true`.
  - The shipped dylibs (`packages/server/appResources/private-api/macos11/*.dylib`) are **ad-hoc signed** (`Signature=adhoc`, no TeamIdentifier). They are universal x86_64 + arm64 + arm64e and use the **macOS platform** (LC_BUILD_VERSION platform 1, minos 11.0).
- **Build** (`helper-dev/Messages/MacOS-11+/BlueBubblesHelper.xcodeproj`):
  - `SDKROOT=macosx` and `SUPPORTS_MACCATALYST=NO`.
  - `OTHER_LDFLAGS = -ObjC -Wl,-undefined,dynamic_lookup -flat_namespace`, so private symbols resolve inside the host at load time.
  - Private frameworks are found through `SYSTEM_FRAMEWORK_SEARCH_PATHS=$(SYSTEM_LIBRARY_DIR)/PrivateFrameworks`.
  - Headers are class-dumped (RuntimeBrowser/classdump-dyld) and checked into the repo.
  - Swizzling uses ZKSwizzle. The socket uses CocoaAsyncSocket (Pod).

---

## 2. Injection mechanism & exact system requirements for Blueberry

### 2.1 Why injection at all (and not just linking IMCore in our agent)
Our own process can load IMCore, IDS, TelephonyUtilities and ChatKit. The probes do exactly that. The classes exist, but they are thin XPC clients:
- `imagent` / `IMDPersistenceAgent` gate their clients by entitlements (`com.apple.imagent.*`, `com.apple.private.ids.*` …).
- `callservicesd` (TelephonyUtilities) gates its clients the same way.

A Developer-ID-signed app cannot carry `com.apple.private.*` entitlements. AMFI kills the process unless `amfi_get_out_of_my_way=1` is set, which is more invasive than what we need. So we run *inside* Messages.app and FaceTime.app, which already hold those entitlements. This is the BlueBubbles design, and it is the one we should copy.

### 2.2 Host process facts on macOS 26.6.2 (verified)
| Host | Platform | Arch | Code-sign flags |
|---|---|---|---|
| `/System/Applications/Messages.app` | **Mac Catalyst** (`LC_BUILD_VERSION platform 6`, minos 26.6). ChatKit is at `/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework` | x86_64, arm64e | `library-validation`, platform binary |
| `/System/Applications/FaceTime.app` | macOS | x86_64, arm64e | `library-validation,runtime` (hardened), platform binary |

Consequences:
- A **macOS-platform** dylib loads fine into the Catalyst Messages process. That is upstream's setup.
- The reverse does not work. Our probe built for macOS got `dlopen ChatKit: wrong platform to load into process`. **Our agent (macOS app) can never load ChatKit itself**, so every CK* call must happen inside Messages.
- Link the helper the upstream way (`-undefined dynamic_lookup -flat_namespace`), or resolve every class with `NSClassFromString`. Do not link against ChatKit at build time.

### 2.3 Required machine configuration (one-time, user-performed)
1. **SIP disabled.** Boot to Recovery (Apple Silicon: hold power, then Options, then Continue) and run `csrutil disable`.
   - When SIP is on, dyld/AMFI drop `DYLD_*` env vars for platform/restricted binaries, and AMFI enforces platform-only library validation.
   - A partial `csrutil enable --without …` setup is not a supported configuration on Apple Silicon. Plan for full disable.
   - This machine currently reports `System Integrity Protection status: enabled.`
2. **Library validation off**: `sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true`. AMFI honours this only when SIP is off. FaceTime.app is hardened-runtime + library-validation, so without this it refuses our dylib. This machine currently has no such pref.
3. **arm64e.** The hosts are arm64e. Third-party arm64e code requires the boot-arg `sudo nvram boot-args="-arm64e_preview_abi"` (the arm64e ABI is not stable for non-Apple code). Upstream ships an arm64e slice but does not document the boot-arg. **Verify early (spike task):**
   - (a) arm64-only dylib, no boot-arg;
   - (b) arm64e dylib, no boot-arg;
   - (c) arm64e dylib with the boot-arg.

   Pick the option that needs the fewest steps. This machine has no `boot-args` set.
4. **Full Disk Access** for the agent. It needs this to read `~/Library/Messages/chat.db`. Today the terminal gets `authorization denied`. FDA is also needed to spawn Messages and read its paths.
5. **Automation (Apple Events)** to hide the windows. Optional.
6. **Signing.**
   - Sign the agent `.app` with Developer ID + notarize for DMG distribution.
   - Sign the helper dylib with the same Team ID. With LV disabled ad-hoc also works, but Team-ID signing keeps notarization of the DMG clean.
   - The agent itself does not need `disable-library-validation`. Upstream's `packages/server/scripts/entitlements.mac.plist` has it, but only for Electron/native modules.

### 2.4 Launch procedure (agent side)
Mirror `dylibPlugins/index.ts`:
1. `pkill -x Messages` (and/or `FaceTime`), then wait about 1 s.
2. Start the host with `posix_spawn` (`Process` in Swift) using the executable path directly, `/System/Applications/Messages.app/Contents/MacOS/Messages`, with environment `DYLD_INSERT_LIBRARIES=<Agent.app>/Contents/Resources/BlueberryMessagesHelper.dylib`. Do not use `NSWorkspace`/`open`, because LaunchServices strips the env var.
3. Supervise the child. Respawn on exit. Back off after N fast crashes (upstream: 5 within 15 s).
4. Hide the window after start. Options: AppleScript `set visible to false`, or `NSRunningApplication.hide()`.
5. Wait for the helper's `hello` over IPC (upstream: a `ping` event with `process` = bundle id) before reporting "private API ready".
6. Messages.app as a Catalyst app may be relaunched by the system, for example on notification tap. In that case it starts without our dylib. Detect the IPC disconnect and redo steps 1–5.

---

## 3. IPC design

Upstream uses TCP `localhost:45670+(uid-501)`, carrying newline-delimited JSON:
- Requests look like `{action, data, transactionId}`.
- Responses look like `{transactionId, error?, identifier?, …}`.
- Events look like `{event, …}`.

Known issues with this approach:
- Any local user or process can connect, with no authentication.
- The read path has a "data is sometimes duplicated" hack (`NetworkController.m:79-91`). There is no framing; it relies on one read equalling one message.
- The server dedupes identical lines (`PrivateApiService.ts:208`), which silently drops legitimately repeated events.
- The server writes every request to *all* connected helpers (`writeToClients`), so Messages and FaceTime both receive each other's actions.

**Proposal for Blueberry: Unix domain socket with length-prefixed JSON, agent as the server.**
- **Socket path:** `~/Library/Application Support/Blueberry/ipc/helper.sock`, directory mode `0700`, socket mode `0600`.
  - Messages and FaceTime run as the same user, so they can connect.
  - They are not sandboxed in a way that blocks this. Messages has a sandbox profile, so verify early; the fallback is a path under `~/Library/Messages/`, which Messages can always write to.
- **Peer authentication:**
  - On accept, call `getsockopt(LOCAL_PEERPID)` / `LOCAL_PEERTOKEN`.
  - Check with `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` that the peer is Apple-signed `com.apple.MobileSMS` / `com.apple.FaceTime`.
  - Also require a per-launch random token. The agent passes it in an env var next to `DYLD_INSERT_LIBRARIES`, and the dylib must present it in `hello`.
- **Framing:** 4-byte big-endian length + UTF-8 JSON. No newline splitting, no dedupe.
- **Envelope:**
  - Request: `{ "v":1, "id":"<uuid>", "type":"req", "action":"send-message", "data":{…}, "deadlineMs":15000 }`
  - Response: `{ "v":1, "id":"<uuid>", "type":"res", "ok":true, "result":{…} }` or `{…, "ok":false, "error":{"code":"ChatNotFound","message":"…"} }`
  - Event: `{ "v":1, "type":"evt", "event":"typing", "data":{…} }`
  - First frame from the helper: `{ "type":"hello", "process":"com.apple.MobileSMS", "osVersion":"26.6.2", "helperVersion":"…", "token":"…", "capabilities":[ "send-message", … ] }`.
    - `capabilities` comes from runtime `respondsToSelector:` probing, so the TS server can feature-gate per OS.
- **Routing:** the agent keeps one connection per process and routes each action to the owning process. FaceTime actions go to FaceTime and everything else to Messages, unlike upstream's broadcast.
- **Threading inside the dylib:**
  - Do all IMCore/ChatKit calls on the **main queue**. Upstream uses `GCDAsyncSocket` with `delegateQueue: main`.
  - Wrap every handler in `@try/@catch`; dev-branch `NetworkController.m` does this. ObjC exceptions from bad selectors must not take Messages down.
- **Why not XPC:**
  - A Mach service needs a launchd job. Anonymous XPC listener endpoints need a rendezvous (bootstrap), which the injected code inside a sandboxed Catalyst app cannot look up freely.
  - NSXPC adds `NSSecureCoding` overhead for no gain.
  - A UDS with peer audit gives the same security with simpler code.
- **Agent ⇄ TS server:** keep that link separate (WebSocket/HTTPS). The agent translates; the dylib never talks to the network.
- **Helper language:** keep the dylib in **Objective-C** (or ObjC++). Calling unknown selectors, swizzling, and `@try/@catch` around ObjC exceptions are all far easier there than in Swift. The agent is Swift.

---

## 4. Action → private API table

Columns: our action, then the upstream action string, then the classes/selectors used upstream, then their status on macOS 26.6.2 from the runtime probe. "dev" means `helper-dev` (development branch) and "master" means `helper`. The server action strings come from `api/privateApi/apis/*.ts`.

| Blueberry action | Upstream action | Upstream implementation | macOS 26.6.2 status |
|---|---|---|---|
| **Look up chat** | (internal) | `[[IMChatRegistry sharedInstance] existingChatWithGUID:]`; `[[CKConversationList sharedConversationList] conversationForExistingChatWithGUID:]` (dev: `NSClassFromString` because ChatKit loads late) | OK both |
| **Look up message** | (internal) | `[[IMChatHistoryController sharedInstance] loadMessageWithGUID:completionBlock:]`, then `message._imMessageItem._newChatItems`. Result is an array or a single `IMMessagePartChatItem`; for photo galleries use `IMAggregateAttachmentMessagePartChatItem.aggregateAttachmentParts` (dev `:267-301`) | OK |
| **Send text** | `send-message` | dev: `CKComposition initWithText:subject:` → `compositionByAppendingText:` → `[CKConversation messageWithComposition:]` → `[CKConversation sendMessage:newComposition:YES]`; reply `{identifier: newMessage.guid}` (dev `:1008-1109`). master: `[[IMMessage alloc] initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:0x100005 error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:]` → `[IMChat sendMessage:]` (master `:1050-1083`) | Both paths OK. CKConversation path preferred on 26 |
| **Send with subject** | `send-message` (`subject`) | `initWithText:subject:`; master flags `0x10000d` | OK |
| **Rich text** (bold/italic…, macOS 15+) | `send-message` (`textFormatting`) | Attributed keys `__kIMTextBoldAttributeName`, `__kIMTextItalicAttributeName`, `__kIMTextUnderlineAttributeName`, `__kIMTextStrikethroughAttributeName` + `__kIMMessagePartAttributeName` (`applyTextFormatting`, dev `:1465`) | Helper present. Not wired into the dev send path; wire it ourselves |
| **Mentions** | `send-multipart` (`parts[].mention`) | Attribute `__kIMMentionConfirmedMention` = handle | OK |
| **Send attachment(s)** | `send-attachment`, `send-multipart` | dev: `[[CKMediaObjectManager sharedInstance] mediaObjectWithFileURL:filename:transcoderUserInfo:]` → `compositionByAppendingMediaObject:`. master: `IMFileTransferCenter guidForNewOutgoingTransferWithLocalURL:` / `transferForGUID:`, copy to `[IMDPersistentAttachmentController _persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:]`, `retargetTransfer:toPath:`, `registerTransferWithDaemon:`, then attributed `￼` with `__kIMFileTransferGUIDAttributeName`, `__kIMFilenameAttributeName`, `__kIMMessagePartAttributeName` (master `:967-1010`, `:471-521`). The file must sit somewhere Messages can read; `~/Library/Messages/…` is safe | OK both |
| **Voice memo** | `send-message` (`isAudioMessage`) | `+[CKComposition audioCompositionWithMediaObject:]` (dev); master flags `0x300005` | OK |
| **Reply (thread)** | `send-message` (`selectedMessageGuid`, `partIndex`) | `chatItem.threadIdentifier`, or `IMCreateThreadIdentifierForMessagePartChatItem(chatItem)` (C function in IMCore); `newMessage.threadIdentifier = …; newMessage.threadOriginator = [chatItem message]` | OK (`IMCreateThreadIdentifierForMessagePartChatItem` resolves) |
| **Effects** (slam, confetti…) | `send-message` (`effectId`) | `[CKComposition setExpressiveSendStyleID:]` (dev) / `expressiveSendStyleID:` init arg (master). IDs look like `com.apple.MobileSMS.expressivesend.impact`, `com.apple.messages.effect.CKConfettiEffect` | OK |
| **Tapback (classic)** | `send-reaction` | dev: build a `CKChatItem` via `+[CKChatItem chatItemWithIMChatItem:balloonMaxWidth:]`, then `[IMChat sendMessageAcknowledgment:(2000..2005 / 3000..3005) forChatItem:ckItem]` (dev `:1111-1140`). master: hand-built `IMMessage initWith…associatedMessageGUID:@"p:<part>/<guid>" associatedMessageType: associatedMessageRange: messageSummaryInfo:@
> _The original write-up was cut off above. The remaining findings are summarized below; they were verified on macOS 26.6.2 (25G83) with probe binaries that dlopen the frameworks (no injection)._

## Remaining action findings (macOS 26.6.2)

- **Still present:** IMChatRegistry/IMChat/IMMessage/IMAccountController/IMFileTransferCenter core selectors, edit (5-arg variant), retract/unsend, `setLocalUserIsTyping:`, IDS availability queries; TelephonyUtilities answer/end/dial and FaceTime link generation.
- **Removed/changed:**
  - Legacy IMChat tapback selectors are gone — tapbacks now route through **ChatKit**, which only loads inside Messages.app (Messages is a Mac Catalyst app; ChatKit lives under `/System/iOSSupport` and refuses to load in a plain macOS process: "wrong platform"). ⇒ the helper **must** run injected in Messages.app.
  - `leaveiMessageGroup` removed.
  - Focus status: use `fetchUpdatedStatusForHandle:` (no underscore).
  - Nickname sharing selector gained arguments; upstream dev helper still calls the old one.
  - Pinned-chat setter removed.
  - FaceTime link invalidation now requires a delete reason.
  - Incoming typing-indicator check used upstream is gone.
- **Upstream bug:** server sends `notify-anyways`, helper dev branch expects `notify-anyway`.

## FaceTime

Upstream supports: answer, leave/hangup, generate link, admit waiting-room participants, incoming-call events. It **cannot start calls or do audio-only**. TelephonyUtilities' dial-request API (build a FaceTime dial request, then dial it) exists on 26.6.2 and is the path for outgoing video/audio calls. FaceTime.app uses hardened runtime + library validation, so injecting into it needs AMFI/library-validation relaxed as well as SIP off.

## chat.db

- Upstream watches `chat.db` + `chat.db-wal`, debounces 500 ms, then re-queries a window starting 30 s before the last check (bounded to 1 week by `date`). ⇒ time-window based; replaced in Blueberry by a ROWID cursor + backup poll.
- Dates: nanoseconds since 2001-01-01 (Apple epoch).
- Text frequently only in `attributedBody` (typedstream/NSArchiver) — decode with `NSUnarchiver` natively in Swift.
- Unsend: `message_summary_info` plist → `retractedParts` + `date_edited`.
- Emoji tapback columns are not read upstream.

## Injection (upstream)

`packages/server/src/server/api/privateApi/modes/dylibPlugins/index.ts`: kill Messages/FaceTime, launch the app binary directly with `DYLD_INSERT_LIBRARIES`, hide window, relaunch on crash. Helper dylibs are ad-hoc signed universal (x86_64/arm64/arm64e). Upstream only checks SIP; BlueBubbles docs additionally require disabling library validation (`defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true`). Whether arm64e needs `-arm64e_preview_abi` is unverified.

IPC upstream: localhost TCP `45670 + (uid - 501)`, newline-delimited JSON `{action, data, transactionId}`, no auth, broadcast to all helpers. Blueberry will use a Unix domain socket under the agent's container with peer-credential checks.
