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
