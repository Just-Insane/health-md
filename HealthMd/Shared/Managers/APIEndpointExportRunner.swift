import Foundation

/// Testable API Endpoint export pipeline shared by manual and scheduled exports.
/// It prepares public daily JSON records for the requested dates, reports dates
/// with no readable data, and uploads bounded envelopes of complete daily records.
@MainActor
struct APIEndpointExportRunner {
    typealias HealthDataFetcher = (
        _ date: Date,
        _ includeGranularData: Bool,
        _ metricSelection: MetricSelectionState
    ) async throws -> HealthData

    typealias ExternalDailyRecordFetcher = (_ date: Date) async -> [ExternalDailyRecord]

    typealias Uploader = (_ preparedBody: Data, _ apiSettings: APIExportSettings) async throws -> APIExportUploadResult

    private struct PreparedDay {
        let date: Date
        let body: Data
        let recordCount: Int
        let externalRecordCount: Int
        var hasContent: Bool { recordCount > 0 || externalRecordCount > 0 }
    }

    static func export(
        dates: [Date],
        healthKitManager: HealthKitManager,
        settings: AdvancedExportSettings,
        apiSettings: APIExportSettings,
        externalIntegrations: ExternalIntegrationDailyRecordProviding? = nil,
        onProgress: ((_ current: Int, _ total: Int, _ date: Date) -> Void)? = nil
    ) async -> ExportOrchestrator.ExportResult {
        let externalFetcher: ExternalDailyRecordFetcher?
        if ConnectedAppsFeature.isEnabled,
           let externalIntegrations,
           externalIntegrations.connectedProviderCount > 0 {
            externalFetcher = { date in
                await externalIntegrations.fetchDailyRecords(for: date)
            }
        } else {
            externalFetcher = nil
        }

        return await export(
            dates: dates,
            settings: settings,
            apiSettings: apiSettings,
            fetchHealthData: { date, includeGranularData, metricSelection in
                try await healthKitManager.fetchHealthData(
                    for: date,
                    includeGranularData: includeGranularData,
                    metricSelection: metricSelection
                )
            },
            fetchExternalDailyRecords: externalFetcher,
            onProgress: onProgress,
            upload: { body, apiSettings in
                try await APIExportClient().uploadPayload(body, apiSettings: apiSettings)
            }
        )
    }

