import Foundation

/// Opens an HTTPS connection while the user is still speaking, so the request
/// after release skips DNS, TCP and TLS setup. A bodiless HEAD without
/// credentials is answered immediately (usually with an error status) and
/// leaves a warm, pooled connection in `session`, which the real request then
/// reuses. Calls within `interval` of the last one are ignored because that
/// connection is still open.
final class ConnectionWarmer: @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastWarm: TimeInterval = -.infinity

    init(url: URL, session: URLSession, interval: TimeInterval = 8) {
        self.url = url
        self.session = session
        self.interval = interval
    }

    func warm() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldWarm = now - lastWarm > interval
        if shouldWarm { lastWarm = now }
        lock.unlock()
        guard shouldWarm else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        request.setValue("WhisprGo", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }
}
