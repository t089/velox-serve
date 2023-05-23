import DequeModule
import Logging
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOPosix

public final class Server: Sendable {
    let serverChannel: Channel
    let quiescingHelper: ServerQuiescingHelper
    public let eventLoopGroup: EventLoopGroup

    init(
        serverChannel: Channel,
        quiescingHelper: ServerQuiescingHelper,
        eventLoopGroup: EventLoopGroup
    ) {
        self.serverChannel = serverChannel
        self.quiescingHelper = quiescingHelper
        self.eventLoopGroup = eventLoopGroup
    }

    public static func start(
        host: String,
        port: Int = 0,
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        logger: Logger = NoopLogger,
        handler: @escaping (RequestReader, inout ResponseWriter) async throws -> Void
    ) async throws -> Server {

        let quiescingHelper = ServerQuiescingHelper(group: group)

        @Sendable func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {

            channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withErrorHandling: true
            )
            .flatMap {
                channel.pipeline.addHandler(
                    HTTPHandler(
                        eventLoop: channel.eventLoop,
                        logger: logger,
                        handler: handler))
            }
        }

        let socketBootstrap = ServerBootstrap(group: group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            .serverChannelInitializer({ channel in
                channel.pipeline.addHandler(
                    quiescingHelper.makeServerChannelHandler(channel: channel))
            })

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer(childChannelInitializer(channel:))

            // Enable SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: true)

        let channel = try await socketBootstrap.bind(host: host, port: port).get()

        return Server(
            serverChannel: channel, quiescingHelper: quiescingHelper, eventLoopGroup: group)
    }

    public var localAddress: SocketAddress {
        serverChannel.localAddress!
    }

    public func run() async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await serverChannel.closeFuture.get()
            },
            onCancel: {
                serverChannel.close(promise: nil)
            })
    }

    public func shutdown() async throws {
        try await serverChannel.close()
    }

    public func shutdownGracefully() async throws {
        let p = self.eventLoopGroup.next().makePromise(of: Void.self)
        quiescingHelper.initiateShutdown(promise: p)
        try await withTaskCancellationHandler(
            operation: {
                try await p.futureResult.get()
            },
            onCancel: {
                serverChannel.close(promise: nil)
            })
    }
}

public struct ConnectionClosedError: Error {}

@usableFromInline
final class HTTPHandler: ChannelInboundHandler, ChannelOutboundHandler, @unchecked Sendable {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart
    public typealias OutboundIn = HTTPServerResponsePart

    enum State: CustomStringConvertible {

        enum RequestState: CustomStringConvertible {
            case streaming(
                head: HTTPRequestHead,
                body: RequestBodyStream,
                trailersPromise: EventLoopPromise<HTTPHeaders?>)
            case end(head: HTTPRequestHead)

            var description: String {
                switch self {
                case .streaming(let head, _, _):
                    return ".streaming(expects100Continue: \(head.expects100Continue))"
                case .end(head: _): return ".end"
                }
            }
        }

        enum ResponseState: CustomStringConvertible {
            case idle
            case waitingForHead(
                expects100Continue: Bool, task: Task<Void, Error>,
                sink: NIOAsyncWriter<ResponsePart, HTTPHandlerWriterSinkDelegate>.Sink)
            case headWritten(
                task: Task<Void, Error>,
                sink: NIOAsyncWriter<ResponsePart, HTTPHandlerWriterSinkDelegate>.Sink)
            case end

            var description: String {
                switch self {
                case .idle: return ".idle"
                case .waitingForHead(let expects100Continue, task: _, sink: _):
                    return ".waitingForHead(expects100Continue: \(expects100Continue))"
                case .headWritten(task: _, sink: _):
                    return ".headWritten"
                case .end: return ".end"
                }
            }
        }

        case idle
        case waitingForHead(context: ChannelHandlerContext)
        case executing(
            context: ChannelHandlerContext, request: RequestState, response: ResponseState)
        case errorCaught(Error)

        var description: String {
            switch self {
            case .idle: return ".idle"
            case .waitingForHead(_): return ".waitingForHead"
            case .executing(context: _, request: let req, response: let res):
                return ".executing(request: \(req), res: \(res))"
            case .errorCaught(let error): return ".errorCaught(\(error))"
            }
        }
    }

    @usableFromInline
    let eventLoop: EventLoop

    var state: State =
        .idle /* {
        didSet {
            print("** state from \n  \(oldValue) \n  -> \(self.state)")
        }
    }*/

    var shouldRead = true
    var pendingRead = false

    var readBuffer: ByteBuffer!

