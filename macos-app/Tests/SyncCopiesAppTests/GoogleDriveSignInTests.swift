import Foundation
import SyncCopiesCore
import XCTest
@testable import SyncCopies

@MainActor
final class GoogleDriveSignInTests: XCTestCase {
    func testSignInRejectsWrongStateThenExchangesCodeAndReadsCurrentDriveUser() async throws {
        let receiver = DriveSignInFixture(mode: .invalidThenValid)
        let http = DriveHTTPFixture(outcomes: [.reply(200, #"{"access_token":"private-access","refresh_token":"private-refresh","expires_in":3600,"token_type":"Bearer"}"#),
                                              .reply(200, #"{"user":{"permissionId":"111","emailAddress":"test@example.invalid","me":true}}"#)])
        let signIn = GoogleDriveSignIn(client: try client(), transport: http.transport, environment: receiver.environment)
        let result = try await signIn.authorize()
        XCTAssertEqual(result.identity.drivePermissionID, "111")
        XCTAssertEqual(result.tokens.accessToken, "private-access")
        XCTAssertFalse(String(reflecting: result).contains("private-access"))
        XCTAssertFalse(String(reflecting: result).contains("private-refresh"))
        XCTAssertEqual(receiver.responses, [false, true])
        XCTAssertTrue(receiver.stopped)
        let requests = (await http.snapshot()).requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=fixture-code"))
        XCTAssertTrue(body.contains("code_verifier="))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53123%2Foauth2%2Fcallback"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer private-access")
        let authorization = try XCTUnwrap(receiver.authorizationURL)
        let fields = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(authorization.host, "accounts.google.com")
        XCTAssertEqual(fields["scope"], "https://www.googleapis.com/auth/drive.metadata.readonly")
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertFalse(fields.keys.contains("client_secret"))
    }

    func testBrowserFailureDenialAndTimeoutCloseReceiverWithoutTokenExchange() async throws {
        for mode in [DriveSignInFixture.Mode.browserFailure, .denied, .timeout] {
            let receiver = DriveSignInFixture(mode: mode)
            let http = DriveHTTPFixture(outcomes: [])
            let signIn = GoogleDriveSignIn(client: try client(), transport: http.transport, environment: receiver.environment)
            do { _ = try await signIn.authorize(); XCTFail("Expected sign-in failure") }
            catch {
                switch mode {
                case .browserFailure: XCTAssertEqual(error as? GoogleDriveSignInFailure, .browserUnavailable)
                case .denied: XCTAssertEqual(error as? GoogleDriveOAuthFailure, .denied)
                case .timeout: XCTAssertEqual(error as? GoogleDriveOAuthFailure, .expired)
                default: XCTFail("Unexpected fixture mode")
                }
            }
            XCTAssertTrue(receiver.stopped)
            let snapshot = await http.snapshot()
            XCTAssertTrue(snapshot.requests.isEmpty)
        }
    }

    func testOnlyOneSessionOwnsListenerAndExplicitCancelReleasesIt() async throws {
        let receiver = DriveSignInFixture(mode: .idle)
        let http = DriveHTTPFixture(outcomes: [])
        let signIn = GoogleDriveSignIn(client: try client(), transport: http.transport, environment: receiver.environment)
        let task = Task { try await signIn.authorize() }
        try await waitForBrowser(receiver)
        do { _ = try await signIn.authorize(); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? GoogleDriveSignInFailure, .busy) }
        await signIn.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(receiver.stopped)
        let snapshot = await http.snapshot()
        XCTAssertTrue(snapshot.requests.isEmpty)
    }

    func testCancellingCallerCancelsOwnedSession() async throws {
        let receiver = DriveSignInFixture(mode: .idle)
        let signIn = GoogleDriveSignIn(client: try client(), transport: DriveHTTPFixture(outcomes: []).transport, environment: receiver.environment)
        let task = Task { try await signIn.authorize() }
        try await waitForBrowser(receiver)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(receiver.stopped)
    }

    func testLoopbackHTTPBoundaryRejectsAmbiguousAndForeignRequests() throws {
        let valid = "GET /oauth2/callback?state=s&code=c HTTP/1.1\r\nHost: 127.0.0.1:53123\r\nContent-Length: 0\r\n\r\n"
        XCTAssertEqual(try GoogleDriveLoopbackReceiver.parseRequest(Data(valid.utf8), port: 53123), "/oauth2/callback?state=s&code=c")
        let invalid = [valid.replacingOccurrences(of: "GET ", with: "POST "),
                       valid.replacingOccurrences(of: "/oauth2/callback", with: "http://127.0.0.1:53123/oauth2/callback"),
                       valid.replacingOccurrences(of: "127.0.0.1:53123", with: "localhost:53123"),
                       valid.replacingOccurrences(of: "127.0.0.1:53123", with: "127.0.0.1:80"),
                       valid.replacingOccurrences(of: "Content-Length: 0", with: "Host: 127.0.0.1:53123"),
                       valid.replacingOccurrences(of: "Content-Length: 0", with: "Transfer-Encoding: chunked"),
                       valid.replacingOccurrences(of: "Content-Length: 0", with: "Content-Length: 1"),
                       valid.replacingOccurrences(of: "Content-Length: 0", with: "Bad Header: x"),
                       valid.replacingOccurrences(of: "Content-Length: 0", with: "Content-Length: 0\nInjected: yes"),
                       valid + "body", valid + valid, String(repeating: "x", count: 40_961)]
        for request in invalid {
            XCTAssertThrowsError(try GoogleDriveLoopbackReceiver.parseRequest(Data(request.utf8), port: 53123)) { error in
                XCTAssertEqual(error as? GoogleDriveSignInFailure, .invalidLocalRequest)
            }
        }
    }

    func testRealLoopbackReceiverFlushesReplyAndCancellationClosesPendingReceive() async throws {
        let receiver = try GoogleDriveLoopbackReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/oauth2/callback?state=fixture-state&code=private-code"))
        let request = Task { try await session.data(from: url) }
        let callback = try await receiver.next()
        XCTAssertEqual(callback.target, "/oauth2/callback?state=fixture-state&code=private-code")
        await callback.respond(true)
        let (data, response) = try await request.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Sign-in received. You can close this window.")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-code"))
        let waiting = Task { try await receiver.next() }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func client() throws -> GoogleDriveOAuthClient {
        try GoogleDriveOAuthClient(clientID: "native-test.apps.googleusercontent.com", clientSecret: "public-client-secret")
    }

    private func waitForBrowser(_ receiver: DriveSignInFixture) async throws {
        let deadline = Date().addingTimeInterval(2)
        while receiver.authorizationURL == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(receiver.authorizationURL)
    }
}

/// A cancellable, memory-only receiver exercises session ownership without a browser or open socket.
private final class DriveSignInFixture: @unchecked Sendable {
    enum Mode: Sendable { case invalidThenValid, denied, timeout, idle, browserFailure }
    private let lock = NSLock()
    private let mode: Mode
    private var url: URL?
    private var pending: [String] = []
    private var waiter: CheckedContinuation<GoogleDriveLoopbackCallback, any Error>?
    private var closed = false
    private var replies: [Bool] = []
    init(mode: Mode) { self.mode = mode }
    var authorizationURL: URL? { lock.withLock { url } }
    var stopped: Bool { lock.withLock { closed } }
    var responses: [Bool] { lock.withLock { replies } }
    var environment: GoogleDriveSignInEnvironment {
        GoogleDriveSignInEnvironment(receiver: {
            GoogleDriveSignInReceiver(port: 53123, next: { try await self.next() }, stop: { self.stop() })
        }, openBrowser: { self.open($0) }, sleep: { _ in
            if self.mode != .timeout { try await Task.sleep(for: .seconds(300)) }
        }, clock: { 0 })
    }
    private func open(_ url: URL) -> Bool {
        lock.withLock {
            self.url = url
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            switch mode {
            case .invalidThenValid:
                pending = ["/oauth2/callback?state=wrong&code=wrong-code", "/oauth2/callback?state=\(state)&code=fixture-code"]
            case .denied: pending = ["/oauth2/callback?state=\(state)&error=access_denied"]
            default: break
            }
            return mode != .browserFailure
        }
    }
    private func next() async throws -> GoogleDriveLoopbackCallback {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if closed { continuation.resume(throwing: CancellationError()) }
                    else if !pending.isEmpty { continuation.resume(returning: callback(pending.removeFirst())) }
                    else { waiter = continuation }
                }
            }
        }, onCancel: { self.stop() })
    }
    private func callback(_ target: String) -> GoogleDriveLoopbackCallback {
        GoogleDriveLoopbackCallback(target: target, respond: { accepted in self.lock.withLock { self.replies.append(accepted) } })
    }
    private func stop() {
        lock.withLock {
            closed = true
            waiter?.resume(throwing: CancellationError())
            waiter = nil
        }
    }
}
