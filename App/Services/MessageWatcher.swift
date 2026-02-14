import Foundation
import OSLog
import SQLite3

private let log = Logger.service("messageWatcher")

final class MessageWatcher {
    private let scriptPath: String
    private let databasePath: String
    private var bookmarkKey: String { "me.mattt.iMCP.messagesDatabaseBookmark" }

    private var dbSource: DispatchSourceFileSystemObject?
    private var walSource: DispatchSourceFileSystemObject?
    private var dbFD: Int32 = -1
    private var walFD: Int32 = -1

    private var debounceTimer: DispatchSourceTimer?
    private var pollingTimer: DispatchSourceTimer?

    private var highWaterMark: Int64 = 0
    private var isRunning = false

    private let queue = DispatchQueue(label: "me.mattt.iMCP.messageWatcher")
    private let scriptTimeout: Duration = .seconds(30)
    private let debounceInterval: TimeInterval = 5.0
    private let pollingInterval: TimeInterval = 60.0

    init(scriptPath: String) {
        self.scriptPath = scriptPath
        self.databasePath = Self.resolveDatabasePath()
    }

    func start() {
        queue.async { [weak self] in
            self?._start()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?._stop()
        }
    }

    // MARK: - Private

    private func _start() {
        guard !isRunning else { return }
        isRunning = true

        log.info("Starting message watcher with script: \(self.scriptPath, privacy: .public)")

        // Set initial high-water mark to current max ROWID.
        highWaterMark = queryMaxRowID() ?? 0
        log.info("Initial high-water mark: \(self.highWaterMark)")

        startFileWatching()
        startPollingTimer()
    }

    private func _stop() {
        guard isRunning else { return }
        isRunning = false

        log.info("Stopping message watcher")

        debounceTimer?.cancel()
        debounceTimer = nil

        pollingTimer?.cancel()
        pollingTimer = nil

        dbSource?.cancel()
        dbSource = nil
        walSource?.cancel()
        walSource = nil

        if dbFD >= 0 { close(dbFD); dbFD = -1 }
        if walFD >= 0 { close(walFD); walFD = -1 }
    }

    private func startFileWatching() {
        let dbPath = databasePath
        let walPath = dbPath + "-wal"

        dbFD = Darwin.open(dbPath, O_EVTONLY)
        if dbFD < 0 {
            log.error("Failed to open file descriptor for chat.db")
        } else {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dbFD, eventMask: .write, queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebounce()
            }
            source.setCancelHandler { [weak self] in
                if let fd = self?.dbFD, fd >= 0 {
                    Darwin.close(fd)
                    self?.dbFD = -1
                }
            }
            source.resume()
            dbSource = source
        }

        walFD = Darwin.open(walPath, O_EVTONLY)
        if walFD < 0 {
            log.warning("Failed to open file descriptor for chat.db-wal (may not exist yet)")
        } else {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: walFD, eventMask: .write, queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebounce()
            }
            source.setCancelHandler { [weak self] in
                if let fd = self?.walFD, fd >= 0 {
                    Darwin.close(fd)
                    self?.walFD = -1
                }
            }
            source.resume()
            walSource = source
        }
    }

    private func startPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + pollingInterval,
            repeating: pollingInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkForNewMessages()
        }
        timer.resume()
        pollingTimer = timer
    }

    private func scheduleDebounce() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            self?.checkForNewMessages()
        }
        timer.resume()
        debounceTimer = timer
    }

    private func checkForNewMessages() {
        guard isRunning else { return }

        guard let currentMax = queryMaxRowID() else {
            log.warning("Failed to query max ROWID")
            return
        }

        guard currentMax > highWaterMark else { return }

        let newCount = currentMax - highWaterMark
        log.info("Detected \(newCount) new inbound message(s) (ROWID \(self.highWaterMark + 1)...\(currentMax))")
        highWaterMark = currentMax

        executeScript(newMessageCount: newCount)
    }

    // MARK: - SQLite

    private func queryMaxRowID() -> Int64? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(databasePath, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            log.error("Failed to open chat.db: \(String(cString: sqlite3_errmsg(db)))")
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT MAX(ROWID) FROM message WHERE is_from_me = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let value = sqlite3_column_int64(stmt, 0)
        return value
    }

    // MARK: - Script Execution

    private func executeScript(newMessageCount: Int64) {
        log.info("Executing watcher script: \(self.scriptPath, privacy: .public)")

        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["IMCP_NEW_MESSAGE_COUNT": String(newMessageCount)]
            ) { _, new in new }

            let errorPipe = Pipe()
            process.standardError = errorPipe
            let errorHandle = errorPipe.fileHandleForReading
            defer { errorHandle.closeFile() }

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
                            domain: "MessageWatcherError",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Watcher script timed out after \(Int(self.scriptTimeout.components.seconds)) seconds"
                            ]
                        )
                    }

                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                if process.isRunning { process.terminate() }
                let stderrData = (try? errorHandle.readToEnd()) ?? Data()
                if !stderrData.isEmpty {
                    let stderrMessage = String(data: stderrData, encoding: .utf8) ?? ""
                    log.error("Watcher script stderr: \(stderrMessage, privacy: .public)")
                }
                log.error("Watcher script failed: \(error.localizedDescription)")
                return
            }

            guard process.terminationStatus == 0 else {
                let stderrData = (try? errorHandle.readToEnd()) ?? Data()
                let errorMessage = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                log.error("Watcher script exited with status \(process.terminationStatus): \(errorMessage, privacy: .public)")
                return
            }

            log.info("Watcher script completed successfully")
        }
    }

    // MARK: - Database Path Resolution

    private static func resolveDatabasePath() -> String {
        let defaultPath = "/Users/\(NSUserName())/Library/Messages/chat.db"
        if FileManager.default.isReadableFile(atPath: defaultPath) {
            return defaultPath
        }

        // Fall back to security-scoped bookmark.
        let bookmarkKey = "me.mattt.iMCP.messagesDatabaseBookmark"
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                return url.path
            }
        }

        log.warning("Could not resolve chat.db path, using default")
        return defaultPath
    }
}
