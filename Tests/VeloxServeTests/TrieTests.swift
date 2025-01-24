import Testing
@testable import VeloxServe
import HTTPTypes
final class TrieTests {

    @Test
    func testSimpleRoute() throws {
        var trie : Trie<String> = Trie()

        trie.insert(path: [], method: .get, handler: "root")
        trie.insert(path: [.literal("some"), .literal("other"), .literal("path")], method: .get, handler: "/some/other/path")
        trie.insert(path: [.literal("some"), .literal("different"), .literal("path")], method: .get, handler: "/some/different/path")
        trie.insert(path: [.literal("some"), .literal("other"), .literal("path"), .parameter("id")], method: .get, handler: "/some/other/path/{id}")
        trie.insert(path: [.literal("some"), .literal("other"), .literal("path"), .parameter("identifier"), .literal("other")], method: .get, handler: "/some/other/path/{identifier}/other")

        #expect(try trie.lookup(path: ["some", "other", "path"], method: .get) == ("/some/other/path", [:]))
        #expect(try trie.lookup(path: ["some", "different", "path"], method: .get) == ("/some/different/path", [:]))
        #expect(try trie.lookup(path: ["some", "other", "path", "123"], method: .get) == ("/some/other/path/{id}", ["id": "123"]))
        #expect(try trie.lookup(path: ["some", "other", "path", "abc", "other"], method: .get) == ("/some/other/path/{identifier}/other", ["identifier": "abc"]))
        #expect(try trie.lookup(path: [], method: .get) == ("root", [:]))
    }

    @Test
    func testCatchAll() throws {
        var trie : Trie<String> = Trie()

        trie.insert(path: [.literal("some"), .catchAll("rest")], method: .get, handler: "/some/*rest")

        #expect(try trie.lookup(path: ["some", "abc", "def"], method: .get) == ("/some/*rest", ["rest": "abc/def"]))
    }

    @Test
    func testCatchAllWithParameter() throws {
        var trie : Trie<String> = Trie()

        trie.insert(path: [.literal("some"), .parameter("id"), .catchAll("rest")], method: .get, handler: "/some/{id}/*rest")
        trie.insert(path: [.literal("some"), .parameter("thingId"), .literal("details")], method: .get, handler: "/some/{thingId}/details")

        #expect(try trie.lookup(path: ["some", "123", "def", "qwe"], method: .get) == ("/some/{id}/*rest", ["id": "123", "rest": "def/qwe"]))
        #expect(try trie.lookup(path: ["some", "123", "details"], method: .get) == ("/some/{thingId}/details", ["thingId": "123"]))
    }

    @Test
    func testLookupWithPrefixParameter() throws {
        var trie : Trie<String> = Trie()

        trie.insert(path: Array(path: "/some/user-{id}"), method: .get, handler: "/some/user-{id}")
        trie.insert(path: [.literal("some"), .prefixParameter(prefix: "user-", parameter: "id"), .literal("posts")], method: .get, handler: "/some/user-{id}/posts")
        trie.insert(path: [.literal("some"), .prefixParameter(prefix: "account-", parameter: "id"), .literal("posts"), .parameter("postId")], method: .get, handler: "/some/account-{id}/posts/{postId}")
        trie.insert(path: Array(path: "/some/account-{id}"), method: .get, handler: "/some/account-{id}")

        #expect(try trie.lookup(path: ["some", "user-123"], method: .get) == ("/some/user-{id}", ["id": "123"]))
        #expect(try trie.lookup(path: ["some", "user-123", "posts"], method: .get) == ("/some/user-{id}/posts", ["id": "123"]))
        #expect(try trie.lookup(path: ["some", "account-123", "posts", "123"], method: .get) == ("/some/account-{id}/posts/{postId}", ["id": "123", "postId": "123"]))
        #expect(try trie.lookup(path: ["some", "account-123"], method: .get) == ("/some/account-{id}", ["id": "123"]))
    }

    @Test
    func testLookupWithSuffixParameter() throws {
        var trie : Trie<String> = Trie()

        trie.insert(path: [.literal("some"), .parameter("id"), .suffixParameter(suffix: ".md", parameter: "docid")], method: .get, handler: "/some/{id}/{docid}.md")
        trie.insert(path: [.literal("some"), .parameter("id"), .suffixParameter(suffix: ".md.txt", parameter: "docid")], method: .get, handler: "/some/{id}/{docid}.md.txt")
        #expect(try trie.lookup(path: ["some", "123", "abc.md"], method: .get) == ("/some/{id}/{docid}.md", ["id": "123", "docid": "abc"]))
        #expect(try trie.lookup(path: ["some", "123", "abc.md.txt"], method: .get) == ("/some/{id}/{docid}.md.txt", ["id": "123", "docid": "abc"]))
    }

    @Test   
    func testPathParsing() {
        #expect(Array(path: "/") == [])
        #expect(Array(path: "/user") == [.literal("user")])
        #expect(Array(path: "/user/123") == [.literal("user"), .literal("123")])
        #expect(Array(path: "/user/123/posts") == [.literal("user"), .literal("123"), .literal("posts")])
        #expect(Array(path: "/user/{id}") == [.literal("user"), .parameter("id")])
        #expect(Array(path: "/user/{id}/posts") == [.literal("user"), .parameter("id"), .literal("posts")])
        #expect(Array(path: "/user/{id}/posts/{postId}") == [.literal("user"), .parameter("id"), .literal("posts"), .parameter("postId")])

    }

    @Test
    func testPrefixParameter() {
        #expect(Array(path: "/user/user-{id}/posts") == [.literal("user"), .prefixParameter(prefix: "user-", parameter: "id"), .literal("posts")])
    }

    @Test
    func testSuffixParameter() {
        #expect(Array(path: "/user/{id}/posts/{id}.md") == [.literal("user"), .parameter("id"), .literal("posts"), .suffixParameter(suffix: ".md", parameter: "id")])
    }
}
