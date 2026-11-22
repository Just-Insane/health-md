import Foundation

struct APIExportUploadResult {
    let statusCode: Int
    let responseBodyPreview: String?
    var acceptedSHA256: String? = nil
    var receiverExportID: String? = nil
}

enum APIExportClientError: LocalizedError {
    case invalidEndpoint
    case invalidPayload
    case invalidResponse
    case payloadTooLarge(byteCount: Int, maximumBytes: Int)
    case serverRejected(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Configure a valid HTTP or HTTPS API endpoint before exporting."
        case .invalidPayload:
            return "Health.md could not prepare the API export payload."
        case .invalidResponse:
            return "The API endpoint returned an invalid response."
        case .payloadTooLarge(let byteCount, let maximumBytes):
            return "A complete daily export is \(byteCount) bytes, exceeding the API limit of \(maximumBytes) bytes. That date was not sent; no records were removed or truncated."
        case .serverRejected(let statusCode, let body):
            if let body, !body.isEmpty {
                return "API endpoint returned HTTP \(statusCode): \(body)"
            }
            return "API endpoint returned HTTP \(statusCode)."
        }
    }
}

struct APIExportClient {
    static let maximumPayloadBytes = 16 * 1024 * 1024
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @MainActor
    func upload(
        records: [HealthData],
        failedDateDetails: [FailedDateDetail],
        externalRecords: [ExternalDailyRecord] = [],
        settings: AdvancedExportSettings,
        apiSettings: APIExportSettings,
        dateRangeStart: Date,
        dateRangeEnd: Date
    ) async throws -> APIExportUploadResult {
        let body = try Self.makePayload(
            records: records,
            failedDateDetails: failedDateDetails,
            externalRecords: externalRecords,
            settings: settings,
            dateRangeStart: dateRangeStart,
            dateRangeEnd: dateRangeEnd
        )

        return try await uploadPayload(body, apiSettings: apiSettings)
    }

    /// Upload already-prepared bytes so membership continuation keeps the
    /// original export timestamp, day membership and body unchanged.
    @MainActor
    func uploadPayload(_ body: Data, apiSettings: APIExportSettings) async throws -> APIExportUploadResult {
        try await uploadPreparedRequest(Self.request(body: body, apiSettings: apiSettings))
    }

