/// How a level's script is wrapped to run: in an async function, so top-level `await` and `return` work as in Postman.
/// The prefix sits on the script's first line, so line numbers stay the script's own and only line 1's columns shift
/// by its length. The runner evaluates scripts wrapped this way, and `ScriptSyntaxChecker` parses them the same way, so
/// both read a script alike.
public enum ScriptWrapper {
    public static let prefix = "__rq.runLevel(async function () {"
    public static let suffix = "\n})"

    public static func wrap(_ source: String) -> String {
        prefix + source + suffix
    }

    /// A column in the wrapped text as the script's own, on line 1 where the prefix sits.
    public static func column(_ column: Int, line: Int) -> Int {
        line == 1 ? max(1, column - prefix.count) : column
    }
}
