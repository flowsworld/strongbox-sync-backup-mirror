import AppKit
import Foundation
import Network
import SyncCopiesCore

enum GoogleDriveSignInFailure: Error, Equatable, Sendable {
    case busy, browserUnavailable, receiverUnavailable, invalidLocalRequest, clientNotConfigured
}

enum GoogleDriveNativeClient {
    static func from(bundle: Bundle = .main) throws -> GoogleDriveOAuthClient {
        guard let id = bundle.object(forInfoDictionaryKey: "GoogleDriveOAuthClientID") as? String else {
            throw GoogleDriveSignInFailure.clientNotConfigured
        }
        let configuredSecret = bundle.object(forInfoDictionaryKey: "GoogleDriveOAuthClientSecret")
        guard configuredSecret == nil || configuredSecret is String else { throw GoogleDriveOAuthFailure.invalidClient }
        return try GoogleDriveOAuthClient(clientID: id, clientSecret: configuredSecret as? String)
    }
}

struct GoogleDriveLoopbackCallback: Sendable {
    let target: String
    let respond: @Sendable (Bool) async -> Void
}

struct GoogleDriveSignInReceiver: Sendable {
    let port: UInt16
    let next: @Sendable () async throws -> GoogleDriveLoopbackCallback
    let stop: @Sendable () -> Void
}

struct GoogleDriveSignInEnvironment: Sendable {
    let receiver: @Sendable () async throws -> GoogleDriveSignInReceiver
    let openBrowser: @MainActor @Sendable (URL) -> Bool
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let clock: @Sendable () -> TimeInterval

    static func live() -> Self {
        Self(receiver: {
            let receiver = try GoogleDriveLoopbackReceiver()
            let port = try await receiver.start()
            return GoogleDriveSignInReceiver(port: port, next: { try await receiver.next() }, stop: { receiver.stop() })
        }, openBrowser: { NSWorkspace.shared.open($0) }, sleep: { try await Task.sleep(for: .seconds($0)) },
             clock: { Date().timeIntervalSince1970 })
    }
}

struct GoogleDriveSignInResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identity: GoogleDriveIdentity
    let tokens: GoogleDriveOAuthTokens
    var description: String { "Google sign-in result, tokens redacted" }
    var debugDescription: String { description }
}

