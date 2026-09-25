import Foundation

/// Output formats for a transcript.
public enum TranscriptFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case markdown = "md"
    case text = "txt"
    case srt
    case vtt
    case json

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .text: return "Plain text"
        case .srt: return "SubRip subtitles (SRT)"
        case .vtt: return "WebVTT subtitles"
        case .json: return "JSON"
        }
    }
}

/// Renders transcripts. Markdown gets YAML front matter from `metadata`, so notes
/// work in Obsidian, Logseq, Bear and friends; the other formats are standard.
public enum TranscriptRenderer {
    public struct MarkdownOptions: Sendable, Equatable {
        public var title: String?
        /// Front matter fields in order; values are written as YAML strings.
        public var metadata: [(String, String)]
        public var includeTimestamps: Bool
        /// Text placed after the front matter and title, before the transcript (for example an audio embed).
        public var preamble: String?

        public init(title: String? = nil, metadata: [(String, String)] = [], includeTimestamps: Bool = true,
                    preamble: String? = nil) {
            self.title = title
            self.metadata = metadata
            self.includeTimestamps = includeTimestamps
            self.preamble = preamble
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title && lhs.includeTimestamps == rhs.includeTimestamps && lhs.preamble == rhs.preamble
                && lhs.metadata.map { "\($0.0)=\($0.1)" } == rhs.metadata.map { "\($0.0)=\($0.1)" }
        }
    }

    public static func render(_ transcript: Transcript, as format: TranscriptFormat,
                              markdown: MarkdownOptions = .init()) throws -> String {
        switch format {
        case .markdown: return self.markdown(transcript, options: markdown)
        case .text: return text(transcript)
        case .srt: return subtitles(transcript, vtt: false)
        case .vtt: return subtitles(transcript, vtt: true)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(transcript), as: UTF8.self)
        }
    }

    // MARK: Markdown

    public static func markdown(_ transcript: Transcript, options: MarkdownOptions = .init()) -> String {
        var lines: [String] = []
        if !options.metadata.isEmpty {
            lines.append("---")
            for (key, value) in options.metadata { lines.append("\(key): \(yamlString(value))") }
            lines.append("---")
            lines.append("")
        }
        if let title = options.title, !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }
        if let preamble = options.preamble, !preamble.isEmpty {
            lines.append(preamble)
            lines.append("")
        }
        for segment in transcript.segments {
            var prefix = ""
            if options.includeTimestamps { prefix += "[\(clock(segment.start))] " }
            if let speaker = transcript.speaker(for: segment.speakerID) { prefix += "**\(speaker.name):** " }
            lines.append(prefix + segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    // MARK: Plain text

    public static func text(_ transcript: Transcript) -> String {
        transcript.segments.map { segment in
            let name = transcript.speaker(for: segment.speakerID)?.name
            return (name.map { "\($0): " } ?? "") + segment.text
        }.joined(separator: "\n\n") + "\n"
    }

    // MARK: Subtitles

    /// Subtitle cues are at most ~7 s / 84 characters, split at word boundaries.
    static let MAX_CUE_SECONDS: TimeInterval = 7
    static let MAX_CUE_CHARACTERS = 84
    static let MIN_CUE_CHARACTERS = 20

    static func subtitles(_ transcript: Transcript, vtt: Bool) -> String {
        var cues: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        for segment in transcript.segments {
            let speaker = transcript.speaker(for: segment.speakerID)?.name
            let words = segment.words.isEmpty
                ? [Word(text: segment.text, start: segment.start, end: segment.end)] : segment.words
            var chunk: [Word] = []
            func flush() {
                guard let first = chunk.first, let last = chunk.last else { return }
                let body = SegmentBuilder.join(chunk)
                let text = vtt ? (speaker.map { "<v \($0)>\(body)" } ?? body)
                               : (speaker.map { "\($0): \(body)" } ?? body)
                cues.append((first.start, max(last.end, first.start + 0.3), text))
                chunk = []
            }
            for word in words {
                if let first = chunk.first {
                    let length = SegmentBuilder.join(chunk + [word]).count
                    if word.end - first.start > MAX_CUE_SECONDS || length > MAX_CUE_CHARACTERS {
                        // Prefer ending the cue at the last clause boundary, so lines read naturally.
                        if let cut = chunk.lastIndex(where: { $0.text.last.map { ".?!…,;:".contains($0) } ?? false }),
                           cut < chunk.count - 1, SegmentBuilder.join(Array(chunk[...cut])).count >= MIN_CUE_CHARACTERS {
                            let rest = Array(chunk[(cut + 1)...])
                            chunk = Array(chunk[...cut])
                            flush()
                            chunk = rest
                        } else {
                            flush()
                        }
                    }
                }
                chunk.append(word)
                if word.text.last.map({ ".?!…".contains($0) }) == true,
                   SegmentBuilder.join(chunk).count >= MIN_CUE_CHARACTERS * 2 {
                    flush()
                }
            }
            flush()
        }

        var out: [String] = vtt ? ["WEBVTT", ""] : []
        for (index, cue) in cues.enumerated() {
            if !vtt { out.append("\(index + 1)") }
            out.append("\(subtitleTime(cue.start, vtt: vtt)) --> \(subtitleTime(cue.end, vtt: vtt))")
            out.append(cue.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Helpers

    /// `mm:ss`, or `h:mm:ss` past an hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `hh:mm:ss`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func subtitleTime(_ seconds: TimeInterval, vtt: Bool) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let (h, m, s, ms) = (millis / 3_600_000, (millis % 3_600_000) / 60_000, (millis % 60_000) / 1000, millis % 1000)
        return String(format: vtt ? "%02d:%02d:%02d.%03d" : "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func yamlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
