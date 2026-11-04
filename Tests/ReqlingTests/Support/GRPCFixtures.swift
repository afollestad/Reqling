import Foundation
import Observation
import ReqlingKit
import XCTest

@testable import Reqling

/// A descriptor set for app tests, which cannot reach `ReqlingKitTests`' fixtures. Kept as hex rather than a resource
/// so the app test target needs none; `protoc --descriptor_set_out=greeter.binpb acme/greeter/v1/greeter.proto`
/// compiled it from:
///
/// ```proto
/// syntax = "proto3";
/// package acme.greeter.v1;
/// enum Mood { MOOD_UNSPECIFIED = 0; MOOD_CHEERFUL = 1; }
/// message HelloRequest { string name = 1; Mood mood = 2; repeated string tags = 3; }
/// message HelloReply { string message = 1; int32 count = 2; }
/// service Greeter {
///   rpc SayHello(HelloRequest) returns (HelloReply);
///   rpc ListGreetings(HelloRequest) returns (stream HelloReply);
///   rpc CollectNames(stream HelloRequest) returns (HelloReply);
///   rpc Chat(stream HelloRequest) returns (stream HelloReply);
/// }
/// ```
enum GRPCFixtures {
    static let service = "acme.greeter.v1.Greeter"
    static let descriptorSetName = "greeter.binpb"

    static var descriptorSet: Data {
        let hex = """
        0ac3040a1d61636d652f677265657465722f76312f677265657465722e70726f746f120f61636d652e677265657465722e763122610a0c48656c6c6f5265717565737412
        120a046e616d6518012001280952046e616d6512290a046d6f6f6418022001280e32152e61636d652e677265657465722e76312e4d6f6f6452046d6f6f6412120a047461
        6773180320032809520474616773223c0a0a48656c6c6f5265706c7912180a076d65737361676518012001280952076d65737361676512140a05636f756e741802200128
        055205636f756e742a2f0a044d6f6f6412140a104d4f4f445f554e535045434946494544100012110a0d4d4f4f445f434845455246554c100132b6020a07477265657465
        7212460a0853617948656c6c6f121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e61636d652e677265657465722e76312e48656c6c6f
        5265706c79124d0a0d4c6973744772656574696e6773121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e61636d652e67726565746572
        2e76312e48656c6c6f5265706c793001124c0a0c436f6c6c6563744e616d6573121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e6163
        6d652e677265657465722e76312e48656c6c6f5265706c79280112460a0443686174121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e
        61636d652e677265657465722e76312e48656c6c6f5265706c7928013001620670726f746f33
        """
        let digits = Array(hex.filter(\.isHexDigit))
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }

    /// A spec that reads its schema from `descriptorSetName` in the project folder.
    static func descriptorSetSpec(method: String = "", messages: [String] = ["{}"], target: String = "localhost:50051") -> GRPCRequestSpec {
        GRPCRequestSpec(
            target: target,
            service: method.isEmpty ? "" : service,
            method: method,
            messages: messages,
            schema: .descriptorSet(.relative(descriptorSetName))
        )
    }

    /// Writes the descriptor set into the project's folder and adds a gRPC request with `spec` at its root.
    @MainActor
    static func addRequest(
        named name: String = "Say hello",
        spec: GRPCRequestSpec = descriptorSetSpec(),
        to project: ProjectID,
        in fixture: AppFixture
    ) throws -> RequestNodeID {
        let root = try projectURL(project, in: fixture)
        try descriptorSet.write(to: root.appendingPathComponent(descriptorSetName))
        let request = RequestItem(name: name, kind: .grpc(spec))
        try fixture.library.mutate(project) { try $0.insert(.request(request), into: nil) }
        return request.id
    }

    @MainActor
    private static func projectURL(_ project: ProjectID, in fixture: AppFixture) throws -> URL {
        guard let url = fixture.library.project(project)?.url else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

/// A loopback TCP port, picked by the kernel, that never answers: connections complete into its backlog and then hear
/// nothing, so a gRPC call to it stays open, waiting on the server, until the test cancels it. That holds a live call
/// (and its open request stream) with no server, no fixed port, and no network beyond this Mac.
final class SilentLoopbackListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, length) == 0 && listen(descriptor, 16) == 0 && getsockname(descriptor, address, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    var target: String {
        "127.0.0.1:\(port)"
    }

    deinit {
        close(descriptor)
    }
}

extension XCTestCase {
    /// Returns once `condition` holds, re-checking whenever what it reads changes. For waits on a gRPC call's
    /// transport, which runs off the main actor, so `waitUntil`'s bounded count of main-actor turns cannot cover it.
    @MainActor
    func waitUntilObserved(_ description: String, timeout: TimeInterval = 30, _ condition: @escaping @MainActor () -> Bool) async {
        let done = expectation(description: description)
        let waiting = Task { @MainActor in
            while !condition() {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = condition()
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        waiting.cancel()
    }
}
