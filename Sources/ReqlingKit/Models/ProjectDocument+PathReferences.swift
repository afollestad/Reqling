extension ProjectDocument {
    /// Every `ProjectPathReference.local` ID the project uses. `WorkspaceStateStore.reconcileLocalPaths(in:keeping:)`
    /// deletes every other stored path.
    public var localPathIDs: Set<LocalPathID> {
        Set(pathReferences.compactMap { reference in
            if case .local(let id) = reference {
                return id
            }
            return nil
        })
    }

    /// The files the project's client certificates read their identities from.
    public var identityReferences: [ProjectPathReference] {
        tls.clientCertificates.flatMap(\.source.files)
    }

    /// How many fields hold the this-Mac-only reference `id`; copies of a request share their original's.
    public func referenceCount(of id: LocalPathID) -> Int {
        pathReferences.filter { $0 == .local(id) }.count
    }

    /// Every `ProjectPathReference.relative` path the project uses. `WorkspaceStateStore.reconcileChosenOutsidePaths`
    /// forgets every other chosen outside path.
    public var relativePaths: Set<String> {
        Set(pathReferences.compactMap { reference in
            if case .relative(let path) = reference {
                return path
            }
            return nil
        })
    }

    /// Every reference the project holds: certificates, proto definitions, and each request's files, GraphQL schema
    /// file, and descriptor set. A new field that holds a reference must be listed here, or in
    /// `RequestKind.mappingPathReferences(_:)` for a request's, or its local path and chosen outside path are lost on
    /// the next launch.
    private var pathReferences: [ProjectPathReference] {
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
        return references
    }
}

extension RequestKind {
    /// The spec with each file it refers to passed through `transform`: form-data file parts, the binary body, the
    /// GraphQL schema file, and the descriptor set. The one list of a request's reference fields, which
    /// `ProjectDocument.pathReferences` reads too.
    public func mappingPathReferences(_ transform: (ProjectPathReference) -> ProjectPathReference) -> RequestKind {
        switch self {
        case .http(var spec):
            for index in spec.body.formData.indices {
                spec.body.formData[index].file = spec.body.formData[index].file.map(transform)
            }
            spec.body.binary.file = spec.body.binary.file.map(transform)
            if case .file(let reference) = spec.body.graphQL.schema {
                spec.body.graphQL.schema = .file(transform(reference))
            }
            return .http(spec)
        case .grpc(var spec):
            if case .descriptorSet(let reference) = spec.schema {
                spec.schema = .descriptorSet(transform(reference))
            }
            return .grpc(spec)
        case .webSocket:
            // Binary messages are typed as base64, never read from a file.
            return self
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
