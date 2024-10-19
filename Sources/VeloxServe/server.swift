import DequeModule
import Logging
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOPosix
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import HTTPTypes
import ServiceLifecycle
import NIOConcurrencyHelpers

public final class Server: Sendable {
    public enum HTTPError : Error {
        case unexpectedHTTPPart(HTTPRequestPart)
    }

    public enum ServerError : Error {
        case alreadyStarted
        case shuttingDown
    }

    typealias ServerChannel = NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>
    
    enum State {
        case initialized(Configuration)
        case starting(waiters: [CheckedContinuation<State.Running, Error>])
        case running(Running)
        case shuttingDown(serverChannel: ServerChannel, quiescingHelper: ServerQuiescingHelper, logger: Logger, handler: Handler)
        case shutdown

        struct Running {
            let serverChannel: ServerChannel
            let quiescingHelper: ServerQuiescingHelper
            let logger: Logger
            let handler: Handler
            let shutdownSignal: (AsyncStream<Void>.Continuation, AsyncStream<Void>)
        }
    }

    private let state: NIOLockedValueBox<State>
    
    struct Configuration {
        var host: String
        var port: Int = 0
        var name: String?
        var group: EventLoopGroup
        var logger: Logger
        var handler: Handler
    }

    public convenience init(
        host: String,
        port: Int = 0,
        name: String? = nil,
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        logger: Logger = NoopLogger,
        handler: @escaping AnyHandler.Handler
    ) {
        self.init(
            host: host,
            port: port,
            name: name,
            group: group,
            logger: logger,
            handler: AnyHandler(handler)
        )
    }

    public init(
        host: String,
        port: Int = 0,
        name: String? = nil,
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        logger: Logger = NoopLogger,
        handler: Handler
    ) {
        self.state = NIOLockedValueBox(.initialized(Configuration(host: host, port: port, name: name, group: group, logger: logger, handler: handler)))
    }

    /// Bind the server to the given `host` and `port` and start listening for incoming connections.
    ///
    /// You must call `run` after calling this method to start processing incoming requests.
    @discardableResult
    public func start() async throws -> SocketAddress {
        let running = try await self._start()
        return running.serverChannel.channel.localAddress!
    }

    private func _start() async throws -> State.Running {
        enum Action {
            case continueStartup(Configuration)
            case returnRunningState(State.Running)
            case waitForRunningState([CheckedContinuation<State.Running, Error>])
            case throwAlreadyShutdown
        }

        let lock = self.state.unsafe
        lock.lock()
        let action : Action = lock.withValueAssumingLockIsAcquired { state in
            switch state {
                case .initialized(let config):
                    state = .starting(waiters: [])
                    return .continueStartup(config)
                case .running(let running):
                    return .returnRunningState(running)
                case .starting(waiters: let waiters):
                    return .waitForRunningState(waiters)
                default:
                    return .throwAlreadyShutdown
            }
        }

        let configuration: Configuration
        switch action {
            case .continueStartup(let config):
                configuration = config
                lock.unlock()
            case .returnRunningState(let running):
                lock.unlock()
                return running
            case .waitForRunningState(var waiters):
                return try await withCheckedThrowingContinuation { continuation in
                    waiters.append(continuation)
                    lock.withValueAssumingLockIsAcquired { value in
                        value = .starting(waiters: waiters)
                    }
                    lock.unlock()
                }
            case .throwAlreadyShutdown:
                throw ServerError.shuttingDown
        }

        let quiescingHelper = ServerQuiescingHelper(group: configuration.group)

        let socketBootstrap = ServerBootstrap(group: configuration.group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            .serverChannelInitializer({ channel in
                channel.pipeline.addHandler(
                    quiescingHelper.makeServerChannelHandler(channel: channel))
            })

            // Set the handlers that are applied to the accepted Channels
            // .childChannelInitializer(childChannelInitializer(channel:))

            // Enable SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            //.childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: true)

        let channel = try await socketBootstrap.bind(host: configuration.host, port: configuration.port, serverBackPressureStrategy: nil) 
        { channel -> EventLoopFuture<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>> in 
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                    withPipeliningAssistance: false, 
                    withServerUpgrade: nil, 
                    withErrorHandling: true,
                    withOutboundHeaderValidation: false)
                try channel.pipeline.syncOperations.addHandler(ChannelQuiescingHandler(logger: configuration.logger))
                try channel.pipeline.syncOperations.addHandler(AutomaticContinueHandler())
                try channel.pipeline.syncOperations.addHandler(OutboundHeaderHandler(clock: UTCClock(), serverName: configuration.name))
                try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))
                