    static func export(
        dates: [Date],
        settings: AdvancedExportSettings,
        apiSettings: APIExportSettings,
        fetchHealthData: HealthDataFetcher,
        fetchExternalDailyRecords: ExternalDailyRecordFetcher? = nil,
        maximumPayloadBytes: Int = APIExportClient.maximumPayloadBytes,
        maximumDatesPerBatch: Int = 32,
        connectedAppsEnabled: Bool? = nil,
        onProgress: ((_ current: Int, _ total: Int, _ date: Date) -> Void)? = nil,
        upload: Uploader
    ) async -> ExportOrchestrator.ExportResult {
        let normalizedDates = Array(Set(dates.map { Calendar.current.startOfDay(for: $0) })).sorted()
        guard !normalizedDates.isEmpty else {
            return ExportOrchestrator.ExportResult(
                successCount: 0, totalCount: 0, failedDateDetails: [], formatsPerDate: 0
            )
        }

        guard !settings.exportFormats.isEmpty else {
            return failureResult(
                dates: normalizedDates,
                reason: .unknown,
                message: "Select at least one export format before exporting to an API endpoint."
            )
        }
        guard apiSettings.isConfigured else {
            return failureResult(
                dates: normalizedDates,
                reason: .unknown,
                message: APIExportClientError.invalidEndpoint.localizedDescription
            )
        }
        precondition(maximumPayloadBytes > 0 && maximumDatesPerBatch > 0)
        let byteLimit = min(maximumPayloadBytes, APIExportClient.maximumPayloadBytes)
        let exportedAt = Date()
        var batch: [PreparedDay] = []
        var batchBody: Data?
        var firstContentBatchAttempted = false
        var successCount = 0
        var uploadedExternalCount = 0
        var failedDateDetails: [FailedDateDetail] = []
        var partialFailures: [ExportPartialFailure] = []

        func result(wasCancelled: Bool = false) -> ExportOrchestrator.ExportResult {
            ExportOrchestrator.ExportResult(
                successCount: successCount,
                totalCount: normalizedDates.count,
                failedDateDetails: failedDateDetails,
                partialFailures: partialFailures,
                formatsPerDate: 0,
                externalRecordFileCount: uploadedExternalCount,
                wasCancelled: wasCancelled
            )
        }

        func recordUploadFailure(_ date: Date, _ error: Error) {
            // A provider-only date can already have a HealthKit failure. Report
            // its unsent export once, without claiming its provider data arrived.
            failedDateDetails.removeAll { $0.date == date }
            failedDateDetails.append(FailedDateDetail(
                date: date, reason: .fileWriteError, errorDetails: error.localizedDescription
            ))
        }

        func flush() async -> Bool {
            guard let body = batchBody else { return true }
            let submittedDays = batch
            batch = []
            batchBody = nil
            guard submittedDays.contains(where: \.hasContent) else { return true }
            firstContentBatchAttempted = true
            do {
                try Task.checkCancellation()
                _ = try await upload(body, apiSettings)
                successCount += submittedDays.reduce(0) { $0 + $1.recordCount }
                uploadedExternalCount += submittedDays.reduce(0) { $0 + $1.externalRecordCount }
                return true
            } catch {
                if Task.isCancelled || error is CancellationError { return false }
                for day in submittedDays where day.hasContent {
                    recordUploadFailure(day.date, error)
                }
                return true
            }
        }

        // Send recent dates before older history and keep at most one bounded
        // batch plus the current day in memory. Never split a daily archive.
        for (index, date) in normalizedDates.reversed().enumerated() {
            if Task.isCancelled { return result(wasCancelled: true) }
            onProgress?(index + 1, normalizedDates.count, date)
            var records: [HealthData] = []
            var dayFailures: [FailedDateDetail] = []
            var externalRecords: [ExternalDailyRecord] = []
            do {
                let record = try await fetchHealthData(
                    date, settings.includeGranularData, settings.metricSelection
                ).filtered(by: settings.metricSelection)
                partialFailures.append(contentsOf: record.partialFailures)
                if record.hasAnyData {
                    records.append(record)
                } else {
                    dayFailures.append(FailedDateDetail(date: date, reason: .noHealthData))
                }
            } catch let error as HealthKitManager.HealthKitError {
                dayFailures.append(FailedDateDetail(
                    date: date, reason: failureReason(for: error), errorDetails: String(describing: error)
                ))
            } catch {
                dayFailures.append(FailedDateDetail(
                    date: date, reason: .healthKitError, errorDetails: error.localizedDescription
                ))
            }

            // Provider records remain independent of HealthKit availability.
            if !Task.isCancelled, let fetchExternalDailyRecords {
                externalRecords = await fetchExternalDailyRecords(date).filter(\.shouldExport)
            }
            failedDateDetails.append(contentsOf: dayFailures)
            if Task.isCancelled { return result(wasCancelled: true) }

            do {
                let dayBody = try APIExportClient.makePayload(
                    records: records,
                    failedDateDetails: dayFailures,
                    externalRecords: externalRecords,
                    settings: settings,
                    dateRangeStart: date,
                    dateRangeEnd: date,
                    exportedAt: exportedAt,
                    connectedAppsEnabled: connectedAppsEnabled
                )
                guard dayBody.count <= byteLimit else {
                    if !(await flush()) { return result(wasCancelled: true) }
                    throw APIExportClientError.payloadTooLarge(
                        byteCount: dayBody.count, maximumBytes: byteLimit
                    )
                }
                let day = PreparedDay(
                    date: date, body: dayBody, recordCount: records.count,
                    externalRecordCount: externalRecords.count
                )
                let combined = try APIExportClient.combinePayloads(batch.map(\.body) + [dayBody])
                if combined.count > byteLimit {
                    if !(await flush()) { return result(wasCancelled: true) }
                    batch = [day]
                    batchBody = dayBody
                } else {
                    batch.append(day)
                    batchBody = combined
                }
                // Deliver the newest available day before collecting older
                // history; later dates can share bounded batches.
                if (!firstContentBatchAttempted && day.hasContent) || batch.count >= maximumDatesPerBatch,
                   !(await flush()) {
                    return result(wasCancelled: true)
                }
            } catch {
                recordUploadFailure(date, error)
            }
        }

        if !(await flush()) { return result(wasCancelled: true) }
        return result()
    }

    private static func failureResult(
        dates: [Date],
        reason: ExportFailureReason,
        message: String
    ) -> ExportOrchestrator.ExportResult {
        let failedDates = dates.isEmpty ? [Date()] : dates
        return ExportOrchestrator.ExportResult(
            successCount: 0,
            totalCount: dates.count,
            failedDateDetails: failedDates.map {
                FailedDateDetail(date: $0, reason: reason, errorDetails: message)
            },
            formatsPerDate: 0
        )
    }

    private static func failureReason(for error: HealthKitManager.HealthKitError) -> ExportFailureReason {
        switch error {
        case .dataProtectedWhileLocked:
            return .deviceLocked
        case .notAuthorized, .dataNotAvailable, .medicationAuthorizationUnsupported,
             .visionAuthorizationUnsupported:
            return .healthKitError
        }
    }
}

