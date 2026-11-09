extension ProjectDocument {
    /// The files the project's client certificates read their identities from.
    public var identityReferences: [PlacedPathReference] {
        tls.clientCertificates.flatMap { entry in
            entry.source.files.map { PlacedPathReference($0, in: .clientCertificate(entry.id)) }
        }
    }

    /// How many fields hold the this-Mac-only reference `id`; copies of a request share their original's.
    public func referenceCount(of id: LocalPathID) -> Int {
        placedReferences.filter { $0.reference == .local(id) }.count
    }

    /// Every reference the project holds, with the slot holding it: certificates, proto definitions, and each request's
    /// files, GraphQL schema file, and descriptor set. A new field that holds a reference must be listed here, or in
    /// `RequestKind.mappingPathReferences(of:_:)` for a request's, or no file chosen for it ever resolves, and its local
    /// path and chosen outside path are lost on the next launch (`WorkspaceStateStore.reconcileChoices(in:holding:)`).
    public var placedReferences: [PlacedPathReference] {
        var placed = tls.caCertificates.map { PlacedPathReference($0, in: .caCertificates) }
            + grpc.protoRoots.map { PlacedPathReference($0, in: .protoRoots) }
            + grpc.descriptorSets.map { PlacedPathReference($0, in: .projectDescriptorSets) }
        placed += identityReferences
        for item in items {
            placed += item.placedReferences
        }
        return placed
    }
}

extension RequestKind {
    /// The spec with each file it refers to passed through `transform`, with its slot in `request`: form-data file
    /// parts, the binary body, the GraphQL schema file, and the descriptor set. The one list of a request's reference
    /// fields, which `ProjectDocument.placedReferences` reads too.
    public func mappingPathReferences(
        of request: RequestNodeID,
        _ transform: (ProjectPathReference, ProjectPathSlot) -> ProjectPathReference
    ) -> RequestKind {
        switch self {
        case .http(var spec):
            for index in spec.body.formData.indices {
                let slot = ProjectPathSlot.formField(request, spec.body.formData[index].id)
                spec.body.formData[index].file = spec.body.formData[index].file.map { transform($0, slot) }
            }
            spec.body.binary.file = spec.body.binary.file.map { transform($0, .binaryBody(request)) }
            if case .file(let reference) = spec.body.graphQL.schema {
                spec.body.graphQL.schema = .file(transform(reference, .graphQLSchema(request)))
            }
            return .http(spec)
        case .grpc(var spec):
            if case .descriptorSet(let reference) = spec.schema {
                spec.schema = .descriptorSet(transform(reference, .descriptorSet(request)))
            }
            return .grpc(spec)
        case .webSocket:
            // Binary messages are typed as base64, never read from a file.
            return self
        }
    }
}

extension RequestNode {
    /// The node with every request's file references, its own or its descendants', passed through `transform` with
    /// the slot holding each.
    public func mappingPathReferences(_ transform: (ProjectPathReference, ProjectPathSlot) -> ProjectPathReference) -> RequestNode {
        switch self {
        case .request(var request):
            request.kind = request.kind.mappingPathReferences(of: request.id, transform)
            return .request(request)
        case .folder(var folder):
            for index in folder.children.indices {
                folder.children[index] = folder.children[index].mappingPathReferences(transform)
            }
            return .folder(folder)
        }
    }

    /// The references the node's requests hold, its own or its descendants', with their slots.
    public var placedReferences: [PlacedPathReference] {
        var placed: [PlacedPathReference] = []
        _ = mappingPathReferences { reference, slot in
            placed.append(PlacedPathReference(reference, in: slot))
            return reference
        }
        return placed
    }
}
