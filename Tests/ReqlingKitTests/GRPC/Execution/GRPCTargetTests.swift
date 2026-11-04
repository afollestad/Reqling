import ReqlingKit
import XCTest

final class GRPCTargetTests: XCTestCase {
    func testParsesHostsIPv6LiteralsAndUnixSockets() throws {
        // Each text and the endpoint it parses to.
        let cases: [String: GRPCTarget.Endpoint] = [
            "localhost:50051": .host("localhost", port: 50051),
            "  api.example.com:443 ": .host("api.example.com", port: 443),
            "10.0.0.2:8080": .host("10.0.0.2", port: 8080),
            "[::1]:9000": .host("::1", port: 9000),
            "unix:/var/run/app.sock": .unixSocket(path: "/var/run/app.sock"),
            "unix:///var/run/app.sock": .unixSocket(path: "/var/run/app.sock"),
            "unix:relative.sock": .unixSocket(path: "relative.sock")
        ]
        for (text, endpoint) in cases {
            XCTAssertEqual(try GRPCTarget(parsing: text).endpoint, endpoint, text)
        }
        XCTAssertEqual(try GRPCTarget(parsing: " api.example.com:443").description, "api.example.com:443")
        XCTAssertEqual(try GRPCTarget(parsing: "[::1]:9000").description, "[::1]:9000")
        XCTAssertEqual(try GRPCTarget(parsing: "unix:///var/run/app.sock").description, "unix:/var/run/app.sock")
        XCTAssertEqual(try GRPCTarget(parsing: "[::1]:9000").host, "::1")
        XCTAssertEqual(try GRPCTarget(parsing: "unix:/a.sock").host, "localhost")
        XCTAssertNil(try GRPCTarget(parsing: "unix:/a.sock").port)
    }

    func testRejectsTargetsWithoutAUsablePort() {
        for text in ["", "localhost", "http://localhost:50051", "::1:80", "[::1]", "[::1:80", "host:0", "host:70000", ":80", "unix:"] {
            XCTAssertThrowsError(try GRPCTarget(parsing: text), text) { error in
                guard case .invalidRequest = error as? GRPCCallError else {
                    return XCTFail("\(text): \(error)")
                }
            }
        }
    }
}
