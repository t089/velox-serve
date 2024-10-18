public protocol Handler : Sendable {
    func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws -> Void
}


public struct AnyHandler: Handler {
    public typealias Handler = @Sendable (any RequestReader, any ResponseWriter) async throws -> Void

    @usableFromInline
    let _handler: Handler
    
    public init<H: VeloxServe.Handler>(_ handler: H) {
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