import Foundation
import SwiftProtobuf

/// Every message, enum, and service a set of `.proto` files defines, indexed by fully qualified name without the
/// leading dot (`helloworld.HelloRequest`).
///
/// One shape for every schema source: protoc output, a descriptor set file, and server reflection all arrive as
/// `FileDescriptorProto`s. The codec and the editor's service and method pickers read it. A name defined twice keeps
/// the later definition, so `merging` lets one source override another.
public struct DescriptorRegistry: Sendable {
    public private(set) var files: [Google_Protobuf_FileDescriptorProto] = []
    private var messages: [String: Google_Protobuf_DescriptorProto] = [:]
    private var enums: [String: Google_Protobuf_EnumDescriptorProto] = [:]
    private var servicesByName: [String: GRPCServiceDescriptor] = [:]
    private var schemas: [String: MessageSchema] = [:]

    public static let empty = DescriptorRegistry(files: [])

    public init(files: [Google_Protobuf_FileDescriptorProto]) {
        for file in files {
            add(file)
        }
    }

    /// Reads a serialized `google.protobuf.FileDescriptorSet`, as `protoc --descriptor_set_out` writes it.
    public init(descriptorSet data: Data) throws(GRPCSchemaError) {
        let set: Google_Protobuf_FileDescriptorSet
        do {
            set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
        } catch {
            throw GRPCSchemaError("Not a protobuf descriptor set: \(error)")
        }
        self.init(files: set.file)
    }

    /// This registry plus `other`'s files; a file of the same name, or a type of the same full name, comes from
    /// `other`.
    public func merging(_ other: DescriptorRegistry) -> DescriptorRegistry {
        let names = Set(other.files.map(\.name))
        return DescriptorRegistry(files: files.filter { !names.contains($0.name) } + other.files)
    }

    public var isEmpty: Bool {
        files.isEmpty
    }

    /// Services sorted by full name, each with its methods in declaration order.
    public var services: [GRPCServiceDescriptor] {
        servicesByName.values.sorted { $0.fullName < $1.fullName }
    }

    public func service(_ fullName: String) -> GRPCServiceDescriptor? {
        servicesByName[Self.normalized(fullName)]
    }

    /// The method at `service/method`, the form `GRPCRequestSpec.methodPath` and gRPC paths use.
    public func method(_ path: String) -> GRPCMethodDescriptor? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let slash = trimmed.lastIndex(of: "/") else {
            return nil
        }
        let serviceName = String(trimmed[..<slash])
        let methodName = String(trimmed[trimmed.index(after: slash)...])
        return service(serviceName)?.methods.first { $0.name == methodName }
    }

    public func message(_ fullName: String) -> Google_Protobuf_DescriptorProto? {
        messages[Self.normalized(fullName)]
    }

    public func enumType(_ fullName: String) -> Google_Protobuf_EnumDescriptorProto? {
        enums[Self.normalized(fullName)]
    }

    /// The codec's field index for a message, built when its file was added.
    func schema(_ fullName: String) -> MessageSchema? {
        schemas[Self.normalized(fullName)]
    }

    public func file(named name: String) -> Google_Protobuf_FileDescriptorProto? {
        files.last { $0.name == name }
    }

    /// Descriptor type names carry a leading dot (`.pkg.Message`); the index does not.
    public static func normalized(_ name: String) -> String {
        name.hasPrefix(".") ? String(name.dropFirst()) : name
    }

    private mutating func add(_ file: Google_Protobuf_FileDescriptorProto) {
        files.removeAll { $0.name == file.name }
        files.append(file)
        let prefix = file.package.isEmpty ? "" : "\(file.package)."
        let features = InheritedFeatures(file: file)
        for message in file.messageType {
            addMessage(message, named: prefix + message.name, features: features)
        }
        for enumType in file.enumType {
            enums[prefix + enumType.name] = enumType
        }
        for service in file.service {
            let fullName = prefix + service.name
            servicesByName[fullName] = GRPCServiceDescriptor(
                fullName: fullName,
                methods: service.method.map { method in
                    GRPCMethodDescriptor(
                        service: fullName,
                        name: method.name,
                        inputType: Self.normalized(method.inputType),
                        outputType: Self.normalized(method.outputType),
                        kind: GRPCMethodKind(clientStreams: method.clientStreaming, serverStreams: method.serverStreaming)
                    )
                }
            )
        }
    }

    private mutating func addMessage(
        _ message: Google_Protobuf_DescriptorProto,
        named fullName: String,
        features: InheritedFeatures
    ) {
        messages[fullName] = message
        let messageFeatures = features.nested(in: message)
        schemas[fullName] = MessageSchema(message, fullName: fullName, features: messageFeatures)
        for nested in message.nestedType {
            addMessage(nested, named: "\(fullName).\(nested.name)", features: messageFeatures)
        }
        for enumType in message.enumType {
            enums["\(fullName).\(enumType.name)"] = enumType
        }
    }
}

public struct GRPCServiceDescriptor: Hashable, Sendable {
    /// Such as `helloworld.Greeter`.
    public let fullName: String
    public let methods: [GRPCMethodDescriptor]

    public init(fullName: String, methods: [GRPCMethodDescriptor]) {
        self.fullName = fullName
        self.methods = methods
    }
}

public struct GRPCMethodDescriptor: Hashable, Sendable {
    /// The service's full name.
    public let service: String
    public let name: String
    /// Full message names, without the leading dot.
    public let inputType: String
    public let outputType: String
    public let kind: GRPCMethodKind

    public init(service: String, name: String, inputType: String, outputType: String, kind: GRPCMethodKind) {
        self.service = service
        self.name = name
        self.inputType = inputType
        self.outputType = outputType
        self.kind = kind
    }

    /// `service/method`.
    public var path: String {
        "\(service)/\(name)"
    }
}

/// A schema that could not be read or does not define what a call needs.
public struct GRPCSchemaError: Error, Hashable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
