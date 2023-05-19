# VeloxServe

Experimental, lightweight Swift HTTP server built on [SwiftNIO](https://github.com/apple/swift-nio) with fully async API.

### Example

You respond to HTTP requests by providing an async function `(RequestReader, inout ResponseWriter) async throws -> Void` to the server. Within in this function you can read the request from the given `RequestReader` struct and write you response to the `ResponseWriter` struct. Returning from this function (or throwing an error) indicates that you are done with the response.

```swift
import VeloxServe

let server = try await Server.start(
    host: "localhost", 
    port: 8080) { req, res in 
    try await res.plainText("Hello, World!\r\n")
}

logger.info("Server listening on: \(server.localAddress)")
try await server.run()
```