    var context: ChannelHandlerContext? {
        switch self.state {
        case .waitingForHead(context: let ctx),
            .executing(context: let ctx, _, _):
            return ctx
        default: return nil
        }
    }

    var logger: Logger
    let handler: (RequestReader, inout ResponseWriter) async throws -> Void

    init(
        eventLoop: EventLoop,
        logger: Logger,
        handler: @escaping (RequestReader, inout ResponseWriter) async throws -> Void
    ) {
        self.eventLoop = eventLoop
        self.logger = logger
        self.handler = handler
    }

    @usableFromInline
    typealias RequestBodyStream = NIOThrowingAsyncSequenceProducer<
        RequestStreamElement, Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, HTTPHandlerProducerDelegate
    >.NewSequence

    @usableFromInline
    func handlerAdded(context: ChannelHandlerContext) {
        self.state = .waitingForHead(context: context)
        self.readBuffer = context.channel.allocator.buffer(capacity: 0)
    }

    @usableFromInline
    func handlerRemoved(context: ChannelHandlerContext) {
        self.state = .idle
        self.readBuffer = nil
    }

    @usableFromInline
    typealias RequestStreamElement = ByteBuffer

    @usableFromInline
    var pendingBodyParts = CircularBuffer<ByteBuffer>()

    @usableFromInline
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case let .head(head):
            let seq: RequestBodyStream = NIOThrowingAsyncSequenceProducer.makeSequence(
                elementType: RequestStreamElement.self,
                backPressureStrategy:
                    NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                        lowWatermark: 512, highWatermark: 4096),
                delegate: HTTPHandlerProducerDelegate(handler: self))

            let newWriter = NIOAsyncWriter.makeWriter(
                elementType: ResponsePart.self, isWritable: context.channel.isWritable,
                delegate: HTTPHandlerWriterSinkDelegate(handler: self))

            let trailersPromise = context.eventLoop.makePromise(of: HTTPHeaders?.self)

            let out = ResponseWriter(
                allocator: context.channel.allocator,
                isKeepAlive: head.isKeepAlive,
                responsePartWriter: newWriter.writer,
                head: httpResponseHead(request: head, status: .ok))
            let `in` = RequestReader(
                logger: self.logger,
                head: head,
                body: ReadableBody(
                    expectedContentLength: head.headers.first(name: "Content-Length").flatMap(
                        Int.init),
                    _internal: seq,
                    onFirstRead: { self.eventLoop.execute { self.onFirstRequestRead() } }),
                _trailers: trailersPromise.futureResult)

            let responseTask = Task {
                var out = out
                do {
                    try await self.handler(`in`, &out)
                } catch {
                    self.logger.error("Unhandled error serving request: \(error)")
                    out.head = httpResponseHead(request: head, status: .internalServerError)
                }

                do {
                    try await out.end()
                } catch {
                    self.logger.error("Error sending request: \(error)")
                    throw error
                }
            }

            self.state = .executing(
                context: context,
                request: .streaming(head: head, body: seq, trailersPromise: trailersPromise),
                response: .waitingForHead(
                    expects100Continue: head.expects100Continue,
                    task: responseTask,
                    sink: newWriter.sink)
            )
        case .body(let buffer):
            self.pendingBodyParts.append(buffer)
        case .end(let trailers):
            switch self.state {

            case let .executing(context: context, request: requestState, response: responseState):
                switch requestState {
                case .streaming(let head, let body, let trailersPromise):
                    _ = body.source.yield(contentsOf: self.pendingBodyParts)
                    self.pendingBodyParts.removeAll(keepingCapacity: true)
                    trailersPromise.succeed(trailers)
                    body.source.finish()
                    self.shouldRead = true

                    self.state = .executing(
                        context: context, request: .end(head: head), response: responseState)
                case .end:
                    fatalError("Invalid.")
                }
            case .errorCaught(_): break  // we just ignore in error state
            default:
                fatalError("Unexpected request end in state \(self.state)")
            }

        }
    }

    @usableFromInline
    func channelReadComplete(context: ChannelHandlerContext) {
        let bodyParts = self.pendingBodyParts
        self.pendingBodyParts.removeAll(keepingCapacity: true)
        guard bodyParts.isEmpty == false else { return }

        switch self.state {
        case let .executing(_, request: requestState, response: _):
            switch requestState {
            case let .streaming(_, body: body, trailersPromise: _):
                let result = body.source.yield(contentsOf: bodyParts)
                switch result {
                case .dropped: break
                case .produceMore:
                    self.shouldRead = true
                    if self.pendingRead {
                        context.read()
                    }
                case .stopProducing:
                    self.shouldRead = false
                }
                break
            case .end:
                fatalError("invalid body parts received in request state: end.")
            }
        case .errorCaught(_): break
        default:
            fatalError("Invalid body parts received in \(self.state)")
        }

        context.fireChannelReadComplete()
    }

    @usableFromInline
    func read(context: ChannelHandlerContext) {
        if self.shouldRead {
            context.read()
            self.pendingRead = false
        } else {
            self.pendingRead = true
        }
    }

    @usableFromInline
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        switch self.state {
        case let .executing(context: _, request: _, response: responseState):
            switch responseState {
            case let .waitingForHead(expects100Continue: _, task: _, sink: sink),
                let .headWritten(task: _, sink: sink):
                sink.setWritability(to: context.channel.isWritable)
            default: break
            }
        default: break
        }

        if !context.channel.isWritable {
            context.flush()
        }

        context.fireChannelWritabilityChanged()
    }

    @usableFromInline
    func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case let .executing(_, request: requestState, response: responseState):
            switch requestState {
            case let .streaming(_, body: body, trailersPromise: trailers):
                body.source.finish(ConnectionClosedError())
                trailers.fail(ConnectionClosedError())
            default: break
            }

            switch responseState {
            case let .waitingForHead(expects100Continue: _, task: task, sink: sink),
                let .headWritten(task: task, sink: sink):
                task.cancel()
                sink.finish(error: ConnectionClosedError())
            default: break
            }

            self.state = .waitingForHead(context: context)
        default:
            self.logger.debug("Channel inactive in state \(self.state)")
            break
        }
    }

    @usableFromInline
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch self.state {
        case .waitingForHead:
            self.state = .errorCaught(error)
        case let .executing(_, request: requestState, response: responseState):
            switch requestState {
            case let .streaming(head: _, body: body, trailersPromise: trailers):
                body.source.finish(error)
                trailers.fail(error)
            default: break
            }

            switch responseState {
            case let .waitingForHead(expects100Continue: _, task: _, sink: sink),
                let .headWritten(task: _, sink: sink):
                sink.finish(error: error)
            default: break
            }

            self.state = .errorCaught(error)
        case .errorCaught(_), .idle:
            self.state = .errorCaught(error)
        }
        context.close(mode: .all, promise: nil)
    }

    func onFirstRequestRead() {
        self.eventLoop.preconditionInEventLoop()
        // guard let context else { return }
        // if we did not write any response yet, and the client expects a 100-continue,
        // write a 100 Continue response head
        switch self.state {
        case let .executing(
            context: context, request: .streaming(head, body, trailers),
            response: .waitingForHead(expects100Continue: true, task: task, sink: sink)):
            
            let continueHead = HTTPResponseHead(version: .http1_1, status: .continue)
            context.writeAndFlush(self.wrapOutboundOut(.head(continueHead)), promise: nil)
            self.state = .executing(
                context: context,
                request: .streaming(head: head, body: body, trailersPromise: trailers),
                response: .waitingForHead(expects100Continue: false, task: task, sink: sink))
        default: break
        }
    }
}

