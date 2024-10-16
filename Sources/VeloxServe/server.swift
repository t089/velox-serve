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

public final class Server: Sendable {
    public enum HTTPError : Error {
        case unexpectedHTTPPart(HTTPRequestPart)
    }

    typealias ServerChannel = NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>
    let serverChannel: ServerChannel
    let quiescingHelper: ServerQuiescingHelper
    let logger: Logger
    let handler: Handler
    
    public let eventLoopGroup: EventLoopGroup

    init(
        serverChannel: ServerChannel,
        quiescingHelper: ServerQuiescingHelper,
        logger: Logger = NoopLogger,
        handler: Handler,
        eventLoopGroup: EventLoopGroup
    ) {
        self.serverChannel = serverChannel
        self.quiescingHelper = quiescingHelper
        self.logger = logger
        self.handler = handler
        self.eventLoopGroup = eventLoopGroup
    }

    public static func start(
        host: String,
        port: Int = 0,
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        logger: Logger = NoopLogger,
        handler: @escaping AnyHandler.Handler
    ) async throws -> Server {
        try await Self.start(
            host: host,
            port: port,
            group: group,
            logger: logger,
            handler: AnyHandler(handler)
        )
    }

    // TODO: move start into run method
    public static func start(
        host: String,
        port: Int = 0,
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        logger: Logger = NoopLogger,
        handler: Handler
    ) async throws -> Server {
        
        let quiescingHelper = ServerQuiescingHelper(group: group)

        let socketBootstrap = ServerBootstrap(group: group)
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

        let channel = try await socketBootstrap.bind(host: host, port: port, serverBackPressureStrategy: nil) 
        { channel -> EventLoopFuture<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>> in 
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                    withPipeliningAssistance: false, 
                    withServerUpgrade: nil, 
                    withErrorHandling: true,
                    withOutboundHeaderValidation: false)
                try channel.pipeline.syncOperations.addHandler(ChannelQuiescingHandler(logger: logger))
                try channel.pipeline.syncOperations.addHandler(AutomaticContinueHandler())
                try channel.pipeline.syncOperations.addHandler(OutboundHeaderHandler(clock: UTCClock(), serverName: "velox-serve"))
                try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))
                
                return try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(inboundType: HTTPRequestPart.self, outboundType: HTTPResponsePart.self))
            }
        }

        return Server(
            serverChannel: channel,
            quiescingHelper: quiescingHelper,
            logger: logger,
            handler: handler,
            eventLoopGroup: group)
    }

    public var localAddress: SocketAddress {
        serverChannel.channel.localAddress!
    }

    public func run() async throws {
        //let closePromise = serverChannel.channel.eventLoop.makePromise(of: Void.self)
        try await withGracefulShutdownHandler {
            try await withThrowingDiscardingTaskGroup { group in
                try await serverChannel.executeThenClose { inbound in
                    logger.info("Listening for connections on \(self.localAddress) ...")
                    for try await channel in inbound.cancelOnGracefulShutdown() {
                        group.addTask { [logger] in 
                            do { 
                                try await self.handle(channel: channel)
                            } catch {
                                logger.trace("Error handling connection: \(error)")
                            }
                        }
                    }
                }
                logger.info("Stopped listening for new connections.")
            }
            logger.info("Server shutdown complete.")
        } onGracefulShutdown: {
            self.quiescingHelper.initiateShutdown(promise: nil)
        }
        
    }

    private
    func handle(channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>) async throws {
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

                let body = ReadableBody(
                        expectedContentLength: head.expectedContentLength,
                        _internal: inboundIterator,
                        trailers: trailers,
                        onFirstRead: {
                            channel.channel.triggerUserOutboundEvent(FirstReadEvent(), promise: nil)
                        }) 

                var logger = self.logger
                logger[metadataKey: "path"] = .string(head.path ?? "/")
                logger[metadataKey: "method"] = .string(head.method.rawValue)
                
                let requestReader = RequestReader(
                    logger: logger,
                    head: head,
                    body: body,
                    _trailers: trailers.futureResult,
                    _eventLoop: channel.channel.eventLoop)

                let responseWriter = RootResponseWriter(
                    allocator: channel.channel.allocator,
                    isKeepAlive: true,
                    responsePartWriter: outbound,
                    head: httpResponse(request: head, status: .ok, headers: [:]))

                try await self.handler.handle(requestReader, responseWriter)
                
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

    public func shutdown() async throws {
        try await serverChannel.channel.close()
    }

    public func shutdownGracefully() async throws {
        let p = self.eventLoopGroup.next().makePromise(of: Void.self)
        quiescingHelper.initiateShutdown(promise: p)
        try await withTaskCancellationHandler(
            operation: {
                try await p.futureResult.get()
            },
            onCancel: {
                serverChannel.channel.close(promise: p)
            })
    }

    public func shutdownGracefully() {
        quiescingHelper.initiateShutdown(promise: nil)
    }
}

extension Server : Service {}

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

public class ReadableBody: AsyncSequence {
    public typealias Element = ByteBuffer

    public let expectedContentLength: Int?

    @usableFromInline
    let trailers: EventLoopPromise<HTTPFields?>

    @usableFromInline
    typealias InboundStream = NIOAsyncChannelInboundStream<HTTPRequestPart>

    @usableFromInline
    var _internal: InboundStream.AsyncIterator

    @usableFromInline
    var wasRead: Bool = false

    @usableFromInline
    var fireFirstRead : (() -> ())!

    init(expectedContentLength: Int?, _internal: InboundStream.AsyncIterator, trailers: EventLoopPromise<HTTPFields?>, onFirstRead: @escaping () -> ()) {
        self._internal = _internal
        self.trailers = trailers
        self.expectedContentLength = expectedContentLength
        self.fireFirstRead = onFirstRead
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return .init(underlying: self, trailers: self.trailers)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var underlying: ReadableBody

        @usableFromInline
        let trailers: EventLoopPromise<HTTPFields?>

        @usableFromInline
        var isFirstRead = true

        @inlinable
        public mutating func next() async throws -> ByteBuffer? {
            do {
                if self.isFirstRead {
                    self.underlying.fireFirstRead()
                    self.underlying.fireFirstRead = nil
                    self.isFirstRead.toggle()
                }
                guard let next = try await underlying._internal.next() else {
                    //trailers.succeed(nil)
                    self.underlying.wasRead = true
                    return nil
                }

                switch next {
                    case .body(let buffer):
                        return buffer
                    case .end(let trailers):
                        self.trailers.succeed(trailers)
                        self.underlying.wasRead = true
                        return nil
                    default:
                        self.underlying.wasRead = true
                        throw Server.HTTPError.unexpectedHTTPPart(next)
                }
            } catch {
                trailers.fail(error)
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

public struct RequestReader {
    public var logger: Logger
    public let method: HTTPRequest.Method
    public let path: String
    public let headers: HTTPFields
    public let body: ReadableBody
    let _trailers: EventLoopFuture<HTTPFields?>
    public var trailers: HTTPFields? {
        get async throws {
            try await _trailers.get()
        }
    }

    public var userInfo: UserInfo = UserInfo()

    public var _eventLoop: any EventLoop

    init(
        logger: Logger,
        head: HTTPRequest,
        body: ReadableBody,
        _trailers: EventLoopFuture<HTTPFields?>,
        _eventLoop: any EventLoop
    ) {
        self.logger = logger
        self.method = head.method
        self.path = head.path!
        self.headers = head.headerFields
        self.body = body
        self._trailers = _trailers
        self._eventLoop = _eventLoop
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
