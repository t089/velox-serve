# VeloxServe Quick Reference

This quick reference guide provides common patterns and code snippets for VeloxServe development.

## Common Patterns

### 1. Basic Server Setup

```swift
import VeloxServe

// Simple server
let server = Server(host: "localhost", port: 8080) { req, res in
    try await res.plainText("Hello, World!")
}
try await server.run()
```

### 2. Request Method Handling

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    switch req.method {
    case .get:
        try await res.plainText("GET request")
    case .post:
        try await res.plainText("POST request")
    case .put:
        try await res.plainText("PUT request")
    case .delete:
        try await res.plainText("DELETE request")
    default:
        res.status = .methodNotAllowed
        try await res.plainText("Method not allowed")
    }
}
```

### 3. Path-based Routing

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    switch req.path {
    case "/":
        try await res.plainText("Home")
    case "/about":
        try await res.plainText("About")
    case "/contact":
        try await res.plainText("Contact")
    default:
        res.status = .notFound
        try await res.plainText("Not found")
    }
}
```

### 4. Router-based Setup

```swift
import VeloxServe

var router = Router()

router.get("/") { req, res in
    try await res.plainText("Home page")
}

router.get("/users/{id}") { req, res in
    let userID = try req.pathParameters[required: "id", as: Int.self]
    try await res.plainText("User ID: \(userID)")
}

router.post("/users") { req, res in
    let body = try await req.body.collect(upTo: 1024 * 1024)
    try await res.plainText("Created user")
}

let server = Server(host: "localhost", port: 8080, handler: router)
try await server.run()
```

### 5. Query Parameter Access

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    // URL: /search?q=swift&page=1
    let query = req.queryItems[first: "q"] ?? "default"
    let page = req.queryItems[first: "page"].flatMap(Int.init) ?? 1
    
    try await res.plainText("Query: \(query), Page: \(page)")
}
```

### 6. JSON Response

```swift
struct User: Codable {
    let id: Int
    let name: String
}

let server = Server(host: "localhost", port: 8080) { req, res in
    let user = User(id: 1, name: "John Doe")
    let jsonData = try JSONEncoder().encode(user)
    
    res.headers[.contentType] = "application/json"
    try await res.writeBodyPart(jsonData)
}
```

### 7. JSON Request Handling

```swift
struct CreateUserRequest: Codable {
    let name: String
    let email: String
}

let server = Server(host: "localhost", port: 8080) { req, res in
    let body = try await req.body.collect(upTo: 1024 * 1024)
    let jsonData = Data(body.readableBytesView)
    let userRequest = try JSONDecoder().decode(CreateUserRequest.self, from: jsonData)
    
    try await res.plainText("Creating user: \(userRequest.name)")
}
```

### 8. File Upload Handling

```swift
import Foundation

let server = Server(host: "localhost", port: 8080) { req, res in
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
    
    try await res.plainText("Uploaded \(totalBytes) bytes")
}
```

### 9. Streaming Response

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    res.headers[.contentType] = "text/plain"
    
    for i in 1...10 {
        try await res.writeBodyPart("Chunk \(i)\n")
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
}
```

### 10. Error Handling

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    do {
        let body = try await req.body.collect(upTo: 1024)
        try await res.plainText("Success")
    } catch is TooManyBytesError {
        res.status = .payloadTooLarge
        try await res.plainText("Request too large")
    } catch {
        res.status = .internalServerError
        try await res.plainText("Internal server error")
    }
}
```

### 11. Custom Headers

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    res.headers[.contentType] = "application/json"
    res.headers[.cacheControl] = "no-cache"
    res.headers["X-Custom-Header"] = "custom-value"
    
    try await res.plainText("Response with custom headers")
}
```

### 12. Redirect

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    res.status = .permanentRedirect
    res.headers[.location] = "/new-location"
    try await res.plainText("Redirecting...")
}
```

### 13. CORS Headers

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    res.headers["Access-Control-Allow-Origin"] = "*"
    res.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE"
    res.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    
    if req.method == .options {
        res.status = .noContent
        return
    }
    
    try await res.plainText("CORS enabled response")
}
```

### 14. User Information Storage

```swift
enum UserIDKey: UserInfoKey {
    typealias Value = String
}

let server = Server(host: "localhost", port: 8080) { req, res in
    // Store user info
    req.userInfo[UserIDKey.self] = "user123"
    
    // Retrieve user info
    if let userID = req.userInfo[UserIDKey.self] {
        try await res.plainText("User ID: \(userID)")
    }
}
```

### 15. Logging

```swift
import Logging

let logger = Logger(label: "my-server")

let server = Server(
    host: "localhost",
    port: 8080,
    logger: logger
) { req, res in
    req.logger.info("Processing request", metadata: [
        "method": .string(req.method.rawValue),
        "path": .string(req.path)
    ])
    
    try await res.plainText("Request logged")
}
```

