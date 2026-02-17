import AppKit
import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var selectedSection: SettingsSection? = .security

    enum SettingsSection: String, CaseIterable, Identifiable {
        case security = "Security"
        case shortcuts = "Shortcuts"
        case automation = "Automation"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .security: return "lock.shield"
            case .shortcuts: return "square.2.layers.3d"
            case .automation: return "gearshape.2"
            }
        }
    }

    var body: some View {
        NavigationView {
            List(
                selection: .init(
                    get: { selectedSection },
                    set: { section in
                        selectedSection = section
                    }
                )
            ) {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
            }

            if let selectedSection {
                switch selectedSection {
                case .security:
                    SecuritySettingsView(serverController: serverController)
                        .navigationTitle("Security")
                        .formStyle(.grouped)
                case .shortcuts:
                    ShortcutsSettingsView(serverController: serverController)
                        .navigationTitle("Shortcuts")
                        .formStyle(.grouped)
                case .automation:
                    AutomationSettingsView(serverController: serverController)
                        .navigationTitle("Automation")
                        .formStyle(.grouped)
                }
            } else {
                Text("Select a category")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Text("")
        }
        .task {
            let window = NSApplication.shared.keyWindow
            window?.toolbarStyle = .unified
            window?.toolbar?.displayMode = .iconOnly
        }
        .onAppear {
            if selectedSection == nil, let firstSection = SettingsSection.allCases.first {
                selectedSection = firstSection
            }
        }
    }

}

// MARK: - Security Settings

