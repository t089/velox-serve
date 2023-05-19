import ArgumentParser
import Logging
import NIO
import VeloxServe

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
        let start = ContinuousClock().now
        var uploadedBytes = 0
        for try await buffer in req.body {
            uploadedBytes += buffer.readableBytes
        }
        let elapsed = .now - start
        try await res.plainText("You uploaded \(uploadedBytes) bytes (\(Double(uploadedBytes)/elapsed.seconds/1024.0/1024.0) MB/s)")
    }

    func chunked(req: RequestReader, res: inout ResponseWriter) async throws {
        res.head.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
        for i in 1...10 {
            try await res << "Chunk \(i)\n"
            try await Task.sleep(for: .seconds(0.5))
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

extension Duration {
    var seconds: Double {
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
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
        let start = ContinuousClock().now
        do {
            try await serve(req, &res)
            let duration = .now - start
            logger.info(
                "\(req.head.method) \(req.head.uri) - \(res.head.status.code) - \(duration)")
        } catch {
            let duration = .now - start
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
