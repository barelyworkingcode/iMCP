import AppKit
import SwiftUI

struct ConnectionApprovalView: View {
    let clientName: String
    let onApprove: (Bool) -> Void  // Bool parameter is for "always trust"
    let onDeny: () -> Void

    @State private var alwaysTrust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Icon
            Image(.menuIconOn)
                .resizable()
                .foregroundColor(.accentColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            // Title
            Text("Client Connection Request")
                .font(.title2)
                .fontWeight(.semibold)

            // Message
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \"\(clientName)\" to connect to iMCP?")

                Text("This will give the client access to enabled services.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }

            // Always trust checkbox
            HStack(alignment: .firstTextBaseline) {
                Toggle("Always trust this client", isOn: $alwaysTrust)
                    .toggleStyle(CheckboxToggleStyle())
                Spacer()
            }
            .padding(.bottom, 20)

            // Buttons
            HStack(spacing: 12) {
                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    onApprove(alwaysTrust)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400, height: 300)
        .fixedSize()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .accentColor : .secondary)
                .accessibilityLabel(
                    configuration.isOn ? "Always trust this client, checked" : "Always trust this client, unchecked"
                )
                .onTapGesture {
                    configuration.isOn.toggle()
                }

            configuration.label
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}

@MainActor
class ConnectionApprovalWindowController: NSObject {
    private var window: NSWindow?
    private var approvalView: ConnectionApprovalView?

    func showApprovalWindow(
        clientName: String,
        onApprove: @escaping (Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        // Create the SwiftUI view
        let approvalView = ConnectionApprovalView(
            clientName: clientName,
            onApprove: { alwaysTrust in
                onApprove(alwaysTrust)
                self.closeWindow()
            },
            onDeny: {
                onDeny()
                self.closeWindow()
            }
        )

        // Create the hosting controller
        let hostingController = NSHostingController(rootView: approvalView)

        // Create the window with fixed size matching the SwiftUI view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Connection Request"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = false

        // Initial centering
        window.center()

        // Store references
        self.window = window
        self.approvalView = approvalView

        // Activate the app first
        NSApp.activate(ignoringOtherApps: true)

        // Show the window
        window.makeKeyAndOrderFront(nil)

        // Center again after showing to ensure proper positioning
        Task { @MainActor in
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let x = (screenRect.width - windowRect.width) / 2 + screenRect.origin.x
                let y = (screenRect.height - windowRect.height) / 2 + screenRect.origin.y
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }

    private func closeWindow() {
        window?.close()
        window = nil
        approvalView = nil
    }
}

// MARK: - Tool Approval

struct ToolApprovalView: View {
    let clientName: String
    let toolName: String
    let onApprove: (Bool) -> Void  // Bool parameter is for "always allow"
    let onDeny: () -> Void

    @State private var alwaysAllow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(.menuIconOn)
                .resizable()
                .foregroundColor(.accentColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            Text("Tool Use Request")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \"\(clientName)\" to use \"\(toolName)\"?")

                Text("This tool will be executed with access to your system.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }

            HStack(alignment: .firstTextBaseline) {
                Toggle("Always allow this tool for this client", isOn: $alwaysAllow)
                    .toggleStyle(CheckboxToggleStyle())
                Spacer()
            }
            .padding(.bottom, 20)

            HStack(spacing: 12) {
                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    onApprove(alwaysAllow)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400, height: 300)
        .fixedSize()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}

@MainActor
class ToolApprovalWindowController: NSObject {
    private var window: NSWindow?

    func showApprovalWindow(
        clientName: String,
        toolName: String,
        onApprove: @escaping (Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        let view = ToolApprovalView(
            clientName: clientName,
            toolName: toolName,
            onApprove: { alwaysAllow in
                onApprove(alwaysAllow)
                self.closeWindow()
            },
            onDeny: {
                onDeny()
                self.closeWindow()
            }
        )

        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Tool Use Request"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = false

        window.center()

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let x = (screenRect.width - windowRect.width) / 2 + screenRect.origin.x
                let y = (screenRect.height - windowRect.height) / 2 + screenRect.origin.y
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }
}

#Preview {
    ConnectionApprovalView(
        clientName: "Claude Desktop",
        onApprove: { alwaysTrust in
            print("Approved with always trust: \(alwaysTrust)")
        },
        onDeny: {
            print("Denied")
        }
    )
    .frame(width: 500, height: 400)
}

#Preview("Tool Approval") {
    ToolApprovalView(
        clientName: "Claude Desktop",
        toolName: "shortcuts_run",
        onApprove: { alwaysAllow in
            print("Approved with always allow: \(alwaysAllow)")
        },
        onDeny: {
            print("Denied")
        }
    )
    .frame(width: 500, height: 400)
}
