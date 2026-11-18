import Foundation

/// Authenticated API and range requests may move within the configured server,
/// but must never forward credentials to another origin or downgrade HTTPS.
nonisolated final class NavidromeRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static func allowsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination,
              let scheme = original.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              destination.scheme?.lowercased() == scheme,
              let host = original.host?.lowercased(),
              destination.host?.lowercased() == host,
              destination.user == nil, destination.password == nil else {
            return false
        }
        let defaultPort = scheme == "https" ? 443 : 80
        return (original.port ?? defaultPort) == (destination.port ?? defaultPort)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.allowsRedirect(
            from: task.originalRequest?.url, to: request.url
        ) ? request : nil)
    }
}
