import Foundation
import ReqlingKit

extension ListRow {
    /// The row under one fixed ID, so a row the code under test built compares with one a test wrote by content alone.
    var unidentified: Self {
        var row = self
        row.id = ID(UUID(uuid: UUID_NULL))
        return row
    }
}

extension Sequence where Element: ListRow {
    var unidentified: [Element] {
        map(\.unidentified)
    }
}

extension Sequence<KeyValuePair> {
    /// Whether an enabled row holds `key` and `value`, whatever its ID.
    func contains(key: String, value: String) -> Bool {
        contains { $0.key == key && $0.value == value && $0.isEnabled }
    }
}
