import Foundation

/// Approximate matching for the quick open palette: the letters of the
/// query must appear in order in the relative path; starts of words, letters
/// in the file name and runs of consecutive letters score higher.
enum FuzzyMatcher {
    struct Match: Equatable {
        let score: Int
        /// Offsets, in characters of the path, of the letters that matched.
        let positions: [Int]
    }

    /// Matches `query` against a relative path such as « docs/stations.md »;
    /// `nil` when the letters do not all appear in order. Spaces in the query
    /// are ignored; case and accents too.
    static func match(_ query: String, in path: String) -> Match? {
        let needle = Array(fold(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }
        let original = Array(path)
        let haystack = original.map { fold(String($0)).first ?? $0 }
        let n = needle.count, m = haystack.count
        guard n <= m else { return nil }
        let nameStart = (original.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        // Score of matching a letter at each position, before the run bonus.
        let base: [Int] = (0..<m).map { j in
            var score = 1
            if isWordStart(original, j) { score += 10 }
            if j >= nameStart { score += 4 }
            if j == nameStart { score += 6 }
            return score
        }

        // best[i][j]: best score with needle[i] matched at j; from[i][j]: where needle[i-1] was.
        let unset = Int.min / 2
        var best = Array(repeating: Array(repeating: unset, count: m), count: n)
        var from = Array(repeating: Array(repeating: -1, count: m), count: n)
        for j in 0..<m where haystack[j] == needle[0] {
            best[0][j] = base[j]
        }
        for i in 1..<n {
            // Running best of row i-1 over positions before j-1.
            var runningBest = unset
            var runningIndex = -1
            for j in i..<m {
                if j - 2 >= 0, best[i - 1][j - 2] > runningBest {
                    runningBest = best[i - 1][j - 2]
                    runningIndex = j - 2
                }
                guard haystack[j] == needle[i] else { continue }
                var candidate = runningBest
                var source = runningIndex
                let adjacent = best[i - 1][j - 1]
                if adjacent > unset, adjacent + Self.runBonus >= candidate {
                    candidate = adjacent + Self.runBonus
                    source = j - 1
                }
                guard candidate > unset else { continue }
                best[i][j] = candidate + base[j]
                from[i][j] = source
            }
        }
        guard let end = (0..<m).max(by: { best[n - 1][$0] < best[n - 1][$1] }), best[n - 1][end] > unset else { return nil }
        var positions = [end]
        var i = n - 1, j = end
        while i > 0 {
            j = from[i][j]
            i -= 1
            positions.append(j)
        }
        // Shorter paths win ties.
        let score = best[n - 1][end] * 4 - m / 8
        return Match(score: score, positions: positions.reversed())
    }

    /// Bonus of a letter that follows the previous match: a run is worth as
    /// much as a start of word.
    private static let runBonus = 12

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if "/-_. ".contains(previous) { return true }
        return previous.isLowercase && characters[index].isUppercase
    }

    /// One entry of the palette, ranked.
    struct Result: Equatable {
        let path: String
        let positions: [Int]
    }

    /// Ranks `paths` for `query`: with an empty query, the recent files first
    /// (most recent first), then the others in path order; otherwise by score,
    /// a recent file winning a tie, then the shorter path.
    static func rank(_ paths: [String], query: String, recents: [String]) -> [Result] {
        let recentRank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recent = recents.filter { recentRank[$0] != nil && paths.contains($0) }
            let others = paths.filter { recentRank[$0] == nil }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return (recent + others).map { Result(path: $0, positions: []) }
        }
        let scored = paths.compactMap { path in match(trimmed, in: path).map { (path, $0) } }
        return scored.sorted { a, b in
            if a.1.score != b.1.score { return a.1.score > b.1.score }
            let ra = recentRank[a.0] ?? .max, rb = recentRank[b.0] ?? .max
            if ra != rb { return ra < rb }
            if a.0.count != b.0.count { return a.0.count < b.0.count }
            return a.0 < b.0
        }.map { Result(path: $0.0, positions: $0.1.positions) }
    }
}