    @MainActor
    static func request(body: Data?, apiSettings: APIExportSettings) throws -> URLRequest {
        guard let endpointURL = apiSettings.endpointURL else {
            throw APIExportClientError.invalidEndpoint
        }
        guard (body?.count ?? 0) <= Self.maximumPayloadBytes else {
            throw APIExportClientError.payloadTooLarge(
                byteCount: body?.count ?? 0, maximumBytes: Self.maximumPayloadBytes
            )
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Health.md iOS API Export", forHTTPHeaderField: "User-Agent")
        if let authorization = apiSettings.authorizationHeaderValue {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        return request
    }

    @MainActor private static var delivering: Set<String> = []

    @MainActor
    func uploadDurablePayload(_ body: Data, apiSettings: APIExportSettings,
                              outbox: APIExportOutbox) async throws -> APIExportUploadResult {
        let request = try Self.request(body: body, apiSettings: apiSettings)
        let entry = try outbox.prepare(body: body, request: request)
        return try await deliver(entry, request: request, outbox: outbox)
    }

    @MainActor
    func resume(_ entry: APIExportOutbox.Entry, apiSettings: APIExportSettings,
                outbox: APIExportOutbox) async throws -> APIExportUploadResult {
        let request = try Self.request(body: nil, apiSettings: apiSettings)
        return try await deliver(entry, request: request, outbox: outbox)
    }

    /// Reuse the normal app-active/export path. This does not create a timer or
    /// query HealthKit; older prepared requests receive a bounded share.
    @MainActor
    func resumePendingPayloads(apiSettings: APIExportSettings, outbox: APIExportOutbox,
                               limit: Int = 4) async throws -> Int {
        let request = try Self.request(body: nil, apiSettings: apiSettings)
        let entries = try outbox.pending(for: request)
        var acknowledged = 0
        for entry in entries.prefix(max(0, min(limit, 32))) {
            try Task.checkCancellation()
            do {
                _ = try await resume(entry, apiSettings: apiSettings, outbox: outbox)
                acknowledged += 1
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                // A held or unsupported destination must not prevent another
                // already-prepared request from obtaining its own receipt.
            }
        }
        return acknowledged
    }

    @MainActor
    private func deliver(_ selected: APIExportOutbox.Entry, request configured: URLRequest,
                         outbox: APIExportOutbox) async throws -> APIExportUploadResult {
        guard Self.delivering.insert(selected.id).inserted else { throw APIExportOutbox.OutboxError.busy }
        defer { Self.delivering.remove(selected.id) }
        var entry = try outbox.read(selected.id)
        guard entry.binding == (try APIExportOutbox.binding(for: configured)) else {
            throw APIExportOutbox.OutboxError.changedDestination
        }
        if entry.state == .acknowledged {
            return APIExportUploadResult(statusCode: entry.statusCode ?? 200, responseBodyPreview: nil)
        }
        var request = configured
        request.httpBody = try outbox.bytes(for: entry)
        try Task.checkCancellation()
        if entry.state == .prepared {
            // A supporting receiver supplies its account-bound export identity
            // before the first write. Generic endpoints may reject GET; their
            // initial POST still works, but an unknown result remains queued.
            if let receipt = try await reconcile(request, entry: entry, allowUnsupported: true) {
                entry.receiverExportID = receipt.exportID
                try outbox.save(entry)
                if receipt.accepted {
                    _ = try outbox.acknowledge(entry, statusCode: 200)
                    return APIExportUploadResult(statusCode: 200, responseBodyPreview: nil)
                }
            }
        }
        if entry.state == .attempted {
            // A timeout, cancellation, process death or lost acknowledgment is
            // unknown. Require an authenticated, exact-digest receipt before
            // either acknowledging or sending the unchanged original again.
            guard let receipt = try await reconcile(request, entry: entry, allowUnsupported: false) else {
                throw APIExportOutbox.OutboxError.recoveryUnavailable
            }
            if receipt.accepted {
                _ = try outbox.acknowledge(entry, statusCode: 200)
                return APIExportUploadResult(statusCode: 200, responseBodyPreview: nil)
            }
        }
        request.setValue(entry.receiverExportID ?? entry.membership?.exportID,
                         forHTTPHeaderField: "X-HealthMD-Export-ID")
        entry.state = .attempted
        try outbox.save(entry)
        let result = try await uploadPreparedRequest(request, previous: entry.membership) { progress in
            if let expected = entry.receiverExportID, progress.exportID != expected {
                throw APIExportOutbox.OutboxError.invalidReceipt
            }
            entry.membership = progress
            try outbox.save(entry)
        }
        if let expected = entry.receiverExportID {
            guard result.acceptedSHA256 == entry.sha256, result.receiverExportID == expected else {
                throw APIExportOutbox.OutboxError.invalidReceipt
            }
        }
        _ = try outbox.acknowledge(entry, statusCode: result.statusCode)
        return result
    }

    @MainActor
    private func reconcile(_ original: URLRequest, entry: APIExportOutbox.Entry,
                           allowUnsupported: Bool) async throws -> (accepted: Bool, exportID: String)? {
        var request = original
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        request.setValue(entry.sha256, forHTTPHeaderField: "X-HealthMD-Export-SHA256")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if allowUnsupported, let response = response as? HTTPURLResponse,
           [404, 405, 501].contains(response.statusCode) { return nil }
        if allowUnsupported, let response = response as? HTTPURLResponse, response.statusCode == 200 {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if !["accepted", "capture_pending"].contains(value?["status"] as? String ?? "") { return nil }
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 8192,
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["sha256"] as? String == entry.sha256,
              let capture = receipt["capture"] as? [String: Any],
              let exportID = capture["export_id"] as? String,
              !exportID.isEmpty, exportID.count <= 512 else {
            throw APIExportOutbox.OutboxError.recoveryUnavailable
        }
        if let expectedID = entry.receiverExportID ?? entry.membership?.exportID {
            guard exportID == expectedID else {
                throw APIExportOutbox.OutboxError.invalidReceipt
            }
        }
        if receipt["status"] as? String == "accepted" { return (true, exportID) }
        guard receipt["status"] as? String == "capture_pending",
              receipt["retry_same_original"] as? Bool == true,
              entry.state == .prepared || entry.receiverExportID != nil || entry.membership != nil else {
            throw APIExportOutbox.OutboxError.invalidReceipt
        }
        return (false, exportID)
    }

    /// Join whole prepared daily envelopes without re-exporting HealthKit
    /// records. The public v1/v2 envelope and daily schemas remain unchanged.
    /// A single input is returned byte-for-byte.
    static func combinePayloads(_ payloads: [Data]) throws -> Data {
        guard let first = payloads.first else { throw APIExportClientError.invalidPayload }
        guard payloads.count > 1 else { return first }
        guard var envelope = try JSONSerialization.jsonObject(with: first) as? [String: Any],
              var records = envelope["records"] as? [Any],
              var failures = envelope["failed_date_details"] as? [Any],
              let firstRange = envelope["date_range"] as? [String: String],
              var rangeStart = firstRange["start"],
              var rangeEnd = firstRange["end"] else {
            throw APIExportClientError.invalidPayload
        }
        var external = envelope["external_records"] as? [Any] ?? []
        let metadataKeys = [
            "schema", "schema_version", "daily_record_schema", "daily_record_schema_version",
            "exported_at", "source", "external_record_schema", "external_record_schema_version"
        ]
        for payload in payloads.dropFirst() {
            guard let next = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let nextRecords = next["records"] as? [Any],
                  let nextFailures = next["failed_date_details"] as? [Any],
                  let nextRange = next["date_range"] as? [String: String],
                  let nextStart = nextRange["start"], let nextEnd = nextRange["end"],
                  metadataKeys.allSatisfy({ key in
                      let left = envelope[key] as? NSObject
                      let right = next[key] as? NSObject
                      return left == right
                  }) else {
                throw APIExportClientError.invalidPayload
            }
            records.append(contentsOf: nextRecords)
            failures.append(contentsOf: nextFailures)
            external.append(contentsOf: next["external_records"] as? [Any] ?? [])
            rangeStart = min(rangeStart, nextStart)
            rangeEnd = max(rangeEnd, nextEnd)
        }
        envelope["records"] = records
        envelope["record_count"] = records.count
        envelope["failed_date_details"] = failures
        envelope["date_range"] = ["start": rangeStart, "end": rangeEnd]
        if envelope["external_records"] != nil {
            envelope["external_records"] = external
            envelope["external_record_count"] = external.count
        }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    /// A receiver may durably inventory a large export over several requests.
    /// Continue only that explicit progress protocol, reusing this exact body,
    /// timestamp, destination and authorization; a rebuilt export is a new job.
    @MainActor
    func uploadPreparedRequest(_ request: URLRequest, previous initial: MembershipProgress? = nil,
                               onProgress: ((MembershipProgress) throws -> Void)? = nil) async throws -> APIExportUploadResult {
        var previous = initial
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIExportClientError.invalidResponse
            }
            let preview = Self.responsePreview(from: data)
            if (200..<300).contains(httpResponse.statusCode) {
                let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return APIExportUploadResult(statusCode: httpResponse.statusCode, responseBodyPreview: preview,
                    acceptedSHA256: receipt?["sha256"] as? String,
                    receiverExportID: (receipt?["capture"] as? [String: Any])?["export_id"] as? String)
            }
            guard httpResponse.statusCode == 503,
                  let progress = try? JSONDecoder().decode(MembershipProgress.self, from: data),
                  progress.status == "capture_membership_pending", progress.retrySameOriginal,
                  !progress.exportID.isEmpty, progress.exportID.count <= 512,
                  progress.nextCursor > (previous?.nextCursor ?? 0),
                  progress.nextCursor < progress.total,
                  progress.total <= (request.httpBody?.count ?? 0),
                  previous == nil || (previous?.exportID == progress.exportID && previous?.total == progress.total)
            else {
                throw APIExportClientError.serverRejected(statusCode: httpResponse.statusCode, body: preview)
            }
            try onProgress?(progress)
            previous = progress
            let requestedDelay = Double(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
            let delay = requestedDelay.isFinite ? min(30, max(0, requestedDelay)) : 5
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }

    struct MembershipProgress: Codable, Equatable {
        let status: String
        let exportID: String
        let nextCursor: Int
        let total: Int
        let retrySameOriginal: Bool
        enum CodingKeys: String, CodingKey {
            case status, total
            case exportID = "export_id"
            case nextCursor = "next_cursor"
            case retrySameOriginal = "retry_same_original"
        }
    }

    @MainActor
    static func makePayload(
        records: [HealthData],
        failedDateDetails: [FailedDateDetail],
        externalRecords: [ExternalDailyRecord] = [],
        settings: AdvancedExportSettings,
        dateRangeStart: Date,
        dateRangeEnd: Date,
        exportedAt: Date = Date(),
        connectedAppsEnabled: Bool? = nil
    ) throws -> Data {
        let connectedAppsEnabled = connectedAppsEnabled ?? ConnectedAppsFeature.isEnabled
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let recordObjects: [Any] = try records.map { record in
            let json = try record.exportThrowing(format: .json, settings: settings)
            guard let data = json.data(using: .utf8) else {
                throw APIExportClientError.invalidPayload
            }
            return try JSONSerialization.jsonObject(with: data)
        }

        let failedDateObjects = try jsonObject(from: failedDateDetails)

        var envelope: [String: Any] = [
            "schema": "healthmd.api_export",
            "schema_version": 1,
            "daily_record_schema": HealthMdExportSchema.identifier,
            "daily_record_schema_version": HealthMdExportSchema.version,
            "exported_at": isoFormatter.string(from: exportedAt),
            "source": "ios",
            "date_range": [
                "start": dateFormatter.string(from: dateRangeStart),
                "end": dateFormatter.string(from: dateRangeEnd)
            ],
            "record_count": recordObjects.count,
            "records": recordObjects,
            "failed_date_details": failedDateObjects
        ]

        if connectedAppsEnabled {
            let exportableExternalRecords = externalRecords.filter(\.shouldExport)
            envelope["schema_version"] = 2
            envelope["external_record_schema"] = ExternalDailyRecord.schema
            envelope["external_record_schema_version"] = ExternalDailyRecord.schemaVersion
            envelope["external_record_count"] = exportableExternalRecords.count
            envelope["external_records"] = try jsonObject(from: exportableExternalRecords)
        }

        guard JSONSerialization.isValidJSONObject(envelope) else {
            throw APIExportClientError.invalidPayload
        }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    private static func responsePreview(from data: Data) -> String? {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 500 { return trimmed }
        return String(trimmed.prefix(500)) + "…"
    }

    private static func jsonObject<T: Encodable>(from value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
