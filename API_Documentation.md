# VeloxServe API Documentation

VeloxServe is an experimental, lightweight Swift HTTP server built on [SwiftNIO](https://github.com/apple/swift-nio) with a fully async API.

## Table of Contents

- [Getting Started](#getting-started)
- [Core Components](#core-components)
  - [Server](#server)
  - [Handler](#handler)
  - [RequestReader](#requestreader)
  - [ResponseWriter](#responsewriter)
- [Request Body Handling](#request-body-handling)
- [Query Parameters](#query-parameters)
- [User Information](#user-information)
- [Routing](#routing)
- [Instrumentation](#instrumentation)
- [Utilities](#utilities)
- [Error Handling](#error-handling)
- [Examples](#examples)

---

## Getting Started

### Basic Server Setup

```swift
import VeloxServe

let server = Server(
    host: "localhost",
    port: 8080
) { req, res in
    try await res.plainText("Hello, World!\r\n")
}

try await server.run()
```

### With Custom Configuration

```swift
import VeloxServe
import Logging

let logger = Logger(label: "my-server")

let server = Server(
    host: "0.0.0.0",
    port: 8080,
    name: "MyServer",
    group: NIOSingletons.posixEventLoopGroup,
    logger: logger
) { req, res in
    try await res.plainText("Hello, World!\r\n")
}

try await server.run()
```

---

## Core Components

### Server

The `Server` class is the main entry point for creating HTTP servers.

#### Public API

```swift
public final class Server: Sendable, Service
```

#### Initializers

```swift
// Convenience initializer with closure handler
public convenience init(
    host: String,
    port: Int = 0,
    name: String? = nil,
    group: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
    logger: Logger = NoopLogger,
    handler: @escaping AnyHandler.Handler
)

// Main initializer with Handler protocol
public init(
    host: String,
    port: Int = 0,
    name: String? = nil,
    group: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
    logger: Logger = NoopLogger,
    handler: Handler
)
```

#### Methods

```swift
// Start the server and bind to the specified address
@discardableResult
public func start() async throws -> SocketAddress

// Run the server (combines start and event loop)
public func run() async throws

// Start listening and serving requests
public func listenAndServe() async throws

// Shutdown the server
public func shutdown()

// Graceful shutdown
public func shutdownGracefully() async throws
```

#### Properties

```swift
// Get the local address the server is bound to
public var localAddress: SocketAddress?
```

#### Example

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    res.status = .ok
    try await res.plainText("Server is running!")
}

let address = try await server.start()
print("Server started on \(address)")

// Run the server
try await server.run()
```

---

### Handler

The `Handler` protocol defines how to handle HTTP requests.

#### Protocol Definition

```swift
public protocol Handler: Sendable {
    func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws -> Void
}
```

#### AnyHandler

A type-erased handler that can wrap closures or other handlers.

```swift
public struct AnyHandler: Handler {
    public typealias Handler = @Sendable (any RequestReader, any ResponseWriter) async throws -> Void
    
    public init<H: VeloxServe.Handler>(_ handler: H)
    public init(_ handler: @escaping Handler)
    
    public func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws
}
```

#### Example

```swift
// Using a closure
let handler = AnyHandler { req, res in
    try await res.plainText("Hello from handler!")
}

// Using a custom handler type
struct MyHandler: Handler {
    func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws {
        try await response.plainText("Custom handler response")
    }
}

let customHandler = MyHandler()
let server = Server(host: "localhost", port: 8080, handler: customHandler)
```

---

### RequestReader

The `RequestReader` protocol provides access to HTTP request data.

#### Protocol Definition

```swift
public protocol RequestReader: AnyObject {
    var logger: Logger { get set }
    var request: HTTPRequest { get }
    var queryItems: QueryItems { get }
    var body: AnyReadableBody { get }
    var userInfo: UserInfo { get set }
    var executor: any (TaskExecutor & SerialExecutor) { get }
}
```

#### Extensions and Convenience Properties

```swift
extension RequestReader {
    public var method: HTTPRequest.Method { get }
    public var path: String { get }
    public var headers: HTTPFields { get }
    public var trailers: HTTPFields? { get async throws }
    public var route: String? { get set }
    public var pathParameters: PathParatmeters { get set }
}
```

#### Example

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    // Access request properties
    print("Method: \(req.method)")
    print("Path: \(req.path)")
    print("Headers: \(req.headers)")
    
    // Access query parameters
    if let name = req.queryItems.name {
        try await res.plainText("Hello, \(name)!")
    } else {
        try await res.plainText("Hello, anonymous!")
    }
}
```

---

### ResponseWriter

The `ResponseWriter` protocol provides methods to write HTTP responses.

#### Protocol Definition

```swift
public protocol ResponseWriter: AnyObject {
    var status: HTTPResponse.Status { get set }
    var headers: HTTPFields { get set }
    var trailers: HTTPFields? { get set }
    
    func writeHead() async throws
    func writeBodyPart(_ data: inout ByteBuffer) async throws
    func end() async throws
}
```

#### Extensions

```swift
extension ResponseWriter {
    // Write string data
    public func writeBodyPart(_ string: String) async throws
    public func writeBodyPart(_ string: Substring) async throws
    public func writeBodyPart(_ bytes: some Sequence<UInt8>) async throws
    
    // Convenience method for plain text responses
    public func plainText(_ text: String) async throws
}
```

#### Example

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    // Set status and headers
    res.status = .ok
    res.headers[.contentType] = "application/json"
    
    // Write response body
    try await res.writeBodyPart("""
        {"message": "Hello, World!"}
        """)
    
    // Or use convenience method
    try await res.plainText("Plain text response")
}
```

---

## Request Body Handling

### ReadableBody Protocol

```swift
public protocol ReadableBody: AsyncSequence where Element == ByteBuffer {
    var expectedContentLength: Int? { get }
    var trailers: HTTPFields? { get async throws }
}
```

### AnyReadableBody

Type-erased wrapper for readable bodies.

```swift
public struct AnyReadableBody: ReadableBody {
    public let expectedContentLength: Int?
    public var trailers: HTTPFields? { get async throws }
    
    public func makeAsyncIterator() -> AsyncIterator
}
```

### Reading Request Bodies

```swift
// Collect entire body (with limit)
extension ReadableBody {
    public func collect(upTo maxBytes: Int) async throws -> ByteBuffer
}
```

#### Examples

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    // Stream body chunks
    for try await chunk in req.body {
        print("Received chunk of \(chunk.readableBytes) bytes")
    }
    
    // Or collect entire body
    let body = try await req.body.collect(upTo: 1024 * 1024) // 1MB limit
    let bodyString = String(decoding: body.readableBytesView, as: UTF8.self)
    
    try await res.plainText("Received: \(bodyString)")
}
```

---

## Query Parameters

### QueryItems

The `QueryItems` struct provides URL query parameter parsing and access.

```swift
@dynamicMemberLookup
public struct QueryItems {
    // Access first value for a parameter
    public subscript(first name: String) -> String?
    
    // Access last value for a parameter
    public subscript(last name: String) -> String?
    
    // Access all values for a parameter
    public subscript(values name: String) -> [String]
    
    // Dynamic member lookup
    public subscript(dynamicMember name: String) -> String?
}
```

#### Example

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    // URL: /search?q=swift&category=web&category=mobile
    
    // Access via subscript
    let query = req.queryItems[first: "q"] // "swift"
    let firstCategory = req.queryItems[first: "category"] // "web"
    let lastCategory = req.queryItems[last: "category"] // "mobile"
    let allCategories = req.queryItems[values: "category"] // ["web", "mobile"]
    
    // Access via dynamic member lookup
    let queryDynamic = req.queryItems.q // "swift"
    
    try await res.plainText("Query: \(query ?? "none")")
}
```

---

## User Information

### UserInfo

The `UserInfo` struct provides type-safe storage for request-scoped data.

```swift
public struct UserInfo {
    public subscript<Key: UserInfoKey>(key: Key.Type) -> Key.Value? { get set }
}

public protocol UserInfoKey {
    associatedtype Value
}
```

#### Example

```swift
// Define a custom key
enum UserIDKey: UserInfoKey {
    typealias Value = String
}

let server = Server(host: "localhost", port: 8080) { req, res in
    // Store user information
    req.userInfo[UserIDKey.self] = "user123"
    
    // Retrieve user information
    if let userID = req.userInfo[UserIDKey.self] {
        try await res.plainText("User ID: \(userID)")
    }
}
```

---

## Routing

### Router

The `Router` struct provides URL routing capabilities using a trie-based implementation.

```swift
public struct Router: Handler {
    public init()
    
    public func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws
    
    // Route registration methods
    public mutating func register(method: HTTPRequest.Method, path: String, handler: Handler)
    public mutating func get(_ path: String, handler: Handler)
    public mutating func post(_ path: String, handler: Handler)
    public mutating func put(_ path: String, handler: Handler)
    public mutating func delete(_ path: String, handler: Handler)
}
```

### Path Parameters

```swift
public struct PathParatmeters {
    public subscript(key: String) -> Substring?
    public subscript<T: LosslessStringConvertible>(required key: String, as type: T.Type) -> T { get throws }
}
```

#### Route Patterns

- **Static routes**: `/users`
- **Parameter routes**: `/users/{id}`
- **Prefix parameters**: `/files/static{filename}`
- **Suffix parameters**: `/files/{filename}.jpg`
- **Catch-all routes**: `/files/*path`

#### Example

```swift
var router = Router()

// Static route
router.get("/") { req, res in
    try await res.plainText("Home page")
}

// Parameter route
router.get("/users/{id}") { req, res in
    let userID = try req.pathParameters[required: "id", as: Int.self]
    try await res.plainText("User ID: \(userID)")
}

// Catch-all route
router.get("/files/*path") { req, res in
    let filePath = req.pathParameters["path"] ?? ""
    try await res.plainText("File path: \(filePath)")
}

let server = Server(host: "localhost", port: 8080, handler: router)
```

---

## Instrumentation

### InstrumentedHandler

Provides distributed tracing support for handlers.

```swift
public struct InstrumentedHandler: Handler {
    public let next: Handler
    
    public func handle(_ request: RequestReader, _ res: any ResponseWriter) async throws
}

extension Handler {
    public func instrumented() -> some Handler
}
```

#### Example

```swift
let handler = AnyHandler { req, res in
    try await res.plainText("Instrumented response")
}

let server = Server(
    host: "localhost",
    port: 8080,
    handler: handler.instrumented()
)
```

---

## Utilities

### UTCInstant

Provides UTC time handling functionality.

```swift
struct UTCInstant: InstantProtocol {
    static var now: UTCInstant
    static var distantFuture: UTCInstant
    
    func formatted() -> String
    func advanced(by duration: Duration) -> UTCInstant
    func duration(to other: UTCInstant) -> Duration
}
```

### UTCClock

Clock implementation for UTC time.

```swift
struct UTCClock: Clock {
    typealias Instant = UTCInstant
    
    var now: UTCInstant
    var minimumResolution: Duration
    
    func sleep(until deadline: UTCInstant, tolerance: Duration?) async throws
}
```

---

## Error Handling

### Server Errors

```swift
public enum ServerError: Error {
    case alreadyStarted
    case shuttingDown
}

public enum HTTPError: Error {
    case unexpectedHTTPPart(HTTPRequestPart)
}
```

### Request Body Errors

```swift
public struct TooManyBytesError: Error {
    public init()
}
```

### Routing Errors

```swift
public struct PathParameterMissingError: Error {
    public let key: String
}

public struct PathParameterInvalidError: Error {
    public let key: String
    public let value: Substring
    public let expectedType: Any.Type
}
```

---

## Examples

### Complete REST API Server

```swift
import VeloxServe
import Logging

struct User: Codable {
    let id: Int
    let name: String
    let email: String
}

// In-memory storage
actor UserStore {
    private var users: [Int: User] = [:]
    private var nextID = 1
    
    func create(name: String, email: String) -> User {
        let user = User(id: nextID, name: name, email: email)
        users[nextID] = user
        nextID += 1
        return user
    }
    
    func getAll() -> [User] {
        Array(users.values)
    }
    
    func get(id: Int) -> User? {
        users[id]
    }
    
    func update(id: Int, name: String?, email: String?) -> User? {
        guard var user = users[id] else { return nil }
        if let name = name { user = User(id: user.id, name: name, email: user.email) }
        if let email = email { user = User(id: user.id, name: user.name, email: email) }
        users[id] = user
        return user
    }
    
    func delete(id: Int) -> Bool {
        users.removeValue(forKey: id) != nil
    }
}

@main
struct APIServer {
    static func main() async throws {
        let logger = Logger(label: "api-server")
        let userStore = UserStore()
        
        var router = Router()
        
        // GET /users - List all users
        router.get("/users") { req, res in
            let users = await userStore.getAll()
            let jsonData = try JSONEncoder().encode(users)
            res.headers[.contentType] = "application/json"
            try await res.writeBodyPart(jsonData)
        }
        
        // GET /users/{id} - Get user by ID
        router.get("/users/{id}") { req, res in
            let userID = try req.pathParameters[required: "id", as: Int.self]
            
            if let user = await userStore.get(id: userID) {
                let jsonData = try JSONEncoder().encode(user)
                res.headers[.contentType] = "application/json"
                try await res.writeBodyPart(jsonData)
            } else {
                res.status = .notFound
                try await res.plainText("User not found")
            }
        }
        
        // POST /users - Create new user
        router.post("/users") { req, res in
            let body = try await req.body.collect(upTo: 1024 * 1024) // 1MB limit
            let jsonData = Data(body.readableBytesView)
            
            struct CreateUserRequest: Codable {
                let name: String
                let email: String
            }
            
            let createRequest = try JSONDecoder().decode(CreateUserRequest.self, from: jsonData)
            let user = await userStore.create(name: createRequest.name, email: createRequest.email)
            
            res.status = .created
            res.headers[.contentType] = "application/json"
            let responseData = try JSONEncoder().encode(user)
            try await res.writeBodyPart(responseData)
        }
        
        // PUT /users/{id} - Update user
        router.put("/users/{id}") { req, res in
            let userID = try req.pathParameters[required: "id", as: Int.self]
            let body = try await req.body.collect(upTo: 1024 * 1024)
            let jsonData = Data(body.readableBytesView)
            
            struct UpdateUserRequest: Codable {
                let name: String?
                let email: String?
            }
            
            let updateRequest = try JSONDecoder().decode(UpdateUserRequest.self, from: jsonData)
            
            if let user = await userStore.update(id: userID, name: updateRequest.name, email: updateRequest.email) {
                res.headers[.contentType] = "application/json"
                let responseData = try JSONEncoder().encode(user)
                try await res.writeBodyPart(responseData)
            } else {
                res.status = .notFound
                try await res.plainText("User not found")
            }
        }
        
        // DELETE /users/{id} - Delete user
        router.delete("/users/{id}") { req, res in
            let userID = try req.pathParameters[required: "id", as: Int.self]
            
            if await userStore.delete(id: userID) {
                res.status = .noContent
            } else {
                res.status = .notFound
                try await res.plainText("User not found")
            }
        }
        
        let server = Server(
            host: "localhost",
            port: 8080,
            name: "UserAPI",
            logger: logger,
            handler: router.instrumented()
        )
        
        logger.info("Starting server on port 8080")
        try await server.run()
    }
}
```

### File Upload Server

```swift
import VeloxServe
import Foundation

let server = Server(host: "localhost", port: 8080) { req, res in
    switch req.method {
    case .get:
        // Serve upload form
        try await res.writeBodyPart("""
            <!DOCTYPE html>
            <html>
            <head><title>File Upload</title></head>
            <body>
                <h1>Upload File</h1>
                <form action="/upload" method="post" enctype="multipart/form-data">
                    <input type="file" name="file" required>
                    <button type="submit">Upload</button>
                </form>
            </body>
            </html>
            """)
        
    case .post where req.path == "/upload":
        // Handle file upload
        let uploadDir = URL(fileURLWithPath: "./uploads")
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        
        let fileName = "upload_\(Date().timeIntervalSince1970).bin"
        let fileURL = uploadDir.appendingPathComponent(fileName)
        
        var totalBytes = 0
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { fileHandle.closeFile() }
        
        for try await chunk in req.body {
            totalBytes += chunk.readableBytes
            try fileHandle.write(contentsOf: chunk.readableBytesView)
        }
        
        try await res.plainText("Uploaded \(totalBytes) bytes to \(fileName)")
        
    default:
        res.status = .methodNotAllowed
        try await res.plainText("Method not allowed")
    }
}

try await server.run()
```

### Streaming Response Server

```swift
import VeloxServe

let server = Server(host: "localhost", port: 8080) { req, res in
    res.headers[.contentType] = "text/plain"
    
    // Stream data in chunks
    for i in 1...10 {
        try await res.writeBodyPart("Chunk \(i)\n")
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    try await res.writeBodyPart("Stream complete!\n")
}

try await server.run()
```

---

This documentation covers all the public APIs, functions, and components of VeloxServe with comprehensive examples and usage instructions. The library provides a modern, async-first approach to HTTP server development in Swift with excellent performance characteristics thanks to its SwiftNIO foundation.