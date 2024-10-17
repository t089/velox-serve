import Instrumentation
import ServiceContextModule
import HTTPTypes
import Logging
import Tracing


public enum RouteKey: UserInfoKey {
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
}

public struct InstrumentedHandler: Handler {
    public let next: Handler

    init(_ next: Handler) {
        self.next = next
    }

    public func handle(_ request: RequestReader, _ res: any ResponseWriter) async throws {
        var context = ServiceContext.topLevel

        InstrumentationSystem.instrument.extract(request.headers, into: &context, using: HTTPHeaderFieldsExtractor())
        
        try await withSpan("HTTP \(request.method.rawValue)", context: context, ofKind: .server) { span in
            defer {
                if let routeName = request.route {
                    span.operationName = "\(request.method.rawValue) \(routeName)"
                } else {
                    span.operationName = "\(request.method.rawValue)"
                }
            }
            try await next.handle(request, res)
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


extension Handler {
    public func instrumented() -> some Handler {
        InstrumentedHandler(self)
    }
}