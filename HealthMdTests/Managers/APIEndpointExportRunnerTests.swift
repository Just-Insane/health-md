import XCTest
@testable import HealthMd

@MainActor
final class APIEndpointExportRunnerTests: XCTestCase {
    // STATIC RETENTION JUSTIFICATION: AdvancedExportSettings contains nested
    // observation state that can crash during test-process teardown on macOS 26.
    private static var retainedSettings: [AdvancedExportSettings] = []
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "APIEndpointExportRunnerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testUploadsOnlyDatesWithDataAndReportsEmptyDates() async throws {
        let first = date(10), second = date(11)
        let (settings, apiSettings) = makeSettings()
        var payloads: [[String: Any]] = []
        let result = await APIEndpointExportRunner.export(
            dates: [first, second], settings: settings, apiSettings: apiSettings,
            fetchHealthData: { day, _, _ in
                day == first ? self.record(day) : HealthData(date: day)
            },
            upload: { body, _ in
                payloads.append(try self.decode(body))
                return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
            }
        )

        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.failedDateDetails.map(\.reason), [.noHealthData])
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(recordDates(payloads), ["2026-05-10"])
        let range = try XCTUnwrap(payloads.first?["date_range"] as? [String: String])
        XCTAssertEqual(range, ["start": "2026-05-10", "end": "2026-05-11"])
        let failures = try XCTUnwrap(payloads.first?["failed_date_details"] as? [[String: Any]])
        XCTAssertEqual(failures.count, 1)
    }

    func testProviderOnlyDayIsUploadedWithoutInventingHealthData() async throws {
        let exportDate = date(10)
        let (settings, apiSettings) = makeSettings()
        var externalFetchCount = 0
        var payloads: [[String: Any]] = []
        let result = await APIEndpointExportRunner.export(
            dates: [exportDate], settings: settings, apiSettings: apiSettings,
            fetchHealthData: { day, _, _ in HealthData(date: day) },
            fetchExternalDailyRecords: { day in
                externalFetchCount += 1
                return [self.sidecar(day)]
            },
            connectedAppsEnabled: true,
            upload: { body, _ in
                payloads.append(try self.decode(body))
                return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
            }
        )

        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.failedDateDetails.first?.reason, .noHealthData)
        XCTAssertEqual(externalFetchCount, 1)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(recordDates(payloads), [])
        XCTAssertEqual(result.externalRecordFileCount, 1)
        XCTAssertEqual(payloads.first?["external_record_count"] as? Int, 1)
        let providers = try XCTUnwrap(payloads.first?["external_records"] as? [[String: Any]])
        XCTAssertEqual(providers.first?["provider"] as? String, "whoop")
    }

    func testProviderRecordsSurviveAppleHealthReadFailure() async throws {
        let exportDate = date(10)
        let (settings, apiSettings) = makeSettings()
        var uploadedExternalCount = 0
        let result = await APIEndpointExportRunner.export(
            dates: [exportDate], settings: settings, apiSettings: apiSettings,
            fetchHealthData: { _, _, _ in throw HealthKitManager.HealthKitError.notAuthorized },
            fetchExternalDailyRecords: { day in [self.sidecar(day)] },
            connectedAppsEnabled: true,
            upload: { body, _ in
                let envelope = try self.decode(body)
                XCTAssertEqual(envelope["record_count"] as? Int, 0)
                uploadedExternalCount += envelope["external_record_count"] as? Int ?? 0
                return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
            }
        )
        XCTAssertEqual(uploadedExternalCount, 1)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.externalRecordFileCount, 1)
        XCTAssertEqual(result.failedDateDetails.first?.reason, .healthKitError)
    }

    func testByteBoundSplitsWholeDaysNewestFirstAndPreservesProviderRecords() async throws {
        let dates = [date(10), date(11), date(12)]
        let (settings, apiSettings) = makeSettings()
        let sidecars = Dictionary(uniqueKeysWithValues: dates.map { ($0, sidecar($0)) })
        let expected = try dates.map { day in
            try APIExportClient.makePayload(
                records: [record(day)], failedDateDetails: [], externalRecords: [sidecars[day]!],
                settings: settings, dateRangeStart: day, dateRangeEnd: day,
                connectedAppsEnabled: true
            )
        }
        let byteLimit = try XCTUnwrap(expected.map(\.count).max()) + 10
        var uploaded: [Data] = []
        var fetchedDates: [Date] = []
        let result = await APIEndpointExportRunner.export(
            dates: dates, settings: settings, apiSettings: apiSettings,
            fetchHealthData: { day, _, _ in
                fetchedDates.append(day)
                return self.record(day)
            },
            fetchExternalDailyRecords: { day in [sidecars[day]!] },
            maximumPayloadBytes: byteLimit,
            connectedAppsEnabled: true,
            upload: { body, _ in
                if uploaded.isEmpty { XCTAssertEqual(fetchedDates, [self.date(12)]) }
                uploaded.append(body)
                return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
            }
        )
        XCTAssertEqual(result.successCount, 3)
        XCTAssertEqual(result.externalRecordFileCount, 3)
        XCTAssertTrue(result.failedDateDetails.isEmpty)
        XCTAssertEqual(uploaded.count, 3)
        XCTAssertTrue(uploaded.allSatisfy { $0.count <= byteLimit })
        let envelopes = try uploaded.map(decode)
        XCTAssertEqual(recordDates(envelopes), ["2026-05-12", "2026-05-11", "2026-05-10"])
        for (sent, original) in zip(envelopes, try expected.reversed().map(decode)) {
            XCTAssertEqual(sent["records"] as? NSArray, original["records"] as? NSArray)
            XCTAssertEqual(sent["external_records"] as? NSArray, original["external_records"] as? NSArray)
            XCTAssertEqual(sent["date_range"] as? NSDictionary, original["date_range"] as? NSDictionary)
        }
    }

    func testOversizedWholeDayIsReportedUnsentWhileOtherDatesContinue() async throws {
        let older = date(10), oversized = date(11)
        let (settings, apiSettings) = makeSettings()
        let small = try APIExportClient.makePayload(
            records: [record(older)], failedDateDetails: [], settings: settings,
            dateRangeStart: older, dateRangeEnd: older, connectedAppsEnabled: true
        )
        var payloads: [[String: Any]] = []
        let result = await APIEndpointExportRunner.export(
            dates: [older, oversized], settings: settings, apiSettings: apiSettings,
            fetchHealthData: { day, _, _ in self.record(day) },
            fetchExternalDailyRecords: { day in
                day == oversized ? [self.sidecar(day, text: String(repeating: "é", count: 20_000))] : []
            },
            maximumPayloadBytes: small.count + 10,
            connectedAppsEnabled: true,
            upload: { body, _ in
                payloads.append(try self.decode(body))
                return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
            }
        )
        XCTAssertEqual(recordDates(payloads), ["2026-05-10"])
        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.externalRecordFileCount, 0)
        XCTAssertEqual(result.failedDateDetails.map(\.date), [oversized])
        XCTAssertEqual(result.failedDateDetails.first?.reason, .fileWriteError)
        XCTAssertTrue(result.failedDateDetails.first?.errorDetails?.contains("not sent") == true)
    }

    func testFailedBatchDoesNotEraseAcknowledgedSuccessOrCountUnsentData() async throws {
        let (settings, apiSettings) = makeSettings()
        var attemptedDates: [String] = []
        let result = await APIEndpointExportRunner.export(
            dates: [date(10), date(11), date(12)], settings: settings, apiSettings: apiSettings,
            fetchHealthData: { day, _, _ in self.record(day) },
            fetchExternalDailyRecords: { day in [self.sidecar(day)] },
            maximumDatesPerBatch: 1,
            connectedAppsEnabled: true,
            upload: { body, _ in
                let day = try XCTUnwrap(self.recordDates([self.decode(body)]).first)
                attemptedDates.append(day)
                if day == "2026-05-11" {
                    throw APIExportClientError.serverRejected(statusCode: 500, body: "fixture failure")
                }
                return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
            }
        )
        XCTAssertEqual(attemptedDates, ["2026-05-12", "2026-05-11", "2026-05-10"])
        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(result.externalRecordFileCount, 2)
        XCTAssertEqual(result.failedDateDetails.map(\.date), [date(11)])
        XCTAssertEqual(result.failedDateDetails.first?.reason, .fileWriteError)
    }

    func testCancellationDoesNotCountPreparedButUnsentRecords() async {
        let (settings, apiSettings) = makeSettings()
        var uploadCount = 0
        let task = Task { @MainActor in
            await APIEndpointExportRunner.export(
                dates: [self.date(10)], settings: settings, apiSettings: apiSettings,
                fetchHealthData: { day, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return self.record(day)
                },
                upload: { _, _ in
                    uploadCount += 1
                    return APIExportUploadResult(statusCode: 202, responseBodyPreview: nil)
                }
            )
        }
        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.externalRecordFileCount, 0)
        XCTAssertEqual(uploadCount, 0)
    }

    func testUploadFailureReturnsFileWriteFailureWithoutCountingPreparedRecordsAsSuccess() async {
        let (settings, apiSettings) = makeSettings()
        let result = await APIEndpointExportRunner.export(
            dates: [date(10)], settings: settings, apiSettings: apiSettings,
            fetchHealthData: { day, _, _ in self.record(day) },
            upload: { _, _ in
                throw APIExportClientError.serverRejected(statusCode: 500, body: "boom")
            }
        )
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(result.failedDateDetails.first?.reason, .fileWriteError)
        XCTAssertTrue(result.failedDateDetails.first?.errorDetails?.contains("500") == true)
    }

    private func makeSettings() -> (AdvancedExportSettings, APIExportSettings) {
        let settings = AdvancedExportSettings(userDefaults: defaults)
        Self.retainedSettings.append(settings)
        let apiSettings = APIExportSettings(userDefaults: defaults)
        apiSettings.endpointURLString = "https://fixture.invalid/healthmd"
        return (settings, apiSettings)
    }

    private func record(_ date: Date) -> HealthData {
        HealthData(date: date, activity: ActivityData(steps: 1234))
    }

    private func sidecar(_ date: Date, text: String = "完整記錄 é 🌱") -> ExternalDailyRecord {
        ExternalDailyRecord(
            provider: .whoop, date: ExternalProviderAPIClient.dayString(date),
            payloads: [ExternalProviderPayload(
                name: "cycles", endpoint: "https://fixture.invalid/cycle", statusCode: 200,
                data: .object(["fixture": .string(text)])
            )]
        )
    }

    private func decode(_ body: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func recordDates(_ envelopes: [[String: Any]]) -> [String] {
        envelopes.flatMap { ($0["records"] as? [[String: Any]] ?? []).compactMap { $0["date"] as? String } }
    }

    private func date(_ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: day))!
    }
}

