public protocol HandlerProtocol : Sendable {
    func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws -> Void
}

public protocol MiddlewareProtocol: Sendable {
    func apply(on next: HandlerProtocol) -> HandlerProtocol
}

public typealias Handler = @Sendable (any RequestReader, any ResponseWriter) async throws -> Void
public typealias Middleware = @Sendable (@escaping Handler) -> Handler


public struct AnyMiddleware: MiddlewareProtocol {
    let middleware: Middleware
    
    public init(_ middleware: @escaping Middleware) {
        self.middleware = middleware
    }

    public func apply(on next: HandlerProtocol) -> HandlerProtocol {
        AnyHandler(self.middleware(next.handle))
    }
}

public struct AnyHandler: HandlerProtocol {
    @usableFromInline
    let _handler: Handler
    
    public init<H: HandlerProtocol>(_ handler: H) {
        self._handler = handler.handle
    }

    public init(_ handler: @escaping Handler) {
        self._handler = handler
    }
    
    @inlinable
    public func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws {
        try await self._handler(request, response)
    }
}