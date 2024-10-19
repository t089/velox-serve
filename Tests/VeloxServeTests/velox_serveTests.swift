import XCTest
import VeloxServe
import AsyncHTTPClient
import NIO
import HTTPTypes
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import Logging
import NIOConcurrencyHelpers


final class VeloxServeTests: XCTestCase {

    var client: HTTPClient!

     

    override func setUp() async throws {
        client = HTTPClient(eventLoopGroupProvider: .shared(NIOSingletons.posixEventLoopGroup))
    }

    override func tearDown() {
        try! client.syncShutdown()
    }

    // configure a server and connect with a client
    private func withServer<T>(handler: @escaping AnyHandler.Handler, client: @escaping SimpleClient.ClientHandler<T>) async throws ->  T {
        let server = Server(host: "localhost", handler: AnyHandler(handler))
    
        return try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                try await server.run()
            }
            defer {
                group.cancelAll()
            }
            let address = try await server.start()
            return try await SimpleClient.execute(host: "localhost", port: address.port!, client)
        }
    }

    func testSimpleGet() async throws {
        let server = Server(host: "localhost", name: "velox-serve") { req, res in 
            try await res.plainText("Hello, World")
        }
        let localAddress = try await server.start()
        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        
        let req =  HTTPClientRequest(url: "http://localhost:\(localAddress.port!)/")
        let response = try await client.execute(req, deadline: .now() + .seconds(2))
        let body = try await response.body.collect(upTo: 1024).readableBytesView
        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("Hello, World", String(decoding: body, as: UTF8.self))
        XCTAssertNotNil(response.headers.first(name: "Date"))
        XCTAssertEqual("velox-serve", response.headers.first(name: "Server"))

        let dateRegex : Regex = ##/(Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-3][0-9]) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([0-9]{4}) ([01][0-9]|2[0-3])(:[0-5][0-9]){2} GMT$/##
        try _ = dateRegex.wholeMatch(in: response.headers.first(name: "Date") ?? "")
    }

    func testShutdownMethod() async throws {
        let server = Server.init(host: "localhost", name: "velox-serve") { req, res in 
            try await res.plainText("Hello, World")
        }

        
        let serverTask = Task {
            try await server.run()
        }
        
        try await Task.sleep(for: .seconds(1))

        server.shutdown()
        let _ = try await serverTask.value
    }

    func testTrailers() async throws {
        let xTest = HTTPField.Name("x-test")!
        let result = try await withServer { req, res in 
            // reading trailers before the body, discards the body
            res.trailers = try await req.trailers
            // this should not do anything
            for try await var buffer in req.body {
                try await res.writeBodyPart(&buffer)
            }
            try await res.writeBodyPart("EOF\r\n")
        } client: { inbound, outbound in 
            try await outbound.write(.head(HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/")))
            try await outbound.write(.body(ByteBuffer(string: "Hello, World\r\n")))
            try await outbound.write(.end([xTest: "test"]))

            let response = try await inbound.readFullResponse()
            print("Full response: \(response)")
            return response
        }

        XCTAssertEqual([ xTest: "test"], result.2)
        XCTAssertEqual("EOF\r\n", String(decoding: result.1.readableBytesView, as: UTF8.self))
    }

    func testInterceptingHandler() async throws {
        final class Wrapper: RequestReader {
            let wrapped: RequestReader
            init(wrapped: RequestReader) {
                self.wrapped = wrapped
                _body = Body(wrapped.body)
            }

            var logger: Logger { 
                get { wrapped.logger }
                set { wrapped.logger = newValue }
            }
            var request: HTTPRequest { wrapped.request }
            let _body: Body
            var body: AnyReadableBody { AnyReadableBody(_body) }
            var userInfo: UserInfo { 
                get { wrapped.userInfo }
                set { wrapped.userInfo = newValue }
            }

            final class Body: ReadableBody {
                let wrapped: AnyReadableBody
                init(_ wrapped: AnyReadableBody) {
                    self.wrapped = wrapped
                }

                var expectedContentLength: Int? { wrapped.expectedContentLength }
                var trailers: HTTPFields? { get async throws { try await wrapped.trailers } }

                var bufferedData: ByteBuffer = ByteBuffer()

                func makeAsyncIterator() -> AsyncIterator {
                    AsyncIterator(underlying: wrapped.makeAsyncIterator(), body: self)
                }

                struct AsyncIterator: AsyncIteratorProtocol {
                    typealias Element = ByteBuffer

                    var underlying: AnyReadableBody.AsyncIterator
                    let body: Body

                    mutating func next() async throws -> ByteBuffer? {
                        let next = try await underlying.next()
                        let remainingCapacity = 16 - body.bufferedData.readableBytes
                        if var next, remainingCapacity > 0 {
                            var slice = next.readSlice(length: Swift.min(next.readableBytes, remainingCapacity))!
                            body.bufferedData.writeBuffer(&slice)
                        }
                        return next                   
                    }
                }
            }
        }

        actor Logs {
            var logs: [String] = []

            func log(_ message: String) {
                logs.append(message)
            }
        }

        let logger = Logs()

        @Sendable
        func reqBodyLogger(_ req: any RequestReader, _ res: any ResponseWriter, _ next: AnyHandler.Handler) async throws {
            let wrapper = Wrapper(wrapped: req)
            try await next(wrapper, res)
            XCTAssertEqual(16, wrapper._body.bufferedData.readableBytes)
            await logger.log("Request body length: \(wrapper._body.bufferedData.readableBytes)")
            await logger.log("\(String(decoding: wrapper._body.bufferedData.readableBytesView, as: UTF8.self))")
        }

        let result = try await withServer { req, res in 
            
            try await reqBodyLogger(req, res) { req, res in
                var body = try await req.body.collect(upTo: 1024)
                try await res.writeBodyPart(&body)
            }

        } client: { inbound, outbound in 
            try await outbound.write(.head(HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/")))
            try await outbound.write(.body(ByteBuffer(string: "Hello, World\r\nThis is just a text\r\n")))
            try await outbound.write(.end(nil)) 
            return try await inbound.readFullResponse()
        }
        let collectedLogs = await logger.logs
        XCTAssertEqual(.ok, result.0.status)
        XCTAssertEqual("Hello, World\r\nThis is just a text\r\n", String(decoding: result.1.readableBytesView, as: UTF8.self))
        XCTAssertEqual("Hello, World\r\nTh", collectedLogs[1])
    }

    func testReadingRequestPartially() async throws {
        let result = try await withServer { req, res in
            for try await var buffer in req.body.prefix(2) {
                try await res.writeBodyPart(&buffer)
            }
        } client: { inbound, outbound in
        
            let parts = (1...10).map { "Part \($0)\r\n" }
            try await outbound.write(.head(HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/")))
            for part in parts {
                try await outbound.write(.body(ByteBuffer(string: part)))
            }
            try await outbound.write(.end(nil))

            return try await inbound.readFullResponse()
        
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

        let server = Server(host: "localhost") { req, res in 
            let v = await counter.increment()
            try await res.plainText("\(v)")
        }

        try await server.start()

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        let N = 1000

        let result = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
            
            for _ in 0..<N {
                group.addTask { [client] in
                    let req = HTTPClientRequest(url: "http://localhost:\(server.localAddress!.port!)/")
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
        let server = Server(host: "localhost") { req, res in 
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

        let localAddress = try await server.start()

        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 
        
        let req =  HTTPClientRequest(url: "http://localhost:\(localAddress.port!)/first")
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

        let server = Server(host: "localhost") { req, res in 
            XCTAssertEqual(req.method, .post)
            XCTAssertEqual(req.body.expectedContentLength, size)
            let data = try await req.body.collect(upTo: req.body.expectedContentLength ?? .max)
            
            try await res.plainText("Uploaded \(data.readableBytes) bytes")
            await uploadedData.setData(data)
        }
        let localAddress = try await server.start()
        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        var uploadData = ByteBufferAllocator().buffer(capacity: size)
        for _ in 0..<size {
            uploadData.writeInteger(UInt8.random(in: 0...UInt8.max))
        }

        var req = HTTPClientRequest(url: "http://localhost:\(localAddress.port!)/")
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

        let server = Server(host: "localhost") { req, res in 
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
        let localAddress = try await server.start()
        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        var req = HTTPClientRequest(url: "http://localhost:\(localAddress.port!)/")
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

        let server = Server(host: "localhost") { req, res in 
            try await res.plainText("\(counter.increment())")
        }

        let port = try await server.start().port!
        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel() } 

        

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

        let server = Server(host: "localhost") { req, res in 
            XCTAssertEqual(req.method, .post)
            XCTAssertEqual(req.body.expectedContentLength, size)
            
            for try await var chunk in req.body {
                try await res.writeBodyPart(&chunk)
            }

            try await res.end()
        }

        let localAddress = try await server.start()
        let serverTask = Task {
            try await server.run()
        }
        defer { serverTask.cancel()}

        
        let chunkSize = 1024
        var sentBytes = 0
        var req = HTTPClientRequest(url: "http://localhost:\(localAddress.port!)/")
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
    typealias ClientHandler<Result> = (NIOAsyncChannelInboundStream<HTTPResponsePart>, NIOAsyncChannelOutboundWriter<HTTPRequestPart>) async throws -> (Result)

    static func execute<Result>(host: String, port: Int, _ work: @escaping ClientHandler<Result>) async throws -> Result {
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
    func readFullResponse() async throws -> (HTTPResponse, ByteBuffer, HTTPFields?) {
        var response: HTTPResponse?
        var body = ByteBuffer()
        for try await part in self {
            switch part {
            case .head(let head):
                response = head
            case .body(var buf):
                body.writeBuffer(&buf)
            case .end(let trailers):
                guard let response = response else {
                    throw HTTPError.unexpectedHTTPPart(part)
                }
                return (response, body, trailers)
            }
        }
        throw HTTPError.unexpectedHTTPPart(nil)
    }
}