import NIO
import HTTPTypes
import NIOHTTP1


final class OutboundHeaderHandler<C : Clock> : ChannelOutboundHandler where C.Instant == UTCInstant {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    let clock: C 
    let serverName: String?
    init(clock: C, serverName: String?) {
        self.clock = clock
        self.serverName = serverName
    }

    var cachedValue : (Int, String)? = nil

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let response = unwrapOutboundIn(data)
        switch response {
        case .head(var head) where head.status.code / 100 != 1:

            var additionalHeaders : [(String, String)] = []

            if let serverName, head.headers["server"].isEmpty {
                additionalHeaders.append(("Server", serverName))
            }
            
            if head.headers["date"].isEmpty {
                let now = clock.now
                var value: String
                if let cachedValue = cachedValue, cachedValue.0 == now.components.seconds {
                    value = cachedValue.1
                } else {
                    value = now.formatted()
                    cachedValue = (now.components.seconds, value)
                }
                
                additionalHeaders.append(("Date", value))
            }

            head.headers = HTTPHeaders(additionalHeaders + head.headers)

            context.write(wrapOutboundOut(.head(head)), promise: promise)
        default:
            context.write(data, promise: promise)
        }
    }
}
