import Foundation

/// Where each line of a text starts, in UTF-16 offsets, kept up to date edit
/// by edit so that finding the line of a position never scans the text.
///
/// Lines are separated by `\n` only: the editor turns every other line break
/// into `\n` when a file is read and when text is pasted.
struct LineIndex: Equatable {
    /// Offset of the first character of each line; never empty.
    private(set) var starts: [Int] = [0]
    /// Length of the whole text.
    private(set) var length = 0

    init() {}

    init(_ text: NSString) {
        length = text.length
        starts = [0] + Self.lineBreaks(in: text, range: NSRange(location: 0, length: text.length)).map { $0 + 1 }
    }

    var lineCount: Int { starts.count }

    /// Brings the index up to date after `text` changed: `editedRange` is the
    /// range of the new characters in `text`, which replaced `editedRange.length
    /// - changeInLength` characters.
    ///
    /// - Returns: the lines that were removed (0-based, in the old index) and how
    ///   many lines replace them, for keeping per-line state in step.
    @discardableResult
    mutating func update(in text: NSString, editedRange: NSRange, changeInLength: Int) -> (removed: Range<Int>, inserted: Int) {
        let location = editedRange.location
        let oldEnd = location + editedRange.length - changeInLength
        // A line starts after each line break; those of the replaced text go.
        let first = firstIndex(after: location)
        let last = firstIndex(after: oldEnd)
        let breaks = Self.lineBreaks(in: text, range: editedRange).map { $0 + 1 }
        starts.replaceSubrange(first..<last, with: breaks)
        if changeInLength != 0 {
            for index in (first + breaks.count)..<starts.count {
                starts[index] += changeInLength
            }
        }
        length = text.length
        return (first..<last, breaks.count)
    }

    /// Index of the line holding `offset` (0-based). An offset at the end of a
    /// line, before its `\n`, belongs to that line.
    func line(at offset: Int) -> Int {
        // Last start that is not after the offset.
        firstIndex(after: offset) - 1
    }

    /// Range of a line (0-based), without its line break.
    func range(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: end - start)
    }

    /// Range of a line (0-based), with its line break.
    func rangeWithBreak(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Index of the first start greater than `offset`.
    private func firstIndex(after offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Offsets of the `\n` characters in a range of the text.
    static func lineBreaks(in text: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = range.location
        let end = range.location + range.length
        while location < end {
            let count = min(chunk, end - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for index in 0..<count where buffer[index] == 10 {
                result.append(location + index)
            }
            location += count
        }
        return result
    }
}
