import Foundation

/// Bounds the live view tree while full transcripts remain available to editing, export and minutes.
struct TranscriptDisplayWindow {
    static let pageSize = 60
    private(set) var count = pageSize

    func hiddenCount(total: Int) -> Int { max(0, total - count) }
    mutating func showEarlier() { count += Self.pageSize }
    mutating func reset() { count = Self.pageSize }

    /// New speech preserves the reading position while the user browses earlier cards.
    mutating func didGrow(from oldCount: Int, to newCount: Int, following: Bool) {
        if !following { count += max(0, newCount - oldCount) }
    }
}
