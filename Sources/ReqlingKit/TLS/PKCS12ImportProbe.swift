import CryptoKit
import Foundation
import Synchronization

/// Decides whether `SecPKCS12Import` can open a PKCS#12 file in this process without ending it. Apple's importer raises
/// an Objective-C exception, which Swift cannot catch, on some files: the known one holds a certificate whose EC key
/// uses explicit curve parameters, which Security cannot read a key from. A protocol, like `KeychainIdentityStore`, so
/// tests choose which processes they launch.
public protocol PKCS12ImportProbe: Sendable {
    /// Returns when importing `data` here is safe. Throws `.unsupportedCertificate` when the import would crash, and
    /// `.certificateCheckFailed` when the check itself could not run, so an unchecked file never reaches the importer.
    func check(_ data: Data, passphrase: String) throws(TLSError)
}

/// Imports the file in the `ReqlingPKCS12Probe` helper first, so a crash ends the helper instead of Reqling. The
/// helper's input and exit statuses are documented on its `PKCS12Probe`.
///
/// Verdicts are kept per file and passphrase for the life of the process: a request opens its identity on every run,
/// and the settings sheet on every edit. A check that could not finish keeps nothing, so the next one tries again. An
/// unkept check blocks its caller for one helper launch, the main actor's included (`RequestRunner` opens identities
/// there).
public final class HelperPKCS12ImportProbe: PKCS12ImportProbe {
    /// Waits for the helper to exit; injected so a test can time a check out without waiting.
    public typealias ExitWait = @Sendable (DispatchSemaphore) -> DispatchTimeoutResult

    private enum Verdict {
        case opens
        case crashes
    }

    private let executable: URL?
    private let waitForExit: ExitWait
    /// Keyed by a digest, so neither the file nor its passphrase stays in memory.
    private let verdicts = Mutex<[SHA256.Digest: Verdict]>([:])

    /// `executable` is `nil` when the helper is missing, which fails every check rather than skipping it.
    public init(executable: URL?, waitForExit: @escaping ExitWait = { $0.wait(timeout: .now() + .seconds(10)) }) {
        self.executable = executable
        self.waitForExit = waitForExit
    }

    public func check(_ data: Data, passphrase: String) throws(TLSError) {
        let key = Self.digest(data, passphrase: passphrase)
        let verdict: Verdict
        if let kept = verdicts.withLock({ $0[key] }) {
            verdict = kept
        } else {
            verdict = try launch(data, passphrase: passphrase)
            verdicts.withLock { $0[key] = verdict }
        }
        if verdict == .crashes {
            throw .unsupportedCertificate
        }
    }

    private func launch(_ data: Data, passphrase: String) throws(TLSError) -> Verdict {
        guard let executable else {
            throw .certificateCheckFailed("Reqling's certificate checker is missing. Reinstall Reqling.")
        }
        let process = Process()
        process.executableURL = executable
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let writer = input.fileHandleForWriting
        // A helper that exits before reading everything must fail the write, not raise SIGPIPE in Reqling.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw .certificateCheckFailed(error.localizedDescription)
        }
        let message = Self.message(data, passphrase: passphrase)
        // Off this thread, so a helper that stops reading cannot hold the caller past the exit wait.
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: message)
            try? writer.close()
        }
        guard waitForExit(exited) == .success else {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw .certificateCheckFailed("The check did not finish in time.")
        }
        switch (process.terminationReason, process.terminationStatus) {
        case (.exit, EXIT_SUCCESS):
            return .opens
        // A crash the exception handler missed counts too, but not a kill from outside, which says nothing of the file.
        case (.exit, EX_DATAERR), (.uncaughtSignal, SIGABRT), (.uncaughtSignal, SIGSEGV), (.uncaughtSignal, SIGBUS),
             (.uncaughtSignal, SIGILL), (.uncaughtSignal, SIGTRAP):
            return .crashes
        case (.exit, let status):
            throw .certificateCheckFailed("The checker exited with status \(status).")
        case (_, let signal):
            throw .certificateCheckFailed("The checker was stopped by signal \(signal).")
        }
    }

    private static func message(_ data: Data, passphrase: String) -> Data {
        let passphraseBytes = Data(passphrase.utf8)
        var message = Data()
        withUnsafeBytes(of: UInt32(passphraseBytes.count).bigEndian) { message.append(contentsOf: $0) }
        message.append(passphraseBytes)
        message.append(data)
        return message
    }

    private static func digest(_ data: Data, passphrase: String) -> SHA256.Digest {
        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(data.count).bigEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        hasher.update(data: Data(passphrase.utf8))
        return hasher.finalize()
    }
}