@usableFromInline
struct HTTPHandlerProducerDelegate: @unchecked Sendable, NIOAsyncSequenceProducerDelegate {

    @usableFromInline
    let eventLoop: EventLoop

    @usableFromInline
    let handler: HTTPHandler

    init(handler: HTTPHandler) {
        self.eventLoop = handler.eventLoop
        self.handler = handler
    }

    @inlinable
    func produceMore() {
        self.eventLoop.execute {
            self.handler._produceMore()
        }
    }

    @inlinable
    func didTerminate() {
        self.eventLoop.execute {
            self.handler._didTerminate()
        }
    }

}

extension HTTPHandler /*: NIOAsyncSequenceProducerDelegate */ {
    @usableFromInline
    func _produceMore() {

        self.shouldRead = true
        if self.pendingRead {
            self.pendingRead.toggle()
            self.context?.read()
        }
    }

    @usableFromInline
    func _didTerminate() {
        // continue reading to capture trailing headers
        self.shouldRead = true
        if self.pendingRead {
            self.pendingRead.toggle()
            context?.read()
        }
    }
}

@usableFromInline
struct HTTPHandlerWriterSinkDelegate: @unchecked Sendable, NIOAsyncWriterSinkDelegate {
    @usableFromInline
    let eventLoop: EventLoop

    @usableFromInline
    let _didYield: (DequeModule.Deque<ResponsePart>) -> Void

    @usableFromInline
    let _didTerminate: (Error?) -> Void

