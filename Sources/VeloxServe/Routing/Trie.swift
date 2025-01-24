import HTTPTypes

enum LookupError: Error {
    case notFound
    case methodNotAllowed
}
// a trie stores values and allows efficient prefix lookups
struct Trie<Value> {
    var nodes: [Node] = [Node()]

    mutating func insert(path: [PathComponent], method: HTTPRequest.Method, handler: Value) {
        var currentIndex = nodes.startIndex
        var paramNames: [Substring] = []

        for component in path {
            switch component {
            case .literal(let literal):
                if let childIndex = nodes[currentIndex].staticChildren[literal] {
                    currentIndex = childIndex
                } else {
                    let newIndex = nodes.count
                    nodes.append(Node())
                    nodes[currentIndex].staticChildren[literal] = newIndex
                    currentIndex = newIndex
                }
            case .parameter(let name):
                if let nextIndex = nodes[currentIndex].parameterChild {
                    currentIndex = nextIndex
                } else {
                    let newIndex = nodes.count
                    nodes.append(Node())
                    nodes[currentIndex].parameterChild = newIndex
                    currentIndex = newIndex
                }
                paramNames.append(name)
            case .prefixParameter(let prefix, let parameter):
                if let existingNode = nodes[currentIndex].prefixParameterChildren.first(where: { $0.prefix == prefix }) {
                    currentIndex = existingNode.index
                } else {
                    let newIndex = nodes.endIndex
                    nodes.append(Node())
                    let indexToInsert = nodes[currentIndex].prefixParameterChildren.firstIndex { $0.prefix > prefix }
                    if let indexToInsert  {
                        nodes[currentIndex].prefixParameterChildren.insert((prefix, newIndex), at: indexToInsert)
                    } else {
                        nodes[currentIndex].prefixParameterChildren.append((prefix, newIndex))
                    }
                    currentIndex = newIndex
                }
                paramNames.append(parameter)
            case .suffixParameter(let suffix, let parameter):
                if let existingNode = nodes[currentIndex].suffixParameterChild.first(where: { $0.suffix == suffix }) {
                    currentIndex = existingNode.index
                } else {
                    let newIndex = nodes.endIndex
                    nodes.append(Node())
                    let indexToInsert = nodes[currentIndex].suffixParameterChild.firstIndex { $0.suffix > suffix }
                    if let indexToInsert  {
                        nodes[currentIndex].suffixParameterChild.insert((suffix, newIndex), at: indexToInsert)
                    } else {
                        nodes[currentIndex].suffixParameterChild.append((suffix, newIndex))
                    }
                    currentIndex = newIndex
                }
                paramNames.append(parameter)
            case .catchAll(let name):
                if nodes[currentIndex].catchAllChild == nil {
                    let newIndex = nodes.count
                    nodes.append(Node())
                    nodes[currentIndex].catchAllChild = (name, newIndex)
                    currentIndex = newIndex
                } else {
                    fatalError("catch-all route already exists")
                }

                break
            }
        }

        nodes[currentIndex].methodHandlers[method] = (paramNames, handler)
    }

    func lookup(path: [Substring], method: HTTPRequest.Method) throws(LookupError) -> (Value, [String: String]) {
        var currentIndex = nodes.startIndex
        var paramValues: [String] = []
        var params = [String: String]()

        for i in path.indices {
            let component = path[i]

            guard currentIndex < nodes.endIndex else {
                throw .notFound
            }

            let node = nodes[currentIndex]

            if let nextIndex = node.staticChildren[component] {
                currentIndex = nextIndex
            } else if let (prefix, nextIndex) = node.prefixParameterChildren.last(where: { component.starts(with: $0.prefix) }) {
                currentIndex = nextIndex
                paramValues.append(String(component.dropFirst(prefix.count)))
            } else if let (suffix, nextIndex) = node.suffixParameterChild.last(where: { component.reversed().starts(with: $0.suffix.reversed()) }) {
                currentIndex = nextIndex
                paramValues.append(String(component.dropLast(suffix.count)))
            } else if let nextIndex = node.parameterChild {
                currentIndex = nextIndex
                paramValues.append(String(component))
            } else if let (catchAllName, nextIndex) = node.catchAllChild {
                currentIndex = nextIndex
                let remainingPath = path[i...]
                if let catchAllName {
                    params[String(catchAllName)] = String(remainingPath.joined(separator: "/"))
                }
                // catch all completes the lookup
                break
            } else {
                throw .notFound
            }
        }

        let endNode = self.nodes[currentIndex]
        guard let (paramNames, value) = endNode.methodHandlers[method] else {
            throw .methodNotAllowed
        }

        assert(paramNames.count == paramValues.count)

        for (name, value) in zip(paramNames, paramValues) {
            params[String(name)] = value
        }

        return (value, params)
    }
}

