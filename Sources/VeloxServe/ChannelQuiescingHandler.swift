import NIO
import NIOHTTP1
import Logging


final class ChannelQuiescingHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart
    typealias InboundIn = HTTPServerRequestPart

    private(set) var logger: Logger
    init(logger: Logger) {
        self.logger = logger
    }
    
    enum InboundState {
        case waitingForHead
        case waitingForEnd
    }

    enum OutboundState {
        case waitingForHead
        case waitingForEnd
        case idle
    }

    private var state: (inbound: InboundState, outbound: OutboundState) = (.waitingForHead, .idle)

    private var shouldCloseAfterEnd = false

    func channelActive(context: ChannelHandlerContext) {
        self.shouldCloseAfterEnd = false
        self.state = (.waitingForHead, .idle)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
            case .head:
                self.state.inbound = .waitingForEnd
                self.state.outbound = .waitingForHead
            case .body: break
            case .end:
                self.state.inbound = .waitingForHead
                self.closeConnectionIfNecessary(context: context)
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        switch part {
            case .head(var head) where head.status.code / 100 != 1:
                self.state.outbound = .waitingForEnd
                if self.shouldCloseAfterEnd {
                    head.headers.replaceOrAdd(name: "Connection", value: "close")
                }
                context.write(self.wrapOutboundOut(.head(head)), promise: promise)
            case .end(_):
                self.state.outbound = .idle
                let p = context.eventLoop.makePromise(of: Void.self)
                context.writeAndFlush(data, promise: p)
                self.closeConnectionIfNecessary(context: context)
                
            default:
                context.write(data, promise: promise)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelShouldQuiesceEvent {
            self.shouldCloseAfterEnd = true
            self.closeConnectionIfNecessary(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func closeConnectionIfNecessary(context: ChannelHandlerContext) {
        if self.shouldCloseAfterEnd && self.state.inbound == .waitingForHead && self.state.outbound == .idle {
            logger.trace("Closing inactive connection after graceful shutdown")
            context.close(promise: nil)
        }
    }
}