import CryptoKit
import Foundation
import Synchronization

/// A loopback WebSocket server for app tests of an open connection: it accepts every handshake, echoes each message,
/// answers pings, and finishes a close handshake by closing its end. `ReqlingTests` has no SwiftNIO, so it speaks just
/// enough RFC 6455 over a POSIX socket: unfragmented frames, unmasked on the way out, as a server's must be.
final class WebSocketLoopbackServer: Sendable {
    let port: Int
    private let descriptor: Int32
    /// Accepted connections, closed on shutdown.
    private let clients = Mutex<[Int32]>([])

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, length) == 0 && listen(descriptor, 16) == 0 && getsockname(descriptor, address, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            serve()
        }
    }

    var url: String {
        "ws://127.0.0.1:\(port)/chat"
    }

    /// Stops accepting and drops every connection.
    func shutdown() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        for client in clients.withLock({ $0 }) {
            Darwin.shutdown(client, SHUT_RDWR)
            close(client)
        }
    }

    private func serve() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                return
            }
            clients.withLock { $0.append(client) }
            Thread.detachNewThread { [self] in
                converse(on: client)
            }
        }
    }

    private func converse(on client: Int32) {
        var connection = Connection(client: client)
        guard let head = connection.readHead(), let key = Self.header("Sec-WebSocket-Key", in: head) else {
            return
        }
        var hash = Insecure.SHA1()
        hash.update(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(hash.finalize()).base64EncodedString()
        let answer = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.write(Array(answer.utf8))
        while let (opcode, payload) = connection.readFrame() {
            switch opcode {
            case 0x1, 0x2:
                connection.write(Self.frame(opcode, payload))
            case 0x9:
                connection.write(Self.frame(0xA, payload))
            case 0x8:
                connection.write(Self.frame(0x8, payload))
                Darwin.shutdown(client, SHUT_RDWR)
                return
            default:
                break
            }
        }
    }

    private static func header(_ name: String, in head: String) -> String? {
        head.components(separatedBy: "\r\n").lazy.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else {
                return nil
            }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
    }

    /// A final, unmasked frame; payloads here stay under 64 KiB.
    private static func frame(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            bytes.append(UInt8(payload.count))
        } else {
            bytes += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        return bytes + payload
    }

    /// One connection's bytes, read as they arrive.
    private struct Connection {
        let client: Int32
        var pending: [UInt8] = []

        mutating func readHead() -> String? {
            while pending.firstRange(of: Array("\r\n\r\n".utf8)) == nil {
                guard fill() else {
                    return nil
                }
            }
            let end = pending.firstRange(of: Array("\r\n\r\n".utf8))!.upperBound
            defer { pending.removeFirst(end) }
            return String(bytes: pending[..<end], encoding: .utf8)
        }

        /// A client frame's opcode and unmasked payload, or `nil` once the connection ends.
        mutating func readFrame() -> (UInt8, [UInt8])? {
            guard let header = take(2) else {
                return nil
            }
            var length = Int(header[1] & 0x7F)
            if length == 126 {
                guard let extended = take(2) else {
                    return nil
                }
                length = Int(extended[0]) << 8 | Int(extended[1])
            } else if length == 127 {
                guard let extended = take(8) else {
                    return nil
                }
                length = extended.reduce(0) { $0 << 8 | Int($1) }
            }
            guard let mask = header[1] & 0x80 != 0 ? take(4) : [0, 0, 0, 0], let masked = take(length) else {
                return nil
            }
            let payload = masked.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            return (header[0] & 0x0F, payload)
        }

        func write(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        }

        private mutating func take(_ count: Int) -> [UInt8]? {
            while pending.count < count {
                guard fill() else {
                    return nil
                }
            }
            defer { pending.removeFirst(count) }
            return Array(pending.prefix(count))
        }

        private mutating func fill() -> Bool {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else {
                return false
            }
            pending += buffer[..<count]
            return true
        }
    }
}
