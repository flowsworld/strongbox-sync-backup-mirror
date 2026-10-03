import Foundation
import Testing
import SyncCopiesCore

struct GoogleDriveOAuthTests {
    private let state = String(repeating: "s", count: 43)
    // RFC 7636, appendix B. Expected challenge is independent of this implementation.
    private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    private func session() throws -> GoogleDriveOAuthSession {
        try GoogleDriveOAuthSession(
            client: GoogleDriveOAuthClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "public-client-secret"),
            loopbackPort: 49152, state: state, verifier: verifier, clock: { 1_000 }
        )
    }

    @Test func browserRequestUsesExactMetadataScopeAndPKCE() throws {
        let url = try session().authorizationURL()
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map { ($0.name, $0.value) })
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        #expect(parameters["scope"] == "https://www.googleapis.com/auth/drive.metadata.readonly")
        #expect(parameters["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(parameters["state"] == state)
        #expect(parameters["response_type"] == "code")
        #expect(parameters["access_type"] == "offline")
        #expect(parameters["prompt"] == "consent")
        #expect(parameters["redirect_uri"] == "http://127.0.0.1:49152/oauth2/callback")
        #expect(parameters["client_secret"] == nil)
        #expect(parameters["code_verifier"] == nil)
    }

    @Test func validCallbackMakesOneFormEncodedExchangeAndCannotReplay() throws {
        var attempt = try session()
        let request = try attempt.consumeCallback(target: "/oauth2/callback?state=\(state)&code=code%2B%2F%26%3D")
        #expect(request.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.method == "POST")
        #expect(request.headers == ["Content-Type": "application/x-www-form-urlencoded"])
        let form = try #require(String(data: request.body, encoding: .utf8))
        #expect(form.contains("code=code%2B%2F%26%3D"))
        #expect(form.contains("grant_type=authorization_code"))
        #expect(form.contains("code_verifier=\(verifier)"))
        #expect(form.contains("client_secret=public-client-secret"))
        #expect(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Foauth2%2Fcallback"))
        #expect(!request.url.absoluteString.contains("code"))
        #expect(throws: GoogleDriveOAuthFailure.sessionConsumed) {
            try attempt.consumeCallback(target: "/oauth2/callback?state=\(state)&code=next")
        }
    }

    @Test func initialTokenResponseRequiresOfflineAccessAndExactScope() throws {
        let json = Data("""
        {"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,
         "token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.metadata.readonly"}
        """.utf8)
        let tokens = try GoogleDriveOAuthTokens.decodeResponse(json, receivedAt: 1_000)
        #expect(tokens.accessToken == "synthetic-access")
        #expect(tokens.refreshToken == "synthetic-refresh")
        #expect(tokens.expiresAt == 4_600)
        #expect(!String(reflecting: tokens).contains("synthetic-access"))
        let withoutRefresh = Data(#"{"access_token":"a","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        #expect(throws: GoogleDriveOAuthFailure.missingRefreshToken) {
            try GoogleDriveOAuthTokens.decodeResponse(withoutRefresh, receivedAt: 1_000)
        }
    }

    @Test(arguments: [
        "/oauth2/callback?state=wrong&code=c",
        "/oauth2/callback?code=c",
        "/oauth2/callback?state=STATE&code=c&code=d",
        "/oauth2/callback?state=STATE&st%61te=STATE&code=c",
        "/oauth2/callback?state=STATE&code=c&extra=1&extra=2",
        "/oauth2/callback?state=STATE&code=c&error=access_denied",
        "/oauth2/callback?state=STATE",
        "/oauth2/callback?state=STATE&code=",
        "/oauth2/callback?state=STATE&error=",
        "/oauth2/callback?state=STATE&code=%00",
        "/oauth2/callback?state=STATE&code=%GG",
        "/oauth2/callback?state=STATE&code=%FF",
        "/oauth2/callback?state=STATE&code=has+space",
        "/oauth2/callback?state=STATE&code=c#fragment",
        "/oauth2/callback?state=STATE&code=c&",
        "/oauth2/callback?state=STATE&code=c&novalue",
        "http://127.0.0.1:49152/oauth2/callback?state=STATE&code=c",
        "//127.0.0.1/oauth2/callback?state=STATE&code=c",
        "/oauth2/callback/?state=STATE&code=c",
        "/oauth2/%63allback?state=STATE&code=c",
        "/other?state=STATE&code=c",
    ])
    func malformedCallbacksCannotConsumeTheLiveAttempt(_ target: String) throws {
        var attempt = try session()
        #expect(throws: GoogleDriveOAuthFailure.invalidCallback) {
            try attempt.consumeCallback(target: target.replacingOccurrences(of: "STATE", with: state))
        }
        _ = try attempt.consumeCallback(target: "/oauth2/callback?state=\(state)&code=valid")
    }

    @Test func callbackBoundsRejectOversizedRequestsAndTooManyFields() throws {
        for suffix in [String(repeating: "c", count: 32_768), "c" + (1...19).map { "&p\($0)=v" }.joined()] {
            var attempt = try session()
            #expect(throws: GoogleDriveOAuthFailure.invalidCallback) {
                try attempt.consumeCallback(target: "/oauth2/callback?state=\(state)&code=\(suffix)")
            }
        }
    }

    @Test func denialAndCancellationAreTerminalAndNeverExposeGoogleErrors() throws {
        var denied = try session()
        #expect(throws: GoogleDriveOAuthFailure.denied) {
            try denied.consumeCallback(target: "/oauth2/callback?state=\(state)&error=sensitive-message")
        }
        #expect(throws: GoogleDriveOAuthFailure.sessionConsumed) { try denied.authorizationURL() }
        var cancelled = try session()
        cancelled.cancel()
        #expect(throws: GoogleDriveOAuthFailure.cancelled) {
            try cancelled.consumeCallback(target: "/oauth2/callback?state=\(state)&code=c")
        }
        #expect(GoogleDriveOAuthFailure.denied.errorDescription == "Google sign-in was denied.")
    }

    @Test func callbackExpiresAtFiveMinutesAndCannotReviveAfterClockMovesBack() throws {
        let time = OAuthTestClock()
        var attempt = try GoogleDriveOAuthSession(
            client: GoogleDriveOAuthClient(clientID: "fixture.apps.googleusercontent.com"),
            loopbackPort: 49152, state: state, verifier: verifier, clock: { time.now() }
        )
        time.set(1_299)
        _ = try attempt.authorizationURL()
        time.set(1_300)
        #expect(throws: GoogleDriveOAuthFailure.expired) {
            try attempt.consumeCallback(target: "/oauth2/callback?state=\(state)&code=c")
        }
        time.set(1_001)
        #expect(throws: GoogleDriveOAuthFailure.expired) { try attempt.authorizationURL() }
    }

    @Test func defaultSessionsProduceFreshStateAndVerifierChallenges() throws {
        let client = try GoogleDriveOAuthClient(clientID: "fixture.apps.googleusercontent.com")
        let first = try GoogleDriveOAuthSession(client: client, loopbackPort: 49152).authorizationURL()
        let second = try GoogleDriveOAuthSession(client: client, loopbackPort: 49152).authorizationURL()
        let a = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems)
        let b = try #require(URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems)
        for key in ["state", "code_challenge"] {
            let av = try #require(a.first(where: { $0.name == key })?.value)
            let bv = try #require(b.first(where: { $0.name == key })?.value)
            #expect(av.utf8.count == 43)
            #expect(av != bv)
        }
    }

    @Test func refreshAndExplicitRevocationKeepTokensInEncodedBodies() throws {
        let client = try GoogleDriveOAuthClient(clientID: "fixture.apps.googleusercontent.com")
        let refresh = try client.refreshRequest(refreshToken: "synthetic+token/&=")
        #expect(refresh.url.absoluteString == "https://oauth2.googleapis.com/token")
        let body = try #require(String(data: refresh.body, encoding: .utf8))
        #expect(body == "client_id=fixture.apps.googleusercontent.com&grant_type=refresh_token&refresh_token=synthetic%2Btoken%2F%26%3D")
        #expect(!body.contains("client_secret"))
        let revoke = try client.revocationRequest(token: "synthetic+token/&=")
        #expect(revoke.url.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(String(data: revoke.body, encoding: .utf8) == "token=synthetic%2Btoken%2F%26%3D")
        #expect(!String(reflecting: refresh).contains("synthetic"))
        #expect(!String(reflecting: client).contains("fixture"))
        #expect(!String(reflecting: try session()).contains(state))
    }

    @Test func refreshRetainsExistingRefreshTokenButAcceptsValidatedRotation() throws {
        let response = Data(#"{"access_token":"new","expires_in":3600,"token_type":"bearer"}"#.utf8)
        let retained = try GoogleDriveOAuthTokens.decodeResponse(response, existingRefreshToken: "previous", receivedAt: 1_000)
        #expect(retained.refreshToken == "previous")
        let rotated = Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        #expect(try GoogleDriveOAuthTokens.decodeResponse(rotated, existingRefreshToken: "previous", receivedAt: 1_000).refreshToken == "rotated")
    }

    @Test(arguments: [
        #"{}"#,
        #"[]"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":true,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":"3600","token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":0,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":86401,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":0.5,"token_type":"Bearer"}"#,
        #"{"access_token":"","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"a\nsecret","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":true,"refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":null,"expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"MAC"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"Bearer","scope":null}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"Bearer","error":"sensitive"}"#,
    ])
    func malformedTokenResponsesHaveSafeFailures(_ json: String) throws {
        #expect(throws: GoogleDriveOAuthFailure.invalidTokenResponse) {
            try GoogleDriveOAuthTokens.decodeResponse(Data(json.utf8), receivedAt: 1_000)
        }
    }

    @Test(arguments: ["", "https://www.googleapis.com/auth/drive", "https://www.googleapis.com/auth/drive.metadata.readonly extra"])
    func unexpectedScopesNeverCreateCredentials(_ scope: String) throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": "a", "refresh_token": "r", "expires_in": 3600, "token_type": "Bearer", "scope": scope,
        ])
        #expect(throws: GoogleDriveOAuthFailure.unexpectedScope) {
            try GoogleDriveOAuthTokens.decodeResponse(response, receivedAt: 1_000)
        }
    }

    @Test func oversizedTokenAndResponseAndInvalidClockAreRejected() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": String(repeating: "a", count: 16_385), "refresh_token": "r",
            "expires_in": 3600, "token_type": "Bearer",
        ])
        for value in [response, Data(repeating: 32, count: 1_048_577)] {
            #expect(throws: GoogleDriveOAuthFailure.invalidTokenResponse) {
                try GoogleDriveOAuthTokens.decodeResponse(value, receivedAt: 1_000)
            }
        }
        let valid = Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        #expect(throws: GoogleDriveOAuthFailure.invalidTokenResponse) {
            try GoogleDriveOAuthTokens.decodeResponse(valid, receivedAt: .nan)
        }
    }
}

/// The lock protects the injected clock across Sendable closures; this never changes system time.
private final class OAuthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
