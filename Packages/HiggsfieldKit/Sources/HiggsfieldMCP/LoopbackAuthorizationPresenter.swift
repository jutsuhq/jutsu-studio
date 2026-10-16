#if canImport(Network)
    import Foundation
    import Network
    import os

    private let logger = Logger(subsystem: "com.jutsustudio", category: "OAuthRedirect")

    /// `AuthorizationPresenter` with a loopback redirect (RFC 8252 §7.3): listens on `127.0.0.1` on the first
    /// free registered port, opens the authorization URL in the user's default browser and waits, for at most
    /// `timeout`, for the browser to hit `/callback` with the request's `state`. Unlike
    /// `ASWebAuthenticationSession`, this works whichever browser is the default: Chrome doesn't pass a
    /// custom-scheme redirect that follows a form POST (the consent page's Allow button) back to the app.
    public struct LoopbackAuthorizationPresenter: AuthorizationPresenter {
        public static let defaultTimeout = Duration.seconds(10 * 60)

        private let ports: [UInt16]
        private let timeout: Duration
        private let open: @Sendable (URL) async throws -> Void

        /// - Parameters:
        ///   - timeout: how long the user has to finish in the browser; then sign-in fails with
        ///     `OAuthError.timedOut`.
        ///   - open: opens a URL in the default browser; throws when it can't, which ends the sign-in.
        public init(
            ports: [UInt16] = ClientRegistration.loopbackPorts, timeout: Duration = Self.defaultTimeout,
            open: @escaping @Sendable (URL) async throws -> Void
        ) {
            self.ports = ports
            self.timeout = timeout
            self.open = open
        }

        public func authorize(
            makeURL: @Sendable (_ redirectURI: String) throws -> URL
        ) async throws -> AuthorizationRedirect {
            let receiver = try await LoopbackReceiver.listen(onFirstFreeOf: ports)
            defer { receiver.stop() }
            let redirectURI = ClientRegistration.redirectURI(port: receiver.port)
            let url = try makeURL(redirectURI)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "state" }?.value
            receiver.redirects.expect(state: state)
            try await open(url)
            return AuthorizationRedirect(
                callback: try await receiver.callback(timeout: timeout), redirectURI: redirectURI)
        }
    }

    /// One listener on `127.0.0.1:port` that answers every `GET /callback` and hands the expected one over.
    final class LoopbackReceiver: @unchecked Sendable {  // listener and connections are driven on `queue`
        let port: UInt16
        private let listener: NWListener
        private let queue = DispatchQueue(label: "com.jutsustudio.oauth-redirect")
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        let redirects = RedirectWaiter()

        private init(port: UInt16, listener: NWListener) {
            self.port = port
            self.listener = listener
        }

        /// Tries `ports` in order and returns the first receiver that is listening.
        static func listen(onFirstFreeOf ports: [UInt16]) async throws -> LoopbackReceiver {
            for port in ports {
                do {
                    return try await listen(on: port)
                } catch {
                    logger.info("Port \(port) unavailable: \(String(describing: error), privacy: .private)")
                }
            }
            throw OAuthError.redirectUnavailable
        }

        private static func listen(on port: UInt16) async throws -> LoopbackReceiver {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw OAuthError.redirectUnavailable }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            let receiver = LoopbackReceiver(port: port, listener: try NWListener(using: parameters))
            try await receiver.start()
            return receiver
        }

        /// Resolves once the listener is ready; throws when the port can't be bound.
        private func start() async throws {
            let started = Once()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                listener.stateUpdateHandler = { [weak self, listener] state in
                    switch state {
                    case .ready:
                        if started.claim() { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        listener.cancel()
                        if started.claim() {
                            continuation.resume(throwing: error)
                        } else {
                            self?.redirects.fail(error)
                        }
                    case .cancelled:
                        if started.claim() { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                listener.start(queue: queue)
            }
        }

        /// The redirect to `/callback` that `redirects` expects. Cancelling the task stops waiting with
        /// `CancellationError`.
        func callback(timeout: Duration = LoopbackAuthorizationPresenter.defaultTimeout) async throws -> URL {
            try await redirects.wait(timeout: timeout)
        }

        func stop() {
            listener.cancel()
            queue.async { [self] in
                for connection in connections.values { connection.cancel() }
                connections.removeAll()
            }
        }

        private func handle(_ connection: NWConnection) {
            let id = ObjectIdentifier(connection)
            connections[id] = connection
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.connections.removeValue(forKey: id)?.cancel()
            }
            receive(connection, buffer: Data())
        }

        /// TCP can split even the request line. Bound the full header and wait for its terminator.
        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024 - buffer.count) {
                [weak self] data, _, complete, error in
                guard let self else { return connection.cancel() }
                var request = buffer
                if let data { request.append(data) }
                guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete || error != nil {
                        connections.removeValue(forKey: ObjectIdentifier(connection))
                        return connection.cancel()
                    }
                    guard request.count < 16 * 1024 else {
                        connections.removeValue(forKey: ObjectIdentifier(connection))
                        return Self.respond(
                            to: connection, status: "431 Request Header Fields Too Large", body: "Too large")
                    }
                    return receive(connection, buffer: request)
                }
                connections.removeValue(forKey: ObjectIdentifier(connection))
                let target = Self.requestTarget(of: request)
                guard let target, target.hasPrefix("/callback?") || target == "/callback",
                    let url = URL(string: "http://127.0.0.1:\(port)\(target)")
                else {
                    return Self.respond(to: connection, status: "404 Not Found", body: "Not found")
                }
                guard redirects.accepts(url) else {
                    return Self.respond(to: connection, status: "400 Bad Request", body: "Not this sign-in")
                }
                Self.respond(to: connection, status: "200 OK", body: Self.page(for: url))
                redirects.offer(url)
            }
        }

        /// The path and query of an HTTP GET request line, e.g. `/callback?code=…`.
        static func requestTarget(of request: Data) -> String? {
            guard let text = String(data: request.prefix(8 * 1024), encoding: .utf8),
                let line = text.split(separator: "\r\n", maxSplits: 1).first
            else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/") else { return nil }
            return String(parts[1])
        }

        private static func respond(to connection: NWConnection, status: String, body: String) {
            let payload = Data(body.utf8)
            let head =
                "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + payload,
                completion: .contentProcessed { _ in connection.cancel() })
        }

        /// What the browser tab shows after the redirect: the outcome and a hint to go back to the app.
        static func page(for callback: URL) -> String {
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let failed = items.contains { $0.name == "error" }
            // The app still checks `state` and exchanges the code, so success here is only the approval.
            let title = failed ? "Sign-in was not completed" : "Access approved"
            let detail =
                failed
                ? "Return to Jutsu Studio to try again, or connect with an API key instead."
                : "Jutsu Studio finishes signing in. You can close this tab."
            return """
                <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Jutsu Studio</title>
                <meta name="viewport" content="width=device-width,initial-scale=1">
                <style>
                body{margin:0;min-height:100vh;display:grid;place-items:center;background:#060607;color:#fff;
                font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
                main{text-align:center;padding:24px}
                .mark{width:56px;height:56px;margin:0 auto 20px;border-radius:14px;
                background:linear-gradient(135deg,#8b5cf6,#d946ef 55%,#f472b6)}
                h1{margin:0 0 6px;font-size:22px}p{margin:0;color:rgba(255,255,255,.6)}
                </style></head><body><main><div class="mark"></div>
                <h1>\(title)</h1><p>\(detail)</p></main></body></html>
                """
        }
    }

    /// A flag that can be claimed once, from any thread.
    private final class Once: @unchecked Sendable {  // `claimed` is only touched under `lock`
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
#endif
