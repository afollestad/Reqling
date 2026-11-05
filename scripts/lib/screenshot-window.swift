// Used by screenshots.sh, compiled once with `xcrun swiftc`, as `screenshot-window <pid>`. Prints
// "<id> <width>" for the process's main window, its largest normal-layer window on screen, with the width in points;
// exits 1 while there is none. It only reads the window list.

import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fail("usage: screenshot-window <pid>")
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let frames = windows.compactMap { window -> (Int, CGRect)? in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds) else {
        return nil
    }
    return (id, frame)
}
guard let (id, frame) = frames.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
    exit(1)
}
print(id, Int(frame.width))
