# iMCP

macOS MCP server that exposes system services (Calendar, Contacts, Messages, Mail, etc.) to AI clients over localhost TCP. Companion to [Eve](../eve) -- iMCP provides eyes/arms (system access), Eve provides the brain (agent logic).

## Architecture

Two components:

- **iMCP.app** -- SwiftUI menu bar app. Manages permissions, service toggles, connection approval, and the TCP listener. All services run in-process.
- **CLI (`CLI/main.swift`)** -- stdio-to-TCP proxy (`imcp-server`). MCP clients (Claude Desktop, etc.) launch this binary; it discovers the app's port via `~/Library/Application Support/iMCP/server.port` and bridges JSON-RPC over stdin/stdout.

`ServerController.swift` owns the `ServiceRegistry` (line ~48), service configs with UI metadata, trusted clients, per-tool approvals, and shortcuts allowlist. `ServerNetworkManager` (actor) handles the TCP listener, connection lifecycle, and MCP handler registration.

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
5. Add `@AppStorage` toggle in `ServerController` properties (~line 174)
6. Add binding parameter to `configureServices()` signature and `computedServiceConfigs`

## Adding a Tool to an Existing Service

Add a `Tool(...)` call inside the service's `@ToolBuilder var tools` body. Each tool needs: `name`, `description`, `inputSchema` (JSONSchema), `annotations` (MCP.Tool.Annotations), and an async throwing closure. The closure receives `[String: Value]` arguments and returns any `Encodable` type.

Use `annotations.readOnlyHint = true` for read-only tools, `destructiveHint = true` for write operations.

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
| `App/Controllers/ServerController.swift` | Service registry, network manager, connection/tool approval |
| `App/Models/Service.swift` | `Service` protocol + `@ToolBuilder` |
| `App/Models/Tool.swift` | `Tool` struct with name, schema, annotations, implementation |
| `App/Models/Value.swift` | Re-exports `MCP.Value` |
| `App/Services/*.swift` | One file per system service |
| `App/Extensions/Logger+Extensions.swift` | `Logger.service()` and `Logger.server` |
| `CLI/main.swift` | stdio-to-TCP proxy binary |
| `.swift-format` | Formatter config |
