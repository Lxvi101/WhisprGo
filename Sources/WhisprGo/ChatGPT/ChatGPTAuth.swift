import Foundation

/// Owns WhisprGo's ChatGPT session: Keychain persistence, an in-memory copy
/// for the latency-sensitive path, and single-flight token renewal.
actor ChatGPTAuth {
    static let shared = ChatGPTAuth()

    /// Renew when the access token has less than this much life left, so a
    /// dictation never waits on an expiry that happens mid-request.
    static let refreshMargin: TimeInterval = 5 * 60

    private let store: ChatGPTCredentialStore
    private let session: URLSession
    private var loaded = false
    private var credentials: ChatGPTCredentials?
    private var refreshTask: Task<ChatGPTCredentials, Error>?

    init(
        store: ChatGPTCredentialStore = KeychainChatGPTCredentialStore(),
        session: URLSession? = nil
    ) {
        self.store = store
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: configuration)
        }()
    }

    var account: ChatGPTAccountSummary? {
        current().map(ChatGPTAccountSummary.init)
    }

    func signIn(openURL: @escaping @Sendable (URL) async -> Void) async throws -> ChatGPTAccountSummary {
        let signedIn = try await ChatGPTOAuth.signIn(session: session, openURL: openURL)
        refreshTask?.cancel()
        refreshTask = nil
        try store.save(signedIn)
        credentials = signedIn
        loaded = true
        return ChatGPTAccountSummary(signedIn)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        loaded = true
        try? store.delete()
    }

    /// Credentials whose access token is good for at least `refreshMargin`.
    func validCredentials() async throws -> ChatGPTCredentials {
        guard let current = current() else { throw ChatGPTError.signInRequired }
        guard current.expires(within: Self.refreshMargin) else { return current }
        return try await renew(from: current)
    }

    /// Renews after the server rejected `rejectedToken`. Concurrent callers
    /// share one renewal, and a token already replaced is not renewed again.
    func credentials(afterRejecting rejectedToken: String) async throws -> ChatGPTCredentials {
        guard let current = current() else { throw ChatGPTError.signInRequired }
        if current.accessToken != rejectedToken { return current }
        return try await renew(from: current)
    }

    /// Starts a renewal in the background when one will soon be needed.
    /// Called when recording starts, so the request after release never waits.
    func renewIfNeededSoon() {
        guard let current = current(), current.expires(within: Self.refreshMargin) else { return }
        Task { _ = try? await self.renew(from: current) }
    }

    private func current() -> ChatGPTCredentials? {
        if !loaded {
            credentials = store.load()
            loaded = true
        }
        return credentials
    }

    private func renew(from stale: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        if let refreshTask { return try await refreshTask.value }
        let session = session
        let task = Task { try await ChatGPTOAuth.refresh(stale, session: session) }
        refreshTask = task
        do {
            let renewed = try await task.value
            refreshTask = nil
            // A sign-out or new sign-in during renewal wins.
            guard credentials?.refreshToken == stale.refreshToken else {
                guard let credentials else { throw ChatGPTError.signInRequired }
                return credentials
            }
            credentials = renewed
            try? store.save(renewed)
            return renewed
        } catch ChatGPTError.sessionExpired {
            refreshTask = nil
            if credentials?.refreshToken == stale.refreshToken {
                credentials = nil
                try? store.delete()
            }
            throw ChatGPTError.sessionExpired
        } catch {
            refreshTask = nil
            throw error
        }
    }
}

protocol ChatGPTCredentialStore: Sendable {
    func load() -> ChatGPTCredentials?
    func save(_ credentials: ChatGPTCredentials) throws
    func delete() throws
}

struct KeychainChatGPTCredentialStore: ChatGPTCredentialStore {
    func load() -> ChatGPTCredentials? {
        guard let data = KeychainStore.chatGPTSessionData() else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }

    func save(_ credentials: ChatGPTCredentials) throws {
        try KeychainStore.saveChatGPTSessionData(JSONEncoder().encode(credentials))
    }

    func delete() throws {
        try KeychainStore.saveChatGPTSessionData(nil)
    }
}
