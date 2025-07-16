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
    var executor: any (TaskExecutor & SerialExecutor) { get }
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

public protocol ReadableBody : AsyncSequence, Sendable where Element == ByteBuffer {
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

    private let _underlyingNextFactory: @Sendable () -> () async throws -> ByteBuffer?
    private let _underlyingTrailers: @Sendable () async throws -> HTTPFields?

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

    let executor: any (TaskExecutor & SerialExecutor)
    
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
        body: RootReadableBody,
        executor: any (TaskExecutor & SerialExecutor)
    ) {
        self.logger = logger
        self.request = head
        self._body = body
        self.executor = executor
    }
    
    /* func reset(logger: Logger, head: HTTPRequest, body: RootReadableBody) {
        self.logger = logger
        self.request = head
        self._body = body
        self.userInfo = UserInfo()
    } */
}

import Synchronization

public struct TooManyIterationsError: Error {
    public init() {}
}

final class RootReadableBody: ReadableBody {
    public typealias Element = ByteBuffer

    public let expectedContentLength: Int?

    public var trailers: HTTPFields? {
        get async throws { 
            enum Action {
                case returnTrailers(HTTPFields?)
                case waitForHeaders
            }

            let action : Action = self.state.withLock { state in
                switch state {
                case .fullyRead(let trailers):
                    return .returnTrailers(trailers)
                case .initial, .reading:
                    return .waitForHeaders
                }
            }

            switch action {
            case .returnTrailers(let trailers):
                return trailers
            case .waitForHeaders:
                // wait for the body to be fully read
                for try await _ in self { }
                return self.state.withLock { $0.trailers }
            }
        }
    }

    @usableFromInline
    typealias InboundStream = NIOAsyncChannelInboundStream<HTTPRequestPart>

    enum State {
        case initial(fireFirstRead: (() -> ()), iteratorCreated: Bool = false)
        case reading
        case fullyRead(trailers: HTTPFields?)
    

        enum Action {
            case fireFirstRead(() -> (), chunk: ByteBuffer)
            case chunkRead(ByteBuffer)
            case endStream
        }

    

        mutating func onMakeIterator() throws(TooManyIterationsError) {
            switch self {
            case .initial(let fireFirstRead, let iteratorCreated):
                guard !iteratorCreated else {
                    throw TooManyIterationsError()
                }
                self = .initial(fireFirstRead: fireFirstRead, iteratorCreated: true)
            case .reading, .fullyRead:
                // already created
                throw TooManyIterationsError()
            }
        }

        mutating func onNext(_ element: borrowing InboundStream.Element?) -> Action {
            switch self {
            case .initial(let fireFirstRead, _):
                switch element {
                case .body(let chunk):
                    self = .reading
                    return .fireFirstRead(fireFirstRead, chunk: chunk)
                case .end(let trailers):
                    self = .fullyRead(trailers: trailers)
                    return .endStream
                case .head(_):
                    // unexpected head part, we are not expecting it
                    self = .reading
                    return .endStream
                case nil:
                    // no more elements, we are done
                    self = .fullyRead(trailers: nil)
                    return .endStream
                }
                
                
            case .reading:
                switch element {
                case .body(let chunk):
                    self = .reading
                    return .chunkRead(chunk)
                case .end(let trailers):
                    self = .fullyRead(trailers: trailers)
                    return .endStream
                case .head(_):
                    // unexpected head part, we are not expecting it
                    fatalError("Impossible state: received head part while reading body")
                case nil:
                    // no more elements, we are done
                    self = .fullyRead(trailers: nil)
                    return .endStream
                }
            case .fullyRead:
                return .endStream
            }
        }

        var trailers: HTTPFields? {
            switch self {
            case .initial, .reading:
                return nil
            case .fullyRead(let trailers):
                return trailers
            }
        }
    }

    @usableFromInline
    let state: Mutex<State>

    @usableFromInline
    var wasRead: Bool {
        self.state.withLock { state in
            switch state {
            case .initial, .reading:
                return false
            case .fullyRead:
                return true
            }
        }
    }

    @usableFromInline
    let _internal: UnsafeTransfer<InboundStream.AsyncIterator>


    init(expectedContentLength: Int?, _internal: InboundStream.AsyncIterator, onFirstRead: sending @escaping () -> ()) {
        self._internal = .init(_internal)
        self.expectedContentLength = expectedContentLength
        self.state = Mutex(.initial(fireFirstRead: onFirstRead))
    }

    public func makeAsyncIterator() -> AsyncIterator {
        do {
            try self.state.withLock { try $0.onMakeIterator() }
            return AsyncIterator(iterating: BodyIterator(body: self, underlying: self._internal.wrapped))
        } catch  {
            return AsyncIterator(throwing: error)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var produceNext: () async throws -> ByteBuffer?

        init(throwing error: Error) {
            self.produceNext = { throw error }
        }

        init(iterating iterator: BodyIterator) {
            var iterator = iterator
            self.produceNext = { try await iterator.next() }
        }

        public func next() async throws -> Element? {
            try await self.produceNext()
        }
    }

    struct ThrowingIterator: AsyncIteratorProtocol {
        @usableFromInline
        let error: Error

        init(throwing error: Error) {
            self.error = error
        }

        func next() async throws -> Element? {
            throw self.error
        }
    }

    struct BodyIterator: AsyncIteratorProtocol {
        @usableFromInline
        let body: RootReadableBody

        @usableFromInline
        var underlying: RootReadableBody.InboundStream.AsyncIterator

        @usableFromInline
        var done: Bool = false

        @inlinable
        public mutating func next() async throws -> ByteBuffer? {
            guard !done else {
                return nil
            }

            let next = try await underlying.next()

            switch self.body.state.withLock({ $0.onNext(next) }) {
                case .fireFirstRead(let fireFirstRead, let chunk):
                    fireFirstRead()
                    return chunk
                case .chunkRead(let chunk):
                    return chunk
                case .endStream:
                    self.done = true
                    return nil
                
            }
        }
    }

}

@usableFromInline
struct UnsafeTransfer<Wrapped>: @unchecked Sendable {
    @usableFromInline
    var wrapped: Wrapped

    @inlinable
    init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }
}