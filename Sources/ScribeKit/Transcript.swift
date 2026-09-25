import Foundation

/// A word with its position in the audio.
public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Who said something. `id` is stable within one transcript; `name` is what readers see
/// and can be renamed freely.
public struct Speaker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// True for the person recording (their microphone track).
    public var isLocal: Bool

    public init(id: String, name: String, isLocal: Bool = false) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
    }
}

/// A run of words by one speaker.
public struct Segment: Codable, Hashable, Sendable {
    public var speakerID: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [Word]

    public init(speakerID: String?, start: TimeInterval, end: TimeInterval, text: String, words: [Word] = []) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// The result of a transcription: speaker-attributed segments plus metadata.
public struct Transcript: Codable, Hashable, Sendable {
    public var segments: [Segment]
    public var speakers: [Speaker]
    public var language: String?
    public var duration: TimeInterval

    public init(segments: [Segment], speakers: [Speaker] = [], language: String? = nil, duration: TimeInterval) {
        self.segments = segments
        self.speakers = speakers
        self.language = language
        self.duration = duration
    }

    /// The whole transcript as plain text, without speakers or times.
    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    public var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    public func speaker(for id: String?) -> Speaker? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }
    }

    /// Renames a speaker everywhere.
    public mutating func rename(speaker id: String, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name
    }
}
