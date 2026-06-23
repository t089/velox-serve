import Instrumentation
import ServiceContextModule
import HTTPTypes
import Logging
import NIOCore
import Tracing


public enum RouteKey: UserInfoKey {
    public typealias Value = String
}

/// Carries the connection's remote peer address so the instrumentation layer can
/// populate `client.address` / `client.port` on the server span.
public enum ClientAddressKey: UserInfoKey {
    public typealias Value = SocketAddress
}

/// Overrides the client address with one extracted from a trusted forwarding
/// header (e.g. `X-Forwarded-For`). Set by ``ForwardedHeaderMiddleware``.
public enum ForwardedClientAddressKey: UserInfoKey {
    public typealias Value = String
}

extension RequestReader {
    public var route: String? {
        get {
            userInfo[RouteKey.self]
        }
        set {
            userInfo[RouteKey.self] = newValue
        }
    }

    /// The originating client IP address.
    ///
    /// Prefers a value supplied by trusted forwarding middleware (so that a
    /// request arriving through a reverse proxy reports the real client rather
    /// than the proxy), falling back to the direct socket peer.
    public var clientAddress: String? {
        userInfo[ForwardedClientAddressKey.self] ?? userInfo[ClientAddressKey.self]?.ipAddress
    }

    /// The originating client port, when known.
    ///
    /// Only the direct socket peer carries a reliable port; forwarding headers
    /// rarely include one, so this is `nil` once the address has been overridden.
    public var clientPort: Int? {
        if userInfo[ForwardedClientAddressKey.self] != nil { return nil }
        return userInfo[ClientAddressKey.self]?.port
    }
}

public struct InstrumentedHandler: HandlerProtocol {
    public let next: HandlerProtocol

    init(_ next: HandlerProtocol) {
        self.next = next
    }

    public func handle(_ request: RequestReader, _ res: any ResponseWriter) async throws {
        var context = ServiceContext.topLevel

        InstrumentationSystem.instrument.extract(request.headers, into: &context, using: HTTPHeaderFieldsExtractor())

        // The low-cardinality span name is `{method}` until the router resolves a
        // route; it is upgraded to `{method} {route}` in the `defer` below.
        // See https://opentelemetry.io/docs/specs/semconv/http/http-spans/
        try await withSpan(request.method.rawValue, context: context, ofKind: .server) { span in
            span.setRequestAttributes(request)

            defer {
                if let routeName = request.route {
                    span.operationName = "\(request.method.rawValue) \(routeName)"
                    span.attributes["http.route"] = routeName
                } else {
                    span.operationName = request.method.rawValue
                }
                span.setResponseAttributes(res)
            }

            do {
                try await next.handle(request, res)
            } catch {
                // `withSpan` records the error and sets the span status; we add the
                // semantic-convention `error.type` attribute on top of that.
                span.attributes["error.type"] = String(describing: type(of: error))
                throw error
            }
        }
    }
}


extension Span {
    /// Sets the OTel HTTP server semantic-convention attributes that are known
    /// before the handler runs.
    fileprivate func setRequestAttributes(_ request: RequestReader) {
        let req = request.request

        attributes["http.request.method"] = req.method.rawValue
        attributes["url.scheme"] = req.scheme ?? "http"

        // `req.path` includes the query component; split it per semconv.
        if let target = req.path {
            if let queryStart = target.firstIndex(of: "?") {
                attributes["url.path"] = String(target[..<queryStart])
                let query = target[target.index(after: queryStart)...]
                if !query.isEmpty {
                    attributes["url.query"] = String(query)
                }
            } else {
                attributes["url.path"] = target
            }
        }

        // `server.address` / `server.port` from the request authority (HTTP/2
        // `:authority`, or the `Host` header for HTTP/1).
        if let authority = req.authority {
            if let colon = authority.lastIndex(of: ":"),
               let port = Int(authority[authority.index(after: colon)...]) {
                attributes["server.address"] = String(authority[..<colon])
                attributes["server.port"] = port
            } else {
                attributes["server.address"] = authority
            }
        }

        if let userAgent = request.headers[.userAgent] {
            attributes["user_agent.original"] = userAgent
        }

        if let clientAddress = request.clientAddress {
            attributes["client.address"] = clientAddress
        }
        if let clientPort = request.clientPort {
            attributes["client.port"] = clientPort
        }

        // Opt-in request body size, when the client announced a Content-Length.
        if let length = req.expectedContentLength {
            attributes["http.request.body.size"] = length
        }
    }

    /// Sets the response-derived attributes once the handler has run.
    fileprivate func setResponseAttributes(_ res: any ResponseWriter) {
        let status = res.status.code
        attributes["http.response.status_code"] = status

        if let length = res.headers[.contentLength].flatMap(Int.init) {
            attributes["http.response.body.size"] = length
        }

        // For SERVER spans only 5xx responses count as errors (4xx are client
        // faults and must not mark the span as failed).
        if status >= 500 {
            attributes["error.type"] = "\(status)"
            setStatus(SpanStatus(code: .error))
        }
    }
}


struct HTTPHeaderFieldsExtractor: Extractor {
    func extract(key: String, from carrier: HTTPFields) -> String? {
        if let key = HTTPField.Name(key) {
            return carrier[key]
        } else {
            return nil
        }
    }
}

enum HTTPRequestKey: ServiceContextKey {
    typealias Value = HTTPRequest
}


extension HandlerProtocol {
    public func instrumented() -> some HandlerProtocol {
        InstrumentedHandler(self)
    }
}