typealias RouteHandler = (any RequestReader, any ResponseWriter) async throws -> Void

extension Trie {
    struct Node {
        var staticChildren: [Substring: Int] = [:]
        var parameterChild: Int? = nil
        var prefixParameterChildren: [(prefix: Substring, index: Int)] = []
        var suffixParameterChild: [(suffix: Substring, index: Int)] = []
        var catchAllChild: (name: Substring?, index: Int)? = nil

        var methodHandlers: [HTTPRequest.Method: ([Substring], Value)] = [:]
    }
}

extension Trie.Node : Sendable where Value : Sendable {}

extension Trie : Sendable where Value : Sendable {}

enum PathComponent: Equatable, CustomStringConvertible {
    case literal(Substring)
    case parameter(Substring)
    case prefixParameter(prefix: Substring, parameter: Substring)
    case suffixParameter(suffix: Substring, parameter: Substring)
    case catchAll(Substring?)

    var description: String {
        switch self {
        case .literal(let literal): return String(literal)
        case .parameter(let parameter): return "{\(parameter)}"
        case .prefixParameter(let prefix, let parameter): return "\(prefix){\(parameter)}"
        case .suffixParameter(let suffix, let parameter): return "{\(parameter)}\(suffix)"
        case .catchAll(let catchAll): return "*\(catchAll ?? "")"
        }
    }
}

extension Array where Element == PathComponent {
    init(path: String) {
        self = path.split(separator: "/", omittingEmptySubsequences: true)
            .map {
                if $0.first == "{" && $0.last == "}" {
                    return .parameter(Substring($0.dropFirst().dropLast()))
                } else if let open = $0.firstIndex(of: "{"), let close = $0.lastIndex(of: "}"), open < close, close == $0.index(before: $0.endIndex) {
                    return .prefixParameter(prefix: $0[..<open], parameter: $0[open...].dropFirst().dropLast())
                } else if let open = $0.firstIndex(of: "{"), let close = $0.lastIndex(of: "}"), open < close, open == $0.startIndex {
                    let suffix = $0[$0.index(after: close)...]
                    let parameter = $0[open..<close].dropFirst()
                    return .suffixParameter(suffix: suffix, parameter: parameter)
                } else if $0.starts(with: "*") {
                    let name = Substring($0.dropFirst())
                    if name.isEmpty {
                        return .catchAll(nil)
                    } else {
                        return .catchAll(name)
                    }
                } else {
                    return .literal($0)
                }
            }
    }
}

public struct Router: Handler {
    private var trie: Trie<Handler> = Trie()

    public init() {}

    public func handle(_ request: any RequestReader, _ response: any ResponseWriter) async throws {
        do {
            let handler = try trie.lookup(path: request.path.split(separator: "/", omittingEmptySubsequences: true), method: request.method)
            request.userInfo[RouteParams.self] = handler.1
            try await handler.0.handle(request, response)
        } catch LookupError.notFound {
            response.status = .notFound
            try await response.writeBodyPart("Not found: \(request.path)")
        } catch LookupError.methodNotAllowed {
            response.status = .methodNotAllowed
            if request.method == .head {
                response.headers[.contentLength] = "0"
            } else {
                try await response.plainText("Method not allowed: \(request.method) \(request.path)")
            } 
            try await response.end()
        }
    }

    public mutating func register(method: HTTPRequest.Method, path: String, handler: Handler) {
        trie.insert(path: .init(path: path), method: method, handler: handler.withRoute(path))
    }

    public mutating func get(_ path: String, handler: Handler) {
        trie.insert(path: .init(path: path), method: .get, handler: handler.withRoute(path))
    }

    public mutating func post(_ path: String, handler: Handler) {
        trie.insert(path: .init(path: path), method: .post, handler: handler.withRoute(path))
    }

   public mutating func put(_ path: String, handler: Handler) {
        trie.insert(path: .init(path: path), method: .put, handler: handler.withRoute(path))
    }

    public mutating func delete(_ path: String, handler: Handler) {
        trie.insert(path: .init(path: path), method: .delete, handler: handler.withRoute(path))
    }
}

extension Handler {
    func withRoute(_ path: String) -> Handler {
        return AnyHandler { req, res in 
            req.route = path
            try await self.handle(req, res)
        }
    }
}

enum RouteParams: UserInfoKey {
    typealias Value = [String: String]
}

extension RequestReader {
    public var routeParameters : [String: String] {
        get {
            return self.userInfo[RouteParams.self] ?? [:]
        }
        set {
            self.userInfo[RouteParams.self] = newValue
        }
    }
}