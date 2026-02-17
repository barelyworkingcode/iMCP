import AppKit
import MCP
import Network
import OSLog
import Ontology
import Security
import SwiftUI
import SystemPackage
import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let log = Logger.server

// MARK: - Token Authentication Model

enum ServicePermission: String, Codable, CaseIterable {
    case off
    case readOnly
    case full
}

struct AuthToken: Codable, Identifiable {
    let id: UUID
    let name: String
    let token: String
    let createdAt: Date
    var permissions: [String: ServicePermission]
}

struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let binding: Binding<Bool>

    var isActivated: Bool {
        get async {
            await service.isActivated
        }
    }

    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        self.iconName = iconName
        self.color = color
        self.service = service
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = {
        var services: [any Service] = [
            CalendarService.shared,
            CaptureService.shared,
            ContactsService.shared,
            LocationService.shared,
            MailService.shared,
            MapsService.shared,
            MessageService.shared,
            RemindersService.shared,
            ShortcutsService.shared,
            UtilitiesService.shared,
        ]
        #if WEATHERKIT_AVAILABLE
            services.append(WeatherService.shared)
        #endif
        return services
    }()

    static func configureServices(
        calendarEnabled: Binding<Bool>,
        captureEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        locationEnabled: Binding<Bool>,
        mailEnabled: Binding<Bool>,
        mapsEnabled: Binding<Bool>,
        messagesEnabled: Binding<Bool>,
        remindersEnabled: Binding<Bool>,
        shortcutsEnabled: Binding<Bool>,
        utilitiesEnabled: Binding<Bool>,
        weatherEnabled: Binding<Bool>
    ) -> [ServiceConfig] {
        var configs: [ServiceConfig] = [
            ServiceConfig(
                name: "Calendar",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: calendarEnabled
            ),
            ServiceConfig(
                name: "Capture",
                iconName: "camera.on.rectangle.fill",
                color: .gray.mix(with: .black, by: 0.7),
                service: CaptureService.shared,
                binding: captureEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: contactsEnabled
            ),
            ServiceConfig(
                name: "Location",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: locationEnabled
            ),
            ServiceConfig(
                name: "Mail",
                iconName: "envelope.fill",
                color: .teal,
                service: MailService.shared,
                binding: mailEnabled
            ),
            ServiceConfig(
                name: "Maps",
                iconName: "mappin.and.ellipse",
                color: .purple,
                service: MapsService.shared,
                binding: mapsEnabled
            ),
            ServiceConfig(
                name: "Messages",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: messagesEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: remindersEnabled
            ),
            ServiceConfig(
                name: "Shortcuts",
                iconName: "square.2.layers.3d",
                color: .indigo,
                service: ShortcutsService.shared,
                binding: shortcutsEnabled
            ),
        ]
        #if WEATHERKIT_AVAILABLE
            configs.append(
                ServiceConfig(
                    name: "Weather",
                    iconName: "cloud.sun.fill",
                    color: .cyan,
                    service: WeatherService.shared,
                    binding: weatherEnabled
                )
            )
        #endif
        return configs
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("captureEnabled") private var captureEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("mailEnabled") private var mailEnabled = false
    @AppStorage("mapsEnabled") private var mapsEnabled = true  // Default enabled
    @AppStorage("messagesEnabled") private var messagesEnabled = false
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("shortcutsEnabled") private var shortcutsEnabled = false
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true  // Default enabled
    @AppStorage("weatherEnabled") private var weatherEnabled = false

    // MARK: - AppStorage for Auth Tokens
    @AppStorage("authTokens") private var authTokensData = Data()

    // MARK: - AppStorage for Shortcuts Allowlist
    @AppStorage("allowedShortcuts") private var allowedShortcutsData = Data()

    // MARK: - AppStorage for Message Watcher
    @AppStorage("messageWatcherEnabled") var messageWatcherEnabled = false
    @AppStorage("messageWatcherScript") var messageWatcherScript = ""

    private var messageWatcher: MessageWatcher?

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            calendarEnabled: $calendarEnabled,
            captureEnabled: $captureEnabled,
            contactsEnabled: $contactsEnabled,
            locationEnabled: $locationEnabled,
            mailEnabled: $mailEnabled,
            mapsEnabled: $mapsEnabled,
            messagesEnabled: $messagesEnabled,
            remindersEnabled: $remindersEnabled,
            shortcutsEnabled: $shortcutsEnabled,
            utilitiesEnabled: $utilitiesEnabled,
            weatherEnabled: $weatherEnabled
        )
    }

    private var currentServiceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: computedServiceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    // MARK: - Auth Token Management
    private var authTokens: [AuthToken] {
        get {
            (try? JSONDecoder().decode([AuthToken].self, from: authTokensData)) ?? []
        }
        set {
            authTokensData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    func generateToken(name: String) -> AuthToken {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        let token = AuthToken(
            id: UUID(),
            name: name,
            token: hex,
            createdAt: Date(),
            permissions: [:]
        )

        var tokens = authTokens
        tokens.append(token)
        authTokens = tokens

        Task {
            await networkManager.setAuthTokens(self.authTokens)
        }

        return token
    }

    func updateTokenPermissions(id: UUID, permissions: [String: ServicePermission]) {
        var tokens = authTokens
        guard let index = tokens.firstIndex(where: { $0.id == id }) else { return }
        tokens[index].permissions = permissions
        authTokens = tokens

        Task {
            await networkManager.setAuthTokens(self.authTokens)
        }
    }

    func revokeToken(id: UUID) {
        var tokens = authTokens
        tokens.removeAll { $0.id == id }
        authTokens = tokens

        Task {
            await networkManager.setAuthTokens(self.authTokens)
        }
    }

    func revokeAllTokens() {
        authTokens = []

        Task {
            await networkManager.setAuthTokens([])
        }
    }

    func getAuthTokens() -> [AuthToken] {
        authTokens
    }

    // MARK: - Service Enablement

    func enableAllServices() {
        calendarEnabled = true
        captureEnabled = true
        contactsEnabled = true
        locationEnabled = true
        mailEnabled = true
        mapsEnabled = true
        messagesEnabled = true
        remindersEnabled = true
        shortcutsEnabled = true
        utilitiesEnabled = true
        weatherEnabled = true

        Task {
            await networkManager.updateServiceBindings(self.currentServiceBindings)
        }
    }

    // MARK: - Shortcuts Allowlist Management
    private var allowedShortcuts: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: allowedShortcutsData)) ?? []
        }
        set {
            allowedShortcutsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    func isShortcutAllowed(_ name: String) -> Bool {
        allowedShortcuts.contains(name)
    }

    func addAllowedShortcut(_ name: String) {
        var shortcuts = allowedShortcuts
        shortcuts.insert(name)
        allowedShortcuts = shortcuts
    }

    func removeAllowedShortcut(_ name: String) {
        var shortcuts = allowedShortcuts
        shortcuts.remove(name)
        allowedShortcuts = shortcuts
    }

    func getAllowedShortcuts() -> [String] {
        Array(allowedShortcuts).sorted()
    }

    // MARK: - Message Watcher Management

    func updateMessageWatcher() {
        let shouldRun = messagesEnabled && messageWatcherEnabled && !messageWatcherScript.isEmpty
        if shouldRun {
            // Restart if script path changed.
            messageWatcher?.stop()
            let watcher = MessageWatcher(scriptPath: messageWatcherScript)
            watcher.start()
            messageWatcher = watcher
        } else {
            messageWatcher?.stop()
            messageWatcher = nil
        }
    }

    init() {
        Task {
            // Initialize bindings and tokens before the server starts.
            await networkManager.updateServiceBindings(self.currentServiceBindings)
            await networkManager.setAuthTokens(self.authTokens)
            await self.networkManager.start()
            self.updateServerStatus("Running")
            self.updateMessageWatcher()
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        // Called by the UI when service toggles change.
        await networkManager.updateServiceBindings(bindings)
    }

    func startServer() async {
        await networkManager.start()
        updateServerStatus("Running")
    }

    func stopServer() async {
        await networkManager.stop()
        updateServerStatus("Stopped")
    }

    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        updateServerStatus(enabled ? "Running" : "Disabled")
    }

    private func updateServerStatus(_ status: String) {
        log.info("Server status updated: \(status)")
        self.serverStatus = status
    }

}

