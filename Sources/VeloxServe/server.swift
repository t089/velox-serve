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
        group: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
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
        group: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
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

        enum ChannelReadyAction {
            case resumeWaiters([CheckedContinuation<State.Running, Error>], State.Running)
            case closeChannel(Channel)
        }
        
        let readyAction : ChannelReadyAction = self.state.withLockedValue { state in
            switch state {
                case .starting(waiters: let waiters):
                    var continuation: AsyncStream<Void>.Continuation!
                    let stream = AsyncStream<Void>() { continuation = $0 }
                    let runningState = State.Running(serverChannel: channel, quiescingHelper: quiescingHelper, logger: configuration.logger, handler: configuration.handler, shutdownSignal: (continuation, stream))
                    state = .running(runningState)
                    return .resumeWaiters(waiters, runningState)
                case .shutdown: // we got shutdown while starting up
                    return .closeChannel(channel.channel)
                case .initialized, .running, .shuttingDown:
                    preconditionFailure("Invalid state while starting: \(state)")
            }
        }

        switch readyAction {
            case .resumeWaiters(let waiters, let runningState):
                for waiter in waiters {
                    waiter.resume(returning: runningState)
                }

                return runningState
            case .closeChannel(let channel):
                channel.close(promise: nil)
                throw ServerError.shuttingDown
        }
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
                        isKeepAlive: head.isKeepAlive,
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
                
                // errors here indicate that the connection died, we can safely ignore this and close the connection
                let nextPart = try? await inboundIterator.next()    

                guard let nextPart else {
                    // if nil, break out of the loop (close the connection)
                    break
                }

                guard case .head(let newHead) = nextPart else {
                    throw HTTPError.unexpectedHTTPPart(nextPart)
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


extension HTTPRequest {
    var isKeepAlive: Bool {
        self.headerFields[.connection] != "close"
    }
}

fileprivate func httpResponse(
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







public let NoopLogger = Logger(label: "noop", factory: SwiftLogNoOpLogHandler.init)