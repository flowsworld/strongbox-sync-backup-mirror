import CryptoKit
import Foundation
import Security

public enum GoogleDriveOAuthFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidClient, invalidSession, randomUnavailable, invalidCallback
    case sessionConsumed, cancelled, expired, denied, invalidTokenResponse, missingRefreshToken, unexpectedScope

    public var errorDescription: String? {
        switch self {
        case .invalidClient: "Invalid Google desktop client configuration."
        case .invalidSession: "Invalid Google sign-in session."
        case .randomUnavailable: "Secure Google sign-in initialization failed."
        case .invalidCallback: "Invalid Google sign-in response."
        case .sessionConsumed: "Google sign-in response was already received."
        case .cancelled: "Google sign-in was cancelled."
        case .expired: "Google sign-in expired."
        case .denied: "Google sign-in was denied."
        case .invalidTokenResponse: "Invalid Google token response."
        case .missingRefreshToken: "Google did not return offline access."
        case .unexpectedScope: "Google did not grant exactly read-only Drive metadata access."
        }
    }
}

/// Desktop client configuration is public. User tokens are separate credentials.
public struct GoogleDriveOAuthClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let clientID: String
    fileprivate let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) throws {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), clientID.utf8.count <= 16_384,
              !clientID.dropLast(suffix.count).isEmpty,
              clientID.dropLast(suffix.count).utf8.allSatisfy({ oauthIdentifierByte($0) }),
              clientSecret.map(oauthCredentialIsValid) ?? true else {
            throw GoogleDriveOAuthFailure.invalidClient
        }
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var description: String { "Google desktop OAuth client" }
    public var debugDescription: String { description }

    public func refreshRequest(refreshToken: String) throws -> GoogleDriveOAuthRequest {
        guard oauthCredentialIsValid(refreshToken) else { throw GoogleDriveOAuthFailure.invalidTokenResponse }
        return try GoogleDriveOAuthRequest(endpoint: .token, fields: tokenClientFields + [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
        ])
    }

    /// Explicit revocation affects the Google grant. Local cancellation must not call this.
    public func revocationRequest(token: String) throws -> GoogleDriveOAuthRequest {
        guard oauthCredentialIsValid(token) else { throw GoogleDriveOAuthFailure.invalidTokenResponse }
        return try GoogleDriveOAuthRequest(endpoint: .revoke, fields: [("token", token)])
    }

    fileprivate var tokenClientFields: [(String, String)] {
        var fields = [("client_id", clientID)]
        if let clientSecret { fields.append(("client_secret", clientSecret)) }
        return fields
    }
}

/// A transport may send this form only to the fixed endpoint and must reject redirects.
public struct GoogleDriveOAuthRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let body: Data
    public var method: String { "POST" }
    public var headers: [String: String] { ["Content-Type": "application/x-www-form-urlencoded"] }

    fileprivate enum Endpoint: String { case token = "/token", revoke = "/revoke" }

    fileprivate init(endpoint: Endpoint, fields: [(String, String)]) throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "oauth2.googleapis.com"
        components.path = endpoint.rawValue
        guard let url = components.url else { throw GoogleDriveOAuthFailure.invalidSession }
        self.url = url
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        body = Data(try fields.map { key, value in
            guard let key = key.addingPercentEncoding(withAllowedCharacters: unreserved),
                  let value = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw GoogleDriveOAuthFailure.invalidTokenResponse
            }
            return "\(key)=\(value)"
        }.joined(separator: "&").utf8)
    }

    public var description: String { "Google OAuth POST request, body redacted" }
    public var debugDescription: String { description }
}

/// Validated tokens stay out of settings and diagnostics. Storage belongs to the credential adapter.
public struct GoogleDriveOAuthTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: TimeInterval

    private init(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Initial exchange requires a refresh token. A refresh response may retain an existing valid token.
    public static func decodeResponse(_ data: Data, existingRefreshToken: String? = nil,
                                      receivedAt: TimeInterval = Date().timeIntervalSince1970) throws -> Self {
        guard data.count <= 1_048_576, receivedAt.isFinite, receivedAt >= 0,
              existingRefreshToken.map(oauthCredentialIsValid) ?? true else {
            throw GoogleDriveOAuthFailure.invalidTokenResponse
        }
        let payload: TokenPayload
        do { payload = try JSONDecoder().decode(TokenPayload.self, from: data) }
        catch { throw GoogleDriveOAuthFailure.invalidTokenResponse }
        guard oauthCredentialIsValid(payload.accessToken),
              payload.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              (1...86_400).contains(payload.expiresIn),
              payload.refreshToken.map(oauthCredentialIsValid) ?? true else {
            throw GoogleDriveOAuthFailure.invalidTokenResponse
        }
        if let scope = payload.scope, scope != GoogleDriveOAuthSession.scope {
            throw GoogleDriveOAuthFailure.unexpectedScope
        }
        guard let refreshToken = payload.refreshToken ?? existingRefreshToken else {
            throw GoogleDriveOAuthFailure.missingRefreshToken
        }
        let expiresAt = receivedAt + TimeInterval(payload.expiresIn)
        guard expiresAt.isFinite, expiresAt > receivedAt else { throw GoogleDriveOAuthFailure.invalidTokenResponse }
        return Self(accessToken: payload.accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    public var description: String { "Google OAuth tokens, redacted" }
    public var debugDescription: String { description }

    private struct TokenPayload: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String
        let scope: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
            case tokenType = "token_type", scope, error
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard !values.contains(.error) else { throw GoogleDriveOAuthFailure.invalidTokenResponse }
            accessToken = try values.decode(String.self, forKey: .accessToken)
            expiresIn = try values.decode(Int.self, forKey: .expiresIn)
            tokenType = try values.decode(String.self, forKey: .tokenType)
            // Explicit null is malformed. Absence is meaningful for refresh responses and scope reporting.
            refreshToken = values.contains(.refreshToken) ? try values.decode(String.self, forKey: .refreshToken) : nil
            scope = values.contains(.scope) ? try values.decode(String.self, forKey: .scope) : nil
        }
    }
}

