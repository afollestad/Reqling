import Foundation
@testable import ReqlingKit
import XCTest

extension SyntaxTokenizerTests {
    /// The lexer replaced the regex JSON rules; on valid JSON it must color exactly as they did.
    func testTheJSONLexerColorsAsTheRegexRulesDid() throws {
        let corpus = [
            #"{"a": 1, "b": [true, false, null], "c": {"d": -2.5e+10}, "e": "x: \"y\" [z]"}"#,
            "{\n  \"key\" :\n    \"value\",\n  \"n\": 0\n}",
            #"[{"café": "日本語 — 🙂"}, "\\", "é", 12, -0.5]"#,
            #"{"empty": "", "nested": {"": []}}"#
        ]
        for json in corpus {
            XCTAssertEqual(JSONLexer.tokens(in: json), try regexTokens(json), json)
        }
    }

    func testJSONOverTheRegexLimitStillColors() {
        let json = "[" + String(repeating: "1,", count: SyntaxTokenizer.maximumLength / 2) + "1]"
        XCTAssertFalse(SyntaxTokenizer.tokens(in: json, language: .json).isEmpty)
    }

    /// Lexing can start anywhere given the state there: a string split across two ranges colors the same.
    func testTheJSONLexerResumesInsideAString() {
        let json = Array(#"{"long key": "va\"lue"}"#.utf8)
        json.withUnsafeBufferPointer { bytes in
            let whole = JSONLexer.tokens(in: bytes, range: 0..<bytes.count, from: .start)
            for split in 1..<bytes.count {
                let state = JSONLexer.state(after: 0..<split, in: bytes, from: .start)
                let parts = JSONLexer.tokens(in: bytes, range: 0..<split, from: .start)
                    + JSONLexer.tokens(in: bytes, range: split..<bytes.count, from: state)
                XCTAssertEqual(Self.merged(parts), whole, "split at \(split)")
            }
        }
    }

    /// The regex rules, as `CompiledSpec` still holds them for JSON.
    private func regexTokens(_ json: String) throws -> [SyntaxToken] {
        let spec = try XCTUnwrap(CompiledSpec.specs[.json])
        let source = json as NSString
        let range = NSRange(location: 0, length: source.length)
        var tokens: [SyntaxToken] = []
        var colored = IndexSet()
        var cursor = 0
        while cursor < source.length {
            let matches = spec.protected.compactMap { rule -> (NSRange, SyntaxRole)? in
                let found = rule.regex.rangeOfFirstMatch(in: json, range: NSRange(location: cursor, length: source.length - cursor))
                return found.location == NSNotFound ? nil : (found, rule.role)
            }
            let best = matches.min { lhs, rhs in
                lhs.0.location < rhs.0.location || (lhs.0.location == rhs.0.location && lhs.0.length > rhs.0.length)
            }
            guard let best else {
                break
            }
            tokens.append(SyntaxToken(range: best.0, role: best.1))
            colored.insert(integersIn: Range(best.0)!)
            cursor = NSMaxRange(best.0)
        }
        for rule in spec.unprotected {
            for match in rule.regex.matches(in: json, range: range) where !colored.intersects(integersIn: Range(match.range)!) {
                colored.insert(integersIn: Range(match.range)!)
                tokens.append(SyntaxToken(range: match.range, role: rule.role))
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    /// Joins tokens a split cut in two, so split and whole lexing compare equal.
    private static func merged(_ tokens: [ByteToken]) -> [ByteToken] {
        var result: [ByteToken] = []
        for token in tokens {
            if let last = result.last, last.range.upperBound == token.range.lowerBound, last.role == token.role,
               token.role == .string || token.role == .property || token.role == .number || token.role == .keyword {
                result[result.count - 1] = ByteToken(range: last.range.lowerBound..<token.range.upperBound, role: token.role)
            } else {
                result.append(token)
            }
        }
        return result
    }
}
