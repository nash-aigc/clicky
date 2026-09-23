import Foundation

/// Detects when the recognized speech newly mentions the screen, for the
/// 「说到“屏幕”立即截屏」 setting.
///
/// Streaming transcription resends the whole cumulative utterance on every
/// interim update, so a plain `contains("屏幕")` would fire on every single
/// interim frame for one mention. The detector instead counts occurrences and
/// only reports an edge — the count going UP — so each spoken 屏幕 fires the
/// capture exactly once, and a second 屏幕 later in the sentence fires again
/// (every detection takes one screenshot, per the setting's contract).
struct BuddyScreenKeywordDetector {
    /// Counted in the transcript of the current utterance so far.
    private var mentionCount = 0

    /// Returns true exactly when `cumulativeTranscript` contains more mentions
    /// of a keyword than the last call saw. Keywords cover the spoken word
    /// 屏幕 and its English equivalent; case-insensitive for the Latin one.
    mutating func detectNewMention(in cumulativeTranscript: String) -> Bool {
        let lowered = cumulativeTranscript.lowercased()
        var count = 0
        for keyword in Self.keywords {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let foundRange = lowered.range(of: keyword, range: searchRange) {
                count += 1
                searchRange = foundRange.upperBound..<lowered.endIndex
            }
        }
        let hasNewMention = count > mentionCount
        mentionCount = count
        return hasNewMention
    }

    /// Called when a new utterance (or a new dictation session) begins, so the
    /// count restarts from zero.
    mutating func reset() {
        mentionCount = 0
    }

    private static let keywords = ["屏幕", "screen"]
}
