import Testing
@testable import VeloxServe

struct ForwardedHeaderTests {

    @Test
    func singleTrustedProxyTakesLeftmost() {
        // client -> proxy -> server, proxy appends the client it saw.
        let header = "203.0.113.7"
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 1) == "203.0.113.7")
    }

    @Test
    func ignoresSpoofedEntriesLeftOfTrustedHops() {
        // A malicious client prepends a fake address; with one trusted proxy we
        // take the rightmost (proxy-appended) entry and ignore the forgery.
        let header = "1.1.1.1, 203.0.113.7"
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 1) == "203.0.113.7")
    }

    @Test
    func countsHopsFromTheRight() {
        // client, proxy1, proxy2 with two trusted proxies resolves to the client.
        let header = "203.0.113.7, 10.0.0.1, 10.0.0.2"
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 2) == "10.0.0.1")
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 3) == "203.0.113.7")
    }

    @Test
    func ignoresHeaderShorterThanTrustedHops() {
        let header = "203.0.113.7"
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 2) == nil)
    }

    @Test
    func trimsWhitespaceAndEmptyEntries() {
        let header = " 203.0.113.7 ,  "
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 1) == "203.0.113.7")
    }

    @Test
    func stripsPortFromIPv4() {
        let header = "203.0.113.7:54321"
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: header, trustedHops: 1) == "203.0.113.7")
    }

    @Test
    func unwrapsBracketedIPv6() {
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: "[2001:db8::1]:443", trustedHops: 1) == "2001:db8::1")
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: "[2001:db8::1]", trustedHops: 1) == "2001:db8::1")
    }

    @Test
    func keepsBareIPv6Intact() {
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: "2001:db8::1", trustedHops: 1) == "2001:db8::1")
    }

    @Test
    func rejectsUnknownToken() {
        #expect(ForwardedHeaderHandler.clientAddress(fromForwardedFor: "unknown", trustedHops: 1) == nil)
    }
}
