// Benchmark boilerplate generated by Benchmark

import Benchmark
import Foundation
import VeloxServe
import AsyncHTTPClient
import NIO

let client = HTTPClient.shared
        

let benchmarks : @Sendable () -> Benchmark? =  { @Sendable () -> Benchmark? in
    Benchmark("SomeBenchmark") {  (benchmark: Benchmark) async throws -> () in
        
        let server = try await Server.start(host: "127.0.0.1") { req, res in 
            switch req.head.uri {
                case "/echo":
                    for try await var chunk in req.body {
                        try await res.writeBodyPart(&chunk)
                    }
                default:
                    res.status = .notFound
                    try await res.plainText("Not Found")
            }
        }

        let port = server.localAddress.port!
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/echo") 
        request.method = .POST
        
        for i in benchmark.scaledIterations {
            request.body = .bytes(Array("Hello, world #\(i)!".utf8))
            let response : HTTPClientResponse = try await client.execute(request, deadline: NIODeadline.now() + .seconds(2))
            _ = try await response.body.collect(upTo: Int.max)
        }
    }
    // Add additional benchmarks here
}