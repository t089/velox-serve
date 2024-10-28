 import NIO
 import NIOHTTP1


 final class AutomaticContinueHandler : ChannelDuplexHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    enum State: Equatable {
        case waitingForHead
        case waitingForBody(expect100Continue: Bool)
        case streaming


        enum ReadAction {
            case doNothing
            case send100Continue
        }

        enum WriteAction {
            case doNothing
            case dropWrite
        }

        mutating func headReceived(_ head: HTTPRequestHead){
            switch self {
                case .waitingForHead:
                    let expects100 = head.headers["Expect"].contains("100-continue")
                    self = .waitingForBody(expect100Continue: expects100)
                default: break
            }
        }

        mutating func bodyReceived() {
            switch self {
                case .waitingForBody(expect100Continue: _): 
                    self = .streaming
                default: break
            }
        }

        mutating func endReceived() {
            switch self {
                case .waitingForBody, .streaming:
                    self = .waitingForHead
                default: break
            }
        }

        mutating func read() -> ReadAction {
            switch self {
                case .waitingForBody(expect100Continue: true): 
                    self = .waitingForBody(expect100Continue: false)
                    return .send100Continue
                default:
                    return .doNothing
            }
        }

        mutating func write(part: HTTPServerResponsePart) -> WriteAction {
            switch (self, part) {
                case (.waitingForBody(expect100Continue: false), .head(let head)) where head.status == .continue,
                     (.streaming,                                .head(let head)) where head.status == .continue: 
                    return .dropWrite
                case (.waitingForBody(expect100Continue: true), _): 
                    self = .waitingForBody(expect100Continue: false)
                    return .doNothing
                default:
                    return .doNothing
            }
        }
    }

    private var state = State.waitingForHead

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
            case .head(let head):
                self.state.headReceived(head)
            case .body:
                self.state.bodyReceived()
            case .end:
                self.state.endReceived()
        }
        context.fireChannelRead(data)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
            case is FirstReadEvent:
                let action = self.state.read()
                switch action {
                    case .doNothing: break
                    case .send100Continue:
                        let response = HTTPServerResponsePart.head(.init(version: .http1_1, status: .continue))
                        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
                }
            default:
                context.triggerUserOutboundEvent(event, promise: promise)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        switch self.state.write(part: part) {
            case .doNothing:
                context.write(data, promise: promise)
            case .dropWrite:
                // not forwarding the write
                promise?.succeed()
        }
    }
 }

 struct FirstReadEvent {} 