// MARK: - Connection Management Components

// Manages a single MCP connection.
actor MCPConnectionManager {
    private let connectionID: UUID
    private let connection: NWConnection
    private let server: MCP.Server
    private var transport: NetworkTransport
    private let parentManager: ServerNetworkManager
    let authenticatedToken: AuthToken
    private(set) var clientName: String?

    init(connectionID: UUID, connection: NWConnection, parentManager: ServerNetworkManager, authenticatedToken: AuthToken) {
        self.connectionID = connectionID
        self.connection = connection
        self.parentManager = parentManager
        self.authenticatedToken = authenticatedToken

        self.transport = NetworkTransport(
            connection: connection,
            logger: nil,
            heartbeatConfig: .disabled,
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )

        // MCP server instance for this connection.
        self.server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
    }

    func start() async throws {
        do {
            log.notice("Starting MCP server for connection: \(self.connectionID)")
            try await server.start(transport: transport) { [weak self] clientInfo, capabilities in
                guard let self = self else { throw MCPError.connectionClosed }

                log.info("Received initialize request from client: \(clientInfo.name)")

                // Use the authenticated token name as the canonical client name.
                await self.setClientName(self.authenticatedToken.name)
            }

            log.notice("MCP Server started successfully for connection: \(self.connectionID)")

            // Register handlers with token-based permission enforcement.
            await registerHandlers()

            // Monitor connection health for early disconnects.
            await startHealthMonitoring()
        } catch {
            log.error("Failed to start MCP server: \(error.localizedDescription)")
            throw error
        }
    }

    private func setClientName(_ name: String) {
        self.clientName = name
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(for: server, connectionID: connectionID, token: authenticatedToken)
    }

    private func startHealthMonitoring() async {
        // Monitor until the manager stops or the connection fails.
        Task {
            outer: while await parentManager.isRunning() {
                switch connection.state {
                case .ready, .setup, .preparing, .waiting:
                    break
                case .cancelled:
                    log.error("Connection \(self.connectionID) was cancelled, removing")
                    await parentManager.removeConnection(connectionID)
                    break outer
                case .failed(let error):
                    log.error(
                        "Connection \(self.connectionID) failed with error \(error), removing"
                    )
                    await parentManager.removeConnection(connectionID)
                    break outer
                @unknown default:
                    log.debug("Connection \(self.connectionID) in unknown state, skipping")
                }

                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            }
        }
    }

    func notifyToolListChanged() async {
        do {
            log.info("Notifying client that tool list changed")
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            log.error("Failed to notify client of tool list change: \(error)")

            // Clean up if the underlying NWConnection is closed.
            if let nwError = error as? NWError,
                nwError.errorCode == 57 || nwError.errorCode == 54
            {
                log.debug("Connection appears to be closed")
                await parentManager.removeConnection(connectionID)
            }
        }
    }

    func stop() async {
        await server.stop()
        connection.cancel()
    }
}

