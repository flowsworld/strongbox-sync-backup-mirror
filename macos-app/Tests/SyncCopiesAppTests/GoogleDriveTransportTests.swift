import Foundation
import SyncCopiesCore
import XCTest
@testable import SyncCopies

@MainActor
final class GoogleDriveTransportTests: XCTestCase {
    func testTransientFailuresUseFourAttemptsAndFreshReadinessChecks() async throws {
        let fixture = DriveHTTPFixture(outcomes: [.failure(.unreachable), .reply(429, ""), .reply(503, ""), .reply(200, "metadata")])
        let result = try await fixture.transport.metadata(GoogleDriveMetadata.folderRequest(id: "folder_1"), accessToken: "private-access")
        XCTAssertEqual(result, Data("metadata".utf8))
        let snapshot = await fixture.snapshot()
        XCTAssertEqual(snapshot.requests.count, 4)
        XCTAssertEqual(snapshot.hosts, Array(repeating: "www.googleapis.com", count: 4))
        XCTAssertEqual(snapshot.delays, [2, 4, 8])
        for request in snapshot.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-access")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.httpBody)
        }
    }

    func testPermanentStatusesAndRedirectsAreNotRetried() async throws {
        for (status, expected) in [(400, GoogleDriveTransportFailure.requestRejected), (401, .authorizationRejected),
                                   (403, .accessDenied), (404, .resourceUnavailable), (302, .redirect)] {
            let fixture = DriveHTTPFixture(outcomes: [.reply(status, "private server error")])
            do {
                _ = try await fixture.transport.metadata(GoogleDriveMetadata.folderRequest(id: "folder"), accessToken: "access")
                XCTFail("Expected terminal HTTP error")
            } catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, expected) }
            let snapshot = await fixture.snapshot()
            XCTAssertEqual(snapshot.requests.count, 1)
            XCTAssertTrue(snapshot.delays.isEmpty)
        }
    }

    func testOverloadExhaustionAndOversizedRepliesAreBounded() async throws {
        let busy = DriveHTTPFixture(outcomes: Array(repeating: .reply(429, ""), count: 4))
        do {
            _ = try await busy.transport.metadata(GoogleDriveMetadata.folderRequest(id: "folder"), accessToken: "access")
            XCTFail("Expected exhaustion")
        } catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, .overloaded) }
        let huge = DriveHTTPFixture(outcomes: [.reply(200, String(repeating: "x", count: 1_048_577))])
        do {
            _ = try await huge.transport.metadata(GoogleDriveMetadata.folderRequest(id: "folder"), accessToken: "access")
            XCTFail("Expected body limit")
        } catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, .responseTooLarge) }
        let hugeSnapshot = await huge.snapshot()
        XCTAssertEqual(hugeSnapshot.requests.count, 1)
    }

    func testIdentityIsStrictAndMalformedJSONIsNotRetried() async throws {
        let fixture = DriveHTTPFixture(outcomes: [.reply(200, #"{"user":{"permissionId":"123","me":true,"displayName":"Test Account"}}"#)])
        let identity = try await fixture.transport.identity(accessToken: "access")
        XCTAssertEqual(identity.drivePermissionID, "123")
        XCTAssertEqual(identity.displayName, "Test Account")
        let identitySnapshot = await fixture.snapshot()
        let request = try XCTUnwrap(identitySnapshot.requests.first)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "user(permissionId,emailAddress,displayName,me)")
        for json in [#"{"user":{"permissionId":"123","me":false}}"#, #"{"user":{"permissionId":"123","me":1}}"#,
                     #"{"user":{"permissionId":"123","me":true,"emailAddress":null}}"#, "not JSON"] {
            let malformed = DriveHTTPFixture(outcomes: [.reply(200, json)])
            do { _ = try await malformed.transport.identity(accessToken: "access"); XCTFail("Expected invalid identity") }
            catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .invalidIdentity) }
            let malformedSnapshot = await malformed.snapshot()
            XCTAssertEqual(malformedSnapshot.requests.count, 1)
        }
    }

    func testRequestPolicyAllowsOnlyFixedMetadataAndTokenEffects() throws {
        let folder = try GoogleDriveMetadata.folderRequest(id: "folder")
        XCTAssertTrue(allowedGoogleDriveRequest(URLRequest(url: folder.url)))
        for url in ["https://www.googleapis.com/drive/v3/files/folder?alt=media",
                    "https://www.googleapis.com/drive/v3/files/folder?fields=id,name,mimeType,trashed&supportsAllDrives=true&fields=id",
                    "https://www.googleapis.com:443/drive/v3/about?fields=user(permissionId,emailAddress,displayName,me)",
                    "https://evil.example/drive/v3/about?fields=user(permissionId,emailAddress,displayName,me)",
                    "http://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress,displayName,me)"] {
            XCTAssertFalse(allowedGoogleDriveRequest(URLRequest(url: try XCTUnwrap(URL(string: url)))))
        }
        var mutation = URLRequest(url: folder.url)
        mutation.httpMethod = "DELETE"
        XCTAssertFalse(allowedGoogleDriveRequest(mutation))
        let client = try GoogleDriveOAuthClient(clientID: "native-test.apps.googleusercontent.com")
        let description = try client.refreshRequest(refreshToken: "private-refresh")
        var token = URLRequest(url: description.url)
        token.httpMethod = description.method; token.httpBody = description.body
        token.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        XCTAssertTrue(allowedGoogleDriveRequest(token))
        token.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(allowedGoogleDriveRequest(token))
    }

    func testInvalidAccessTokenNeverTouchesTransport() async throws {
        let fixture = DriveHTTPFixture(outcomes: [])
        do {
            _ = try await fixture.transport.metadata(GoogleDriveMetadata.folderRequest(id: "folder"), accessToken: "bad\r\nheader")
            XCTFail("Expected token rejection")
        } catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, .invalidAccessToken) }
        let snapshot = await fixture.snapshot()
        XCTAssertTrue(snapshot.requests.isEmpty)
    }

    func testReadinessWaitsThirtySecondsWithoutSendingCredentials() async throws {
        let clock = DriveFixtureClock()
        let fixture = DriveHTTPFixture(outcomes: [.reply(403, "")])
        let readiness = GoogleDriveReadiness(routeAvailable: { false }, send: { try await fixture.send($0) },
                                            uptime: { clock.now }, sleep: { clock.advance($0) })
        do { try await readiness.wait(host: "www.googleapis.com"); XCTFail("Expected no route") }
        catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, .noNetwork) }
        XCTAssertEqual(clock.now, 30)
        let absentSnapshot = await fixture.snapshot()
        XCTAssertTrue(absentSnapshot.requests.isEmpty)
        let reachable = GoogleDriveReadiness(routeAvailable: { true }, send: { try await fixture.send($0) },
                                            uptime: { clock.now }, sleep: { clock.advance($0) })
        try await reachable.wait(host: "oauth2.googleapis.com")
        let reachableSnapshot = await fixture.snapshot()
        let probe = try XCTUnwrap(reachableSnapshot.requests.first)
        XCTAssertEqual(probe.httpMethod, "HEAD")
        XCTAssertEqual(probe.url?.absoluteString, "https://oauth2.googleapis.com/")
        XCTAssertEqual(probe.timeoutInterval, 3)
        XCTAssertNil(probe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(probe.httpBody)
    }

    func testCancellationDoesNotRetry() async throws {
        let fixture = DriveHTTPFixture(outcomes: [.cancelled])
        do { _ = try await fixture.transport.identity(accessToken: "access"); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = await fixture.snapshot()
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertTrue(snapshot.delays.isEmpty)
    }

    func testRealHTTPSessionReadsBoundedSyntheticResponsesAndRefusesRedirects() async throws {
        let client = GoogleDriveHTTPClient(protocolClasses: [DriveHTTPProtocolFixture.self])
        let normal = try await client.send(URLRequest(url: URL(string: "https://www.googleapis.com/fixture/normal")!))
        XCTAssertEqual(normal.statusCode, 200)
        XCTAssertEqual(normal.body, Data("fixture body".utf8))
        for (path, expected) in [("oversized", GoogleDriveTransportFailure.responseTooLarge),
                                 ("unannounced", .responseTooLarge), ("redirect", .redirect)] {
            do {
                _ = try await client.send(URLRequest(url: URL(string: "https://www.googleapis.com/fixture/" + path)!))
                XCTFail("Expected bounded session error")
            } catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, expected) }
        }
        var head = URLRequest(url: URL(string: "https://www.googleapis.com/fixture/oversized")!)
        head.httpMethod = "HEAD"
        let headReply = try await client.send(head)
        XCTAssertTrue(headReply.body.isEmpty)
    }
}

