import AppKit

/// What a sidebar drag reads from outside the app: the clock it pauses on, and the hardware state its watch polls.
/// Injected, so a test drives a drag with synthesized events without the real mouse button, which is up, ending it.
struct SidebarDragSystem: Sendable {
    var sleep: @Sendable (Duration) async throws -> Void
    var isEscapePressed: @MainActor @Sendable () -> Bool
    var isPointerDown: @MainActor @Sendable () -> Bool

    static let live = SidebarDragSystem(
        sleep: { try await Task.sleep(for: $0) },
        isEscapePressed: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(SidebarDragKeyCode.escape)) },
        isPointerDown: { CGEventSource.buttonState(.combinedSessionState, button: .left) }
    )
}

enum SidebarDragKeyCode {
    static let escape: UInt16 = 53
    /// Keys a drag swallows, which would otherwise rename, delete, or move the selection underneath it.
    static let suppressedDuringDrag: Set<UInt16> = [
        36, // Return
        51, // Delete
        76, // Keypad Enter
        117, // Forward Delete
        123, // Left Arrow
        124, // Right Arrow
        125, // Down Arrow
        126 // Up Arrow
    ]
}
