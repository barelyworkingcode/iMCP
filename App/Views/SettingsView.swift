import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var selectedSection: SettingsSection? = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case toolApprovals = "Tool Approvals"
        case shortcuts = "Shortcuts"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .toolApprovals: return "checkmark.shield"
            case .shortcuts: return "square.2.layers.3d"
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
                case .general:
                    GeneralSettingsView(serverController: serverController)
                        .navigationTitle("General")
                        .formStyle(.grouped)
                case .toolApprovals:
                    ToolApprovalsSettingsView(serverController: serverController)
                        .navigationTitle("Tool Approvals")
                        .formStyle(.grouped)
                case .shortcuts:
                    ShortcutsSettingsView(serverController: serverController)
                        .navigationTitle("Shortcuts")
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

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var showingResetAlert = false
    @State private var selectedClients = Set<String>()

    private var trustedClients: [String] {
        serverController.getTrustedClients()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Trusted Clients")
                            .font(.headline)
                        Spacer()
                        if !trustedClients.isEmpty {
                            Button("Remove All") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Clients that automatically connect without approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                if trustedClients.isEmpty {
                    HStack {
                        Text("No trusted clients")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(trustedClients, id: \.self, selection: $selectedClients) { client in
                        HStack {
                            Text(client)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                        .contextMenu {
                            Button("Remove Client", role: .destructive) {
                                serverController.removeTrustedClient(client)
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .onDeleteCommand {
                        for clientID in selectedClients {
                            serverController.removeTrustedClient(clientID)
                        }
                        selectedClients.removeAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Remove All Trusted Clients", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
                selectedClients.removeAll()
            }
        } message: {
            Text(
                "This will remove all trusted clients. They will need to be approved again when connecting."
            )
        }
    }
}

struct ToolApprovalsSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var showingResetAlert = false

    private var approvals: [(client: String, tool: String)] {
        serverController.getToolApprovals()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Approved Tools")
                            .font(.headline)
                        Spacer()
                        if !approvals.isEmpty {
                            Button("Revoke All") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Tools that clients can use without prompting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                if approvals.isEmpty {
                    HStack {
                        Text("No approved tools")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(approvals, id: \.tool) { approval in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(approval.tool)
                                    .font(.system(.body, design: .monospaced))
                                Text(approval.client)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contextMenu {
                            Button("Revoke", role: .destructive) {
                                serverController.revokeToolApproval(
                                    client: approval.client,
                                    tool: approval.tool
                                )
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Revoke All Tool Approvals", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke All", role: .destructive) {
                serverController.resetToolApprovals()
            }
        } message: {
            Text(
                "This will revoke all tool approvals. Each tool will require confirmation again on next use."
            )
        }
    }
}

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
