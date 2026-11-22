import CryptoKit
import Foundation

/// Source-owned custody for prepared API requests. The public export remains
/// untouched. Metadata contains a one-way destination/credential binding, never
/// an endpoint credential, and only this app's protected container holds bytes.
@MainActor
final class APIExportOutbox {
    enum State: String, Codable { case prepared, attempted, acknowledged }

    struct Day: Codable, Equatable {
        let date: String
        var records: Int
        var externalRecords: Int
    }

    struct Entry: Codable {
        let version: Int
        let id: String
        let binding: String
        let sha256: String
        let byteCount: Int
        let exportedAt: String
        let days: [Day]
        let failures: [FailedDateDetail]
        let failureDates: [String]
        let partialDates: [String]
        let createdAt: Date
        var state: State
        var membership: APIExportClient.MembershipProgress?
        var receiverExportID: String?
        var statusCode: Int?
    }

    enum OutboxError: LocalizedError {
        case unavailable, changedDestination, invalidReceipt, recoveryUnavailable, busy
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The protected API export queue is unavailable. Prepared exports remain queued."
            case .changedDestination:
                return "A queued export belongs to different API settings and was not sent."
            case .invalidReceipt, .recoveryUnavailable:
                return "The API endpoint could not confirm the interrupted export. Its exact bytes remain queued; no unconfirmed upload was repeated."
            case .busy:
                return "This prepared API export is already being delivered."
            }
        }
    }

    private let directory: URL
    private let files: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.files = fileManager
        self.directory = try directory ?? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("APIExportOutbox", isDirectory: true)
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: self.directory.appendingPathComponent("receipts", isDirectory: true),
                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: self.directory.path)
        #endif
        var location = self.directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try location.setResourceValues(resources)
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func binding(for request: URLRequest) throws -> String {
        guard let url = request.url else { throw OutboxError.changedDestination }
        // Length-delimited JSON avoids ambiguous concatenation. The credential
        // is used only transiently to bind to the current account; it is never saved.
        return digest(try JSONEncoder().encode([
            url.absoluteString, request.value(forHTTPHeaderField: "Authorization") ?? ""
        ]))
    }

    func prepare(body: Data, request: URLRequest) throws -> Entry {
        guard !body.isEmpty, body.count <= APIExportClient.maximumPayloadBytes,
              let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload["schema"] as? String == "healthmd.api_export",
              let exportedAt = payload["exported_at"] as? String,
              let range = payload["date_range"] as? [String: String],
              let rangeStart = range["start"], let rangeEnd = range["end"],
              let records = payload["records"] as? [[String: Any]],
              let failures = payload["failed_date_details"] as? [[String: Any]] else {
            throw APIExportClientError.invalidPayload
        }
        let binding = try Self.binding(for: request), sha256 = Self.digest(body)
        let id = Self.digest(Data((binding + ":" + sha256).utf8))
        if files.fileExists(atPath: metadataURL(id).path) || files.fileExists(atPath: receiptURL(id).path) {
            let prior = try read(id)
            guard prior.binding == binding, prior.sha256 == sha256,
                  prior.byteCount == body.count else { throw OutboxError.unavailable }
            if prior.state != .acknowledged { _ = try bytes(for: prior) }
            return prior
        }
        var days: [String: Day] = [:]
        func add(_ value: Any?, records: Int, external: Int) throws {
            guard let date = value as? String, date.count >= 10 else {
                throw APIExportClientError.invalidPayload
            }
            let day = String(date.prefix(10))
            guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                throw APIExportClientError.invalidPayload
            }
            var stored = days[day] ?? Day(date: day, records: 0, externalRecords: 0)
            stored.records += records; stored.externalRecords += external
            days[day] = stored
        }
        for record in records { try add(record["date"], records: 1, external: 0) }
        for record in payload["external_records"] as? [[String: Any]] ?? [] {
            try add(record["date"], records: 0, external: 1)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sourceFailures = try decoder.decode([FailedDateDetail].self,
            from: JSONSerialization.data(withJSONObject: failures))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let failureDates = sourceFailures.map {
            rangeStart == rangeEnd ? rangeStart : formatter.string(from: $0.date)
        }
        for date in failureDates {
            guard date >= rangeStart, date <= rangeEnd else { throw APIExportClientError.invalidPayload }
            try add(date, records: 0, external: 0)
        }
        let partialDates = records.compactMap { record -> String? in
            guard record["raw_capture_status"] as? String == "partial" else { return nil }
            return record["date"] as? String
        }
        let entry = Entry(version: 1, id: id, binding: binding, sha256: sha256,
                          byteCount: body.count, exportedAt: exportedAt,
                          days: days.values.sorted { $0.date < $1.date },
                          failures: sourceFailures, failureDates: failureDates,
                          partialDates: partialDates, createdAt: Date(),
                          state: .prepared)
        // Retain bytes before publishing the queue entry. No network operation
        // may start until both files have been atomically written and synced.
        try write(body, to: bodyURL(id))
        try save(entry)
        return entry
    }

    func pending(for request: URLRequest) throws -> [Entry] {
        let binding = try Self.binding(for: request)
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try read($0.deletingPathExtension().lastPathComponent) }
            .filter { $0.binding == binding && $0.state != .acknowledged }
            .sorted {
                let left = $0.days.last?.date ?? "", right = $1.days.last?.date ?? ""
                return left == right ? $0.createdAt < $1.createdAt : left > right
            }
    }

    func read(_ id: String) throws -> Entry {
        guard id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw OutboxError.unavailable
        }
        let location = files.fileExists(atPath: metadataURL(id).path) ? metadataURL(id) : receiptURL(id)
        let data = try Data(contentsOf: location)
        guard data.count <= 128 * 1024 else { throw OutboxError.unavailable }
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        guard entry.version == 1, entry.id == id,
              entry.id == Self.digest(Data((entry.binding + ":" + entry.sha256).utf8)),
              entry.byteCount > 0, entry.byteCount <= APIExportClient.maximumPayloadBytes,
              entry.days.count <= 32, entry.failures.count == entry.failureDates.count,
              entry.state != .acknowledged || (200..<300).contains(entry.statusCode ?? 0) else { throw OutboxError.unavailable }
        return entry
    }

    func bytes(for entry: Entry) throws -> Data {
        let data = try Data(contentsOf: bodyURL(entry.id))
        guard data.count == entry.byteCount, Self.digest(data) == entry.sha256 else {
            throw OutboxError.unavailable
        }
        return data
    }

    func save(_ entry: Entry) throws {
        let encoded = try JSONEncoder().encode(entry)
        guard encoded.count <= 128 * 1024 else { throw OutboxError.unavailable }
        try write(encoded, to: metadataURL(entry.id))
    }

    func acknowledge(_ entry: Entry, statusCode: Int) throws -> Entry {
        var acknowledged = entry
        acknowledged.state = .acknowledged
        acknowledged.statusCode = statusCode
        // Persist the small acknowledged counts/identity before retiring bytes.
        // If termination intervenes, this receipt is authoritative on reopening.
        try save(acknowledged)
        try? files.removeItem(at: bodyURL(entry.id))
        // Retained receipts do not participate in future pending scans. A
        // failed move leaves the acknowledged metadata safe in the queue.
        try? files.moveItem(at: metadataURL(entry.id), to: receiptURL(entry.id))
        return acknowledged
    }

    private func metadataURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    private func bodyURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".body") }
    private func receiptURL(_ id: String) -> URL {
        directory.appendingPathComponent("receipts", isDirectory: true).appendingPathComponent(id + ".json")
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
