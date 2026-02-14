import AppKit
import Foundation
import ImageIO
import OSLog
import SQLite3

private let log = Logger.service("messageDatabase")
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class MessageDatabase {
    private let databasePath: String

    struct FetchedMessage {
        let rowID: Int64
        let guid: String
        let text: String
        let date: Date
        let isFromMe: Bool
        let isRead: Bool
        let sender: String?
        let subject: String?
        let hasAttachments: Bool
    }

    struct Attachment {
        let filename: String?
        let mimeType: String?
        let totalBytes: Int64
    }

    enum Error: LocalizedError {
        case failedToOpen(String)
        case queryFailed(String)
        case databaseBusy

        var errorDescription: String? {
            switch self {
            case .failedToOpen(let msg): return "Failed to open database: \(msg)"
            case .queryFailed(let msg): return "Query failed: \(msg)"
            case .databaseBusy: return "Database is busy"
            }
        }
    }

    init(path: String) {
        self.databasePath = path
    }

    // MARK: - Database Access

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let uri = "file:\(databasePath)?immutable=1&mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if db != nil { sqlite3_close(db) }
            throw Error.failedToOpen(msg)
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 5000)

        return try operation(db)
    }

    // MARK: - Unread Messages

    func fetchUnreadMessages(limit: Int = 10) throws -> [FetchedMessage] {
        try withDatabase { db in
            let sql = """
                SELECT m.ROWID, m.guid, m.text, HEX(m.attributedBody), m.date,
                       m.is_from_me, m.is_read, m.subject, m.cache_has_attachments, h.id
                FROM message m
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE m.is_from_me = 0 AND m.is_read = 0
                  AND m.item_type = 0 AND m.is_audio_message = 0
                ORDER BY m.date DESC
                LIMIT ?
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw Error.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var results: [FetchedMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let msg = readMessageRow(stmt) {
                    results.append(msg)
                }
            }
            return results
        }
    }

    // MARK: - Messages with Filtering

    func fetchMessages(
        participants: [String] = [],
        dateRange: Range<Date>? = nil,
        searchTerm: String? = nil,
        limit: Int = 30
    ) throws -> [FetchedMessage] {
        try withDatabase { db in
            var conditions: [String] = [
                "m.item_type = 0",
                "m.is_audio_message = 0",
            ]
            var bindings: [(Int32, Any)] = []
            var paramIndex: Int32 = 1

            if !participants.isEmpty {
                let handles = try resolveHandles(db: db, aliases: participants)
                if !handles.isEmpty {
                    let placeholders = handles.map { _ in "?" }.joined(separator: ",")
                    conditions.append("""
                        m.ROWID IN (
                            SELECT m2.ROWID FROM message m2
                            JOIN handle h2 ON m2.handle_id = h2.ROWID
                            WHERE h2.id IN (\(placeholders))
                        )
                        """)
                    for handle in handles {
                        bindings.append((paramIndex, handle))
                        paramIndex += 1
                    }
                }
            }

            if let dateRange {
                let nsecPerSec: Int64 = 1_000_000_000
                let lowerNS = Int64(dateRange.lowerBound.timeIntervalSinceReferenceDate * Double(nsecPerSec))
                let upperNS = Int64(dateRange.upperBound.timeIntervalSinceReferenceDate * Double(nsecPerSec))
                conditions.append("m.date >= ?")
                bindings.append((paramIndex, lowerNS))
                paramIndex += 1
                conditions.append("m.date < ?")
                bindings.append((paramIndex, upperNS))
                paramIndex += 1
            }

            let whereClause = conditions.joined(separator: " AND ")

            let sql = """
                SELECT m.ROWID, m.guid, m.text, HEX(m.attributedBody), m.date,
                       m.is_from_me, m.is_read, m.subject, m.cache_has_attachments, h.id
                FROM message m
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE \(whereClause)
                ORDER BY m.date DESC
                LIMIT ?
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw Error.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            for (idx, value) in bindings {
                if let s = value as? String {
                    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                } else if let i = value as? Int64 {
                    sqlite3_bind_int64(stmt, idx, i)
                }
            }
            sqlite3_bind_int(stmt, paramIndex, Int32(limit * 10))

            var results: [FetchedMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard results.count < limit else { break }

                if let msg = readMessageRow(stmt) {
                    if msg.text.isEmpty { continue }

                    if let searchTerm, !msg.text.localizedCaseInsensitiveContains(searchTerm) {
                        continue
                    }

                    results.append(msg)
                }
            }
            return results
        }
    }

    // MARK: - Attachments

    func fetchAttachments(forMessageRowID rowID: Int64) throws -> [Attachment] {
        try withDatabase { db in
            let sql = """
                SELECT a.filename, a.mime_type, a.total_bytes
                FROM attachment a
                INNER JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                WHERE maj.message_id = ?
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw Error.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, rowID)

            var results: [Attachment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let filename = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                let mimeType = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let totalBytes = sqlite3_column_int64(stmt, 2)

                results.append(Attachment(
                    filename: filename,
                    mimeType: mimeType,
                    totalBytes: totalBytes
                ))
            }
            return results
        }
    }

    /// Read an image attachment from disk, resizing if needed.
    /// Returns (data, mimeType) or nil if the file can't be read or isn't an image.
    func readImageAttachment(_ attachment: Attachment, maxDimension: CGFloat = 1024, maxBytes: Int = 5_242_880) -> (Data, String)? {
        guard let filename = attachment.filename else { return nil }
        guard let mimeType = attachment.mimeType, mimeType.hasPrefix("image/") else { return nil }
        guard attachment.totalBytes <= maxBytes else {
            log.debug("Skipping attachment \(filename): \(attachment.totalBytes) bytes exceeds limit")
            return nil
        }

        let expandedPath = (filename as NSString).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            log.debug("Attachment file not readable: \(expandedPath)")
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: expandedPath) as CFURL, nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        return (pngData, "image/png")
    }

    // MARK: - Handle Resolution

    private func resolveHandles(db: OpaquePointer, aliases: [String]) throws -> [String] {
        guard !aliases.isEmpty else { return [] }

        let normalized = aliases.map { alias in
            if alias.contains("@") {
                return alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return alias.filter { $0.isNumber || $0 == "+" }
            }
        }

        let placeholders = normalized.map { _ in "?" }.joined(separator: ",")
        let suffixConditions = normalized.map { _ in "h.id LIKE '%' || ?" }.joined(separator: " OR ")

        let sql = """
            SELECT DISTINCT h.id
            FROM handle h
            WHERE h.id IN (\(placeholders))
               OR h.uncanonicalized_id IN (\(placeholders))
               OR (\(suffixConditions))
            LIMIT 100
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Error.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for n in normalized { sqlite3_bind_text(stmt, idx, n, -1, SQLITE_TRANSIENT); idx += 1 }
        for a in aliases { sqlite3_bind_text(stmt, idx, a, -1, SQLITE_TRANSIENT); idx += 1 }
        for n in normalized { sqlite3_bind_text(stmt, idx, n, -1, SQLITE_TRANSIENT); idx += 1 }

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: text))
            }
        }
        return results
    }

    // MARK: - Row Reading

    private func readMessageRow(_ stmt: OpaquePointer?) -> FetchedMessage? {
        guard let stmt else { return nil }

        let rowID = sqlite3_column_int64(stmt, 0)
        let guid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "N/A"

        let text: String
        if let rawText = sqlite3_column_text(stmt, 2) {
            text = String(cString: rawText)
        } else if let hexData = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let data = Data(hexString: hexData),
                  let plainText = try? TypedStreamDecoder.decode(data)
                      .compactMap({ $0.stringValue })
                      .joined(separator: "\n")
        {
            text = plainText
        } else {
            text = ""
        }

        let nsecPerSec: Double = 1_000_000_000
        let dateNS = sqlite3_column_int64(stmt, 4)
        let date = Date(timeIntervalSinceReferenceDate: Double(dateNS) / nsecPerSec)

        let isFromMe = sqlite3_column_int(stmt, 5) != 0
        let isRead = sqlite3_column_int(stmt, 6) != 0
        let subject = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let hasAttachments = sqlite3_column_int(stmt, 8) != 0
        let sender = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

        return FetchedMessage(
            rowID: rowID,
            guid: guid,
            text: text,
            date: date,
            isFromMe: isFromMe,
            isRead: isRead,
            sender: sender,
            subject: subject,
            hasAttachments: hasAttachments
        )
    }
}

// MARK: - Data hex init (duplicated from madrid for standalone use)

private extension Data {
    init?(hexString: String) {
        let string = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var data = Data(capacity: string.count / 2)

        var index = string.startIndex
        while index < string.endIndex {
            let nextIndex = string.index(index, offsetBy: 2)
            guard nextIndex <= string.endIndex,
                  let byte = UInt8(string[index..<nextIndex], radix: 16)
            else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