struct SecuritySettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var newTokenName = ""
    @State private var generatedToken: AuthToken?
    @State private var copiedTokenID: UUID?
    @State private var selectedTokenID: UUID?
    @State private var showingRevokeAllAlert = false

    private var tokens: [AuthToken] {
        serverController.getAuthTokens()
    }

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    var body: some View {
        Form {
            // MARK: Token List
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Auth Tokens")
                            .font(.headline)
                        Spacer()
                        if !tokens.isEmpty {
                            Button("Revoke All") {
                                showingRevokeAllAlert = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Generate tokens for MCP clients. Pass via --token in the CLI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                // Generate new token
                HStack {
                    TextField("Token name (e.g. Claude Desktop)", text: $newTokenName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { generateToken() }
                    Button("Generate") { generateToken() }
                        .disabled(newTokenName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // Show generated token (one-time display)
                if let generated = generatedToken {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token generated for \"\(generated.name)\"")
                            .font(.caption)
                            .fontWeight(.semibold)

                        HStack {
                            Text(generated.token)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button("Copy Token") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generated.token, forType: .string)
                                copiedTokenID = generated.id
                            }
                            .buttonStyle(.bordered)
                            Button("Copy MCP Config") {
                                let command = Bundle.main.bundleURL
                                    .appendingPathComponent("Contents/MacOS/imcp-server")
                                    .path
                                let configBlock: [String: Any] = [
                                    "iMCP": [
                                        "command": command,
                                        "args": ["--token", generated.token],
                                    ]
                                ]
                                if let data = try? JSONSerialization.data(
                                    withJSONObject: configBlock,
                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                ),
                                    let json = String(data: data, encoding: .utf8)
                                {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(json, forType: .string)
                                    copiedTokenID = generated.id
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        if copiedTokenID == generated.id {
                            Text("Copied to clipboard. This token will not be shown again.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Copy this token now. It will not be shown again.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .cornerRadius(8)
                }

                // Token list
                if tokens.isEmpty {
                    HStack {
                        Text("No tokens configured. All connections will be rejected.")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(tokens, selection: $selectedTokenID) { token in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(token.name)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    Text(maskedToken(token.token))
                                        .font(.system(.caption, design: .monospaced))
                                    Text("--")
                                        .font(.caption)
                                    Text(token.createdAt, style: .date)
                                        .font(.caption)
                                }
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(token.id)
                        .contextMenu {
                            Button("Revoke", role: .destructive) {
                                if selectedTokenID == token.id {
                                    selectedTokenID = nil
                                }
                                serverController.revokeToken(id: token.id)
                            }
                        }
                    }
                    .frame(minHeight: 80, maxHeight: 200)
                }
            }

            // MARK: Permission Editor
            if let tokenID = selectedTokenID,
                let token = tokens.first(where: { $0.id == tokenID })
            {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Permissions for \"\(token.name)\"")
                            .font(.headline)

                        Text("Control which services this token can access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    HStack {
                        Text("Set All")
                            .fontWeight(.medium)
                        Spacer()
                        Button("Off") { setAllPermissions(.off, tokenID: tokenID) }
                            .buttonStyle(.bordered)
                        Button("Read-only") { setAllPermissions(.readOnly, tokenID: tokenID) }
                            .buttonStyle(.bordered)
                        Button("Full") { setAllPermissions(.full, tokenID: tokenID) }
                            .buttonStyle(.bordered)
                    }

                    Divider()

                    ForEach(serviceConfigs) { config in
                        HStack {
                            Image(systemName: config.iconName)
                                .foregroundStyle(config.color)
                                .frame(width: 20)
                            Text(config.name)
                            Spacer()
                            Picker("", selection: permissionBinding(for: config.id, tokenID: tokenID)) {
                                Text("Off").tag(ServicePermission.off)
                                Text("Read-only").tag(ServicePermission.readOnly)
                                Text("Full").tag(ServicePermission.full)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Revoke All Tokens", isPresented: $showingRevokeAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke All", role: .destructive) {
                selectedTokenID = nil
                generatedToken = nil
                serverController.revokeAllTokens()
            }
        } message: {
            Text("This will revoke all tokens. All connections will be rejected until new tokens are created.")
        }
    }

    private func generateToken() {
        let name = newTokenName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let token = serverController.generateToken(name: name)
        generatedToken = token
        copiedTokenID = nil
        newTokenName = ""
        selectedTokenID = token.id
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 12 else { return token }
        let prefix = token.prefix(6)
        let suffix = token.suffix(6)
        return "\(prefix)...\(suffix)"
    }

    private func setAllPermissions(_ permission: ServicePermission, tokenID: UUID) {
        var permissions: [String: ServicePermission] = [:]
        for config in serviceConfigs {
            permissions[config.id] = permission
        }
        serverController.updateTokenPermissions(id: tokenID, permissions: permissions)
    }

    private func permissionBinding(for serviceID: String, tokenID: UUID) -> Binding<ServicePermission> {
        Binding(
            get: {
                let tokens = serverController.getAuthTokens()
                guard let token = tokens.first(where: { $0.id == tokenID }) else { return .off }
                return token.permissions[serviceID] ?? .off
            },
            set: { newValue in
                let tokens = serverController.getAuthTokens()
                guard let index = tokens.firstIndex(where: { $0.id == tokenID }) else { return }
                var permissions = tokens[index].permissions
                permissions[serviceID] = newValue
                serverController.updateTokenPermissions(id: tokenID, permissions: permissions)
            }
        )
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var newShortcutName = ""

    private var allowedShortcuts: [String] {
        serverController.getAllowedShortcuts()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shortcuts Allowlist")
                        .font(.headline)

                    Text("Only shortcuts in this list can be executed via MCP. Others will be blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                HStack {
                    TextField("Shortcut name", text: $newShortcutName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addShortcut()
                        }
                    Button("Add") {
                        addShortcut()
                    }
                    .disabled(newShortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if allowedShortcuts.isEmpty {
                    HStack {
                        Text("No shortcuts allowed")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(allowedShortcuts, id: \.self) { shortcut in
                        HStack {
                            Text(shortcut)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                serverController.removeAllowedShortcut(shortcut)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addShortcut() {
        let name = newShortcutName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        serverController.addAllowedShortcut(name)
        newShortcutName = ""
    }
}

// MARK: - Automation Settings

struct AutomationSettingsView: View {
    @ObservedObject var serverController: ServerController

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Message Watcher")
                        .font(.headline)

                    Text("Run a script when new inbound iMessages are detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                Toggle("Run script on new messages", isOn: Binding(
                    get: { serverController.messageWatcherEnabled },
                    set: {
                        serverController.messageWatcherEnabled = $0
                        serverController.updateMessageWatcher()
                    }
                ))

                HStack {
                    TextField(
                        "Script path",
                        text: Binding(
                            get: { serverController.messageWatcherScript },
                            set: { serverController.messageWatcherScript = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.unixExecutable, .shellScript, .script, .item]
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            serverController.messageWatcherScript = url.path
                            serverController.updateMessageWatcher()
                        }
                    }
                }

                Text("The script receives IMCP_NEW_MESSAGE_COUNT as an environment variable. Requires the Messages service to be enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