// Manages the TCP listener (localhost-only, no Bonjour advertisement).
actor NetworkDiscoveryManager {
    var listener: NWListener

    private static var portFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("iMCP/server.port")
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        self.listener = try NWListener(using: parameters)

        log.info("Network discovery manager initialized (localhost-only, no Bonjour)")
    }

    func start(
        stateHandler: @escaping @Sendable (NWListener.State) -> Void,
        connectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) {
        listener.stateUpdateHandler = stateHandler
        listener.newConnectionHandler = connectionHandler
        listener.start(queue: .main)

        log.info("Started TCP listener")
    }

    func stop() {
        listener.cancel()
        Self.removePortFile()
        log.info("Stopped TCP listener and removed port file")
    }

    func writePortFile() {
        guard let port = listener.port else {
            log.error("Cannot write port file: listener has no port")
            return
        }

        let url = Self.portFileURL
        let dir = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            // Repair existing directory permissions for upgrades.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.path
            )

            try "\(port.rawValue)".write(to: url, atomically: true, encoding: .utf8)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )

            log.info("Wrote port file: \(url.path) with port \(port.rawValue)")
        } catch {
            log.error("Failed to write port file: \(error)")
        }
    }

    static func removePortFile() {
        try? FileManager.default.removeItem(at: portFileURL)
        log.info("Removed port file")
    }

    func restartWithRandomPort() async throws {
        listener.cancel()
        Self.removePortFile()

        let parameters: NWParameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        let newListener: NWListener = try NWListener(using: parameters)

        if let currentStateHandler = listener.stateUpdateHandler {
            newListener.stateUpdateHandler = currentStateHandler
        }

        if let currentConnectionHandler = listener.newConnectionHandler {
            newListener.newConnectionHandler = currentConnectionHandler
        }

        newListener.start(queue: .main)

        self.listener = newListener

        log.notice("Restarted listener with a dynamic port")
    }
}

