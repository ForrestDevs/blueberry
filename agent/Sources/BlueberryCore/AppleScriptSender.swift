import Foundation

/// Baseline sender that works without SIP changes. Supports text + attachments only;
/// everything else needs the Private API helper.
///
/// Arguments are passed via `on run argv` rather than string interpolation, so message
/// text can never break out of the script.
public struct AppleScriptSender: Sendable {
    public init() {}

    /// Sends to an existing chat or to handles. For 1:1 chats the participant form is used because
    /// macOS 26 rewrote chat ids to `any;-;…`, which `chat id` lookups reject (upstream #777).
    public func send(chatGuid: String?, to handles: [String]?, text: String?, attachmentPaths: [String]) throws {
        let target: Target
        if let handles, handles.count == 1 {
            target = .participant(handles[0])
        } else if let chatGuid, let handle = Self.directHandle(from: chatGuid) {
            target = .participant(handle)
        } else if let chatGuid {
            target = .chat(chatGuid)
        } else {
            // Starting a brand-new group needs the Private API (AppleScript can't create one reliably).
            throw CommandError("unsupported", "creating a group chat requires the Private API helper; send to an existing chatGuid instead")
        }

        if let text, !text.isEmpty {
            try run(script(for: target, payload: "item 2 of argv"), args: [target.value, text])
        }
        for path in attachmentPaths {
            try run(script(for: target, payload: "POSIX file (item 2 of argv)"), args: [target.value, path])
        }
    }

    enum Target {
        case participant(String)
        case chat(String)

        var value: String {
            switch self {
            case .participant(let h): h
            case .chat(let g): g
            }
        }
    }

    /// `iMessage;-;+15551234567` / `any;-;foo@bar.com` → the handle. Group chats use `;+;`.
    static func directHandle(from chatGuid: String) -> String? {
        let parts = chatGuid.components(separatedBy: ";-;")
        return parts.count == 2 ? parts[1] : nil
    }

    private func script(for target: Target, payload: String) -> String {
        switch target {
        case .participant:
            """
            on run argv
                tell application "Messages"
                    set svc to 1st account whose service type = iMessage
                    send \(payload) to participant (item 1 of argv) of svc
                end tell
            end run
            """
        case .chat:
            """
            on run argv
                tell application "Messages"
                    send \(payload) to chat id (item 1 of argv)
                end tell
            end run
            """
        }
    }

    private func run(_ script: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-1743") || message.contains("Not authorized") {
                throw CommandError("automation_denied", "Blueberry is not allowed to control Messages. Enable it in System Settings → Privacy & Security → Automation.")
            }
            throw CommandError("applescript_failed", message.isEmpty ? "osascript exited \(process.terminationStatus)" : message)
        }
    }
}
