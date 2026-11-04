import ReqlingKit
import SwiftUI

/// A project's name, project-level auth, and TLS certificates.
struct ProjectSettingsSheet: View {
    @State var settings: ProjectSettingsModel
    let tokenContext: TemplateTokenContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    LabeledRow("Name") {
                        TextField("Name", text: $settings.name)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                }
                Section {
                    AuthEditor(auth: $settings.auth, allowsInherit: false, tokenContext: tokenContext)
                } header: {
                    Text("Auth")
                } footer: {
                    Text("Requests and folders set to Inherit use this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ClientCertificatesSection(settings: settings)
                CACertificatesSection(settings: settings)
            }
            .formStyle(.grouped)
            SheetFooter {
                dismiss()
            } onPrimary: {
                if settings.save() {
                    dismiss()
                }
            }
        }
        .frame(width: 640, height: 600)
    }
}

private struct ClientCertificatesSection: View {
    @Bindable var settings: ProjectSettingsModel

    var body: some View {
        Section {
            ForEach($settings.clientCertificates) { $entry in
                ClientCertificateRow(entry: $entry, settings: settings)
            }
            HStack {
                Button("Add Certificate File…") { settings.addPKCS12Certificate() }
                Button("Choose from Keychain…") { settings.addKeychainCertificate() }
                    .disabled(settings.availableKeychainIdentities.isEmpty)
            }
        } header: {
            Text("Client Certificates")
        } footer: {
            Text("""
                Presented to hosts that ask for one (mutual TLS). Use a PKCS#12 file (.p12 or .pfx). For a .crt and .key \
                pair, convert it first: \(PKCS12Importer.conversionHint)
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ClientCertificateRow: View {
    @Binding var entry: ClientCertificateEntry
    let settings: ProjectSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledRow("Host") {
                    TextField("Host", text: $entry.hostPattern, prompt: Text("api.example.com, *.internal, or host:8443"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                }
                Button {
                    settings.removeClientCertificate(entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this certificate")
                .accessibilityLabel("Remove this certificate")
            }
            if !entry.hostPattern.isEmpty, !settings.isValidHostPattern(entry.hostPattern) {
                LabeledRowNote(text: "Enter a host, optionally with *. in front and :port after.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            switch entry.source {
            case .pkcs12(let file):
                LabeledRow("File") {
                    Text(settings.describe(file))
                        .foregroundStyle(.secondary)
                }
                LabeledRow("Passphrase") {
                    SecureField("Passphrase", text: Binding(
                        get: { settings.passphrases[entry.id] ?? "" },
                        set: { settings.passphrases[entry.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                }
            case .keychainIdentity:
                LabeledRow("Identity") {
                    Picker("Identity", selection: Binding(
                        get: { settings.keychainIdentities[entry.id] },
                        set: { settings.keychainIdentities[entry.id] = $0 }
                    )) {
                        Text("Choose…").tag(Data?.none)
                        ForEach(settings.availableKeychainIdentities, id: \.persistentReference) { identity in
                            Text(identity.summary.subject).tag(Data?.some(identity.persistentReference))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            CertificateStatusLabel(status: settings.status(of: entry))
                .alignedWithLabeledRowControls()
        }
        .padding(.vertical, 4)
    }
}

private struct CACertificatesSection: View {
    let settings: ProjectSettingsModel

    var body: some View {
        Section {
            ForEach(settings.caCertificates.indices, id: \.self) { index in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.describe(settings.caCertificates[index]))
                        CertificateStatusLabel(status: settings.status(ofCA: settings.caCertificates[index]))
                    }
                    Spacer()
                    Button {
                        settings.removeCACertificate(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this CA certificate")
                    .accessibilityLabel("Remove this CA certificate")
                }
            }
            Button("Add CA Certificate…") { settings.addCACertificate() }
        } header: {
            Text("CA Certificates")
        } footer: {
            Text("Trusted in addition to the system's roots, for internal or self-signed servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CertificateStatusLabel: View {
    let status: ProjectSettingsModel.CertificateStatus

    var body: some View {
        switch status {
        case .valid(let summary):
            Label(describe(summary), systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .expired(let summary):
            Label("Expired. \(describe(summary))", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .problem(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func describe(_ summary: CertificateSummary) -> String {
        var parts = [summary.subject]
        if let issuer = summary.issuer {
            parts.append("issued by \(issuer)")
        }
        if let date = summary.notValidAfter {
            parts.append("valid until \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: ", ")
    }
}
