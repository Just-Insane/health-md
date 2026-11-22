import Foundation

struct APIExportUploadResult {
    let statusCode: Int
    let responseBodyPreview: String?
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
        guard let endpointURL = apiSettings.endpointURL else {
            throw APIExportClientError.invalidEndpoint
        }
        guard body.count <= Self.maximumPayloadBytes else {
            throw APIExportClientError.payloadTooLarge(
                byteCount: body.count, maximumBytes: Self.maximumPayloadBytes
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

        return try await uploadPreparedRequest(request)
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
    func uploadPreparedRequest(_ request: URLRequest) async throws -> APIExportUploadResult {
        var previous: MembershipProgress?
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIExportClientError.invalidResponse
            }
            let preview = Self.responsePreview(from: data)
            if (200..<300).contains(httpResponse.statusCode) {
                return APIExportUploadResult(statusCode: httpResponse.statusCode, responseBodyPreview: preview)
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
            previous = progress
            let requestedDelay = Double(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
            let delay = requestedDelay.isFinite ? min(30, max(0, requestedDelay)) : 5
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }

    private struct MembershipProgress: Decodable {
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

