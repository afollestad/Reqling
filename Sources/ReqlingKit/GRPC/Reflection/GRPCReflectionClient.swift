import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

/// Reads a server's schema through gRPC server reflection, over the same transport and TLS plumbing as calls
/// (`GRPCConnection`).
public struct GRPCReflectionClient: Sendable {
    /// Tried in order. v1alpha is wire-compatible with v1 and still the only version many servers offer.
    static let reflectionServices = ["grpc.reflection.v1.ServerReflection", "grpc.reflection.v1alpha.ServerReflection"]

    public init() {}

    /// Every service the server lists (the reflection service itself left out), with the files that define it and
    /// everything they import. A listed service the server cannot describe, or an import it cannot provide, is
    /// left out rather than failing the rest: a partial schema still lets the described methods be called.
    ///
    /// `metadata` goes with the reflection call, for servers that require authentication; `timeout` bounds each
    /// attempt (v1, then v1alpha).
    public func registry(
        target: GRPCTarget,
        security: GRPCTransportSecurity,
        metadata: [KeyValuePair] = [],
        timeout: Duration? = nil
    ) async throws(GRPCReflectionError) -> DescriptorRegistry {
        let requestMetadata: Metadata
        do {
            requestMetadata = try GRPCMetadataCoding.metadata(from: metadata)
        } catch {
            throw .call(error)
        }
        var options = CallOptions.defaults
        options.timeout = timeout
        let result: Result<DescriptorRegistry, GRPCReflectionError>
        do {
            result = try await GRPCConnection.run(target: target, security: security) { client in
                for service in Self.reflectionServices {
                    switch try await Self.session(client, service: service, metadata: requestMetadata, options: options) {
                    case .registry(let registry):
                        return .success(registry)
                    case .unimplemented:
                        continue
                    case .failed(let error):
                        return .failure(error)
                    }
                }
                return .failure(.unsupported)
            }
        } catch {
            switch error {
            case .status(let status, _):
                throw .status(status)
            case .failure(let failure):
                throw .call(failure)
            }
        }
        if Task.isCancelled {
            throw .call(.cancelled)
        }
        return try result.get()
    }

    private enum SessionResult: Sendable {
        case registry(DescriptorRegistry)
        /// The server has no reflection under this service name.
        case unimplemented
        case failed(GRPCReflectionError)
    }

    /// One bidirectional stream carries the whole conversation, request by request.
    private static func session(
        _ client: GRPCClient<HTTP2ClientTransport.Posix>,
        service: String,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> SessionResult {
        let (requests, sink) = AsyncStream.makeStream(of: Grpc_Reflection_V1_ServerReflectionRequest.self)
        let request = StreamingClientRequest(of: Grpc_Reflection_V1_ServerReflectionRequest.self, metadata: metadata) { writer in
            for await message in requests {
                try await writer.write(message)
            }
        }
        return try await client.bidirectionalStreaming(
            request: request,
            descriptor: MethodDescriptor(fullyQualifiedService: service, method: "ServerReflectionInfo", type: .bidirectionalStreaming),
            serializer: ProtobufSerializer<Grpc_Reflection_V1_ServerReflectionRequest>(),
            deserializer: ProtobufDeserializer<Grpc_Reflection_V1_ServerReflectionResponse>(),
            options: options
        ) { response in
            defer { sink.finish() }
            var conversation = ReflectionConversation(requests: sink, responses: response.bodyParts.makeAsyncIterator())
            do {
                return .registry(try await conversation.registry())
            } catch let error as RPCError {
                return error.code == .unimplemented ? .unimplemented : .failed(.status(GRPCStatusRecord(error)))
            } catch let error as GRPCReflectionError {
                return .failed(error)
            } catch {
                return .failed(Task.isCancelled ? .call(.cancelled) : .invalidResponse("Reflection failed: \(error)"))
            }
        }
    }
}

/// Why reflection produced no schema.
public enum GRPCReflectionError: Error, Hashable, Sendable, LocalizedError {
    /// The call never reached a status: no connection, a TLS failure, or cancellation.
    case call(GRPCCallError)
    /// The server ended the reflection call with this status, such as `UNAUTHENTICATED`.
    case status(GRPCStatusRecord)
    /// The server implements neither v1 nor v1alpha reflection.
    case unsupported
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .call(let error):
            error.errorDescription
        case .status(let status):
            status.message.isEmpty ? "Reflection failed with \(status.name)." : "Reflection failed with \(status.name): \(status.message)"
        case .unsupported:
            "The server does not offer gRPC reflection; use its .proto files or a descriptor set instead."
        case .invalidResponse(let message):
            message
        }
    }
}

