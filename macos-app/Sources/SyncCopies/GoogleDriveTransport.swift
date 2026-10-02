import Foundation
import Network
import SyncCopiesCore

enum GoogleDriveTransportFailure: Error, Equatable, Sendable {
    case disallowedRequest, invalidAccessToken, invalidResponse, responseTooLarge, redirect
    case noNetwork, unreachable, requestRejected, authorizationRejected, accessDenied, resourceUnavailable
    case overloaded, providerUnavailable
}

struct GoogleDriveHTTPReply: Sendable {
    let statusCode: Int
    let body: Data
}

/// The session never follows redirects, stores cookies, credentials or cached responses.
final class GoogleDriveHTTPClient: Sendable {
    private let session: URLSession

    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: GoogleDriveRedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> GoogleDriveHTTPReply {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            throw GoogleDriveTransportFailure.invalidResponse
        }
        guard !(300..<400).contains(response.statusCode) else { throw GoogleDriveTransportFailure.redirect }
        if request.httpMethod == "HEAD" { return GoogleDriveHTTPReply(statusCode: response.statusCode, body: Data()) }
        guard response.expectedContentLength <= 1_048_576 else { throw GoogleDriveTransportFailure.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            guard body.count < 1_048_576 else { throw GoogleDriveTransportFailure.responseTooLarge }
            body.append(byte)
        }
        try Task.checkCancellation()
        return GoogleDriveHTTPReply(statusCode: response.statusCode, body: body)
    }
}

final class GoogleDriveRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// NWPathMonitor reports route availability. Endpoint probing separately proves DNS, TCP and TLS readiness.
private final class GoogleDriveRoute: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var reachable = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.reachable = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "cloud.diesis.sync-copies.google-route"))
    }

    deinit { monitor.cancel() }
    func available() -> Bool { lock.withLock { reachable } }
}

struct GoogleDriveReadiness: Sendable {
    let routeAvailable: @Sendable () -> Bool
    let send: @Sendable (URLRequest) async throws -> GoogleDriveHTTPReply
    let uptime: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void

    func wait(host: String) async throws {
        guard ["www.googleapis.com", "oauth2.googleapis.com"].contains(host),
              let url = URL(string: "https://\(host)/") else { throw GoogleDriveTransportFailure.disallowedRequest }
        let deadline = uptime() + 30
        var failure = GoogleDriveTransportFailure.noNetwork
        while true {
            try Task.checkCancellation()
            let remaining = deadline - uptime()
            if remaining <= 0 { throw failure }
            if routeAvailable() {
                failure = .unreachable
                var probe = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(3, remaining))
                probe.httpMethod = "HEAD"
                do {
                    // All HTTP statuses prove a connection; a credential-free redirect also reached the endpoint.
                    _ = try await send(probe)
                    return
                } catch GoogleDriveTransportFailure.redirect {
                    return
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                }
            }
            let remainingAfterProbe = deadline - uptime()
            if remainingAfterProbe <= 0 { throw failure }
            try await sleep(min(2, remainingAfterProbe))
        }
    }
}

struct GoogleDriveTransport: Sendable {
    let send: @Sendable (URLRequest) async throws -> GoogleDriveHTTPReply
    let ready: @Sendable (String) async throws -> Void
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static func live() -> Self {
        let client = GoogleDriveHTTPClient()
        let route = GoogleDriveRoute()
        let sleeper: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
        let readiness = GoogleDriveReadiness(routeAvailable: { route.available() }, send: { try await client.send($0) },
                                            uptime: { ProcessInfo.processInfo.systemUptime }, sleep: sleeper)
        return Self(send: { try await client.send($0) }, ready: { try await readiness.wait(host: $0) }, sleep: sleeper)
    }

    func metadata(_ description: GoogleDriveMetadataRequest, accessToken: String) async throws -> Data {
        var request = URLRequest(url: description.url)
        request.httpMethod = description.method
        try authorize(&request, token: accessToken)
        return try await execute(request)
    }

    func oauth(_ description: GoogleDriveOAuthRequest) async throws -> Data {
        var request = URLRequest(url: description.url)
        request.httpMethod = description.method
        request.httpBody = description.body
        for (key, value) in description.headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await execute(request)
    }

