import Foundation

/// How the app and the helper delimit messages in both directions: a big-endian `UInt32` length, then that many bytes.
/// Not one JSON object per line: line readers split on U+2028 and U+2029, which `JSONEncoder` leaves unescaped and a
/// `console.log` can hold, and bodies travel as raw bytes.
public enum ScriptFraming {
    /// Bigger frames are refused as corrupt rather than buffered.
    public static let maximumFrameLength = 512 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Every frame in `data`, or `nil` when it ends partway through one or a length is out of bounds.
    public static func frames(in data: Data) -> [Data]? {
        var reader = Reader()
        guard let frames = reader.append(data), !reader.hasPartialFrame else {
            return nil
        }
        return frames
    }

    /// Splits a byte stream into frames as it arrives.
    public struct Reader: Sendable {
        private var buffer = Data()

        public init() {}

        /// Whether bytes of an unfinished frame are waiting.
        public var hasPartialFrame: Bool {
            !buffer.isEmpty
        }

        /// The frames `data` completes, or `nil` once a length is out of bounds, after which the stream is unusable.
        public mutating func append(_ data: Data) -> [Data]? {
            buffer.append(data)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = buffer[start..<start + 4].reduce(0) { Int($0) << 8 | Int($1) }
                guard length <= ScriptFraming.maximumFrameLength else {
                    return nil
                }
                guard buffer.count >= 4 + length else {
                    break
                }
                frames.append(Data(buffer[start + 4..<start + 4 + length]))
                buffer.removeSubrange(start..<start + 4 + length)
            }
            return frames
        }
    }
}
