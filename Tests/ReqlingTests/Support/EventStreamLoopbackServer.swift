import Foundation
import Synchronization

/// A loopback server that answers every request with an event stream's head and one event, then holds the connection
/// open until it shuts down, for app tests of an open stream. `ReqlingTests` has no SwiftNIO, so it speaks just enough
/// HTTP/1.1 over a POSIX socket: a body without a length, which ends when the connection does.
final class EventStreamLoopbackServer: Sendable {
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
        "http://127.0.0.1:\(port)/events"
    }

    /// Stops accepting and drops every connection; a stream still open sees its connection end.
    func shutdown() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        for client in clients.withLock({ $0 }) {
            close(client)
        }
    }

    /// Accepts until shut down, answering each connection once its request head has arrived.
    private func serve() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                return
            }
            clients.withLock { $0.append(client) }
            var request: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while request.firstRange(of: Array("\r\n\r\n".utf8)) == nil {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else {
                    break
                }
                request += buffer[..<count]
            }
            let response = Array("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\ndata: hello\n\n".utf8)
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }
}