                return try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(inboundType: HTTPRequestPart.self, outboundType: HTTPResponsePart.self))
            }
        }

        let (waiters, runningState) = try self.state.withLockedValue { state in
            switch state {
                case .starting(waiters: let waiters):
                    var continuation: AsyncStream<Void>.Continuation!
                    let stream = AsyncStream<Void>() { continuation = $0 }
                    let runningState = State.Running(serverChannel: channel, quiescingHelper: quiescingHelper, logger: configuration.logger, handler: configuration.handler, shutdownSignal: (continuation, stream))
                    state = .running(runningState)
                    return (waiters, runningState)
                case .shutdown: // we got shutdown while starting up
                    throw ServerError.shuttingDown
                case .initialized, .running, .shuttingDown:
                    preconditionFailure("Invalid state while starting: \(state)")
            }
        }

        for waiter in waiters {
            waiter.resume(returning: runningState)
        }

        return runningState
    }

    public var localAddress: SocketAddress? {
        self.state.withLockedValue { state -> SocketAddress? in
            guard case let .running(running) = state else {
                return nil
            }
            return running.serverChannel.channel.localAddress
        }
    }

    /// Start the server and run the loop to process incoming requests.
    public func listenAndServe() async throws {
        try await withGracefulShutdownHandler {
            let running = try await self._start()
            let serverChannel = running.serverChannel
            let logger = running.logger
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await  _ in running.shutdownSignal.1 { }
                }

                group.addTask {
                    try await withThrowingDiscardingTaskGroup { group in
                        try await serverChannel.executeThenClose { inbound in
                            logger.info("Listening for connections on \(serverChannel.channel.localAddress!) ...")
                            defer {
                                logger.info("Stopped listening for new connections.")
                            }
                            for try await channel in inbound.cancelOnGracefulShutdown() {
                                group.addTask { [logger] in 
                                    do { 
                                        try await self.handle(channel: channel, running: running)
                                    } catch {
                                        logger.trace("Error handling connection: \(error)")
                                    }
                                }
                            }
                        }
                    }
                }
                
                try await group.next()
                group.cancelAll()
            }
            
            logger.info("Server shutdown complete.")
            self.state.withLockedValue { $0 = .shutdown }
        } onGracefulShutdown: {
            enum Action {
                case doNothing
                case triggerShutdown(ServerQuiescingHelper)
                case signalFailure([CheckedContinuation<State.Running, Error>])
            }
            let action: Action = self.state.withLockedValue { state in
                switch state {
                    case .initialized, .shutdown, .shuttingDown:
                        return .doNothing
                    case .starting(let waiters):
                        state = .shutdown
                        return .signalFailure(waiters)
                    case .running(let running):
                        state = .shuttingDown(serverChannel: running.serverChannel, quiescingHelper: running.quiescingHelper, logger: running.logger, handler: running.handler)
                        return .triggerShutdown(running.quiescingHelper)
                }
            }

            switch action {
                case .triggerShutdown(let quiescingHelper):
                    quiescingHelper.initiateShutdown(promise: nil)
                case .signalFailure(let waiters):
                    for waiter in waiters {
                        waiter.resume(throwing: ServerError.shuttingDown)
                    }
                case .doNothing:
                    break
            }
            
        }
        
    }

    private
    func handle(channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, running: State.Running) async throws {
        try await channel.executeThenClose { inbound, outbound in
            var inboundIterator = inbound.makeAsyncIterator()
            
            guard let part = try await inboundIterator.next() else { return }
            guard case var .head(head) = part else {
                throw HTTPError.unexpectedHTTPPart(part)
            }

            while true {
                let trailers = channel.channel.eventLoop.makePromise(of: HTTPFields?.self)
                defer {
                    trailers.succeed(nil)
                }

                let body = RootReadableBody(
                        expectedContentLength: head.expectedContentLength,
                        _internal: inboundIterator,
                        onFirstRead: {
                            channel.channel.triggerUserOutboundEvent(FirstReadEvent(), promise: nil)
                        }) 

                var logger = running.logger
                logger[metadataKey: "req.path"] = .string(head.path ?? "/")
                logger[metadataKey: "req.method"] = .string(head.method.rawValue)
                
                let requestReader = RootRequestReader(
                    logger: logger,
                    head: head,
                    body: body)
                requestReader.userInfo[EventLoopKey.self] = channel.channel.eventLoop

                let responseWriter = RootResponseWriter(
                    allocator: channel.channel.allocator,
                    isKeepAlive: true,
                    responsePartWriter: outbound,
                    head: httpResponse(request: head, status: .ok, headers: [:]))

                try await running.handler.handle(requestReader, responseWriter)
                
                if !body.wasRead {
                    // if the body was not read, we need to consume it
                    for try await _ in body {}
                } 

                if !responseWriter.isDone {
                    try await responseWriter.end()
                }

                if !head.isKeepAlive {
                    break
                }
                
                
                var part: HTTPRequestPart?
                
                part = try await inboundIterator.next()    

                guard let part else {
                    // if nil, break out of the loop
                    break
                }

                guard case .head(let newHead) = part else {
                    throw HTTPError.unexpectedHTTPPart(part)
                }
                head = newHead
            }
        }
    }

    public func shutdown() {
        enum Action {
            case finishContinuation(AsyncStream<Void>.Continuation)
            case doNothing
        }

        let action : Action  = self.state.withLockedValue { state in
            switch state {
                case .running(let running):
                    state = .shuttingDown(serverChannel: running.serverChannel, quiescingHelper: running.quiescingHelper, logger: running.logger, handler: running.handler)
                    return .finishContinuation(running.shutdownSignal.0)
                default:
                    return .doNothing
            }
        }

        switch action {
            case .finishContinuation(let continuation):
                continuation.finish()
            case .doNothing:
                break
        }
    }

    public func shutdownGracefully() async throws {
        // TODO: signal graceful shutdown to the server
    }
}

