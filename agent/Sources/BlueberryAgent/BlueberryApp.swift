import BlueberryCore
import SwiftUI

struct BlueberryApp: App {
    @State private var model = AgentModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(systemName: model.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class AgentModel {
    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "ws://localhost:8787/v1/agent/connect"
    var token = Keychain.read("lineToken") ?? ""
    var statusText = "Not configured"
    var connected = false
    var error: String?
    private var agent: Agent?

    var symbol: String { connected ? "message.fill" : "message" }

    init() {
        if !token.isEmpty { start() }
    }

    func save() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        Keychain.write("lineToken", token)
        start()
    }

    func start() {
        Task {
            await agent?.stop()
            guard let url = URL(string: serverURL), !token.isEmpty else { return }
            do {
                let agent = try Agent(config: .init(url: url, token: token))
                self.agent = agent
                self.error = nil
                await agent.observe { status in
                    Task { @MainActor in self.apply(status) }
                }
                await agent.start()
            } catch {
                self.error = String(describing: error)
                self.statusText = "Error"
            }
        }
    }

    private func apply(_ status: Agent.Status) {
        switch status.connection {
        case .connected:
            connected = true
            statusText = status.privateApi ? "Connected · Private API" : "Connected"
        case .connecting:
            connected = false
            statusText = "Connecting…"
        case .disconnected(let reason):
            connected = false
            statusText = "Disconnected" + (reason.map { " — \($0)" } ?? "")
        }
    }
}

struct StatusMenu: View {
    @Bindable var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blueberry").font(.headline)
            Label(model.statusText, systemImage: model.connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.connected ? .green : .secondary)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Open Full Disk Access settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
            Divider()
            TextField("Server URL", text: $model.serverURL)
            SecureField("Line token", text: $model.token)
            HStack {
                Button("Save & Connect") { model.save() }.keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }
}

enum Keychain {
    private static let service = "dev.forrest.blueberry"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
