import Foundation
import Observation
import ReqlingKit
import XCTest

@testable import Reqling

/// The greeter schema for app tests, which cannot reach `ReqlingKitTests`' fixtures. Screenshot mode's demo project
/// shares it; `GreeterDescriptorSet` holds the bytes and the `.proto` they were compiled from.
enum GRPCFixtures {
    static let service = GreeterDescriptorSet.service
    static let descriptorSetName = GreeterDescriptorSet.fileName

    static var descriptorSet: Data {
        GreeterDescriptorSet.data
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
