import HTTPTypes
import NIOCore
import NIOHTTPTypes

public protocol ResponseWriter: AnyObject {

    var status: HTTPResponse.Status { get set }
    var headers: HTTPFields { get set }
    var trailers: HTTPFields? { get set }

    func writeHead() async throws
    func writeBodyPart(_ data: inout ByteBuffer) async throws
    func end() async throws
}

extension ResponseWriter {
    public func writeBodyPart(_ string: String) async throws {
        try await self.writeBodyPart(string.utf8)
    }

    public func writeBodyPart(_ string: Substring) async throws {
        try await self.writeBodyPart(string.utf8)
    }

    @inlinable
    public func writeBodyPart(_ bytes: some Sequence<UInt8>) async throws {
        var buffer = ByteBuffer(bytes: bytes)
        try await self.writeBodyPart(&buffer)
    }

    public func plainText(_ text: String) async throws {
        self.headers[.contentType] = "text/plain"
        let data = text.utf8
        self.headers[.contentLength] = "\(data.count)"
        try await self.writeBodyPart(data)
    }
}


// IMPLEMENTATION

public enum EventLoopKey: UserInfoKey {
    public typealias Value = EventLoop
}





final class RootResponseWriter : ResponseWriter {


    private(set) var isKeepAlive: Bool

    private(set) var responsePartWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>

    var status: HTTPResponse.Status
    var headers: HTTPFields
    var trailers: HTTPFields?

    init(
        allocator: ByteBufferAllocator,
        isKeepAlive: Bool,
        responsePartWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
        head: HTTPResponse
    ) {
        self.isKeepAlive = isKeepAlive
        self.responsePartWriter = responsePartWriter
        self.status = head.status
        self.headers = head.headerFields
        self.writeBuffer = allocator.buffer(capacity: 4096)
    }

    /* func reset(responsePartWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>, head: HTTPResponse, isKeepAlive: Bool) {   
        self.responsePartWriter = responsePartWriter
        self.status = head.status
        self.headers = head.headerFields
        self.isKeepAlive = isKeepAlive
        self.writeBuffer.clear(minimumCapacity: 4096)
        self.isDone = false
        self.headerWritten = false
    } */

    private(set) var headerWritten: Bool = false
    private(set) var isDone: Bool = false

    private var head: HTTPResponse {
        HTTPResponse(status: self.status, headerFields: self.headers)
    }

    private
    var writeBuffer: ByteBuffer

    func writeHead() async throws {
        precondition(self.headerWritten == false, "Header can only be written once.")
        
        var head = self.head
        if head.status.code / 100 == 1 { // remove connection header for informational responses
            head.headerFields[.connection] = nil
        }
        
        try await self.responsePartWriter.write(.head(head))
        if self.head.status.code / 100 != 1 {
            self.headerWritten.toggle()
        }
    }

    private func writeHeadIfNecessary() async throws {
        guard self.headerWritten == false else {
            return
        }
        precondition(self.head.status.code / 100 != 1, "Head must not be 1xx")
        try await self.writeHead()
    }

     @inlinable
    func writeBodyPart(_ data: some Sequence<UInt8>) async throws {
        self.writeBuffer.writeBytes(data)
        try await self.flushIfNecessary()
    }

    @inlinable
    public func writeBodyPart(_ data: inout ByteBuffer) async throws {
        if data.readableBytes > 0 {
            self.writeBuffer.writeBuffer(&data)
            try await self.flushIfNecessary()
        }
    }

    @inlinable
    func flushIfNecessary() async throws {
        try await self.writeHeadIfNecessary()
        let readableBytes = self.writeBuffer.readableBytes
        if readableBytes >= 0 {
            try await responsePartWriter.write(
                .body(self.writeBuffer.readSlice(length: readableBytes)!))
        }
    }

    public func end(_ trailers: HTTPFields?) async throws {
        precondition(self.isDone == false)
        self.isDone.toggle()
        try await self.flushIfNecessary()
        self.trailers = trailers
        try await responsePartWriter.write(.end(self.trailers))
    }

    public func end() async throws {
        precondition(self.isDone == false)
        self.isDone.toggle()
        try await self.flushIfNecessary()
        try await responsePartWriter.write(.end(self.trailers))
    }

    public func plainText(_ text: String) async throws {
        self.headers[.contentType] = "text/plain"
        let data = text.utf8
        self.headers[.contentLength] = "\(data.count)"
        try await self.writeBodyPart(data)
    }
}