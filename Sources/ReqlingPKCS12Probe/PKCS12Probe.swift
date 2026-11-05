import Foundation
import Security

/// Opens one PKCS#12 file with `SecPKCS12Import` in this throwaway process, so Reqling learns whether opening it in its
/// own process is safe. Apple's importer raises an Objective-C exception, which Swift cannot catch, on some files (a
/// certificate whose EC key uses explicit curve parameters); here that ends only this process.
///
/// Standard input is the passphrase's UTF-8 byte count as a big-endian `UInt32`, the passphrase, then the file; nothing
/// travels in arguments or the environment, which other processes can read. The exit status is the verdict that
/// `HelperPKCS12ImportProbe` reads:
/// - `0`: the importer returned, whatever its status, so the app may import the file itself.
/// - `EX_DATAERR` (65): the importer raised an exception.
/// - `EX_USAGE` (64): standard input was malformed.
@main
enum PKCS12Probe {
    static func main() {
        // Exiting from the handler skips the abort, so the expected failure leaves no crash report behind.
        NSSetUncaughtExceptionHandler { _ in _exit(EX_DATAERR) }
        guard let input = try? FileHandle.standardInput.readToEnd(), let (passphrase, file) = parse(input) else {
            exit(EX_USAGE)
        }
        // In memory only, exactly as `PKCS12Importer` imports, so this never touches a keychain.
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true
        ]
        var items: CFArray?
        _ = SecPKCS12Import(file as CFData, options as CFDictionary, &items)
        exit(EXIT_SUCCESS)
    }

    private static func parse(_ input: Data) -> (passphrase: String, file: Data)? {
        let bytes = [UInt8](input)
        guard bytes.count >= 4 else {
            return nil
        }
        let length = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        guard bytes.count >= 4 + length, let passphrase = String(bytes: bytes[4..<4 + length], encoding: .utf8) else {
            return nil
        }
        return (passphrase, Data(bytes[(4 + length)...]))
    }
}
