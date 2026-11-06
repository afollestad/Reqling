import Foundation

extension String {
    /// The longest prefix within `utf8Count` bytes that ends on a Unicode scalar boundary, for cutting text to fit the
    /// run history without splitting a character's bytes.
    func prefix(utf8Count: Int) -> String {
        let utf8 = self.utf8
        guard utf8.count > utf8Count else {
            return self
        }
        var end = utf8.index(utf8.startIndex, offsetBy: utf8Count)
        while end > utf8.startIndex, end.samePosition(in: unicodeScalars) == nil {
            end = utf8.index(before: end)
        }
        return String(unicodeScalars[..<end])
    }
}
