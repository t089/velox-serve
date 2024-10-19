import ArgumentParser
import Logging
import NIO
import VeloxServe
import Dispatch
import ServiceLifecycle


struct ListenAddress {
    var host: String
    var port: Int
}

extension ListenAddress: ExpressibleByArgument {
    init?(argument: String) {
        var hostAndPort = argument.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let (host, port) = (
            String(hostAndPort.removeFirst()), hostAndPort.first.flatMap { Int(String($0)) } ?? 0
        )

        self.init(host: host, port: port)
    }
}

@main
struct Example: AsyncParsableCommand {
    @Option
    var listen: ListenAddress

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

        let elg = MultiThreadedEventLoopGroup.singleton

        let logger: Logger = {
            var logger =  Logger(label: "main")
            logger.logLevel = .trace
            return logger
        }()

        let server = Server(
            host: self.listen.host, port: self.listen.port, name: "Example", group: elg, logger: logger,
            handler: AnyHandler(loggingServe(logger, serve: self.serve)).instrumented())
        
        let group = ServiceGroup(
            services: [ server ],
            gracefulShutdownSignals: [ .sigterm, .sigint ],
            cancellationSignals: [ ],
            logger: logger)
        try await group.run()
    }

    @Sendable func serve(req: RequestReader, res: any ResponseWriter) async throws {
        switch req.path {
            case "/": 
                req.route = "/"
                try await res.plainText("Hello, world!\r\n")
            case "/upload": 
                req.route = "/upload"
                try await upload(req: req, res: res)
            case let path where path.hasPrefix("/chunked"): 
                req.route = "/chunked"
                try await chunked(req: req, res: res)
            case "/echo":
                req.route = "/echo"
                try await echo(req: req, res: res)
            case "/random":
                req.route = "/random"
                try await random(req: req, res: res)

            default: 
                res.status = .notFound
                try await res.plainText("ERROR: Not found")
        }
    }

    func upload(req: RequestReader, res: any ResponseWriter) async throws {
        if req.headers[values: .expect].contains("100-continue") {
            res.status = .continue
            try await res.writeHead()
        }
        res.status = .ok
        let start = DispatchTime.now()
        var uploadedBytes = 0
        for try await buffer in req.body {
            uploadedBytes += buffer.readableBytes
        }
        let elapsed = start.distance(to: .now())
        try await res.plainText("You uploaded \(uploadedBytes) bytes (\(Double(uploadedBytes)/elapsed.seconds/1024.0/1024.0) MB/s)")
    }

    func chunked(req: RequestReader, res: any ResponseWriter) async throws {
        res.headers[.contentType] = "text/plain"

        let numberOfChunks = req.path.components(separatedBy: "/").last.flatMap { Int($0) } ?? 10

        for i in 1...numberOfChunks {
            try await res << "Chunk \(i)\n"
            try await Task.sleep(nanoseconds: 0_500_000_000)
        }
        try await res << "End\n" 
    }

    func echo(req: RequestReader, res: any ResponseWriter) async throws {
        /**/
        res.status = .ok
        
        if let contentType = req.headers[.contentType] {
            res.headers[.contentType] = contentType
        }
        if let contentLength = req.headers[.contentLength] {
            res.headers[.contentLength] = contentLength
        }
        var count = 0

        if req.headers[values: .expect].contains("100-continue") {
            res.status = .continue
            try await res.writeHead()
        }

        res.status = .ok

        for try await var buffer in req.body {
            count += buffer.readableBytes
            try await res.writeBodyPart(&buffer)
        }
        print("Echoed \(count)")
        
    }
    
    
    
    func random(req: RequestReader, res: any ResponseWriter) async throws {
        
        res.headers[.contentLength] = "\(randomStaticBuffer.value.count)"
        res.headers[.contentType] =  "text/plain"
        
        try await res.writeBodyPart(randomStaticBuffer.value)
        
    }
}

extension DispatchTimeInterval {
    var seconds: Double {
        return millis / 1000.0
    }
    
    var millis: Double {
        switch self {
        case .seconds(let s):      return Double(s) * 1000.0
            case .milliseconds(let s): return Double(s)
            case .microseconds(let s): return Double(s)/1_000.0
            case .nanoseconds(let s):  return Double(s)/1_000_000.0
            case .never: return Double.greatestFiniteMagnitude
            @unknown default:
                return 0.0
        }
    }
}

struct UnsafeSendableBox<Value> : @unchecked Sendable {
    let value: Value
}

let randomStaticBuffer : UnsafeSendableBox<UnsafeMutableBufferPointer<UInt8>> = {
    let count = 1024 * 1024 * 10
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: count)
    buffer.initialize(repeating: 0)
    
    
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8.withContiguousStorageIfAvailable { alphabet in
        for i in 0..<count {
            buffer[i] = alphabet[i % alphabet.count]
        }
    }
    return .init(value: buffer)
}()

@Sendable func loggingServe(
    _ logger: Logger, serve: @Sendable @escaping (RequestReader, any ResponseWriter) async throws -> Void
) -> @Sendable (RequestReader, any ResponseWriter) async throws -> Void {
    { req, res in
        let start = DispatchTime.now()
        do {
            try await serve(req, res)
            let duration = start.distance(to: .now())
            logger.info(
                "\(req.method) \(req.path) - \(res.status.code) - \(duration.millis.formatted(3))ms")
        } catch {
            let duration = start.distance(to: .now())
            logger.error("\(req.method) \(req.path) - ERROR - \(duration): \(error)")
            throw error
        }
    }
}

extension Double {
    func formatted(_ decimalPlaces: Int) -> String {
        let factor = pow(10, Double(decimalPlaces))
        let rounded = (self * factor).rounded()
        return "\(rounded/factor)"
    }
}

infix operator <<
func <<(lhs: any ResponseWriter, rhs: String) async throws {
    try await lhs.writeBodyPart(rhs)
}

func <<(lhs: any ResponseWriter, rhs: any CustomStringConvertible) async throws {
    try await lhs.writeBodyPart("\(rhs)")
}