    func identity(accessToken: String) async throws -> GoogleDriveIdentity {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user%28permissionId%2CemailAddress%2CdisplayName%2Cme%29") else {
            throw GoogleDriveTransportFailure.disallowedRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try authorize(&request, token: accessToken)
        return try GoogleDriveIdentity.decode(try await execute(request))
    }

    private func authorize(_ request: inout URLRequest, token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 16_384,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw GoogleDriveTransportFailure.invalidAccessToken
        }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }

    private func execute(_ original: URLRequest) async throws -> Data {
        guard allowedGoogleDriveRequest(original), let host = original.url?.host else {
            throw GoogleDriveTransportFailure.disallowedRequest
        }
        var request = original
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<4 {
            try Task.checkCancellation()
            try await ready(host)
            let failure: GoogleDriveTransportFailure
            do {
                let reply = try await send(request)
                guard reply.body.count <= 1_048_576 else { throw GoogleDriveTransportFailure.responseTooLarge }
                if (200..<300).contains(reply.statusCode) { return reply.body }
                switch reply.statusCode {
                case 300..<400: throw GoogleDriveTransportFailure.redirect
                case 400: throw host == "oauth2.googleapis.com" ? GoogleDriveTransportFailure.authorizationRejected : .requestRejected
                case 401: throw GoogleDriveTransportFailure.authorizationRejected
                case 403: throw GoogleDriveTransportFailure.accessDenied
                case 404: throw GoogleDriveTransportFailure.resourceUnavailable
                case 429: failure = .overloaded
                case 500..<600: failure = .providerUnavailable
                default: throw GoogleDriveTransportFailure.invalidResponse
                }
            } catch let error as GoogleDriveTransportFailure {
                if error != .unreachable { throw error }
                failure = .unreachable
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                failure = .unreachable
            }
            if attempt == 3 { throw failure }
            try await sleep(TimeInterval(1 << (attempt + 1)))
        }
        throw GoogleDriveTransportFailure.providerUnavailable
    }
}

/// Defense at the effect boundary, including fields and queries, even for core-generated requests.
func allowedGoogleDriveRequest(_ request: URLRequest) -> Bool {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme == "https", components.user == nil, components.password == nil,
          components.port == nil, components.fragment == nil else { return false }
    if request.httpMethod == "POST" {
        return components.host == "oauth2.googleapis.com" && ["/token", "/revoke"].contains(components.path)
            && components.query == nil && request.value(forHTTPHeaderField: "Authorization") == nil
            && request.httpBody.map({ !$0.isEmpty && $0.count <= 262_144 }) == true
            && request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
    }
    guard request.httpMethod == "GET", components.host == "www.googleapis.com", request.httpBody == nil,
          let items = components.queryItems, Set(items.map(\.name)).count == items.count,
          items.allSatisfy({ $0.value != nil }) else { return false }
    let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    if components.path == "/drive/v3/about" {
        return fields == ["fields": "user(permissionId,emailAddress,displayName,me)"]
    }
    if components.path.hasPrefix("/drive/v3/files/") {
        let id = String(components.path.dropFirst("/drive/v3/files/".count))
        return (try? GoogleDriveMetadata.folderRequest(id: id)) != nil
            && fields == ["fields": "id,name,mimeType,trashed", "supportsAllDrives": "true"]
    }
    return components.path == "/drive/v3/files"
        && Set(fields.keys) == (fields["pageToken"] == nil
            ? Set(["q", "fields", "spaces", "pageSize", "supportsAllDrives", "includeItemsFromAllDrives"])
            : Set(["q", "fields", "spaces", "pageSize", "supportsAllDrives", "includeItemsFromAllDrives", "pageToken"]))
        && fields["fields"] == "nextPageToken,incompleteSearch,files(id,name,parents,trashed,size,md5Checksum,sha256Checksum)"
        && fields["spaces"] == "drive" && fields["pageSize"] == "100"
        && fields["supportsAllDrives"] == "true" && fields["includeItemsFromAllDrives"] == "true"
}