extension Server : Service {
    public func  run() async throws {
        try await self.listenAndServe()
    }
}

public struct ConnectionClosedError: Error {}


extension HTTPRequest {
    var expectedContentLength: Int? {
        self.headerFields[.contentLength].flatMap(Int.init)
    }
}

extension HTTPRequestHead {
    var expects100Continue: Bool {
        self.headers["Expect"].contains("100-continue")
    }
}

internal class RootReadableBody: ReadableBody {
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

public struct TooManyBytesError: Error {
    public init() {}
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

extension HTTPRequest {
    var isKeepAlive: Bool {
        self.headerFields[.connection] != "close"
    }
}

func httpResponse(
    request: HTTPRequest,
    status: HTTPResponse.Status,
    headers: HTTPFields
) -> HTTPResponse {
    var response = HTTPResponse(status: status, headerFields: headers)
    
    let connectionHeaders: [String] = headers[values: .connection].map {
        $0.lowercased()
    }

    if !connectionHeaders.contains("keep-alive") && !connectionHeaders.contains("close") {
        // the user hasn't pre-set either 'keep-alive' or 'close', so we might need to add headers

        switch (request.isKeepAlive) {
        case true: break
            //response.headerFields[.connection] = "keep-alive"
        case false:
            response.headerFields[.connection] = "close"
        }
    }
    return response
}

public protocol ReadableBody : AsyncSequence where Element == ByteBuffer {
    var expectedContentLength: Int? { get }
    var trailers: HTTPFields? { get async throws }
}

public protocol RequestReader : AnyObject {
    var logger: Logger { get set }
    var request: HTTPRequest { get}
    var body: AnyReadableBody { get }
    var userInfo: UserInfo { get set }
}

extension RequestReader {
    public var method: HTTPRequest.Method { self.request.method }
    public var path: String { self.request.path! }
    public var headers: HTTPFields { self.request.headerFields }
    public var trailers: HTTPFields? { 
        get async throws {
            try await self.body.trailers
        }
    }
}


public enum EventLoopKey: UserInfoKey {
    public typealias Value = EventLoop
}

class RootRequestReader: RequestReader {
    var logger: Logger
    let request: HTTPRequest
    private let _body: RootReadableBody
    
    var body: AnyReadableBody {
        AnyReadableBody(self._body)
    }
    

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
    
}

@usableFromInline
enum ResponsePart: Sendable {
    case head(HTTPResponseHead)
    case bodyPart(ByteBuffer)
    case end(HTTPHeaders?)
}

public protocol ResponseWriter: AnyObject {