actor ServerNetworkManager {
    private var isRunningState: Bool = false
    private var isEnabledState: Bool = true
    private var discoveryManager: NetworkDiscoveryManager?
    private var connections: [UUID: MCPConnectionManager] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]

    private var authTokens: [AuthToken] = []

    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]

    init() {
        do {
            self.discoveryManager = try NetworkDiscoveryManager()
        } catch {
            log.error("Failed to initialize network discovery manager: \(error)")
        }
    }

    func isRunning() -> Bool {
        isRunningState
    }

    func setAuthTokens(_ tokens: [AuthToken]) {
        self.authTokens = tokens
    }

    // MARK: - Token Validation

    /// Constant-time comparison to prevent timing attacks.
    private static func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }

    /// Reads a newline-terminated token from a raw NWConnection with a timeout.
    private func validateToken(on connection: NWConnection, timeout: TimeInterval = 5.0) async -> AuthToken? {
        // Snapshot tokens before entering Sendable closure.
        let tokensSnapshot = authTokens

        // Race: receive vs timeout.
        let data: Data? = await withCheckedContinuation { continuation in
            let gate = ResumeGate()

            // Timeout.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                Task {
                    guard await gate.shouldResume() else { return }
                    log.warning("Token validation timed out")
                    continuation.resume(returning: nil as Data?)
                }
            }

            // Receive.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                Task {
                    guard await gate.shouldResume() else { return }
                    if let data = data, error == nil {
                        continuation.resume(returning: data)
                    } else {
                        log.warning("Token receive failed: \(error?.localizedDescription ?? "no data")")
                        continuation.resume(returning: nil as Data?)
                    }
                }
            }
        }

        guard let data = data else { return nil }

        // Extract the first newline-terminated line as the token.
        guard let line = String(data: data, encoding: .utf8)?
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else {
            log.warning("Token receive: empty or invalid data")
            return nil
        }

        // Constant-time compare against each configured token.
        for authToken in tokensSnapshot {
            if Self.constantTimeCompare(line, authToken.token) {
                return authToken
            }
        }

        log.warning("Token validation failed: no matching token")
        return nil
    }

    func start() async {
        log.info("Starting network manager")
        isRunningState = true

        guard let discoveryManager = discoveryManager else {
            log.error("Cannot start network manager: discovery manager not initialized")
            return
        }

        await discoveryManager.start(
            stateHandler: { [weak self] (state: NWListener.State) -> Void in
                guard let strongSelf = self else { return }

                Task {
                    await strongSelf.handleListenerStateChange(state)
                }
            },
            connectionHandler: { [weak self] (connection: NWConnection) -> Void in
                guard let strongSelf = self else { return }

                Task {
                    await strongSelf.handleNewConnection(connection)
                }
            }
        )

        // Monitor listener health and auto-restart if it stops advertising.
        Task {
            while self.isRunningState {
                if let currentDM = self.discoveryManager,
                    self.isRunningState
                {
                    let listenerState: NWListener.State = await currentDM.listener.state

                    if listenerState != .ready {
                        log.warning(
                            "Listener not in ready state, current state: \\(listenerState)"
                        )

                        let shouldAttemptRestart: Bool
                        switch listenerState {
                        case .failed, .cancelled:
                            shouldAttemptRestart = true
                        default:
                            shouldAttemptRestart = false
                        }

                        if shouldAttemptRestart {
                            log.info(
                                "Attempting to restart listener (state: \\(listenerState)) because it was failed or cancelled."
                            )
                            try? await currentDM.restartWithRandomPort()
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10s
            }
        }
    }

    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            log.info("Server ready and listening on localhost")
            await discoveryManager?.writePortFile()
        case .setup:
            log.debug("Server setting up...")
        case .waiting(let error):
            log.warning("Server waiting: \(error)")

            // If the port is already in use, try a new one.
            if error.errorCode == 48 {
                log.error("Port already in use, will try to restart service")

                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

                if isRunningState {
                    try? await discoveryManager?.restartWithRandomPort()
                }
            }
        case .failed(let error):
            log.error("Server failed: \(error)")

            // Attempt recovery after a brief delay.
            if isRunningState {
                log.info("Attempting to recover from server failure")
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

                try? await discoveryManager?.restartWithRandomPort()
            }
        case .cancelled:
            log.info("Server cancelled")
        @unknown default:
            log.warning("Unknown server state")
        }
    }

    func stop() async {
        log.info("Stopping network manager")
        isRunningState = false

        for (id, connectionManager) in connections {
            log.debug("Stopping connection: \(id)")
            await connectionManager.stop()
            connectionTasks[id]?.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()
        pendingConnections.removeAll()

        await discoveryManager?.stop()
        NetworkDiscoveryManager.removePortFile()
    }

    func removeConnection(_ id: UUID) async {
        log.debug("Removing connection: \(id)")

        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        if let task = connectionTasks[id] {
            task.cancel()
        }

        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        pendingConnections.removeValue(forKey: id)
    }

    // Handle new incoming connections with token authentication.
    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionID = UUID()
        log.info("Handling new connection: \(connectionID)")

        // Reject if no tokens are configured.
        guard !authTokens.isEmpty else {
            log.warning("No auth tokens configured, rejecting connection \(connectionID)")
            connection.cancel()
            return
        }

        // Start the connection so we can read the token.
        connection.start(queue: .main)

        // Wait for the connection to become ready.
        let ready: Bool = await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            connection.stateUpdateHandler = { state in
                Task {
                    switch state {
                    case .ready:
                        guard await gate.shouldResume() else { return }
                        continuation.resume(returning: true)
                    case .failed, .cancelled:
                        guard await gate.shouldResume() else { return }
                        continuation.resume(returning: false)
                    default:
                        break
                    }
                }
            }
        }

        guard ready else {
            log.warning("Connection \(connectionID) failed to reach ready state")
            connection.cancel()
            return
        }

        // Validate the token from the raw connection.
        guard let matchedToken = await validateToken(on: connection) else {
            log.warning("Connection \(connectionID) rejected: invalid or missing token")
            connection.cancel()
            return
        }

        log.notice("Connection \(connectionID) authenticated as '\(matchedToken.name)'")

        // Token consumed -- create the MCP connection manager.
        let connectionManager = MCPConnectionManager(
            connectionID: connectionID,
            connection: connection,
            parentManager: self,
            authenticatedToken: matchedToken
        )

        connections[connectionID] = connectionManager

        let task = Task {
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
            }

            do {
                try await connectionManager.start()
                log.notice("Connection \(connectionID) successfully established")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        connectionTasks[connectionID] = task

        // Time out stalled setups to avoid orphaned connections.
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

            if self.connectionTasks[connectionID] != nil,
                self.connections[connectionID] != nil
            {
                log.warning(
                    "Connection \(connectionID) setup timed out (task still in registry), closing it"
                )
                await removeConnection(connectionID)
            }
        }
    }

    /// Builds a lookup from tool name to service ID for permission enforcement.
    private func buildToolServiceMap() -> [String: String] {
        var map: [String: String] = [:]
        for service in services {
            let serviceId = String(describing: type(of: service))
            for tool in service.tools {
                map[tool.name] = serviceId
            }
        }
        return map
    }

    /// Checks whether a token permits the given tool based on its service permission.
    private nonisolated func isToolPermitted(_ tool: Tool, serviceId: String, token: AuthToken) -> Bool {
        let permission = token.permissions[serviceId] ?? .off
        switch permission {
        case .off:
            return false
        case .readOnly:
            return tool.annotations.readOnlyHint == true
        case .full:
            return true
        }
    }

    func registerHandlers(for server: MCP.Server, connectionID: UUID, token: AuthToken) async {
        let toolServiceMap = buildToolServiceMap()

        await server.withMethodHandler(ListPrompts.self) { _ in
            log.debug("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: [])
        }

        await server.withMethodHandler(ListResources.self) { _ in
            log.debug("Handling ListResources request for \(connectionID)")
            return ListResources.Result(resources: [])
        }

        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }

            log.debug("Handling ListTools request for \(connectionID)")

            var tools: [MCP.Tool] = []
            if await self.isEnabledState {
                for service in await self.services {
                    let serviceId = String(describing: type(of: service))

                    // Check global service toggle.
                    if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                        isServiceEnabled
                    {
                        for tool in service.tools {
                            // Check token permission for this service.
                            if self.isToolPermitted(tool, serviceId: serviceId, token: token) {
                                tools.append(
                                    .init(
                                        name: tool.name,
                                        description: tool.description,
                                        inputSchema: tool.inputSchema,
                                        annotations: tool.annotations
                                    )
                                )
                            }
                        }
                    }
                }
            }

            log.info("Returning \(tools.count) available tools for \(connectionID) (\(token.name))")
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(
                    content: [.text("Server unavailable")],
                    isError: true
                )
            }

            log.notice("Tool call received from \(connectionID) (\(token.name)): \(params.name)")

            guard await self.isEnabledState else {
                log.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [.text("iMCP is currently disabled. Please enable it to use tools.")],
                    isError: true
                )
            }

            // Permission enforcement: check token permissions for this tool.
            if let serviceId = toolServiceMap[params.name] {
                // Find the tool to check its annotations.
                var permitted = false
                for service in await self.services {
                    let sid = String(describing: type(of: service))
                    guard sid == serviceId else { continue }
                    for tool in service.tools where tool.name == params.name {
                        permitted = self.isToolPermitted(tool, serviceId: serviceId, token: token)
                        break
                    }
                    break
                }

                if !permitted {
                    log.notice("Tool call denied by permissions: \(params.name) for \(token.name)")
                    return CallTool.Result(
                        content: [.text("Permission denied: '\(params.name)' is not allowed for this token.")],
                        isError: true
                    )
                }
            }

            for service in await self.services {
                let serviceId = String(describing: type(of: service))

                // Check global service toggle.
                if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                    isServiceEnabled
                {
                    do {
                        guard
                            let value = try await service.call(
                                tool: params.name,
                                with: params.arguments ?? [:]
                            )
                        else {
                            continue
                        }

                        log.notice("Tool \(params.name) executed successfully for \(connectionID)")
                        switch value {
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("audio/"):
                            return CallTool.Result(
                                content: [
                                    .audio(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType
                                    )
                                ],
                                isError: false
                            )
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("image/"):
                            return CallTool.Result(
                                content: [
                                    .image(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        metadata: nil
                                    )
                                ],
                                isError: false
                            )
                        default:
                            let encoder = JSONEncoder()
                            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                                TimeZone.current
                            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                            let data = try encoder.encode(value)
                            let text = String(data: data, encoding: .utf8)!

                            return CallTool.Result(content: [.text(text)], isError: false)
                        }
                    } catch {
                        log.error(
                            "Error executing tool \(params.name): \(error.localizedDescription)"
                        )
                        return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
                    }
                }
            }

            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [.text("Tool not found or service not enabled: \(params.name)")],
                isError: true
            )
        }
    }

    // Update the enabled state and notify clients.
    func setEnabled(_ enabled: Bool) async {
        // Only act on changes.
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.info("iMCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed.
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // Update service bindings.
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        self.serviceBindings = newBindings

        // Notify clients that tool availability may have changed.
        Task {
            for (_, connectionManager) in connections {
                await connectionManager.notifyToolListChanged()
            }
        }
    }
}
