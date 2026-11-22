import XCTest
@testable import HealthMd

@MainActor
final class APIExportClientTests: XCTestCase {
    // STATIC RETENTION JUSTIFICATION: AdvancedExportSettings contains nested
    // observation state that can crash during test-process teardown on macOS 26.
    private static var retainedSettings: [AdvancedExportSettings] = []

    func testMembershipContinuationResendsExactPreparedBytes() async throws {
        let body = Data(repeating: 32, count: 18_000)
        var requests: [URLRequest] = []
        let session = membershipSession { request in
            requests.append(request)
            return requests.count == 1
                ? (503, "{\"status\":\"capture_membership_pending\",\"export_id\":\"fixture-export\",\"next_cursor\":8192,\"total\":9000,\"retry_same_original\":true}")
                : (200, "{\"status\":\"accepted\"}")
        }
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://fixture.invalid/healthmd")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer fabricated-token", forHTTPHeaderField: "Authorization")
        let result = try await APIExportClient(session: session).uploadPreparedRequest(request)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(requests.count, 2)
        for sent in requests {
            XCTAssertEqual(sent.httpBody, body)
            XCTAssertEqual(sent.url, request.url)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fabricated-token")
        }
    }

    func testStalledMembershipProgressStopsWithoutRebuildingTheExport() async throws {
        var calls = 0
        let session = membershipSession { _ in
            calls += 1
            return (503, "{\"status\":\"capture_membership_pending\",\"export_id\":\"fixture-export\",\"next_cursor\":8192,\"total\":9000,\"retry_same_original\":true}")
        }
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://fixture.invalid/healthmd")!)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 32, count: 18_000)
        do {
            _ = try await APIExportClient(session: session).uploadPreparedRequest(request)
            XCTFail("A repeated cursor must remain a failed export")
        } catch APIExportClientError.serverRejected(let status, _) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(calls, 2)
    }

    private func membershipSession(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        HealthAPIMembershipURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthAPIMembershipURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testWHOOPSidecarsUseAPIEnvelopeV2AndAreRedacted() throws {
        let date = Self.day(2026, 7, 13)
        var healthData = HealthData(date: date)
        healthData.activity.steps = 1234
        let settings = makeSettings()
        Self.retainedSettings.append(settings)
        let external = ExternalDailyRecord(
            provider: .whoop,
            date: "2026-07-13",
            payloads: [ExternalProviderPayload(
                name: "cycles",
                endpoint: "https://api.prod.whoop.com/developer/v2/cycle?nextToken=opaque&access_token=secret",
                statusCode: 200,
                data: .object([
                    "access_token": .string("secret"),
                    "records": .array([.object(["id": .number(1)])])
                ])
            )]
        )

        let data = try APIExportClient.makePayload(
            records: [healthData],
            failedDateDetails: [],
            externalRecords: [external],
            settings: settings,
            dateRangeStart: date,
            dateRangeEnd: date,
            connectedAppsEnabled: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["schema" ] as? String, "healthmd.api_export")
        XCTAssertEqual(json["schema_version"] as? Int, 2)
        XCTAssertEqual(json["external_record_schema"] as? String, ExternalDailyRecord.schema)
        XCTAssertEqual(json["external_record_schema_version"] as? Int, 1)
        XCTAssertEqual(json["external_record_count"] as? Int, 1)
        XCTAssertEqual((json["external_records"] as? [Any])?.count, 1)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("opaque"))
    }

    func testAPIPayloadCarriesCurrentV6DailyDocumentWithCompleteCanonicalArchive() throws {
        let date = Self.day(2026, 7, 13)
        let archive = HealthKitRecordArchive(
            captureStatus: .complete,
            dailyOwnership: HealthKitDailyOwnershipMetadata(
                ownerDate: "2026-07-13",
                intervalStart: Calendar.current.startOfDay(for: date),
                intervalEnd: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))!,
                calendarTimeZoneIdentifier: TimeZone.current.identifier
            )
        )
        let healthData = HealthData(
            date: date,
            healthKitRecordArchive: archive,
            healthKitRecordCaptureStatus: .complete
        )
        let settings = makeSettings()
        settings.includeGranularData = true
        Self.retainedSettings.append(settings)

        let data = try APIExportClient.makePayload(
            records: [healthData],
            failedDateDetails: [],
            settings: settings,
            dateRangeStart: date,
            dateRangeEnd: date,
            connectedAppsEnabled: false
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["daily_record_schema"] as? String, HealthMdExportSchema.identifier)
        XCTAssertEqual(envelope["daily_record_schema_version"] as? Int, HealthMdExportSchema.version)
        let records = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        let daily = try XCTUnwrap(records.first)
        XCTAssertEqual(daily["schema"] as? String, HealthMdExportSchema.identifier)
        XCTAssertEqual(daily["schema_version"] as? Int, HealthMdExportSchema.version)
        let encodedArchive = try XCTUnwrap(daily["healthkit_record_archive"] as? [String: Any])
        XCTAssertEqual(encodedArchive["schema"] as? String, HealthKitRecordArchive.canonicalSchemaIdentifier)
        XCTAssertEqual(
            encodedArchive["schema_version"] as? Int,
            HealthKitRecordArchive.currentRecordSchemaVersion
        )
        XCTAssertEqual(encodedArchive["capture_status"] as? String, "complete")
    }

    func testDisabledConnectedAppsKeepsActiveEnvelopeV1() throws {
        let date = Self.day(2026, 7, 13)
        var healthData = HealthData(date: date)
        healthData.activity.steps = 1234

        let settings = makeSettings()
        Self.retainedSettings.append(settings)
        let data = try APIExportClient.makePayload(
            records: [healthData],
            failedDateDetails: [],
            settings: settings,
            dateRangeStart: date,
            dateRangeEnd: date,
            connectedAppsEnabled: false
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNil(json["external_records"])
        XCTAssertNil(json["external_record_schema"])
    }

    private func makeSettings() -> AdvancedExportSettings {
        let suiteName = "APIExportClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AdvancedExportSettings(userDefaults: defaults)
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

private final class HealthAPIMembershipURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Retry-After": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