    init(handler: HTTPHandler) {
        self.eventLoop = handler.eventLoop
        self._didYield = handler._didYield(contentsOf:)
        self._didTerminate = handler._didTerminate(error:)
    }

    @inlinable
    func didYield(contentsOf sequence: DequeModule.Deque<ResponsePart>) {
        self.eventLoop.execute {
            self._didYield(sequence)
        }
    }

    @inlinable
    func didTerminate(error: Error?) {
        self.eventLoop.execute {
            self._didTerminate(error)
        }
    }

}

extension HTTPHandler /* : SinkDelegate */ {
    @usableFromInline
    func _didYield(contentsOf sequence: Deque<ResponsePart>) {
        self.eventLoop.preconditionInEventLoop()
        switch self.state {
        case .errorCaught(_): break
        case .idle: break
        case .waitingForHead(context: _): break

        case let .executing(context: context, request: requestState, response: responseState):
            for part in sequence {
                switch part {
                case .head(var head):

                    if head.status.code / 100 != 1 && head.headers["date"].isEmpty {
                        head.headers.add(name: "Date", value: UTCInstant.now.formatted())
                    }

                    context.write(self.wrapOutboundOut(.head(head)), promise: nil)

                    switch responseState {
                    case let .waitingForHead(expects100Continue: _, task: task, sink: sink):
                        if head.status == .continue {
                            self.state = .executing(
                                context: context, request: requestState,
                                response: .waitingForHead(
                                    expects100Continue: false, task: task, sink: sink))
                        } else if head.status.code / 100 != 1 {
                            self.state = .executing(
                                context: context, request: requestState,
                                response: .headWritten(task: task, sink: sink))
                        }
                    default: break
                    }

                case .bodyPart(let data):
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(data))), promise: nil)
                case .end(let trailers):
                    context.write(self.wrapOutboundOut(.end(trailers)), promise: nil)
                }
            }

            context.flush()
        }

    }

    @usableFromInline
    func _didTerminate(error: Error?) {
        self.eventLoop.preconditionInEventLoop()

        switch self.state {

        case let .executing(context: context, request: requestState, response: _):
            if let error {
                self.logger.debug("Response writer terminated with error: \(error)")
                context.close(mode: .output, promise: nil)
            } else {

                switch requestState {
                case .streaming(let head, let body, let trailersPromise):
                    context.flush()

                    if head.isKeepAlive == false {
                        context.close(mode: .output, promise: nil)
                    }

                    self.state = .executing(
                        context: context,
                        request: .streaming(
                            head: head, body: body, trailersPromise: trailersPromise),
                        response: .end)
                case .end(let head):
                    context.flush()

                    if head.isKeepAlive == false {
                        context.close(mode: .output, promise: nil)
                    }
                    self.state = .waitingForHead(context: context)
                }

            }
        default: break

        }
        self.logger.debug("Response writer terminated")
    }
}

extension HTTPRequestHead {
    var expects100Continue: Bool {
        self.headers["Expect"].contains("100-continue")
    }
}

public struct ReadableBody: AsyncSequence {
    public typealias Element = ByteBuffer

    public let expectedContentLength: Int?

    @usableFromInline
    let _internal: HTTPHandler.RequestBodyStream

    @usableFromInline
    let onFirstRead: () -> Void

