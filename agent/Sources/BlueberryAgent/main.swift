import AppKit
import BlueberryCore
import SwiftUI

// `blueberry-agent --headless` runs without UI (dev / SSH), reading BLUEBERRY_URL and
// BLUEBERRY_LINE_TOKEN from the environment. Otherwise it runs as a menu bar app.

if CommandLine.arguments.contains("--headless") {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["BLUEBERRY_URL"].flatMap(URL.init(string:)), let token = env["BLUEBERRY_LINE_TOKEN"] else {
        FileHandle.standardError.write(Data("set BLUEBERRY_URL (ws://host:8787/v1/agent/connect) and BLUEBERRY_LINE_TOKEN\n".utf8))
        exit(1)
    }
    do {
        let agent = try Agent(config: .init(url: url, token: token), chatDBPath: env["BLUEBERRY_CHAT_DB"] ?? ChatDB.defaultPath)
        Task { await agent.start() }
        dispatchMain()
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
} else {
    BlueberryApp.main()
}
