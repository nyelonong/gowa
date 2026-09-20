import Foundation

/// Minimal line diff (LCS) for comparing consecutive responses.
enum LineDiff {
    enum Line: Equatable, Sendable {
        case same(String)
        case added(String)
        case removed(String)
    }

    /// Returns nil when either side exceeds `maxLines` (too large to diff).
    static func diff(_ oldText: String, _ newText: String, maxLines: Int = 2000) -> [Line]? {
        var oldLines = oldText.isEmpty ? [] : oldText.components(separatedBy: "\n")
        var newLines = newText.isEmpty ? [] : newText.components(separatedBy: "\n")

        // Trim the common prefix/suffix first so the LCS table stays small.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix]
        {
            suffix += 1
        }
        let prefixLines: [Line] = oldLines.prefix(prefix).map { .same($0) }
        let suffixLines: [Line] = newLines.suffix(suffix).map { .same($0) }
        oldLines = Array(oldLines[prefix..<(oldLines.count - suffix)])
        newLines = Array(newLines[prefix..<(newLines.count - suffix)])

        if oldLines.count > maxLines || newLines.count > maxLines { return nil }

        var result: [Line] = prefixLines

        // LCS table.
        let rows = oldLines.count
        let columns = newLines.count
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if oldLines[row] == newLines[column] {
                    table[row][column] = table[row + 1][column + 1] + 1
                } else {
                    table[row][column] = max(table[row + 1][column], table[row][column + 1])
                }
            }
        }

        var row = 0
        var column = 0
        while row < rows, column < columns {
            if oldLines[row] == newLines[column] {
                result.append(.same(oldLines[row]))
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                result.append(.removed(oldLines[row]))
                row += 1
            } else {
                result.append(.added(newLines[column]))
                column += 1
            }
        }
        while row < rows {
            result.append(.removed(oldLines[row]))
            row += 1
        }
        while column < columns {
            result.append(.added(newLines[column]))
            column += 1
        }

        result.append(contentsOf: suffixLines)
        return result
    }
}
