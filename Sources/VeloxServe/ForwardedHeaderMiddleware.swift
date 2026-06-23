import HTTPTypes

/// Middleware that derives the originating client address from the
/// `X-Forwarded-For` header so that requests arriving through a reverse proxy
/// report the real client (via ``RequestReader/clientAddress`` and the
/// `client.address` span attribute) instead of the proxy's address.
///
/// `X-Forwarded-For` is client-controllable, so it is only trustworthy for the
/// hops appended by proxies you operate. ``trustedHops`` says how many such
/// proxies sit directly in front of this server; the address is taken that many
/// entries from the *right* of the header, ignoring any values a malicious
/// client could have prepended. Enable this **only** when running behind a
/// trusted proxy.
///
/// ```swift
/// let handler = router
///     .instrumented()
///     .forwarded()           // runs before instrumentation, overrides the client address
/// ```
public struct ForwardedHeaderMiddleware: MiddlewareProtocol {
    /// The number of trusted reverse proxies directly in front of this server.
    public let trustedHops: Int

    /// - Parameter trustedHops: How many trusted proxies sit in front of this
    ///   server. Defaults to `1` (a single reverse proxy). Values `< 1` are
    ///   treated as `1`.
    public init(trustedHops: Int = 1) {
        self.trustedHops = max(1, trustedHops)
    }

    public func apply(on next: HandlerProtocol) -> HandlerProtocol {
        ForwardedHeaderHandler(next: next, trustedHops: trustedHops)
    }
}

extension HandlerProtocol {
    /// Wraps the handler so the client address is taken from `X-Forwarded-For`.
    /// See ``ForwardedHeaderMiddleware``.
    public func forwarded(trustedHops: Int = 1) -> some HandlerProtocol {
        ForwardedHeaderHandler(next: self, trustedHops: max(1, trustedHops))
    }
}

struct ForwardedHeaderHandler: HandlerProtocol {
    let next: HandlerProtocol
    let trustedHops: Int

    static let forwardedFor = HTTPField.Name("X-Forwarded-For")!

    func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws {
        if let header = request.headers[Self.forwardedFor],
           let client = Self.clientAddress(fromForwardedFor: header, trustedHops: trustedHops) {
            request.userInfo[ForwardedClientAddressKey.self] = client
        }
        try await next.handle(request, response)
    }

    /// Selects the client address from a (possibly multi-valued) `X-Forwarded-For`
    /// header value, counting `trustedHops` entries from the right.
    static func clientAddress(fromForwardedFor header: String, trustedHops: Int) -> String? {
        let entries = header
            .split(separator: ",")
            .map { $0.trimmingASCIIWhitespace() }
            .filter { !$0.isEmpty }

        // The header must contain at least as many entries as the proxies we
        // trust; otherwise it is shorter than expected and we ignore it.
        guard entries.count >= trustedHops else { return nil }

        let candidate = entries[entries.count - trustedHops]
        let normalized = normalize(candidate)
        // Per RFC 7239 the identifier may be an obfuscated/`unknown` token; only
        // accept it when it looks like an actual address.
        return normalized.isEmpty || normalized.lowercased() == "unknown" ? nil : normalized
    }

    /// Strips an optional port and IPv6 brackets, leaving a bare host/IP.
    static func normalize(_ entry: Substring) -> String {
        var value = entry
        if value.first == "[" {
            // `[2001:db8::1]` or `[2001:db8::1]:443`
            if let close = value.firstIndex(of: "]") {
                return String(value[value.index(after: value.startIndex)..<close])
            }
        }
        // `1.2.3.4:443` — strip the port only when there is a single colon
        // (a bare IPv6 address contains several and must be left intact).
        if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            value = value[..<colon]
        }
        return String(value)
    }
}

extension Substring {
    fileprivate func trimmingASCIIWhitespace() -> Substring {
        var result = self[...]
        while let first = result.first, first == " " || first == "\t" {
            result = result.dropFirst()
        }
        while let last = result.last, last == " " || last == "\t" {
            result = result.dropLast()
        }
        return result
    }
}
