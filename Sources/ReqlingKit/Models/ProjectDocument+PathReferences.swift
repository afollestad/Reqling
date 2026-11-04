extension ProjectDocument {
    /// Every `ProjectPathReference.local` ID the project uses: certificates, proto definitions, and each request's
    /// files and descriptor set. `WorkspaceStateStore.reconcileLocalPaths(in:keeping:)` deletes every other stored path,
    /// so a new field that holds a reference must be listed here or its path is lost on the next launch.
    public var localPathIDs: Set<LocalPathID> {
        var references = tls.caCertificates + grpc.protoRoots + grpc.descriptorSets
        for entry in tls.clientCertificates {
            if case .pkcs12(let reference) = entry.source {
                references.append(reference)
            }
        }
        for (request, _) in allRequests {
            switch request.kind {
            case .http(let spec):
                references += spec.body.formData.compactMap(\.file)
                if let file = spec.body.binary.file {
                    references.append(file)
                }
            case .grpc(let spec):
                if case .descriptorSet(let reference) = spec.schema {
                    references.append(reference)
                }
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
