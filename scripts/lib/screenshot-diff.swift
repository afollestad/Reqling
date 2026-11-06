// Used by screenshots.sh, compiled once with `xcrun swiftc`, as `screenshot-diff <a.png> <b.png>`. Prints "same" when
// the two captures match pixel for pixel, "resized" when their sizes differ, and otherwise "<x> <y> <width> <height>",
// the box around every pixel that differs, so the script can tell an indicator spinning in one spot from a window
// still settling.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

/// Draws the image into 8-bit RGBA, so both captures compare in one pixel format whatever the PNGs hold.
func pixels(at path: String) -> (width: Int, height: Int, data: [UInt32]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("couldn't read \(path)")
    }
    let (width, height) = (image.width, image.height)
    var data = [UInt32](repeating: 0, count: width * height)
    let drawn = data.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else {
        fail("couldn't draw \(path)")
    }
    return (width, height, data)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: screenshot-diff <a.png> <b.png>")
}
let first = pixels(at: CommandLine.arguments[1])
let second = pixels(at: CommandLine.arguments[2])
guard first.width == second.width, first.height == second.height else {
    print("resized")
    exit(0)
}
var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
for row in 0..<first.height {
    let start = row * first.width
    for column in 0..<first.width where first.data[start + column] != second.data[start + column] {
        (minX, minY) = (min(minX, column), min(minY, row))
        (maxX, maxY) = (max(maxX, column), max(maxY, row))
    }
}
if maxX < 0 {
    print("same")
} else {
    print(minX, minY, maxX - minX + 1, maxY - minY + 1)
}