/// The request-and-answer exchange on one reflection stream: each request gets exactly one response, in order.
private struct ReflectionConversation {
    typealias Request = Grpc_Reflection_V1_ServerReflectionRequest
    typealias Response = Grpc_Reflection_V1_ServerReflectionResponse

    let requests: AsyncStream<Request>.Continuation
    var responses: RPCAsyncSequence<StreamingClientResponse<Response>.Contents.BodyPart, any Error>.AsyncIterator
    private var collected = FileCollector()

    init(
        requests: AsyncStream<Request>.Continuation,
        responses: RPCAsyncSequence<StreamingClientResponse<Response>.Contents.BodyPart, any Error>.AsyncIterator
    ) {
        self.requests = requests
        self.responses = responses
    }

    /// Lists the services, asks for the file defining each, then asks by name for every import still missing until
    /// none is.
    mutating func registry() async throws -> DescriptorRegistry {
        let listing: Grpc_Reflection_V1_ListServiceResponse
        switch try await ask(.listServices("*")) {
        case .listServicesResponse(let response):
            listing = response
        case .errorResponse(let error):
            throw GRPCReflectionError.invalidResponse("The server could not list its services: \(error.errorMessage)")
        default:
            throw GRPCReflectionError.invalidResponse("The server answered a service listing with something else.")
        }
        let services = listing.service.map(\.name).filter { !GRPCReflectionClient.reflectionServices.contains($0) }
        for service in services {
            try await fetch(.fileContainingSymbol(service))
        }
        while let missing = collected.nextMissingDependency() {
            try await fetch(.fileByFilename(missing))
            collected.markRequested(missing)
        }
        return DescriptorRegistry(files: collected.files)
    }

    /// An error response leaves that file out; see `GRPCReflectionClient.registry`.
    private mutating func fetch(_ request: Request.OneOf_MessageRequest) async throws {
        switch try await ask(request) {
        case .fileDescriptorResponse(let response):
            try collected.add(response)
        case .errorResponse:
            break
        default:
            throw GRPCReflectionError.invalidResponse("The server answered a file request with something else.")
        }
    }

    private mutating func ask(_ request: Request.OneOf_MessageRequest) async throws -> Response.OneOf_MessageResponse {
        var message = Request()
        message.messageRequest = request
        requests.yield(message)
        switch try await responses.next() {
        case .message(let response):
            guard let payload = response.messageResponse else {
                throw GRPCReflectionError.invalidResponse("The server sent an empty reflection response.")
            }
            return payload
        case .trailingMetadata, nil:
            throw GRPCReflectionError.invalidResponse("The server closed the reflection stream before answering.")
        }
    }
}

/// The files received so far, each once, in arrival order.
private struct FileCollector {
    private(set) var files: [Google_Protobuf_FileDescriptorProto] = []
    private var names: Set<String> = []
    /// Imports already asked for by name; a server that cannot provide one is not asked again.
    private var requested: Set<String> = []

    mutating func add(_ response: Grpc_Reflection_V1_FileDescriptorResponse) throws(GRPCReflectionError) {
        for data in response.fileDescriptorProto {
            let file: Google_Protobuf_FileDescriptorProto
            do {
                file = try Google_Protobuf_FileDescriptorProto(serializedBytes: data)
            } catch {
                throw .invalidResponse("The server sent a file descriptor that could not be read: \(error)")
            }
            if names.insert(file.name).inserted {
                files.append(file)
            }
        }
    }

    func nextMissingDependency() -> String? {
        files.lazy.flatMap(\.dependency).first { !names.contains($0) && !requested.contains($0) }
    }

    mutating func markRequested(_ name: String) {
        requested.insert(name)
    }
}
