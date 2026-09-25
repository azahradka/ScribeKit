import Foundation

/// Turns timed words and speaker turns into readable segments. Pure logic, no models,
/// so it can be tested and reused with any ASR or diarizer.
public enum SegmentBuilder {
    /// A span of time attributed to one speaker, as produced by a diarizer.
    public struct Turn: Sendable, Hashable {
        public var speakerID: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
            self.speakerID = speakerID
            self.start = start
            self.end = end
        }
    }

    /// A new segment starts after a pause this long, even when the speaker stays the same.
    public static let PARAGRAPH_PAUSE: TimeInterval = 2.0
    /// Segments are split at the next sentence end once they are this long.
    public static let MAX_SEGMENT_SECONDS: TimeInterval = 45

    /// Assigns each word the speaker whose turn overlaps it most (or the nearest turn when
    /// none overlaps), then groups consecutive words into segments.
    public static func segments(words: [Word], turns: [Turn]) -> [Segment] {
        let sortedTurns = turns.sorted { $0.start < $1.start }
        let attributed = words.map { word in (word, speaker(for: word, in: sortedTurns)) }
        return group(attributed)
    }

    /// Groups words that already carry a speaker (or none).
    public static func group(_ words: [(Word, String?)]) -> [Segment] {
        var segments: [Segment] = []
        var current: [Word] = []
        var currentSpeaker: String?

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(Segment(speakerID: currentSpeaker, start: first.start, end: last.end,
                                    text: join(current), words: current))
            current = []
        }

        for (word, speaker) in words {
            if let last = current.last {
                let pause = word.start - last.end
                let length = word.end - (current.first?.start ?? word.start)
                let endsSentence = last.text.last.map { ".?!…".contains($0) } ?? false
                if speaker != currentSpeaker || pause >= PARAGRAPH_PAUSE
                    || (length >= MAX_SEGMENT_SECONDS && endsSentence) {
                    flush()
                }
            }
            if current.isEmpty { currentSpeaker = speaker }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Joins words, keeping punctuation tight to the word before it.
    public static func join(_ words: [Word]) -> String {
        var text = ""
        for word in words {
            let token = word.text
            if text.isEmpty {
                text = token
            } else if let first = token.first, ",.;:!?…%)]}".contains(first) {
                text += token
            } else {
                text += " " + token
            }
        }
        return text
    }

    static func speaker(for word: Word, in turns: [Turn]) -> String? {
        guard !turns.isEmpty else { return nil }
        var best: (id: String, overlap: TimeInterval)?
        var nearest: (id: String, distance: TimeInterval)?
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speakerID, overlap) }
            let distance = overlap > 0 ? 0 : min(abs(word.start - turn.end), abs(turn.start - word.end))
            if distance < (nearest?.distance ?? .infinity) { nearest = (turn.speakerID, distance) }
            if turn.start > word.end + 30 { break }
        }
        return best?.id ?? nearest?.id
    }

    /// Merges segments from several tracks (for example microphone and system audio)
    /// into one conversation ordered by time.
    public static func interleave(_ tracks: [[Segment]]) -> [Segment] {
        tracks.flatMap { $0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Removes microphone words that are only the other side heard through the speakers:
    /// a microphone word is dropped when the system track has the same word within `window` seconds.
    /// Harmless with headphones, where there is no bleed to remove.
    public static func removeEcho(microphone: [Word], system: [Word], window: TimeInterval = 0.6) -> [Word] {
        guard !system.isEmpty else { return microphone }
        let reference = system.map { (normalize($0.text), $0.start) }.sorted { $0.1 < $1.1 }
        var kept: [Word] = []
        var runStart: Int?
        var candidates: [Int] = []

        for (index, word) in microphone.enumerated() {
            let key = normalize(word.text)
            let echoed = !key.isEmpty && reference.contains { $0.0 == key && abs($0.1 - word.start) <= window }
            if echoed {
                if runStart == nil { runStart = index }
                candidates.append(index)
            } else {
                // Keep isolated matches: a lone shared word ("yes", "okay") is likely real speech.
                if candidates.count < 2 { kept.append(contentsOf: candidates.map { microphone[$0] }) }
                candidates = []
                runStart = nil
                kept.append(word)
            }
        }
        if candidates.count < 2 { kept.append(contentsOf: candidates.map { microphone[$0] }) }
        return kept.sorted { $0.start < $1.start }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
