import XCTest
import VeloxServe
import AsyncHTTPClient
import NIO
import HTTPTypes
import NIOHTTPTypes
import NIOHTTPTypesHTTP1

final class VeloxServeTests: XCTestCase {

    var client: HTTPClient!

    override func setUp() async throws {
        client = HTTPClient(eventLoopGroupProvider: .shared(NIOSingletons.posixEventLoopGroup))
    }

    override func tearDown() {
        try! client.syncShutdown()
    }


    func testSimpleGet() async throws {
        let server = try await Server.start(host: "localhost") { req, res in 
            try await res.plainText("Hello, World")
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        
        let req =  HTTPClientRequest(url: "http://localhost:\(server.localAddress.port!)/")
        let response = try await client.execute(req, deadline: .now() + .seconds(2))
        let body = try await response.body.collect(upTo: 1024).readableBytesView
        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("Hello, World", String(decoding: body, as: UTF8.self))
        XCTAssertNotNil(response.headers.first(name: "Date"))
        XCTAssertEqual("velox-serve", response.headers.first(name: "Server"))

        let dateRegex : Regex = ##/(Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-3][0-9]) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([0-9]{4}) ([01][0-9]|2[0-3])(:[0-5][0-9]){2} GMT$/##
        try _ = dateRegex.wholeMatch(in: response.headers.first(name: "Date") ?? "")

        try await server.shutdown()
    }

    private func withServer<T>(handler: @escaping AnyHandler.Handler, _ body: @escaping (Server) async throws -> T) async throws ->  T {
        let server = try await Server.start(host: "localhost", handler: AnyHandler(handler))
    
        return try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                try await server.run()
            }
            defer {
                group.cancelAll()
            }

            return try await body(server)
        }
        
        
    }

    func testReadingRequestPartially() async throws {
        let result = try await withServer { req, res in
            for try await var buffer in req.body.prefix(2) {
                try await res.writeBodyPart(&buffer)
            }
        } _: { server in
            try await SimpleClient.execute(host: "localhost", port: server.localAddress.port!) { inbound, outbound in
                let parts = (1...10).map { "Part \($0)\r\n" }
                try await outbound.write(.head(HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/")))
                for part in parts {
                    try await outbound.write(.body(ByteBuffer(string: part)))
                }
                try await outbound.write(.end(nil))

                return try await inbound.readFullResponse()
            }
        }

        XCTAssertEqual(.ok, result.0.status)
        XCTAssertEqual("Part 1\r\nPart 2\r\n", String(decoding: result.1.readableBytesView, as: UTF8.self))
    }

    func testMassiveParallelism() async throws {
        actor Counter {
            var value: Int

            init(initialValue: Int) { self.value = initialValue }

            func increment() -> Int {
                value = value + 1
                return value
            }
        }

        let counter = Counter(initialValue: 0)

        let server = try await Server.start(host: "localhost") { req, res in 
            let v = await counter.increment()
            try await res.plainText("\(v)")
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        let N = 1000

        let result = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
            
            for _ in 0..<N {
                group.addTask { [client] in
                    let req = HTTPClientRequest(url: "http://localhost:\(server.localAddress.port!)/")
                    let response = try await client!.execute(req, deadline: .now() + .seconds(2))
                    let body = try await response.body.collect(upTo: 1024).readableBytesView
                    return Int(String(decoding: body, as: UTF8.self))!
                }
            }

            var results = [Int]()
            while let result = try await group.next() {
                
                results.append(result)
                if results.count == N {
                    break
                }
                
            }
            group.cancelAll()

            return results
        }

        XCTAssertEqual(N, result.count)
        XCTAssertEqual((1...N).map({$0}), result.sorted())
    }


    func testRedirect() async throws {
        let server = try await Server.start(host: "localhost") { req, res in 
            switch req.path {
                case "/first":
                    res.status = .permanentRedirect
                    res.headers[.location] =  "/second"
                case "/second":
                    try await res.plainText("OK")
                default:
                    res.status = .notFound
            }
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 
        
        let req =  HTTPClientRequest(url: "http://localhost:\(server.localAddress.port!)/first")
        let response = try await client.execute(req, deadline: .now() + .seconds(2))
        let body = try await response.body.collect(upTo: 1024).readableBytesView
        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("OK", String(decoding: body, as: UTF8.self))

    }


    func testUpload() async throws {
        let size = 1024 * 1024 // 1MB

        actor UploadedData {
            var data = ByteBuffer()

            func setData(_ data: ByteBuffer) {
                self.data = data
            }
        }

        let uploadedData = UploadedData()

        let server = try await Server.start(host: "localhost") { req, res in 
            XCTAssertEqual(req.method, .post)
            XCTAssertEqual(req.body.expectedContentLength, size)
            let data = try await req.body.collect(upTo: req.body.expectedContentLength ?? .max)
            
            try await res.plainText("Uploaded \(data.readableBytes) bytes")
            await uploadedData.setData(data)
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        var uploadData = ByteBufferAllocator().buffer(capacity: size)
        for _ in 0..<size {
            uploadData.writeInteger(UInt8.random(in: 0...UInt8.max))
        }

        var req = HTTPClientRequest(url: "http://localhost:\(server.localAddress.port!)/")
        req.body = .bytes(uploadData)
        req.method = .POST

        let response = try await client.execute(req, deadline: .now() + .seconds(6))
        let body = try await response.body.collect(upTo: 1024).readableBytesView
        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("Uploaded \(size) bytes", String(decoding: body, as: UTF8.self))
        let receivedData = await uploadedData.data
        XCTAssertEqual(uploadData, receivedData)
    }

    func testUploadTooLarge() async throws {
        let size = 1024 * 64 // 64kb

        let server = try await Server.start(host: "localhost") { req, res in 
            XCTAssertEqual(req.method, .post)
            XCTAssertEqual(req.body.expectedContentLength, size)
            do {
                let data = try await req.body.collect(upTo: 32 * 1024)
                try await res.plainText("Uploaded \(data.readableBytes) bytes")
            } catch is TooManyBytesError {
                res.status = .badRequest
                try await res.plainText("Too many bytes")
            }
            
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        var req = HTTPClientRequest(url: "http://localhost:\(server.localAddress.port!)/")
        req.body = .bytes([UInt8](repeating: 0, count: size))
        req.method = .POST

        let response = try await client.execute(req, deadline: .now() + .seconds(6))
        let body = try await response.body.collect(upTo: 1024).readableBytesView
        XCTAssertEqual(.badRequest, response.status)
        XCTAssertEqual("Too many bytes", String(decoding: body, as: UTF8.self))

    }


    func testConcurrentRequests() async throws {
        let N = 10

        actor Counter {
            private(set) var int = 0
            func increment() -> Int {
                self.int += 1
                return int
            }
        }

        let counter = Counter()

        let server = try await Server.start(host: "localhost") { req, res in 
            try await res.plainText("\(counter.increment())")
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        let port = server.localAddress.port!

        let responses : [Int] = try await withThrowingTaskGroup(of: Int?.self) { group in 
            for _ in 0..<N {
                group.addTask { [client] in
                    let req = HTTPClientRequest(url: "http://localhost:\(port)/")
                    let response = try await client!.execute(req, deadline: .now() + .seconds(2))
                    let body = try await response.body.collect(upTo: 1024).readableBytesView
                    return Int(String(decoding: body, as: UTF8.self))
                }
            }

            var results = [Int]()
            while let result = try await group.next() {
                if let result {
                    results.append(result)
                }
            }

            return results.sorted()
        }

        XCTAssertEqual(N, responses.count)
        XCTAssertEqual(Array(1...N), responses)
    }


    func testStreamingEcho() async throws {
        let size = 1024 * 128 // 128kb

        let server = try await Server.start(host: "localhost") { req, res in 
            XCTAssertEqual(req.method, .post)
            XCTAssertEqual(req.body.expectedContentLength, size)
            
            for try await var chunk in req.body {
                try await res.writeBodyPart(&chunk)
            }

            try await res.end()
        }

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel()}

        
        let chunkSize = 1024
        var sentBytes = 0
        var req = HTTPClientRequest(url: "http://localhost:\(server.localAddress.port!)/")
        let stream = AsyncStream<ByteBuffer>() { cont in 
            var buffer = ByteBuffer()
            for _ in 0..<(size / chunkSize) {
                let remaining = size - sentBytes
                buffer.writeString(String(repeating: "x", count: min(chunkSize, remaining)))
                sentBytes += buffer.readableBytes
                cont.yield(buffer.readSlice(length: buffer.readableBytes)!)
            }
            cont.finish()
        }
        req.method = .POST
        req.body = .stream(stream, length: .known(Int64(size)))
        let response = try await self.client.execute(req, deadline: .now() + .seconds(2))
        let body = try await response.body.collect(upTo: 2*size).readableBytesView

        XCTAssertEqual(size, body.count)
        
    }

}

enum HTTPError: Error {
    case unexpectedHTTPPart(HTTPResponsePart?)
}

enum SimpleClient {
    static func execute<Result>(host: String, port: Int, _ work: @escaping (NIOAsyncChannelInboundStream<HTTPResponsePart>, NIOAsyncChannelOutboundWriter<HTTPRequestPart>) async throws -> (Result)) async throws -> Result {
        let channel : NIOAsyncChannel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .connect(host: host, port: port) { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(HTTP1ToHTTPClientCodec())
                }.flatMapThrowing {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: HTTPResponsePart.self,
                            outboundType: HTTPRequestPart.self)
                        )
                }

            }
        
        return try await channel.executeThenClose(work)
    }
}

extension NIOAsyncChannelInboundStream<HTTPResponsePart> {
    func readFullResponse() async throws -> (HTTPResponse, ByteBuffer) {
        var response: HTTPResponse?
        var body = ByteBuffer()
        for try await part in self {
            switch part {
            case .head(let head):
                response = head
            case .body(var buf):
                body.writeBuffer(&buf)
            case .end:
                guard let response = response else {
                    throw HTTPError.unexpectedHTTPPart(part)
                }
                return (response, body)
            }
        }
        throw HTTPError.unexpectedHTTPPart(nil)
    }
}