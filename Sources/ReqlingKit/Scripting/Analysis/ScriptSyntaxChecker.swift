import Foundation
import JavaScriptCore
import ReqlingScriptProtocol
import Synchronization

/// A script's syntax error, where the runner would report it.
public struct ScriptSyntaxError: Hashable, Sendable {
    public let message: String
    /// The line's text, from its first character that isn't a space, in the script's own UTF-16 offsets: JavaScriptCore
    /// names a syntax error's line but not its column.
    public let range: NSRange
    public let line: Int
}

/// Finds a script's syntax error as the runner would meet it, by parsing it inside `ScriptWrapper`, so top-level
/// `await` and `return` parse as they run. It only parses: `JSCheckScriptSyntax` never evaluates, so this is the one
/// JavaScriptCore use in this process (scripts run in the helper, which a time limit can kill). One context, behind a
/// lock, serves every check; call it off the main actor.
public final class ScriptSyntaxChecker: Sendable {
    public static let shared = ScriptSyntaxChecker()

    private let context = Mutex(JSContext())

    public func error(in source: String) -> ScriptSyntaxError? {
        context.withLock { context -> ScriptSyntaxError? in
            guard let context else {
                return nil
            }
            let script = JSStringCreateWithCFString(ScriptWrapper.wrap(source) as CFString)
            defer { JSStringRelease(script) }
            var exception: JSValueRef?
            guard !JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception), let exception,
                  let value = JSValue(jsValueRef: exception, in: context) else {
                return nil
            }
            let line = Int(value.forProperty("line")?.toInt32() ?? 1)
            return ScriptSyntaxError(message: value.toString() ?? "SyntaxError", range: Self.range(line: line, in: source as NSString), line: line)
        }
    }

    /// Line `line`'s text (from 1), without its indentation or line break; past the script's end, its last character,
    /// where an unclosed bracket or string is noticed.
    static func range(line: Int, in text: NSString) -> NSRange {
        var lineStart = 0
        var current = 1
        while current < line, lineStart < text.length {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: lineStart, length: text.length - lineStart))
            guard newline.location != NSNotFound else {
                lineStart = text.length
                break
            }
            lineStart = NSMaxRange(newline)
            current += 1
        }
        guard current == line, lineStart < text.length else {
            return NSRange(location: max(0, text.length - 1), length: text.length == 0 ? 0 : 1)
        }
        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let contentEnd = NSMaxRange(lineRange) - (text.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
        var start = lineStart
        while start < contentEnd - 1, [" ", "\t"].contains(text.substring(with: NSRange(location: start, length: 1))) {
            start += 1
        }
        return NSRange(location: start, length: max(1, contentEnd - start))
    }
}
