import Testing
import RobotLink

@Suite("RobotEndpoint")
struct RobotEndpointTests {
    @Test("default targets the Wireless mDNS host")
    func defaults() {
        let e = RobotEndpoint()
        #expect(e.host == "reachy-mini.local")
        #expect(e.port == 8000)
        #expect(e.baseURL.absoluteString == "http://reachy-mini.local:8000")
    }

    @Test("apiURL composes correctly")
    func api() {
        let e = RobotEndpoint(host: "10.0.0.5", port: 8000)
        #expect(e.apiURL("/api/state/full").absoluteString == "http://10.0.0.5:8000/api/state/full")
    }

    @Test("wsURL uses ws:// scheme")
    func ws() {
        let e = RobotEndpoint()
        #expect(e.wsURL("/api/state/ws/full").absoluteString.hasPrefix("ws://"))
    }
}