/// One value owns one attempt. The caller must serialize access and retain its mutated state.
public struct GoogleDriveOAuthSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let scope = "https://www.googleapis.com/auth/drive.metadata.readonly"
    private let client: GoogleDriveOAuthClient
    private let state: String
    private let verifier: String
    private let redirectURI: String
    private let startedAt: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var phase = Phase.waiting

    private enum Phase: Sendable { case waiting, consumed, cancelled, expired }

    public init(client: GoogleDriveOAuthClient, loopbackPort: UInt16,
                clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        try self.init(client: client, loopbackPort: loopbackPort,
                      state: oauthRandomString(byteCount: 32), verifier: oauthRandomString(byteCount: 64), clock: clock)
    }

    /// Explicit state/verifier input supports deterministic protocol fixtures without replacing cryptography.
    public init(client: GoogleDriveOAuthClient, loopbackPort: UInt16, state: String, verifier: String,
                clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        let startedAt = clock()
        guard loopbackPort > 0, oauthPKCEStringIsValid(state), oauthPKCEStringIsValid(verifier),
              startedAt.isFinite, startedAt >= 0, (startedAt + 300).isFinite else {
            throw GoogleDriveOAuthFailure.invalidSession
        }
        self.client = client
        self.state = state
        self.verifier = verifier
        redirectURI = "http://127.0.0.1:\(loopbackPort)/oauth2/callback"
        self.startedAt = startedAt
        self.clock = clock
    }

    public func authorizationURL() throws -> URL {
        try requireLiveSession()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/o/oauth2/v2/auth"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: oauthBase64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw GoogleDriveOAuthFailure.invalidSession }
        return url
    }

    /// Parses the HTTP origin-form target only. No callback values enter errors or diagnostics.
    public mutating func consumeCallback(target: String) throws -> GoogleDriveOAuthRequest {
        do { try requireLiveSession() }
        catch GoogleDriveOAuthFailure.expired {
            phase = .expired
            throw GoogleDriveOAuthFailure.expired
        }
        guard target.utf8.count <= 32_768, target.utf8.allSatisfy({ (33...126).contains($0) }),
              !target.contains("#") else { throw GoogleDriveOAuthFailure.invalidCallback }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "/oauth2/callback" else { throw GoogleDriveOAuthFailure.invalidCallback }
        let pairs = parts[1].split(separator: "&", omittingEmptySubsequences: false)
        guard pairs.count <= 20 else { throw GoogleDriveOAuthFailure.invalidCallback }
        var parameters: [String: String] = [:]
        for pair in pairs {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard field.count == 2,
                  let name = String(field[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(field[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !name.isEmpty, parameters[name] == nil else { throw GoogleDriveOAuthFailure.invalidCallback }
            parameters[name] = value
        }
        guard parameters["state"] == state,
              (parameters["code"] == nil) != (parameters["error"] == nil) else {
            throw GoogleDriveOAuthFailure.invalidCallback
        }
        if let error = parameters["error"] {
            guard oauthCredentialIsValid(error) else { throw GoogleDriveOAuthFailure.invalidCallback }
            phase = .consumed
            throw GoogleDriveOAuthFailure.denied
        }
        guard let code = parameters["code"], oauthCredentialIsValid(code) else { throw GoogleDriveOAuthFailure.invalidCallback }
        let request = try GoogleDriveOAuthRequest(endpoint: .token, fields: client.tokenClientFields + [
            ("grant_type", "authorization_code"), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", redirectURI),
        ])
        phase = .consumed
        return request
    }

    public mutating func cancel() {
        if phase == .waiting { phase = .cancelled }
    }

    private func requireLiveSession() throws {
        switch phase {
        case .consumed: throw GoogleDriveOAuthFailure.sessionConsumed
        case .cancelled: throw GoogleDriveOAuthFailure.cancelled
        case .expired: throw GoogleDriveOAuthFailure.expired
        case .waiting: break
        }
        let now = clock()
        guard now.isFinite, now >= startedAt, now < startedAt + 300 else { throw GoogleDriveOAuthFailure.expired }
    }

    public var description: String { "Google OAuth session" }
    public var debugDescription: String { description }
}

private func oauthIdentifierByte(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
}

private func oauthPKCEStringIsValid(_ value: String) -> Bool {
    (43...128).contains(value.utf8.count) && value.utf8.allSatisfy { oauthIdentifierByte($0) || $0 == 46 || $0 == 126 }
}

private func oauthCredentialIsValid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 16_384 &&
    !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
}

private func oauthBase64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func oauthRandomString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
    }
    guard status == errSecSuccess else { throw GoogleDriveOAuthFailure.randomUnavailable }
    return oauthBase64URL(Data(bytes))
}
