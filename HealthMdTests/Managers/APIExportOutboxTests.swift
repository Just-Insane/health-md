import XCTest
@testable import HealthMd

@MainActor
final class APIExportOutboxTests: XCTestCase {
    private var directories: [URL] = []
    private var credentials: [SystemKeychainStore] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        for keychain in credentials { keychain.remove(key: "apiExport.bearerToken") }
        HealthOutboxURLProtocol.handler = nil
        try await super.tearDown()
    }

    private func settings() -> APIExportSettings {
        let keychain = SystemKeychainStore(service: "HealthOutboxTests." + UUID().uuidString)
        credentials.append(keychain)
        let value = APIExportSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, keychain: keychain)
        value.endpointURLString = "https://fixture.invalid/v1/healthmd"
        value.bearerToken = "fabricated-outbox-credential"
        return value
    }

    private func store() throws -> (URL, APIExportOutbox) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return (directory, try APIExportOutbox(directory: directory))
    }

    private func body() -> Data {
        Data(#"{ "schema":"healthmd.api_export", "exported_at":"2026-10-05T12:00:00Z", "date_range":{"start":"2020-01-01","end":"2020-01-01"}, "records":[{"date":"2020-01-01","raw_capture_status":"partial"}], "record_count":1, "external_records":[{"date":"2020-01-01"}], "failed_date_details":[] }"#.utf8)
    }

    private func receipt(_ status: String, sha: String, id: String = "fixture-export") -> String {
        "{\"status\":\"\(status)\",\"sha256\":\"\(sha)\",\"capture\":{\"export_id\":\"\(id)\"},\"retry_same_original\":true}"
    }

    private func client(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> (APIExportClient, URLSession) {
        HealthOutboxURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthOutboxURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (APIExportClient(session: session), session)
    }

    func testProtectedPreparedBytesAndCountsSurviveReopeningWithoutCredentials() async throws {
        let (directory, outbox) = try store(), settings = settings(), bytes = body()
        let request = try APIExportClient.request(body: bytes, apiSettings: settings)
        let entry = try outbox.prepare(body: bytes, request: request)
        let reopened = try APIExportOutbox(directory: directory)
        XCTAssertEqual(try reopened.bytes(for: entry), bytes)
        XCTAssertEqual(try reopened.pending(for: request).map(\.id), [entry.id])
        XCTAssertEqual(entry.days.first?.records, 1)
        XCTAssertEqual(entry.days.first?.externalRecords, 1)
        XCTAssertEqual(entry.partialDates, ["2020-01-01"])
        let metadata = try String(contentsOf: directory.appendingPathComponent(entry.id + ".json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("fabricated-outbox-credential"))
        XCTAssertFalse(metadata.contains("Authorization"))
        XCTAssertFalse(metadata.contains("fixture.invalid"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(entry.id + ".body").path)[.posixPermissions] as? Int, 0o600)
        let acknowledged = try reopened.acknowledge(entry, statusCode: 200)
        XCTAssertEqual(try APIExportOutbox(directory: directory).read(entry.id).state, .acknowledged)
        XCTAssertEqual(acknowledged.days.first?.records, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id + ".body").path))
    }

    func testLostPostAcknowledgementReopensAsGetAndDoesNotDuplicatePost() async throws {
        let (directory, outbox) = try store(), settings = settings(), bytes = body(), sha = APIExportOutbox.digest(body())
        var methods: [String] = []
        var serverAccepted = false
        let (client, session) = client { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-HealthMD-Export-SHA256"), sha)
                return (200, self.receipt(serverAccepted ? "accepted" : "capture_pending", sha: sha))
            }
            XCTAssertEqual(request.httpBody, bytes)
            serverAccepted = true
            throw URLError(.networkConnectionLost)
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.uploadDurablePayload(bytes, apiSettings: settings, outbox: outbox); XCTFail() }
        catch { XCTAssertTrue(error is URLError) }
        let reopened = try APIExportOutbox(directory: directory)
        let pending = try reopened.pending(for: APIExportClient.request(body: nil, apiSettings: settings))
        XCTAssertEqual(pending.first?.state, .attempted)
        XCTAssertEqual(pending.first?.receiverExportID, "fixture-export")
        _ = try await client.resume(XCTUnwrap(pending.first), apiSettings: settings, outbox: reopened)
        XCTAssertEqual(methods, ["GET", "POST", "GET"])
        XCTAssertEqual(try reopened.read(pending[0].id).state, .acknowledged)
    }

    func testExplicitPendingReceiptResumesIdenticalBodyWithNativeDatesAndSameAccount() async throws {
        let (directory, outbox) = try store(), settings = settings(), bytes = body(), sha = APIExportOutbox.digest(body())
        var calls = 0, posts: [Data] = []
        let (client, session) = client { request in
            if request.httpMethod == "GET" { return (200, self.receipt("capture_pending", sha: sha)) }
            posts.append(request.httpBody!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fabricated-outbox-credential")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-HealthMD-Export-ID"), "fixture-export")
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            return (200, self.receipt("accepted", sha: sha))
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.uploadDurablePayload(bytes, apiSettings: settings, outbox: outbox); XCTFail() } catch {}
        let reopened = try APIExportOutbox(directory: directory)
        let pending = try reopened.pending(for: APIExportClient.request(body: nil, apiSettings: settings))
        _ = try await client.resume(XCTUnwrap(pending.first), apiSettings: settings, outbox: reopened)
        XCTAssertEqual(posts, [bytes, bytes])
        XCTAssertEqual(try reopened.read(pending[0].id).exportedAt, "2026-10-05T12:00:00Z")
        XCTAssertEqual(try reopened.read(pending[0].id).days.first?.date, "2020-01-01")
    }

    func testUnknownUnsupportedOrMismatchedReceiptNeverResends() async throws {
        for response in ["unsupported", "wrong-digest", "wrong-account", "refused"] {
            let (_, outbox) = try store(), settings = settings(), bytes = body()
            let request = try APIExportClient.request(body: bytes, apiSettings: settings)
            var entry = try outbox.prepare(body: bytes, request: request)
            entry.state = .attempted; entry.receiverExportID = "fixture-export"; try outbox.save(entry)
            var methods: [String] = []
            let (client, session) = client { request in
                methods.append(request.httpMethod!)
                switch response {
                case "unsupported": return (405, "{}")
                case "wrong-digest": return (200, self.receipt("capture_pending", sha: String(repeating: "0", count: 64)))
                case "wrong-account": return (200, self.receipt("capture_pending", sha: entry.sha256, id: "another-account-export"))
                default: return (503, "{\"status\":\"source_unavailable\"}")
                }
            }
            do { _ = try await client.resume(entry, apiSettings: settings, outbox: outbox); XCTFail(response) } catch {}
            session.invalidateAndCancel()
            XCTAssertEqual(methods, ["GET"], response)
            XCTAssertEqual(try outbox.bytes(for: entry), bytes)
            XCTAssertEqual(try outbox.read(entry.id).state, .attempted)
        }
    }

    func testChangedDestinationAndDamagedBytesAreRefusedBeforeNetwork() async throws {
        let (_, outbox) = try store(), settings = settings(), bytes = body()
        let request = try APIExportClient.request(body: bytes, apiSettings: settings)
        let entry = try outbox.prepare(body: bytes, request: request)
        var requests = 0
        let (client, session) = client { _ in requests += 1; return (200, "{}") }
        defer { session.invalidateAndCancel() }
        settings.bearerToken = "different-fabricated-account"
        XCTAssertTrue(try outbox.pending(for: APIExportClient.request(body: nil, apiSettings: settings)).isEmpty)
        do { _ = try await client.resume(entry, apiSettings: settings, outbox: outbox); XCTFail() } catch {}
        settings.bearerToken = "fabricated-outbox-credential"
        try Data("damaged".utf8).write(to: directories.last!.appendingPathComponent(entry.id + ".body"))
        do { _ = try await client.resume(entry, apiSettings: settings, outbox: outbox); XCTFail() } catch {}
        XCTAssertEqual(requests, 0)
    }

    func testGenericReceiverKeepsInitialPostButUnknownWriteNeedsExplicitRecovery() async throws {
        let (_, outbox) = try store(), settings = settings(), bytes = body()
        var methods: [String] = []
        let (client, session) = client { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "GET" { return (200, "{\"api\":\"generic-upload\"}") }
            throw URLError(.networkConnectionLost)
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.uploadDurablePayload(bytes, apiSettings: settings, outbox: outbox); XCTFail() } catch {}
        let entry = try XCTUnwrap(outbox.pending(for: APIExportClient.request(body: nil, apiSettings: settings)).first)
        do { _ = try await client.resume(entry, apiSettings: settings, outbox: outbox); XCTFail() } catch {}
        XCTAssertEqual(methods, ["GET", "POST", "GET"])
        XCTAssertEqual(try outbox.bytes(for: entry), bytes)
    }

    func testMembershipProgressSurvivesTerminationAndCannotMoveBackwards() async throws {
        let (directory, outbox) = try store(), settings = settings(), sha = APIExportOutbox.digest(body())
        let bytes = body() + Data(repeating: 32, count: 200)
        var posts = 0
        let (client, session) = client { request in
            if request.httpMethod == "GET" { return (200, self.receipt("capture_pending", sha: APIExportOutbox.digest(bytes))) }
            posts += 1
            if posts == 1 { return (503, "{\"status\":\"capture_membership_pending\",\"export_id\":\"fixture-export\",\"next_cursor\":10,\"total\":20,\"retry_same_original\":true}") }
            throw URLError(.networkConnectionLost)
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await client.uploadDurablePayload(bytes, apiSettings: settings, outbox: outbox); XCTFail() } catch {}
        let reopened = try APIExportOutbox(directory: directory)
        let entry = try XCTUnwrap(reopened.pending(for: APIExportClient.request(body: nil, apiSettings: settings)).first)
        XCTAssertEqual(entry.membership?.nextCursor, 10)
        XCTAssertEqual(entry.membership?.exportID, "fixture-export")
        XCTAssertNotEqual(entry.sha256, sha)
        HealthOutboxURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, self.receipt("capture_pending", sha: entry.sha256)) }
            return (503, "{\"status\":\"capture_membership_pending\",\"export_id\":\"fixture-export\",\"next_cursor\":10,\"total\":20,\"retry_same_original\":true}")
        }
        do { _ = try await client.resume(entry, apiSettings: settings, outbox: reopened); XCTFail() } catch {}
        XCTAssertEqual(try reopened.read(entry.id).membership?.nextCursor, 10)
        XCTAssertEqual(try reopened.bytes(for: entry), bytes)
    }
}

private final class HealthOutboxURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var sent = request
            if sent.httpBody == nil, let stream = sent.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                sent.httpBody = body
            }
            let (status, body) = try Self.handler!(sent)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type":"application/json", "Retry-After":"0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
