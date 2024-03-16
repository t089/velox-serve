import ArgumentParser
import Logging
import NIO
import VeloxServe
import Dispatch

@main
struct Example: AsyncParsableCommand {
    @Option
    var listen: String

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

        var hostAndPort = self.listen.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let (host, port) = (
            String(hostAndPort.removeFirst()), hostAndPort.first.flatMap { Int(String($0)) } ?? 0
        )

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let logger = Logger(label: "main")

        let server = try await Server.start(
            host: host, port: port, group: elg, logger: logger,
            handler: loggingServe(logger, serve: self.serve))
        logger.info("Server listening on: \(server.localAddress)")
        try await server.run()
    }

    func serve(req: RequestReader, res: inout ResponseWriter) async throws {
        switch req.head.uri {
            case "/": try await res.plainText("Hello, world!\r\n")
            case "/upload": try await upload(req: req, res: &res)
            case "/chunked": try await chunked(req: req, res: &res)
            case "/echo": try await echo(req: req, res: &res)
            case "/random": try await random(req: req, res: &res)

            default: 
                res.head.status = .notFound
                try await res.plainText("ERROR: Not found")
        }
    }

    func upload(req: RequestReader, res: inout ResponseWriter) async throws {
        if req.head.headers["Expect"].contains("100-continue") {
            res.head.status = .continue
            try await res.writeHead()
        }
        res.head.status = .ok
        let start = DispatchTime.now()
        var uploadedBytes = 0
        for try await buffer in req.body {
            uploadedBytes += buffer.readableBytes
        }
        let elapsed = start.distance(to: .now())
        try await res.plainText("You uploaded \(uploadedBytes) bytes (\(Double(uploadedBytes)/elapsed.seconds/1024.0/1024.0) MB/s)")
    }

    func chunked(req: RequestReader, res: inout ResponseWriter) async throws {
        res.head.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
        for i in 1...10 {
            try await res << "Chunk \(i)\n"
            try await Task.sleep(nanoseconds: 0_500_000_000)
        }
        try await res << "End\n" 
    }

    func echo(req: RequestReader, res: inout ResponseWriter) async throws {
        if req.head.headers["Expect"].contains("100-continue") {
            res.head.status = .continue
            try await res.writeHead()
        }
        res.head.status = .ok
        
        if let contentType = req.head.headers.first(name: "Content-Type") {
            res.head.headers.add(name: "Content-Type", value: contentType)
        }
        if let contentLength = req.head.headers.first(name: "Content-Length") {
            res.head.headers.add(name: "Content-Length", value: contentLength)
        }
        var count = 0
        for try await var buffer in req.body {
            count += buffer.readableBytes
            try await res.writeBodyPart(&buffer)
        }
        print("Echoed \(count)")
        
    }
    
    
    
    func random(req: RequestReader, res: inout ResponseWriter) async throws {
        
        res.head.headers.replaceOrAdd(name: "Content-Length", value: "\(randomStaticBuffer.count)")
        res.head.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
        
        try await res.writeBodyPart(randomStaticBuffer)
        
    }
}

extension DispatchTimeInterval {
    var seconds: Double {
        switch self {
            case .seconds(let s):      return Double(s)
            case .milliseconds(let s): return Double(s)/1_000.0
            case .microseconds(let s): return Double(s)/1_000_000.0
            case .nanoseconds(let s):  return Double(s)/1_000_000_000.0
            case .never: return Double.greatestFiniteMagnitude
            @unknown default:
                return 0.0
        }
    }
}

let randomStaticBuffer : UnsafeMutableBufferPointer<UInt8> = {
    let count = 1024 * 1024 * 10
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: count)
    buffer.initialize(repeating: 0)
    
    
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8.withContiguousStorageIfAvailable { alphabet in
        for i in 0..<count {
            buffer[i] = alphabet[i % alphabet.count]
        }
    }
    return buffer
}()

func loggingServe(
    _ logger: Logger, serve: @escaping (RequestReader, inout ResponseWriter) async throws -> Void
) -> (RequestReader, inout ResponseWriter) async throws -> Void {
    { req, res in
        let start = DispatchTime.now()
        do {
            try await serve(req, &res)
            let duration = start.distance(to: .now())
            logger.info(
                "\(req.head.method) \(req.head.uri) - \(res.head.status.code) - \(duration)")
        } catch {
            let duration = start.distance(to: .now())
            logger.error("\(req.head.method) \(req.head.uri) - ERROR - \(duration): \(error)")
            throw error
        }
    }
}

infix operator <<
func <<(lhs: inout ResponseWriter, rhs: String) async throws {
    try await lhs.writeBodyPart(rhs)
    try await lhs.flush()
}

func <<(lhs: inout ResponseWriter, rhs: any CustomStringConvertible) async throws {
    try await lhs.writeBodyPart("\(rhs)")
    try await lhs.flush()
}