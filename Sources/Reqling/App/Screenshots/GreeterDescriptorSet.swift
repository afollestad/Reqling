#if DEBUG
import Foundation

/// The greeter schema behind screenshot mode's gRPC requests and the app tests' (`GRPCFixtures`). Kept as hex rather
/// than a resource so neither the app bundle nor the test target needs one;
/// `protoc --descriptor_set_out=greeter.binpb acme/greeter/v1/greeter.proto` compiled it from:
///
/// ```proto
/// syntax = "proto3";
/// package acme.greeter.v1;
/// enum Mood { MOOD_UNSPECIFIED = 0; MOOD_CHEERFUL = 1; }
/// message HelloRequest { string name = 1; Mood mood = 2; repeated string tags = 3; }
/// message HelloReply { string message = 1; int32 count = 2; }
/// service Greeter {
///   rpc SayHello(HelloRequest) returns (HelloReply);
///   rpc ListGreetings(HelloRequest) returns (stream HelloReply);
///   rpc CollectNames(stream HelloRequest) returns (HelloReply);
///   rpc Chat(stream HelloRequest) returns (stream HelloReply);
/// }
/// ```
enum GreeterDescriptorSet {
    static let service = "acme.greeter.v1.Greeter"
    static let fileName = "greeter.binpb"

    static var data: Data {
        let hex = """
        0ac3040a1d61636d652f677265657465722f76312f677265657465722e70726f746f120f61636d652e677265657465722e763122610a0c48656c6c6f5265717565737412
        120a046e616d6518012001280952046e616d6512290a046d6f6f6418022001280e32152e61636d652e677265657465722e76312e4d6f6f6452046d6f6f6412120a047461
        6773180320032809520474616773223c0a0a48656c6c6f5265706c7912180a076d65737361676518012001280952076d65737361676512140a05636f756e741802200128
        055205636f756e742a2f0a044d6f6f6412140a104d4f4f445f554e535045434946494544100012110a0d4d4f4f445f434845455246554c100132b6020a07477265657465
        7212460a0853617948656c6c6f121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e61636d652e677265657465722e76312e48656c6c6f
        5265706c79124d0a0d4c6973744772656574696e6773121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e61636d652e67726565746572
        2e76312e48656c6c6f5265706c793001124c0a0c436f6c6c6563744e616d6573121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e6163
        6d652e677265657465722e76312e48656c6c6f5265706c79280112460a0443686174121d2e61636d652e677265657465722e76312e48656c6c6f526571756573741a1b2e
        61636d652e677265657465722e76312e48656c6c6f5265706c7928013001620670726f746f33
        """
        let digits = Array(hex.filter(\.isHexDigit))
        return Data(stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) })
    }
}
#endif
