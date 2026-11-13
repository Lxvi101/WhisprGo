import CryptoKit
import Foundation
import Network
import Security

/// The ChatGPT browser sign-in: OAuth 2.0 authorization code with PKCE and a
/// loopback redirect. This is the same public-client flow the Codex CLI uses,
/// so its client ID and registered redirect URI are reused.
enum ChatGPTOAuth {
    static let issuer = URL(string: "https://auth.openai.com")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access"
    static let refreshScope = "openid profile email"
    static let signInTimeout: Duration = .seconds(600)

    static var tokenEndpoint: URL { issuer.appendingPathComponent("oauth/token") }

    struct PKCE: Equatable {
        let verifier: String
        let challenge: String

        init() {
            self.init(verifier: ChatGPTOAuth.randomURLSafeString(byteCount: 64))
        }

        init(verifier: String) {
            self.verifier = verifier
            challenge = ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    static func authorizeURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(
            url: issuer.appendingPathComponent("oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    /// Runs the whole browser sign-in and returns new credentials.
    /// `openURL` is called once the loopback listener is ready.
    static func signIn(
        session: URLSession,
        openURL: @escaping @Sendable (URL) async -> Void
    ) async throws -> ChatGPTCredentials {
        let pkce = PKCE()
        let state = randomURLSafeString(byteCount: 32)
        let server = ChatGPTLoopbackServer(port: callbackPort, path: callbackPath)
        try await server.start()
        defer { server.stop() }

        await openURL(authorizeURL(pkce: pkce, state: state))

        let callback = try await withThrowingTaskGroup(of: ChatGPTLoopbackServer.Callback.self) { group in
            group.addTask { try await server.nextCallback() }
            group.addTask {
                try await Task.sleep(for: signInTimeout)
                throw ChatGPTError.signInFailed("The browser sign-in timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }

        guard callback.parameters["state"] == state else {
            callback.respond(.failure("This sign-in link was not started by WhisprGo."))
            throw ChatGPTError.signInFailed("The browser returned an unexpected sign-in.")
        }
        if let error = callback.parameters["error"] {
            let detail = callback.parameters["error_description"] ?? error
            callback.respond(.failure(detail))
            throw ChatGPTError.signInFailed(detail)
        }
        guard let code = callback.parameters["code"], !code.isEmpty else {
            callback.respond(.failure("No authorization code was returned."))
            throw ChatGPTError.signInFailed("No authorization code was returned.")
        }

        do {
            let credentials = try await exchange(code: code, pkce: pkce, session: session)
            callback.respond(.success)
            return credentials
        } catch {
            callback.respond(.failure(error.localizedDescription))
            throw error
        }
    }

    static func exchange(
        code: String,
        pkce: PKCE,
        session: URLSession
    ) async throws -> ChatGPTCredentials {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ])
        let response = try await tokenRequest(request, session: session)
        guard let credentials = ChatGPTCredentials.make(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            idToken: response.idToken
        ) else {
            throw ChatGPTError.signInFailed("ChatGPT did not return a usable account.")
        }
        return credentials
    }

    static func refresh(
        _ credentials: ChatGPTCredentials,
        session: URLSession
    ) async throws -> ChatGPTCredentials {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": refreshScope,
        ])
        let response: TokenResponse
        do {
            response = try await tokenRequest(request, session: session)
        } catch ChatGPTError.service(let status) where status == 400 || status == 401 {
            // The refresh token expired, was revoked, or was already used.
            throw ChatGPTError.sessionExpired
        }
        guard let renewed = ChatGPTCredentials.make(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            idToken: response.idToken,
            previous: credentials
        ) else {
            throw ChatGPTError.invalidResponse
        }
        return renewed
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private static func tokenRequest(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> TokenResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatGPTError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatGPTError.service(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ChatGPTError.invalidResponse
        }
        return decoded
    }

    static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(name)=\(encoded)"
            }
            .joined(separator: "&")
            .utf8)
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener bound to the loopback interface for the OAuth
/// redirect. It never accepts connections from other machines.
final class ChatGPTLoopbackServer: @unchecked Sendable {
    enum Page {
        case success
        case failure(String)
    }

    struct Callback: Sendable {
        let parameters: [String: String]
        fileprivate let reply: @Sendable (Page) -> Void

        func respond(_ page: Page) { reply(page) }
    }

    private let port: UInt16
    private let path: String
    private let queue = DispatchQueue(label: "com.whisprgo.chatgpt-signin")
    private var listener: NWListener?
    private var waiter: CheckedContinuation<Callback, Error>?
    private var pending: Result<Callback, Error>?
    private var finished = false

    init(port: UInt16, path: String) {
        self.port = port
        self.path = path
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ChatGPTError.callbackPortInUse
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw ChatGPTError.callbackPortInUse
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // State updates arrive on the serial listener queue; this flag
            // only guards against resuming the continuation twice.
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume()
                case .failed, .waiting:
                    guard once.claim() else { return }
                    listener.cancel()
                    continuation.resume(throwing: ChatGPTError.callbackPortInUse)
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func nextCallback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let pending = self.pending {
                        self.pending = nil
                        continuation.resume(with: pending)
                    } else if self.finished {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.deliver(.failure(CancellationError()))
        }
    }

    func stop() {
        queue.async {
            self.finished = true
            self.listener?.cancel()
            self.listener = nil
            if let waiter = self.waiter {
                self.waiter = nil
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    private func deliver(_ result: Result<Callback, Error>) {
        queue.async {
            guard !self.finished else { return }
            if let waiter = self.waiter {
                self.waiter = nil
                waiter.resume(with: result)
            } else if self.pending == nil {
                self.pending = result
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, error == nil, !isComplete, buffer.count < 16_384 {
                self.receiveRequest(on: connection, buffer: buffer)
                return
            }
            self.handleRequest(buffer, on: connection)
        }
    }

    private func handleRequest(_ data: Data, on connection: NWConnection) {
        guard let requestLine = String(decoding: data, as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1)
            .first,
            let target = Self.requestTarget(String(requestLine)),
            let components = URLComponents(string: "http://localhost\(target)")
        else {
            Self.send(status: "400 Bad Request", body: "Bad request", on: connection)
            return
        }

        switch components.path {
        case path:
            let parameters = (components.queryItems ?? []).reduce(into: [String: String]()) {
                $0[$1.name] = $1.value ?? ""
            }
            let callback = Callback(parameters: parameters) { page in
                Self.send(page, on: connection)
            }
            deliver(.success(callback))
        case "/cancel":
            // Another sign-in tool asks the listener on this port to step aside.
            Self.send(status: "200 OK", body: "Cancelled", on: connection)
            deliver(.failure(ChatGPTError.signInFailed("Another app started a sign-in.")))
        default:
            Self.send(status: "404 Not Found", body: "Not found", on: connection)
        }
    }

    static func requestTarget(_ line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    private static func send(_ page: Page, on connection: NWConnection) {
        let title: String
        let message: String
        switch page {
        case .success:
            title = "Signed in to WhisprGo"
            message = "ChatGPT Mode is ready. You can close this tab."
        case let .failure(reason):
            title = "Sign-in did not finish"
            message = reason
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:15px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}
        main{text-align:center;padding:24px}h1{font-size:22px;font-weight:600;margin:0 0 8px}p{margin:0;color:#6e6e73}
        @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}p{color:#a1a1a6}}</style></head>
        <body><main><h1>\(escape(title))</h1><p>\(escape(message))</p></main></body></html>
        """
        send(status: "200 OK", body: html, contentType: "text/html; charset=utf-8", on: connection)
    }

    private static func send(
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection
    ) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
