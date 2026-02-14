import AppKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    func activate() async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()

        guard FileManager.default.isReadableFile(atPath: selectedURL.path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        log.debug("Successfully activated message service")
    }

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabaseAtDefaultPath || canAccessDatabaseUsingBookmark
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_fetch",
            description: "Fetch messages from the Messages app",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate()

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            var dateRange: Range<Date>?
            if let startDateStr = arguments["start"]?.stringValue,
                let endDateStr = arguments["end"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            {
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )

                dateRange = normalizedStart ..< normalizedEnd
            }

            let searchTerm = arguments["query"]?.stringValue
            let limit = arguments["limit"]?.intValue ?? defaultLimit

            let msgDB = try self.createMessageDatabase()
            let fetched = try msgDB.fetchMessages(
                participants: participants,
                dateRange: dateRange,
                searchTerm: searchTerm,
                limit: limit
            )

            var messages: [[String: Value]] = []
            for msg in fetched {
                let sender = msg.isFromMe ? "me" : (msg.sender ?? "unknown")

                var entry: [String: Value] = [
                    "@id": .string(msg.guid),
                    "sender": .object(["@id": .string(sender)]),
                    "text": .string(msg.text),
                    "createdAt": .string(msg.date.formatted(.iso8601)),
                ]

                if let subject = msg.subject, !subject.isEmpty {
                    entry["subject"] = .string(subject)
                }

                if msg.hasAttachments {
                    let attachments = (try? msgDB.fetchAttachments(forMessageRowID: msg.rowID)) ?? []
                    if !attachments.isEmpty {
                        entry["attachments"] = .array(attachments.map { a in
                            .object([
                                "filename": .string(a.filename ?? "unknown"),
                                "mimeType": .string(a.mimeType ?? "application/octet-stream"),
                                "totalBytes": .int(Int(a.totalBytes)),
                            ])
                        })
                    }
                }

                messages.append(entry)
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }

        Tool(
            name: "messages_unread",
            description: "Fetch unread inbound messages from the Messages app",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(10)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Unread Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting unread message fetch")
            try await self.activate()

            let limit = arguments["limit"]?.intValue ?? 10
            let msgDB = try self.createMessageDatabase()
            let fetched = try msgDB.fetchUnreadMessages(limit: limit)

            var messages: [[String: Value]] = []
            for msg in fetched {
                var entry: [String: Value] = [
                    "@id": .string(msg.guid),
                    "sender": .object(["@id": .string(msg.sender ?? "unknown")]),
                    "text": .string(msg.text),
                    "createdAt": .string(msg.date.formatted(.iso8601)),
                    "isRead": .bool(msg.isRead),
                ]

                if let subject = msg.subject, !subject.isEmpty {
                    entry["subject"] = .string(subject)
                }

                if msg.hasAttachments {
                    let attachments = (try? msgDB.fetchAttachments(forMessageRowID: msg.rowID)) ?? []
                    if !attachments.isEmpty {
                        entry["attachments"] = .array(attachments.map { a in
                            .object([
                                "filename": .string(a.filename ?? "unknown"),
                                "mimeType": .string(a.mimeType ?? "application/octet-stream"),
                                "totalBytes": .int(Int(a.totalBytes)),
                            ])
                        })
                    }
                }

                messages.append(entry)
            }

            log.debug("Successfully fetched \(messages.count) unread messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }

        Tool(
            name: "messages_send",
            description: "Send an iMessage to a recipient",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description:
                            "Recipient phone number (E.164 format) or email address"
                    ),
                    "message": .string(
                        description: "The message text to send"
                    ),
                ],
                required: ["recipient", "message"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Message",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case let .string(recipient) = arguments["recipient"], !recipient.isEmpty else {
                throw NSError(
                    domain: "MessagesError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Recipient is required"]
                )
            }

            guard case let .string(message) = arguments["message"], !message.isEmpty else {
                throw NSError(
                    domain: "MessagesError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Message text is required"]
                )
            }

            return try await self.sendMessage(to: recipient, text: message)
        }
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func createMessageDatabase() throws -> MessageDatabase {
        if canAccessDatabaseAtDefaultPath {
            return MessageDatabase(path: messagesDatabasePath)
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            MessageDatabase(path: url.path)
        }
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: url.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        alert.informativeText = """
            To read your Messages history, we need to open your database file.

            In the next screen, please select the file `chat.db` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select the Messages database file (chat.db)"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [UTType.item]
        openPanel.directoryURL = URL(fileURLWithPath: messagesDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == "chat.db"
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    // MARK: - Send Message

    private let osascriptPath = "/usr/bin/osascript"
    private let sendTimeout: Duration = .seconds(30)

    private func runProcess(_ process: Process) async throws {
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    private func sendMessage(to recipient: String, text: String) async throws -> Value {
        log.info("Sending message to: \(recipient, privacy: .private)")

        let escapedMessage = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "Messages"
                set targetService to 1st service whose service type = iMessage
                send "\(escapedMessage)" to buddy "\(escapedRecipient)" of targetService
            end tell
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorHandle = errorPipe.fileHandleForReading
        defer { errorHandle.closeFile() }

        var errorData = Data()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.runProcess(process)
                }

                group.addTask {
                    try await Task.sleep(for: self.sendTimeout)
                    process.terminate()
                    throw NSError(
                        domain: "MessagesError",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Message send timed out after \(Int(self.sendTimeout.components.seconds)) seconds"
                        ]
                    )
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            errorData = (try? errorHandle.readToEnd()) ?? Data()
            if !errorData.isEmpty {
                let stderrMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                log.error("Message send stderr: \(stderrMessage, privacy: .public)")
            }
            log.error("Failed to send message: \(error.localizedDescription)")
            throw error
        }

        if errorData.isEmpty {
            errorData = (try? errorHandle.readToEnd()) ?? Data()
        }

        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("Message send failed: \(errorMessage)")
            throw NSError(
                domain: "MessagesError",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to send message: \(errorMessage)"]
            )
        }

        log.info("Message sent successfully to: \(recipient, privacy: .private)")

        return .object([
            "success": .bool(true),
            "recipient": .string(recipient),
        ])
    }

    // NSOpenSavePanelDelegate method to constrain file selection
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = url.lastPathComponent == "chat.db"
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}
