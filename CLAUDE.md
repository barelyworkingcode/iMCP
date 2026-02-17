# iMCP

macOS MCP server that exposes system services (Calendar, Contacts, Messages, Mail, etc.) to AI clients over localhost TCP. Companion to [Eve](../eve) -- iMCP provides eyes/arms (system access), Eve provides the brain (agent logic).

## Architecture

Two components:

- **iMCP.app** -- SwiftUI menu bar app. Manages permissions, service toggles, token authentication, and the TCP listener. All services run in-process.
- **CLI (`CLI/main.swift`)** -- stdio-to-TCP proxy (`imcp-server`). MCP clients (Claude Desktop, etc.) launch this binary; it discovers the app's port via `~/Library/Application Support/iMCP/server.port` (0600) and bridges JSON-RPC over stdin/stdout. Requires `--token <hex>` argument.

`ServerController.swift` owns the `ServiceRegistry`, service configs with UI metadata, auth tokens with per-service permissions, and shortcuts allowlist. `ServerNetworkManager` (actor) handles the TCP listener, token validation, connection lifecycle, and MCP handler registration with permission enforcement.

## Token Authentication

Connections are authenticated via pre-shared tokens. No runtime approval dialogs.

**Flow:** CLI sends `token\n` on raw TCP before MCP traffic -> server validates with constant-time compare -> creates `MCPConnectionManager` with matched `AuthToken` -> MCP handshake proceeds -> `ListTools`/`CallTool` filtered by token permissions.

**Types** (in `ServerController.swift`):

```swift
enum ServicePermission: String, Codable, CaseIterable {
    case off        // no access
    case readOnly   // only tools where readOnlyHint == true
    case full       // all tools
}

struct AuthToken: Codable, Identifiable {
    let id: UUID
    let name: String         // e.g. "Claude Desktop"
    let token: String        // 64-char hex (32 bytes via SecRandomCopyBytes)
    let createdAt: Date
    var permissions: [String: ServicePermission]  // serviceID -> permission
}
```

`permissions` is keyed on service ID (e.g. `"CalendarService"`, `"ContactsService"`). Missing keys default to `.off`. Tokens are stored in `@AppStorage("authTokens")` as JSON.

**CLI usage:** `imcp-server --token <64-char-hex>`

**No tokens configured = all connections rejected.**

## Adding a New Service

1. Create `App/Services/MyService.swift`
2. Implement the `Service` protocol (`App/Models/Service.swift`):

```swift
private let log = Logger.service("myservice")

final class MyService: Service {
    static let shared = MyService()

    var isActivated: Bool {
        get async { /* check permission status */ }
    }

    func activate() async throws {
        /* request permission */
    }

    @ToolBuilder var tools: [Tool] {
        Tool(
            name: "myservice_action",
            description: "Does something",
            inputSchema: .object(
                properties: ["param": .string(description: "A parameter")],
                required: ["param"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "My Action",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // implementation -- return Encodable value
        }
    }
}
```

3. Register in `ServiceRegistry.services` array (`ServerController.swift:48`)
4. Add `ServiceConfig` entry in `configureServices()` (`ServerController.swift:80`) with icon, color, and binding
5. Add `@AppStorage` toggle in `ServerController` properties (~line 191)
6. Add binding parameter to `configureServices()` signature and `computedServiceConfigs`

## Adding a Tool to an Existing Service

Add a `Tool(...)` call inside the service's `@ToolBuilder var tools` body. Each tool needs: `name`, `description`, `inputSchema` (JSONSchema), `annotations` (MCP.Tool.Annotations), and an async throwing closure. The closure receives `[String: Value]` arguments and returns any `Encodable` type.

Use `annotations.readOnlyHint = true` for read-only tools, `destructiveHint = true` for write operations. The `readOnlyHint` annotation is load-bearing -- it controls whether a tool is accessible under `readOnly` permission.

## Coding Conventions

- **Formatter**: swift-format (`.swift-format` at root -- 4-space indent, 120-char lines)
- **Logging**: `Logger.service("name")` for services, `Logger.server` for server infra
- **Errors**: `NSError` with domain-specific error domain strings (e.g., `"RemindersError"`)
- **Results**: Return Ontology types for structured JSON-LD output where applicable. Plain `Encodable` types work too -- `Tool.init` handles encoding.
- **Value type**: `MCP.Value` enum (re-exported as `Value` via `App/Models/Value.swift`). Access args via pattern matching: `case .string(let s) = arguments["key"]`
- **Sections**: `// MARK: -` comments to separate logical sections
- **Switch**: Exhaustive `switch` with `@unknown default` for framework enums

## Build & Run

```sh
./build.sh          # Debug build, installs to ~/Applications, launches
```

Requires Xcode 16+, macOS 15.3+. This is a hardened fork -- SPM dependencies are pinned as local checkouts in `build/derived/SourcePackages`, not auto-fetched.

## Key Files

| Path | Purpose |
|------|---------|
| `App/Controllers/ServerController.swift` | Service registry, auth tokens, network manager, permission enforcement |
| `App/Integrations/ClaudeDesktop.swift` | Claude Desktop config generation (token + JSON) |
| `App/Models/Service.swift` | `Service` protocol + `@ToolBuilder` |
| `App/Models/Tool.swift` | `Tool` struct with name, schema, annotations, implementation |
| `App/Models/Value.swift` | Re-exports `MCP.Value` |
| `App/Services/*.swift` | One file per system service |
| `App/Views/SettingsView.swift` | Security (token mgmt), Shortcuts, Automation settings |
| `App/Extensions/Logger+Extensions.swift` | `Logger.service()` and `Logger.server` |
| `CLI/main.swift` | stdio-to-TCP proxy binary (`--token` arg) |
| `.swift-format` | Formatter config |
