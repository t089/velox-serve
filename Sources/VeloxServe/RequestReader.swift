import NIOCore
import Logging
import HTTPTypes
import NIOHTTPTypes


public protocol RequestReader : AnyObject {
    var logger: Logger { get set }
    var request: HTTPRequest { get}
    var queryItems: QueryItems { get }
    var body: AnyReadableBody { get }
    var userInfo: UserInfo { get set }
    
}




extension RequestReader {
    public var method: HTTPRequest.Method { self.request.method }
    public var path: String { self.request.path! }
    public var headers: HTTPFields { self.request.headerFields }

    // accessing trailers before consuming the body, will consume the body
    public var trailers: HTTPFields? { 
        get async throws {
            try await self.body.trailers
        }
    }
}

public protocol ReadableBody : AsyncSequence where Element == ByteBuffer {
    var expectedContentLength: Int? { get }

    // accessing trailers is async because it may require reading the entire body
    var trailers: HTTPFields? { get async throws }
}


extension ReadableBody {
    @inlinable public func collect(upTo maxBytes: Int) async throws -> ByteBuffer {
        if let contentLength = self.expectedContentLength {
            if contentLength > maxBytes {
                throw TooManyBytesError()
            }
        }

        /// calling collect function within here in order to ensure the correct nested type
        func collect<Body: AsyncSequence>(_ body: Body, maxBytes: Int) async throws -> ByteBuffer
        where Body.Element == ByteBuffer {
            try await body.collect(upTo: maxBytes)
        }
        return try await collect(self, maxBytes: maxBytes)
    }
}

public struct AnyReadableBody: ReadableBody {
    public typealias Element = ByteBuffer

    private let _underlyingNextFactory: () -> () async throws -> ByteBuffer?
    private let _underlyingTrailers: () async throws -> HTTPFields?

    public init<Body: ReadableBody>(_ body: Body)
    where Body.Element == ByteBuffer {
        self._underlyingNextFactory = { 
            var iterator = body.makeAsyncIterator()
            return { try await iterator.next() }
         }
        self._underlyingTrailers = { try await body.trailers }
        self.expectedContentLength = body.expectedContentLength
    }

    public let expectedContentLength: Int?

    public var trailers: HTTPFields? {
        get async throws {
            try await self._underlyingTrailers()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self._underlyingNextFactory())
    }

    
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var _iterator: () async throws -> Element?

        init(iterator: @escaping () async throws -> Element?) {
            self._iterator = iterator
        }

        @inlinable
        public mutating func next() async throws -> Element? {
            try await self._iterator()
        }
    }
}

extension HTTPRequest {
    var expectedContentLength: Int? {
        self.headerFields[.contentLength].flatMap(Int.init)
    }
}


public struct TooManyBytesError: Error {
    public init() {}
}



// Implementation

final class RootRequestReader: RequestReader {
    var logger: Logger
    private(set) var request: HTTPRequest
    private var _body: RootReadableBody
    
    var body: AnyReadableBody {
        AnyReadableBody(self._body)
    }
    
    lazy var queryItems: QueryItems = {
        let endOfPath = self.request.path!.firstIndex(of: "?") ?? self.request.path!.endIndex
        return QueryItems(parsing: self.request.path![endOfPath...].dropFirst())
    }()

    var userInfo: UserInfo = UserInfo()



    init(
        logger: Logger,
        head: HTTPRequest,
        body: RootReadableBody
    ) {
        self.logger = logger
        self.request = head
        self._body = body
    }
    
    /* func reset(logger: Logger, head: HTTPRequest, body: RootReadableBody) {
        self.logger = logger
        self.request = head
        self._body = body
        self.userInfo = UserInfo()
    } */
}

final class RootReadableBody: ReadableBody {
    public typealias Element = ByteBuffer

    public let expectedContentLength: Int?

    @usableFromInline
    var _trailers: HTTPFields?

    public var trailers: HTTPFields? {
        get async throws { 
            if !self.wasRead {
                for try await _ in self {}
            }
            return self._trailers
        }
    }

    @usableFromInline
    typealias InboundStream = NIOAsyncChannelInboundStream<HTTPRequestPart>

    @usableFromInline
    var _internal: InboundStream.AsyncIterator

    @usableFromInline
    var wasRead: Bool = false

    @usableFromInline
    var fireFirstRead : (() -> ())!

    init(expectedContentLength: Int?, _internal: InboundStream.AsyncIterator, onFirstRead: @escaping () -> ()) {
        self._internal = _internal
        self.expectedContentLength = expectedContentLength
        self.fireFirstRead = onFirstRead
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return .init(underlying: self)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var underlying: RootReadableBody

        @inlinable
        public mutating func next() async throws -> ByteBuffer? {
            do {
                guard !self.underlying.wasRead else {
                    return nil
                }

                if let fireFirstRead = self.underlying.fireFirstRead {
                    fireFirstRead()
                    self.underlying.fireFirstRead = nil
                }
                guard let next = try await underlying._internal.next() else {
                    self.underlying.wasRead = true
                    return nil
                }

                switch next {
                    case .body(let buffer):
                        return buffer
                    case .end(let trailers):
                        self.underlying._trailers = trailers
                        self.underlying.wasRead = true
                        return nil
                    default:
                        self.underlying.wasRead = true
                        throw Server.HTTPError.unexpectedHTTPPart(next)
                }
            } catch {
                throw error
            }
        }
    }

}