    var status: HTTPResponse.Status { get set }
    var headers: HTTPFields { get set }
    var trailers: HTTPFields? { get set }

    func writeHead() async throws
    func writeBodyPart(_ data: inout ByteBuffer) async throws
    func end() async throws
}

extension ResponseWriter {
    public func writeBodyPart(_ string: String) async throws {
        try await self.writeBodyPart(string.utf8)
    }

    public func writeBodyPart(_ string: Substring) async throws {
        try await self.writeBodyPart(string.utf8)
    }

    @inlinable
    public func writeBodyPart(_ bytes: some Sequence<UInt8>) async throws {
        var buffer = ByteBuffer(bytes: bytes)
        try await self.writeBodyPart(&buffer)
    }

    public func plainText(_ text: String) async throws {
        self.headers[.contentType] = "text/plain"
        let data = text.utf8
        self.headers[.contentLength] = "\(data.count)"
        try await self.writeBodyPart(data)
    }
}


internal class RootResponseWriter : ResponseWriter {


    let isKeepAlive: Bool

    let responsePartWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>

    var status: HTTPResponse.Status
    
    var headers: HTTPFields

    var trailers: HTTPFields?

    init(
        allocator: ByteBufferAllocator,
        isKeepAlive: Bool,
        responsePartWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
        head: HTTPResponse
    ) {
        self.isKeepAlive = isKeepAlive
        self.responsePartWriter = responsePartWriter
        self.status = head.status
        self.headers = head.headerFields
        self.writeBuffer = allocator.buffer(capacity: 4096)
    }

    private(set) var headerWritten: Bool = false
    private(set) var isDone: Bool = false

    private var head: HTTPResponse {
        HTTPResponse(status: self.status, headerFields: self.headers)
    }

    private
    var writeBuffer: ByteBuffer

    func writeHead() async throws {
        precondition(self.headerWritten == false, "Header can only be written once.")
        
        var head = self.head
        if head.status.code / 100 == 1 { // remove connection header for informational responses
            head.headerFields[.connection] = nil
        }
        
        try await self.responsePartWriter.write(.head(head))
        if self.head.status.code / 100 != 1 {
            self.headerWritten.toggle()
        }
    }

    private func writeHeadIfNecessary() async throws {
        guard self.headerWritten == false else {
            return
        }
        precondition(self.head.status.code / 100 != 1, "Head must not be 1xx")
        try await self.writeHead()
    }

     @inlinable
    func writeBodyPart(_ data: some Sequence<UInt8>) async throws {
        self.writeBuffer.writeBytes(data)
        try await self.flushIfNecessary()
    }

    @inlinable
    public func writeBodyPart(_ data: inout ByteBuffer) async throws {
        if data.readableBytes > 0 {
            self.writeBuffer.writeBuffer(&data)
            try await self.flushIfNecessary()
        }
    }

    @inlinable
    func flushIfNecessary() async throws {
        try await self.writeHeadIfNecessary()
        let readableBytes = self.writeBuffer.readableBytes
        if readableBytes >= 0 {
            try await responsePartWriter.write(
                .body(self.writeBuffer.readSlice(length: readableBytes)!))
        }
    }

    @inlinable
    public func flush() async throws {
        try await self.writeHeadIfNecessary()
        if self.writeBuffer.readableBytes > 0 {
            try await responsePartWriter.write(
                .body(self.writeBuffer.readSlice(length: self.writeBuffer.readableBytes)!))
        }
    }

    public func end(_ trailers: HTTPFields?) async throws {
        precondition(self.isDone == false)
        self.isDone.toggle()
        try await self.flush()
        self.trailers = trailers
        try await responsePartWriter.write(.end(self.trailers))
    }

    public func end() async throws {
        precondition(self.isDone == false)
        self.isDone.toggle()
        try await self.flush()
        try await responsePartWriter.write(.end(self.trailers))
    }

    public func plainText(_ text: String) async throws {
        self.headers[.contentType] = "text/plain"
        let data = text.utf8
        self.headers[.contentLength] = "\(data.count)"
        try await self.writeBodyPart(data)
    }
}


public let NoopLogger = Logger(label: "noop", factory: SwiftLogNoOpLogHandler.init)


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