/// One owned task serializes a complete browser attempt; cancellation closes its listener.
actor GoogleDriveSignIn {
    private let client: GoogleDriveOAuthClient
    private let transport: GoogleDriveTransport
    private let environment: GoogleDriveSignInEnvironment
    private var active: Task<GoogleDriveSignInResult, any Error>?

    init(client: GoogleDriveOAuthClient, transport: GoogleDriveTransport, environment: GoogleDriveSignInEnvironment = .live()) {
        self.client = client
        self.transport = transport
        self.environment = environment
    }

    func cancel() { active?.cancel() }

    func authorize() async throws -> GoogleDriveSignInResult {
        guard active == nil else { throw GoogleDriveSignInFailure.busy }
        let client = self.client, transport = self.transport, environment = self.environment
        let task = Task {
            try Task.checkCancellation()
            let receiver = try await environment.receiver()
            defer { receiver.stop() }
            let initial = try GoogleDriveOAuthSession(client: client, loopbackPort: receiver.port, clock: environment.clock)
            guard await environment.openBrowser(try initial.authorizationURL()) else { throw GoogleDriveSignInFailure.browserUnavailable }
            let request = try await withThrowingTaskGroup(of: GoogleDriveOAuthRequest.self) { group in
                defer { group.cancelAll(); receiver.stop() }
                group.addTask {
                    var session = initial
                    while true {
                        try Task.checkCancellation()
                        let callback = try await receiver.next()
                        do {
                            let request = try session.consumeCallback(target: callback.target)
                            await callback.respond(true)
                            return request
                        } catch GoogleDriveOAuthFailure.invalidCallback {
                            await callback.respond(false)
                        } catch GoogleDriveOAuthFailure.denied {
                            await callback.respond(true)
                            throw GoogleDriveOAuthFailure.denied
                        } catch {
                            await callback.respond(false)
                            throw error
                        }
                    }
                }
                group.addTask {
                    try await environment.sleep(300)
                    throw GoogleDriveOAuthFailure.expired
                }
                guard let request = try await group.next() else { throw GoogleDriveSignInFailure.receiverUnavailable }
                return request
            }
            try Task.checkCancellation()
            let response = try await transport.oauth(request)
            let tokens = try GoogleDriveOAuthTokens.decodeResponse(response, receivedAt: environment.clock())
            let identity = try await transport.identity(accessToken: tokens.accessToken)
            try Task.checkCancellation()
            return GoogleDriveSignInResult(identity: identity, tokens: tokens)
        }
        active = task
        defer { active = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

/// All mutable state belongs to `queue`. Only its callbacks touch listener/connection continuations.
final class GoogleDriveLoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cloud.diesis.sync-copies.google-oauth-loopback")
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var callbackContinuation: CheckedContinuation<GoogleDriveLoopbackCallback, any Error>?
    private var callbacks: [GoogleDriveLoopbackCallback] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var started = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        do { listener = try NWListener(using: parameters, on: .any) }
        catch { throw GoogleDriveSignInFailure.receiverUnavailable }
    }

    deinit { listener.cancel(); connections.values.forEach { $0.cancel() } }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                    guard !self.started else { continuation.resume(throwing: GoogleDriveSignInFailure.busy); return }
                    self.started = true
                    self.startContinuation = continuation
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener.port?.rawValue else { self.close(.receiverUnavailable); return }
                            self.startContinuation?.resume(returning: port)
                            self.startContinuation = nil
                        case .failed: self.close(.receiverUnavailable)
                        default: break
                        }
                    }
                    self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    self.listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 5) {
                        if self.startContinuation != nil { self.close(.receiverUnavailable) }
                    }
                }
            }
        }, onCancel: { self.stop() })
    }

    func next() async throws -> GoogleDriveLoopbackCallback {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                    guard self.callbackContinuation == nil else { continuation.resume(throwing: GoogleDriveSignInFailure.busy); return }
                    if !self.callbacks.isEmpty { continuation.resume(returning: self.callbacks.removeFirst()) }
                    else { self.callbackContinuation = continuation }
                }
            }
        }, onCancel: { self.stop() })
    }

    func stop() { queue.async { self.close(nil) } }

    private func close(_ failure: GoogleDriveSignInFailure?) {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        callbacks.removeAll()
        let error: any Error = failure ?? CancellationError()
        startContinuation?.resume(throwing: error)
        startContinuation = nil
        callbackContinuation?.resume(throwing: error)
        callbackContinuation = nil
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            if self.connections.removeValue(forKey: id) != nil { connection.cancel() }
        }
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var received = accumulated
            if let data { received.append(data) }
            guard error == nil, received.count <= 40_960 else { self.respond(connection, accepted: false); return }
            if let range = received.range(of: Data("\r\n\r\n".utf8)) {
                guard range.upperBound == received.endIndex, let port = self.listener.port?.rawValue,
                      let target = try? Self.parseRequest(received, port: port) else { self.respond(connection, accepted: false); return }
                let callback = GoogleDriveLoopbackCallback(target: target, respond: { accepted in
                    await withCheckedContinuation { continuation in
                        self.queue.async { self.respond(connection, accepted: accepted, completion: { continuation.resume() }) }
                    }
                })
                if let continuation = self.callbackContinuation {
                    self.callbackContinuation = nil
                    continuation.resume(returning: callback)
                } else if self.callbacks.count < 8 { self.callbacks.append(callback) }
                else { self.respond(connection, accepted: false) }
            } else if complete { self.respond(connection, accepted: false) }
            else { self.receive(connection, accumulated: received) }
        }
    }

    private func respond(_ connection: NWConnection, accepted: Bool, completion: @escaping @Sendable () -> Void = {}) {
        guard !stopped, connections[ObjectIdentifier(connection)] != nil else { connection.cancel(); completion(); return }
        let body = accepted ? "Sign-in received. You can close this window." : "Invalid local sign-in request."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            completion()
        })
    }

    static func parseRequest(_ data: Data, port: UInt16) throws -> String {
        guard data.count <= 40_960, data.allSatisfy({ $0 == 13 || $0 == 10 || (32...126).contains($0) }),
              let text = String(data: data, encoding: .ascii), text.hasSuffix("\r\n\r\n") else {
            throw GoogleDriveSignInFailure.invalidLocalRequest
        }
        // CRLF is one Swift grapheme. Remove the four terminator bytes rather than four characters.
        let lines = String(decoding: data.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 100,
              lines.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else { throw GoogleDriveSignInFailure.invalidLocalRequest }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(request[2]),
              request[1].hasPrefix("/"), !request[1].hasPrefix("//") else { throw GoogleDriveSignInFailure.invalidLocalRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw GoogleDriveSignInFailure.invalidLocalRequest }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let punctuation = "!#$%&'*+-.^_`|~".utf8
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) }),
                  headers[name] == nil else { throw GoogleDriveSignInFailure.invalidLocalRequest }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else {
            throw GoogleDriveSignInFailure.invalidLocalRequest
        }
        return String(request[1])
    }
}
