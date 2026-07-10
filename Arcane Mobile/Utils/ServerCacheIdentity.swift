import Foundation

nonisolated enum ServerCacheIdentity {
    static func canonical(for url: URL) -> String {
        guard let components = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host else {
            return url.absoluteString
        }

        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        let authority = host.contains(":") ? "[\(host)]" : host
        let effectivePort = components.port ?? defaultPort(for: scheme)
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }

        if let effectivePort {
            return "\(scheme)://\(authority):\(effectivePort)\(path)"
        }
        return "\(scheme)://\(authority)\(path)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
