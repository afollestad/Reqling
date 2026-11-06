/// The helper's exit statuses, from `sysexits.h`. Both sides read these constants, so they can't drift apart. A kill
/// by signal is the app's own doing (a time limit or a cancel); any other signal is a crash.
public enum ScriptRunnerExit {
    /// Every level ran and `ScriptRunnerEvent.done` was written.
    public static let success: Int32 = 0
    /// The input couldn't be read, or names another protocol version (`EX_USAGE`).
    public static let badInput: Int32 = 64
    /// The runtime folder, or a file in it, couldn't be read (`EX_NOINPUT`).
    public static let missingRuntime: Int32 = 66
    /// JavaScriptCore couldn't make a context (`EX_SOFTWARE`).
    public static let noContext: Int32 = 70
}