/// URLProtocol supplies every byte locally. None of these requests reach Google or a live socket.
private final class DriveHTTPProtocolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let oversized = url.path.hasSuffix("oversized")
        let unannounced = url.path.hasSuffix("unannounced")
        let redirect = url.path.hasSuffix("redirect")
        let headers = unannounced ? [:] : ["Content-Length": oversized ? "1048577" : "12",
                                          "Location": "https://evil.example/token"]
        let response = HTTPURLResponse(url: url, statusCode: redirect ? 302 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: unannounced ? Data(repeating: 120, count: 1_048_577) : Data("fixture body".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

actor DriveHTTPFixture {
    enum Outcome: Sendable { case reply(Int, String), failure(GoogleDriveTransportFailure), cancelled }
    struct Snapshot: Sendable { let requests: [URLRequest]; let hosts: [String]; let delays: [TimeInterval] }
    private var outcomes: [Outcome]
    private var requests: [URLRequest] = []
    private var hosts: [String] = []
    private var delays: [TimeInterval] = []

    init(outcomes: [Outcome]) { self.outcomes = outcomes }
    nonisolated var transport: GoogleDriveTransport {
        GoogleDriveTransport(send: { try await self.send($0) }, ready: { await self.ready($0) }, sleep: { await self.sleep($0) })
    }
    func send(_ request: URLRequest) throws -> GoogleDriveHTTPReply {
        requests.append(request)
        guard !outcomes.isEmpty else { throw GoogleDriveTransportFailure.invalidResponse }
        switch outcomes.removeFirst() {
        case .reply(let status, let body): return GoogleDriveHTTPReply(statusCode: status, body: Data(body.utf8))
        case .failure(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
    func ready(_ host: String) { hosts.append(host) }
    func sleep(_ delay: TimeInterval) { delays.append(delay) }
    func snapshot() -> Snapshot { Snapshot(requests: requests, hosts: hosts, delays: delays) }
}

final class DriveFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ amount: TimeInterval) { lock.withLock { value += amount } }
}