    public func makeAsyncIterator() -> AsyncIterator {
        return .init(underlying: _internal.sequence.makeAsyncIterator(), onFirstRead: onFirstRead)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        var underlying:
            NIOThrowingAsyncSequenceProducer<
                HTTPHandler.RequestStreamElement, Error,
                NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
                HTTPHandlerProducerDelegate
            >.AsyncIterator

        @usableFromInline
        var onFirstRead: (() -> Void)?

        @usableFromInline
        var firstRead = true

        @inlinable
        public mutating func next() async throws -> ByteBuffer? {
            if let onFirstRead {
                onFirstRead()
                self.onFirstRead = nil
            }
            return try await underlying.next()
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

func httpResponseHead(
    request: HTTPRequestHead,
    status: HTTPResponseStatus,
    headers: HTTPHeaders = HTTPHeaders()
) -> HTTPResponseHead {
    var head = HTTPResponseHead(version: request.version, status: status, headers: headers)
    let connectionHeaders: [String] = head.headers[canonicalForm: "connection"].map {
        $0.lowercased()
    }

    if !connectionHeaders.contains("keep-alive") && !connectionHeaders.contains("close") {
        // the user hasn't pre-set either 'keep-alive' or 'close', so we might need to add headers

        switch (request.isKeepAlive, request.version.major, request.version.minor) {
        case (true, 1, 0):
            // HTTP/1.0 and the request has 'Connection: keep-alive', we should mirror that
            head.headers.add(name: "Connection", value: "keep-alive")
        case (false, 1, let n) where n >= 1:
            // HTTP/1.1 (or treated as such) and the request has 'Connection: close', we should mirror that
            head.headers.add(name: "Connection", value: "close")
        default:
            // we should match the default or are dealing with some HTTP that we don't support, let's leave as is
            ()
        }
    }
    return head
}

public struct RequestReader {
    public var logger: Logger
    public let head: HTTPRequestHead
    public let body: ReadableBody
    let _trailers: EventLoopFuture<HTTPHeaders?>
    public var trailers: HTTPHeaders? {
        get async throws {
            try await _trailers.get()
        }
    }

    public var userInfo: UserInfo = UserInfo()
}

@usableFromInline
enum ResponsePart {
    case head(HTTPResponseHead)
    case bodyPart(ByteBuffer)
    case end(HTTPHeaders?)
}

public struct ResponseWriter {
    let isKeepAlive: Bool

    @usableFromInline
    let responsePartWriter: NIOAsyncWriter<ResponsePart, HTTPHandlerWriterSinkDelegate>

    public var head: HTTPResponseHead
    public var status: HTTPResponseStatus {
        get {
            self.head.status
        }
        set {
            self.head.status = newValue
        }
    }
    public var headers: HTTPHeaders {
        get {
            self.head.headers
        }
        set {
            self.head.headers = newValue
        }
    }

    public var trailers: HTTPHeaders?

    init(
        allocator: ByteBufferAllocator,
        isKeepAlive: Bool,
        responsePartWriter: NIOAsyncWriter<ResponsePart, HTTPHandlerWriterSinkDelegate>,
        head: HTTPResponseHead
    ) {
        self.isKeepAlive = isKeepAlive
        self.responsePartWriter = responsePartWriter
        self.head = head
        self.writeBuffer = allocator.buffer(capacity: 4096)
    }

    private(set) var headerWritten: Bool = false
    private(set) var isDone: Bool = false

    @usableFromInline
    var writeBuffer: ByteBuffer

    public mutating func writeHead() async throws {
        precondition(self.headerWritten == false, "Header can only be written once.")
        try await self.responsePartWriter.yield(.head(self.head))
        if self.head.status.code / 100 != 1 {
            self.headerWritten.toggle()
        }
    }

    @usableFromInline
    internal mutating func writeHeadIfNecessary() async throws {
        guard self.headerWritten == false else {
            return
        }
        precondition(self.head.status.code / 100 != 1, "Head must not be 1xx")
        try await self.writeHead()
    }

    public mutating func writeBodyPart(_ string: String) async throws {
        try await self.writeBodyPart(string.utf8)
    }

    public mutating func writeBodyPart(_ string: Substring) async throws {
        try await self.writeBodyPart(string.utf8)
    }

    public mutating func writeBodyPart(_ data: UInt8) async throws {
        self.writeBuffer.writeInteger(data)
        try await self.flushIfNecessary()
    }

    @inlinable
    public mutating func writeBodyPart(_ data: some Sequence<UInt8>) async throws {
        self.writeBuffer.writeBytes(data)
        try await self.flushIfNecessary()
    }

    @inlinable
    public mutating func writeBodyPart(_ data: inout ByteBuffer) async throws {
        if data.readableBytes > 0 {
            self.writeBuffer.writeBuffer(&data)
            try await self.flushIfNecessary()
        }
    }

    @inlinable
    mutating func flushIfNecessary() async throws {
        try await self.writeHeadIfNecessary()
        if self.writeBuffer.readableBytes >= 163840 {
            try await responsePartWriter.yield(
                .bodyPart(self.writeBuffer.readSlice(length: self.writeBuffer.readableBytes)!))
        }
    }

    @inlinable
    public mutating func flush() async throws {
        try await self.writeHeadIfNecessary()
        if self.writeBuffer.readableBytes > 0 {
            try await responsePartWriter.yield(
                .bodyPart(self.writeBuffer.readSlice(length: self.writeBuffer.readableBytes)!))
        }
    }

    internal mutating func end() async throws {
        precondition(self.isDone == false)
        self.isDone.toggle()
        try await self.flush()
        try await responsePartWriter.yield(.end(self.trailers))
        self.responsePartWriter.finish()
    }

    public mutating func plainText(_ text: String) async throws {
        self.head.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
        let data = text.utf8
        self.head.headers.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
        try await self.writeBodyPart(data)
    }
}

public let NoopLogger = Logger(label: "noop", factory: SwiftLogNoOpLogHandler.init)
