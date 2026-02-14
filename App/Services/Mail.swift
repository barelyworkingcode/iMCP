import Foundation
import JSONSchema
import OSLog
import Ontology

private let log = Logger.service("mail")

private let defaultFetchLimit = 50

final class MailService: Service {
    static let shared = MailService()

    private let osascriptPath = "/usr/bin/osascript"
    private let scriptTimeout: Duration = .seconds(30)

    var isActivated: Bool {
        get async {
            do {
                _ = try await runJXA("var Mail = Application('Mail'); Mail.name()")
                return true
            } catch {
                return false
            }
        }
    }

    func activate() async throws {
        log.debug("Activating mail service")
        _ = try await runJXA("var Mail = Application('Mail'); Mail.name()")
        log.debug("Mail service activated")
    }

    // MARK: - JXA Execution

    private func runJXA(_ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        defer {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try process.run()
                    await withCheckedContinuation { continuation in
                        process.terminationHandler = { _ in
                            continuation.resume()
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: self.scriptTimeout)
                    process.terminate()
                    throw NSError(
                        domain: "MailService",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Script timed out after \(Int(self.scriptTimeout.components.seconds)) seconds"
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
            throw error
        }

        guard process.terminationStatus == 0 else {
            let stderrData = (try? stderrHandle.readToEnd()) ?? Data()
            let errorMessage = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            log.error("JXA script failed: \(errorMessage, privacy: .public)")
            throw NSError(
                domain: "MailService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Mail script failed: \(errorMessage)"]
            )
        }

        let stdoutData = (try? stdoutHandle.readToEnd()) ?? Data()
        return String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func runJXAAsValue(_ script: String) async throws -> Value {
        let output = try await runJXA(script)
        guard !output.isEmpty else {
            return .null
        }
        guard let data = output.data(using: .utf8) else {
            return .string(output)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    // MARK: - JXA String Escaping

    private func escapeForJXA(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Tools

    var tools: [Tool] {
        Tool(
            name: "mail_accounts",
            description: "List configured email accounts in Mail.app, including account name, email address, and account type",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mail Accounts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var accounts = Mail.accounts();
                var result = [];
                for (var i = 0; i < accounts.length; i++) {
                    var a = accounts[i];
                    result.push({
                        name: a.name(),
                        email: a.emailAddresses()[0] || '',
                        type: a.accountType(),
                        enabled: a.enabled()
                    });
                }
                JSON.stringify(result);
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_mailboxes",
            description: "List mailboxes for a specific email account, including unread message counts",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_accounts)"
                    ),
                ],
                required: ["account"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mailboxes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(account) = arguments["account"], !account.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Account name is required"]
                )
            }

            let escapedAccount = self.escapeForJXA(account)
            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var acct = Mail.accounts.byName('\(escapedAccount)');
                var mailboxes = acct.mailboxes();
                var result = [];
                for (var i = 0; i < mailboxes.length; i++) {
                    var mb = mailboxes[i];
                    result.push({
                        name: mb.name(),
                        unreadCount: mb.unreadCount()
                    });
                }
                JSON.stringify(result);
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_fetch",
            description: "Fetch message summaries from a mailbox. Returns message ID, subject, sender, date, read status, and whether it has attachments.",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name (from mail_mailboxes), e.g. 'INBOX'"
                    ),
                    "limit": .integer(
                        description: "Maximum number of messages to return",
                        default: .int(defaultFetchLimit)
                    ),
                    "unreadOnly": .boolean(
                        description: "If true, only return unread messages"
                    ),
                ],
                required: ["account", "mailbox"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(account) = arguments["account"], !account.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Account name is required"]
                )
            }
            guard case let .string(mailbox) = arguments["mailbox"], !mailbox.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mailbox name is required"]
                )
            }

            let limit = arguments["limit"]?.intValue ?? defaultFetchLimit
            let unreadOnly = arguments["unreadOnly"]?.boolValue ?? false
            let escapedAccount = self.escapeForJXA(account)
            let escapedMailbox = self.escapeForJXA(mailbox)

            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var acct = Mail.accounts.byName('\(escapedAccount)');
                var mb = acct.mailboxes.byName('\(escapedMailbox)');
                var msgs = mb.messages();
                var result = [];
                var count = 0;
                for (var i = 0; i < msgs.length && count < \(limit); i++) {
                    var m = msgs[i];
                    try {
                        var isRead = m.readStatus();
                        if (\(unreadOnly ? "true" : "false") && isRead) continue;
                        result.push({
                            id: m.id(),
                            subject: m.subject() || '',
                            sender: m.sender(),
                            dateReceived: m.dateReceived() ? m.dateReceived().toISOString() : null,
                            isRead: isRead,
                            hasAttachments: m.mailAttachments().length > 0
                        });
                        count++;
                    } catch(e) {}
                }
                JSON.stringify(result);
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_read",
            description: "Read the full content of a specific email message, including headers, body text, and attachment metadata",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name"
                    ),
                    "id": .integer(
                        description: "Message ID (from mail_fetch or mail_search)"
                    ),
                ],
                required: ["account", "mailbox", "id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Message",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(account) = arguments["account"], !account.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Account name is required"]
                )
            }
            guard case let .string(mailbox) = arguments["mailbox"], !mailbox.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mailbox name is required"]
                )
            }
            guard let messageId = arguments["id"]?.intValue else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"]
                )
            }

            let escapedAccount = self.escapeForJXA(account)
            let escapedMailbox = self.escapeForJXA(mailbox)

            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var acct = Mail.accounts.byName('\(escapedAccount)');
                var mb = acct.mailboxes.byName('\(escapedMailbox)');
                var msgs = mb.messages.whose({id: \(messageId)})();
                if (msgs.length === 0) throw new Error('Message not found');
                var m = msgs[0];
                var attachments = [];
                var atts = m.mailAttachments();
                for (var i = 0; i < atts.length; i++) {
                    var att = atts[i];
                    attachments.push({
                        name: att.name(),
                        mimeType: att.mimeType(),
                        fileSize: att.fileSize()
                    });
                }
                var result = {
                    id: m.id(),
                    subject: m.subject() || '',
                    sender: m.sender(),
                    replyTo: m.replyTo() || '',
                    dateReceived: m.dateReceived() ? m.dateReceived().toISOString() : null,
                    dateSent: m.dateSent() ? m.dateSent().toISOString() : null,
                    isRead: m.readStatus(),
                    toRecipients: m.toRecipients().map(function(r) { return {name: r.name(), address: r.address()}; }),
                    ccRecipients: m.ccRecipients().map(function(r) { return {name: r.name(), address: r.address()}; }),
                    content: m.content() || '',
                    attachments: attachments
                };
                JSON.stringify(result);
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_search",
            description: "Search for messages by subject or content across mailboxes. Searches the specified mailbox, or INBOX if not specified.",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name"
                    ),
                    "query": .string(
                        description: "Search query string"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name to search in (defaults to INBOX)"
                    ),
                    "limit": .integer(
                        description: "Maximum number of results",
                        default: .int(25)
                    ),
                ],
                required: ["account", "query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(account) = arguments["account"], !account.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Account name is required"]
                )
            }
            guard case let .string(query) = arguments["query"], !query.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Search query is required"]
                )
            }

            let mailbox = arguments["mailbox"]?.stringValue ?? "INBOX"
            let limit = arguments["limit"]?.intValue ?? 25
            let escapedAccount = self.escapeForJXA(account)
            let escapedMailbox = self.escapeForJXA(mailbox)
            let escapedQuery = self.escapeForJXA(query)

            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var acct = Mail.accounts.byName('\(escapedAccount)');
                var mb = acct.mailboxes.byName('\(escapedMailbox)');
                var matched = mb.messages.whose({subject: {_contains: '\(escapedQuery)'}})();
                var result = [];
                var count = Math.min(matched.length, \(limit));
                for (var i = 0; i < count; i++) {
                    var m = matched[i];
                    try {
                        result.push({
                            id: m.id(),
                            account: '\(escapedAccount)',
                            mailbox: '\(escapedMailbox)',
                            subject: m.subject() || '',
                            sender: m.sender(),
                            dateReceived: m.dateReceived() ? m.dateReceived().toISOString() : null,
                            isRead: m.readStatus(),
                            hasAttachments: m.mailAttachments().length > 0
                        });
                    } catch(e) {}
                }
                JSON.stringify(result);
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_send",
            description: "Compose and send an email message",
            inputSchema: .object(
                properties: [
                    "to": .array(
                        description: "Recipient email addresses",
                        items: .string()
                    ),
                    "subject": .string(
                        description: "Email subject"
                    ),
                    "body": .string(
                        description: "Email body text"
                    ),
                    "cc": .array(
                        description: "CC recipient email addresses",
                        items: .string()
                    ),
                    "bcc": .array(
                        description: "BCC recipient email addresses",
                        items: .string()
                    ),
                    "fromAccount": .string(
                        description: "Account name to send from (uses default if omitted)"
                    ),
                ],
                required: ["to", "subject", "body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Email",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let toArray = arguments["to"]?.arrayValue,
                  !toArray.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "At least one recipient is required"]
                )
            }
            guard case let .string(subject) = arguments["subject"] else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Subject is required"]
                )
            }
            guard case let .string(body) = arguments["body"] else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Body is required"]
                )
            }

            let toAddresses = toArray.compactMap { $0.stringValue }
            let ccAddresses = arguments["cc"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let bccAddresses = arguments["bcc"]?.arrayValue?.compactMap { $0.stringValue } ?? []

            let escapedSubject = self.escapeForJXA(subject)
            let escapedBody = self.escapeForJXA(body)

            var recipientLines = ""
            for addr in toAddresses {
                let escaped = self.escapeForJXA(addr)
                recipientLines += "var toR = Mail.Recipient({address: '\(escaped)'}); msg.toRecipients.push(toR);\n"
            }
            for addr in ccAddresses {
                let escaped = self.escapeForJXA(addr)
                recipientLines += "var ccR = Mail.CcRecipient({address: '\(escaped)'}); msg.ccRecipients.push(ccR);\n"
            }
            for addr in bccAddresses {
                let escaped = self.escapeForJXA(addr)
                recipientLines += "var bccR = Mail.BccRecipient({address: '\(escaped)'}); msg.bccRecipients.push(bccR);\n"
            }

            var accountLine = ""
            if case let .string(fromAccount) = arguments["fromAccount"], !fromAccount.isEmpty {
                let escapedFrom = self.escapeForJXA(fromAccount)
                accountLine = "msg.sender = Mail.accounts.byName('\(escapedFrom)').emailAddresses()[0];"
            }

            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var msg = Mail.OutgoingMessage({
                    subject: '\(escapedSubject)',
                    content: '\(escapedBody)',
                    visible: false
                });
                Mail.outgoingMessages.push(msg);
                \(accountLine)
                \(recipientLines)
                msg.send();
                JSON.stringify({success: true, subject: '\(escapedSubject)', recipientCount: \(toAddresses.count)});
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_move",
            description: "Move a message to a different mailbox within the same account",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name"
                    ),
                    "mailbox": .string(
                        description: "Current mailbox name"
                    ),
                    "id": .integer(
                        description: "Message ID to move"
                    ),
                    "targetMailbox": .string(
                        description: "Destination mailbox name"
                    ),
                ],
                required: ["account", "mailbox", "id", "targetMailbox"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move Message",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(account) = arguments["account"], !account.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Account name is required"]
                )
            }
            guard case let .string(mailbox) = arguments["mailbox"], !mailbox.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mailbox name is required"]
                )
            }
            guard let messageId = arguments["id"]?.intValue else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"]
                )
            }
            guard case let .string(targetMailbox) = arguments["targetMailbox"], !targetMailbox.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Target mailbox name is required"]
                )
            }

            let escapedAccount = self.escapeForJXA(account)
            let escapedMailbox = self.escapeForJXA(mailbox)
            let escapedTarget = self.escapeForJXA(targetMailbox)

            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var acct = Mail.accounts.byName('\(escapedAccount)');
                var mb = acct.mailboxes.byName('\(escapedMailbox)');
                var msgs = mb.messages.whose({id: \(messageId)})();
                if (msgs.length === 0) throw new Error('Message not found');
                var targetMb = acct.mailboxes.byName('\(escapedTarget)');
                Mail.move(msgs[0], {to: targetMb});
                JSON.stringify({success: true, messageId: \(messageId), movedTo: '\(escapedTarget)'});
                """
            return try await self.runJXAAsValue(script)
        }

        Tool(
            name: "mail_save_attachments",
            description: "Save all attachments from a message to a local folder",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name"
                    ),
                    "id": .integer(
                        description: "Message ID"
                    ),
                    "savePath": .string(
                        description: "Folder path to save attachments to (e.g. ~/Downloads)"
                    ),
                ],
                required: ["account", "mailbox", "id", "savePath"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Save Attachments",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(account) = arguments["account"], !account.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Account name is required"]
                )
            }
            guard case let .string(mailbox) = arguments["mailbox"], !mailbox.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mailbox name is required"]
                )
            }
            guard let messageId = arguments["id"]?.intValue else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"]
                )
            }
            guard case let .string(savePath) = arguments["savePath"], !savePath.isEmpty else {
                throw NSError(
                    domain: "MailService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Save path is required"]
                )
            }

            let expandedPath = NSString(string: savePath).expandingTildeInPath
            let escapedAccount = self.escapeForJXA(account)
            let escapedMailbox = self.escapeForJXA(mailbox)
            let escapedPath = self.escapeForJXA(expandedPath)

            // Ensure the directory exists
            try FileManager.default.createDirectory(
                atPath: expandedPath,
                withIntermediateDirectories: true
            )

            let script = """
                var Mail = Application('Mail');
                if (!Mail.running()) { Mail.launch(); delay(2); }
                var acct = Mail.accounts.byName('\(escapedAccount)');
                var mb = acct.mailboxes.byName('\(escapedMailbox)');
                var msgs = mb.messages.whose({id: \(messageId)})();
                if (msgs.length === 0) throw new Error('Message not found');
                var m = msgs[0];
                var atts = m.mailAttachments();
                if (atts.length === 0) throw new Error('Message has no attachments');
                var saved = [];
                for (var i = 0; i < atts.length; i++) {
                    var att = atts[i];
                    var fileName = att.name();
                    var saveTo = '\(escapedPath)/' + fileName;
                    att.save({in: Path(saveTo)});
                    saved.push({name: fileName, path: saveTo, mimeType: att.mimeType(), fileSize: att.fileSize()});
                }
                JSON.stringify({success: true, attachmentsSaved: saved.length, attachments: saved});
                """
            return try await self.runJXAAsValue(script)
        }
    }
}