### 16. Content Negotiation

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    let acceptHeader = req.headers[.accept] ?? ""
    
    if acceptHeader.contains("application/json") {
        res.headers[.contentType] = "application/json"
        try await res.writeBodyPart(#"{"message": "JSON response"}"#)
    } else if acceptHeader.contains("text/html") {
        res.headers[.contentType] = "text/html"
        try await res.writeBodyPart("<h1>HTML response</h1>")
    } else {
        res.headers[.contentType] = "text/plain"
        try await res.plainText("Plain text response")
    }
}
```

### 17. Request Body Validation

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    guard let contentLength = req.body.expectedContentLength else {
        res.status = .badRequest
        try await res.plainText("Content-Length required")
        return
    }
    
    if contentLength > 1024 * 1024 { // 1MB limit
        res.status = .payloadTooLarge
        try await res.plainText("Request too large")
        return
    }
    
    let body = try await req.body.collect(upTo: contentLength)
    try await res.plainText("Received \(body.readableBytes) bytes")
}
```

### 18. Basic Authentication

```swift
import Foundation

let server = Server(host: "localhost", port: 8080) { req, res in
    guard let authHeader = req.headers[.authorization] else {
        res.status = .unauthorized
        res.headers["WWW-Authenticate"] = "Basic realm=\"Protected\""
        try await res.plainText("Authentication required")
        return
    }
    
    // Basic authentication parsing
    if authHeader.hasPrefix("Basic ") {
        let base64String = String(authHeader.dropFirst(6))
        if let decodedData = Data(base64Encoded: base64String),
           let credentials = String(data: decodedData, encoding: .utf8) {
            let parts = credentials.split(separator: ":")
            if parts.count == 2 {
                let username = String(parts[0])
                let password = String(parts[1])
                
                if username == "admin" && password == "secret" {
                    try await res.plainText("Authenticated as \(username)")
                    return
                }
            }
        }
    }
    
    res.status = .unauthorized
    try await res.plainText("Invalid credentials")
}
```

### 19. Rate Limiting

```swift
import Foundation

actor RateLimiter {
    private var requests: [String: [Date]] = [:]
    private let maxRequests = 10
    private let timeWindow: TimeInterval = 60 // 1 minute
    
    func isAllowed(for clientIP: String) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-timeWindow)
        
        // Clean old requests
        requests[clientIP] = requests[clientIP]?.filter { $0 > cutoff } ?? []
        
        // Check if under limit
        if requests[clientIP]!.count < maxRequests {
            requests[clientIP]!.append(now)
            return true
        }
        
        return false
    }
}

let rateLimiter = RateLimiter()

let server = Server(host: "localhost", port: 8080) { req, res in
    let clientIP = req.headers["X-Forwarded-For"] ?? "unknown"
    
    if await rateLimiter.isAllowed(for: clientIP) {
        try await res.plainText("Request processed")
    } else {
        res.status = .tooManyRequests
        try await res.plainText("Rate limit exceeded")
    }
}
```

### 20. Health Check Endpoint

```swift
let server = Server(host: "localhost", port: 8080) { req, res in
    if req.path == "/health" {
        res.headers[.contentType] = "application/json"
        try await res.writeBodyPart("""
            {
                "status": "healthy",
                "timestamp": "\(Date().timeIntervalSince1970)",
                "version": "1.0.0"
            }
            """)
        return
    }
    
    try await res.plainText("Main application")
}
```

## Common HTTP Status Codes

```swift
res.status = .ok                    // 200
res.status = .created               // 201
res.status = .noContent             // 204
res.status = .badRequest            // 400
res.status = .unauthorized          // 401
res.status = .forbidden             // 403
res.status = .notFound              // 404
res.status = .methodNotAllowed      // 405
res.status = .payloadTooLarge       // 413
res.status = .tooManyRequests       // 429
res.status = .internalServerError   // 500
res.status = .notImplemented        // 501
res.status = .serviceUnavailable    // 503
```

## Common HTTP Headers

```swift
res.headers[.contentType] = "application/json"
res.headers[.contentLength] = "1024"
res.headers[.cacheControl] = "no-cache"
res.headers[.location] = "/new-path"
res.headers[.authorization] = "Bearer token"
res.headers["X-Custom-Header"] = "custom-value"
```

## Middleware Pattern

```swift
typealias Middleware = (RequestReader, ResponseWriter, @escaping AnyHandler.Handler) async throws -> Void

@Sendable
func loggingMiddleware(_ req: RequestReader, _ res: ResponseWriter, _ next: @escaping AnyHandler.Handler) async throws {
    let start = Date()
    try await next(req, res)
    let duration = Date().timeIntervalSince(start)
    print("Request took \(duration) seconds")
}

let server = Server(host: "localhost", port: 8080) { req, res in
    try await loggingMiddleware(req, res) { req, res in
        try await res.plainText("Hello with middleware!")
    }
}
```

This quick reference provides the most common patterns and operations you'll use when developing with VeloxServe.