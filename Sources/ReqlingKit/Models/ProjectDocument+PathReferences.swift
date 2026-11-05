extension ProjectDocument {
    /// Every `ProjectPathReference.local` ID the project uses: certificates, proto definitions, and each request's
    /// files and descriptor set. `WorkspaceStateStore.reconcileLocalPaths(in:keeping:)` deletes every other stored path,
    /// so a new field that holds a reference must be listed here, or in `RequestKind.mappingPathReferences(_:)` for a
    /// request's, or its path is lost on the next launch.
    public var localPathIDs: Set<LocalPathID> {
        var references = tls.caCertificates + grpc.protoRoots + grpc.descriptorSets
        for entry in tls.clientCertificates {
            references += entry.source.files
        }
        for (request, _) in allRequests {
            _ = request.kind.mappingPathReferences { reference in
                references.append(reference)
                return reference
            }
        }
        return Set(references.compactMap { reference in
            if case .local(let id) = reference {
                return id
            }
            return nil
        })
    }
}

extension RequestKind {
    /// The spec with each file it refers to passed through `transform`: form-data file parts, the binary body, and the
    /// descriptor set. The one list of a request's reference fields, which `ProjectDocument.localPathIDs` reads too.
    public func mappingPathReferences(_ transform: (ProjectPathReference) -> ProjectPathReference) -> RequestKind {
        switch self {
        case .http(var spec):
            for index in spec.body.formData.indices {
                spec.body.formData[index].file = spec.body.formData[index].file.map(transform)
            }
            spec.body.binary.file = spec.body.binary.file.map(transform)
            return .http(spec)
        case .grpc(var spec):
            if case .descriptorSet(let reference) = spec.schema {
                spec.schema = .descriptorSet(transform(reference))
            }
            return .grpc(spec)
        }
    }
}

extension RequestNode {
    /// The node with every request's file references, its own or its descendants', passed through `transform`.
    public func mappingPathReferences(_ transform: (ProjectPathReference) -> ProjectPathReference) -> RequestNode {
        switch self {
        case .request(var request):
            request.kind = request.kind.mappingPathReferences(transform)
            return .request(request)
        case .folder(var folder):
            for index in folder.children.indices {
                folder.children[index] = folder.children[index].mappingPathReferences(transform)
            }
            return .folder(folder)
        }
    }
}
