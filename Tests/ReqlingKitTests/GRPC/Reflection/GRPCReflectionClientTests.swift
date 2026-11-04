import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import GRPCReflectionService
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

final class GRPCReflectionClientTests: XCTestCase {
    func testReflectionV1ListsServicesWithTheirFilesAndImports() async throws {
        let server = try await start([try ReflectionService(descriptorSetFileURLs: [try descriptorSetURL()]), EchoService()])

        let registry = try await GRPCReflectionClient().registry(target: server.target, security: .plaintext)

        try assertDescribesEchoService(registry)
    }

    /// The v1alpha stand-in answers `file_containing_symbol` with the defining file alone, so every import has to be
    /// fetched by name, and it lists a service it cannot describe.
    func testFallsBackToV1AlphaAndFetchesImportsByName() async throws {
        let files = try Google_Protobuf_FileDescriptorSet(serializedBytes: Data(contentsOf: try descriptorSetURL())).file
        let server = try await start([AlphaReflectionService(files: files), EchoService()])

        let registry = try await GRPCReflectionClient().registry(target: server.target, security: .plaintext)

        try assertDescribesEchoService(registry)
        XCTAssertEqual(Set(registry.files.map(\.name)), Set(files.map(\.name)))
    }

    func testReflectionWorksOverMutualTLS() async throws {
        let leaf = try TLSFixtures.mint()
        let authority = [UInt8](try TLSFixtures.data("ca.pem"))
        let security = HTTP2ServerTransport.Posix.TransportSecurity.mTLS(
            certificateChain: [.bytes(Array(leaf.certificatePEM.utf8), format: .pem)],
            privateKey: .bytes(Array(leaf.privateKeyPEM.utf8), format: .pem)
        ) { config in
            config.trustRoots = .certificates([.bytes(authority, format: .pem)])
        }
        let server = try await start([try ReflectionService(descriptorSetFileURLs: [try descriptorSetURL()])], security: security)
        let identity = try PKCS12Importer.importIdentity(try TLSFixtures.data("client.p12"), passphrase: try TLSFixtures.clientPassphrase)
        let context = TLSContext(anchors: try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem"))) { _, _ in identity }

        let registry = try await GRPCReflectionClient().registry(target: server.target, security: .tls(context))

        try assertDescribesEchoService(registry)
    }

    func testAServerWithoutReflectionIsUnsupported() async throws {
        let server = try await start([EchoService()])

        do {
            _ = try await GRPCReflectionClient().registry(target: server.target, security: .plaintext)
            XCTFail("Expected reflection to be unsupported")
        } catch {
            XCTAssertEqual(error, .unsupported)
        }
    }

    func testASilentServerEndsReflectionAtItsDeadlineOrOnCancel() async throws {
        let silent = try await SilentServer.start()
        addTeardownBlock { await silent.stop() }
        let target = silent.target

        let expired = await bounded("deadline", Task { await Self.reflect(target, timeout: .milliseconds(200)) })
        let running = Task { await Self.reflect(target, timeout: nil) }
        running.cancel()
        let cancelled = await bounded("cancel", running)

        XCTAssertEqual(expired, .status(GRPCStatusRecord(code: 4, name: "DEADLINE_EXCEEDED", message: "RPC timed out before completing")))
        XCTAssertEqual(cancelled, .call(.cancelled))
    }

    private static func reflect(_ target: GRPCTarget, timeout: Duration?) async -> GRPCReflectionError? {
        do {
            _ = try await GRPCReflectionClient().registry(target: target, security: .plaintext, timeout: timeout)
            return nil
        } catch {
            return error
        }
    }

    func testARefusedConnectionIsACallFailure() async throws {
        let port = try FreePort.next()

        do {
            _ = try await GRPCReflectionClient().registry(target: GRPCTarget(.host("127.0.0.1", port: port)), security: .plaintext)
            XCTFail("Expected a connection failure")
        } catch {
            guard case .call(.connectionFailed) = error else {
                return XCTFail("Expected a connection failure, got \(error)")
            }
        }
    }
}

extension GRPCReflectionClientTests {
    private func start(
        _ services: [any RegistrableRPCService],
        security: HTTP2ServerTransport.Posix.TransportSecurity = .plaintext
    ) async throws -> GRPCTestServer {
        let server = try await GRPCTestServer.start(services, security: security)
        addTeardownBlock { await server.stop() }
        return server
    }

    private func descriptorSetURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "codec_test", withExtension: "binpb", subdirectory: "Fixtures"))
    }

    private func assertDescribesEchoService(_ registry: DescriptorRegistry, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(registry.services.map(\.fullName), [EchoService.name], file: file, line: line)
        let methods = try XCTUnwrap(registry.service(EchoService.name), file: file, line: line).methods
        XCTAssertEqual(methods.map(\.name), ["Unary", "ServerStream", "ClientStream", "Bidi"], file: file, line: line)
        XCTAssertEqual(methods.map(\.kind), [.unary, .serverStreaming, .clientStreaming, .bidirectionalStreaming], file: file, line: line)
        XCTAssertNotNil(registry.message("reqling.test.v1.Everything"), file: file, line: line)
        XCTAssertNotNil(registry.message("google.protobuf.Timestamp"), "Imports arrive too", file: file, line: line)
    }
}

/// Reflection served only under `grpc.reflection.v1alpha`, as older servers do, built on the v1 messages since the
/// two are wire-compatible. It lists itself and a service it cannot describe alongside the real ones. `gate` holds
/// every answer until it opens; `onListServices` reports each listing request.
struct AlphaReflectionService: RegistrableRPCService {
    typealias Request = Grpc_Reflection_V1_ServerReflectionRequest
    typealias Response = Grpc_Reflection_V1_ServerReflectionResponse

    static let name = "grpc.reflection.v1alpha.ServerReflection"

    let files: [Google_Protobuf_FileDescriptorProto]
    var gate: TestGate?
    var onListServices: (@Sendable () -> Void)?

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        let files = files
        let gate = gate
        let onListServices = onListServices
        router.registerHandler(
            forMethod: MethodDescriptor(fullyQualifiedService: Self.name, method: "ServerReflectionInfo"),
            deserializer: ProtobufDeserializer<Request>(),
            serializer: ProtobufSerializer<Response>()
        ) { request, _ in
            StreamingServerResponse { writer in
                for try await message in request.messages {
                    if case .listServices = message.messageRequest {
                        onListServices?()
                    }
                    await gate?.wait()
                    try await writer.write(try Self.answer(message, files: files))
                }
                return [:]
            }
        }
    }

    private static func answer(_ request: Request, files: [Google_Protobuf_FileDescriptorProto]) throws -> Response {
        var response = Response()
        response.originalRequest = request
        let file: Google_Protobuf_FileDescriptorProto?
        switch request.messageRequest {
        case .listServices:
            let names = files.flatMap { file in file.service.map { "\(file.package).\($0.name)" } } + [name, "reqling.test.v1.Ghost"]
            response.listServicesResponse = .with { $0.service = names.map { name in .with { $0.name = name } } }
            return response
        case .fileContainingSymbol(let symbol):
            file = files.first { file in file.service.contains { "\(file.package).\($0.name)" == symbol } }
        case .fileByFilename(let name):
            file = files.first { $0.name == name }
        default:
            file = nil
        }
        if let file {
            response.fileDescriptorResponse = try .with { $0.fileDescriptorProto = [try file.serializedData()] }
        } else {
            response.errorResponse = .with {
                $0.errorCode = Int32(RPCError.Code.notFound.rawValue)
                $0.errorMessage = "Not found"
            }
        }
        return response
    }
}
