import XCTest
@testable import ScribeKit

final class SegmentBuilderTests: XCTestCase {
    private func words(_ text: String, start: TimeInterval = 0, step: TimeInterval = 0.4) -> [Word] {
        text.split(separator: " ").enumerated().map { index, token in
            let begin = start + Double(index) * step
            return Word(text: String(token), start: begin, end: begin + step * 0.8)
        }
    }

    func testAssignsWordsToOverlappingTurns() {
        let all = words("hello there how are you fine thanks")
        let turns = [
            SegmentBuilder.Turn(speakerID: "A", start: 0, end: 1.9),
            SegmentBuilder.Turn(speakerID: "B", start: 2.0, end: 3.0),
        ]
        let segments = SegmentBuilder.segments(words: all, turns: turns)
        XCTAssertEqual(segments.map(\.speakerID), ["A", "B"])
        XCTAssertEqual(segments[0].text, "hello there how are you")
        XCTAssertEqual(segments[1].text, "fine thanks")
    }

    func testWordsOutsideTurnsGoToNearestSpeaker() {
        let all = [Word(text: "late", start: 10, end: 10.3)]
        let turns = [SegmentBuilder.Turn(speakerID: "A", start: 0, end: 2),
                     SegmentBuilder.Turn(speakerID: "B", start: 9, end: 9.8)]
        XCTAssertEqual(SegmentBuilder.segments(words: all, turns: turns).first?.speakerID, "B")
    }

    func testLongPauseStartsNewParagraph() {
        let all = words("one two", start: 0) + words("three four", start: 5)
        let segments = SegmentBuilder.group(all.map { ($0, "A") })
        XCTAssertEqual(segments.count, 2)
    }

    func testJoinKeepsPunctuationTight() {
        let joined = SegmentBuilder.join([Word(text: "Hi", start: 0, end: 0), Word(text: ",", start: 0, end: 0),
                                          Word(text: "you", start: 0, end: 0), Word(text: "?", start: 0, end: 0)])
        XCTAssertEqual(joined, "Hi, you?")
    }

    func testInterleaveOrdersByTime() {
        let a = [Segment(speakerID: "me", start: 0, end: 1, text: "a"), Segment(speakerID: "me", start: 5, end: 6, text: "c")]
        let b = [Segment(speakerID: "them", start: 2, end: 3, text: "b")]
        XCTAssertEqual(SegmentBuilder.interleave([a, b]).map(\.text), ["a", "b", "c"])
    }

    func testRemovesEchoRunsButKeepsLoneWords() {
        let system = words("we should ship the release on friday", start: 10)
        let echo = words("we should ship the release", start: 10.2)
        let own = words("okay sounds good", start: 20)
        let lone = [Word(text: "friday", start: 12.5, end: 12.8)]
        let kept = SegmentBuilder.removeEcho(microphone: echo + own + lone, system: system)
        XCTAssertEqual(kept.map(\.text), ["friday", "okay", "sounds", "good"])
    }

    func testNamesSpeakersInOrderOfFirstSpeech() {
        let all = words("a b c d")
        let turns = [SegmentBuilder.Turn(speakerID: "S7", start: 0, end: 0.7),
                     SegmentBuilder.Turn(speakerID: "S2", start: 0.75, end: 2),
                     SegmentBuilder.Turn(speakerID: "S9", start: 50, end: 51)]
        let (renamed, speakers) = Scribe.nameSpeakers(turns: turns, words: all, prefix: nil, template: "Speaker %d")
        XCTAssertEqual(speakers.map(\.name), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(renamed.map(\.speakerID), ["s1", "s2"])
    }
}

final class RendererTests: XCTestCase {
    private let transcript = Transcript(
        segments: [
            Segment(speakerID: "local", start: 0, end: 2, text: "Hello, everyone.",
                    words: [Word(text: "Hello,", start: 0, end: 0.5), Word(text: "everyone.", start: 0.6, end: 2)]),
            Segment(speakerID: "s1", start: 3725.4, end: 3727, text: "Hi \"there\"."),
        ],
        speakers: [Speaker(id: "local", name: "Łukasz", isLocal: true), Speaker(id: "s1", name: "Speaker 1")],
        language: "pl",
        duration: 3727
    )

    func testMarkdown() throws {
        let md = TranscriptRenderer.markdown(transcript, options: .init(
            title: "Standup", metadata: [("date", "2026-09-25"), ("title", "A \"quoted\" title")]))
        XCTAssertTrue(md.hasPrefix("---\ndate: \"2026-09-25\"\ntitle: \"A \\\"quoted\\\" title\"\n---\n\n# Standup\n"))
        XCTAssertTrue(md.contains("[00:00] **Łukasz:** Hello, everyone."))
        XCTAssertTrue(md.contains("[1:02:05] **Speaker 1:** Hi \"there\"."))
    }

    func testSRTAndVTT() throws {
        let srt = try TranscriptRenderer.render(transcript, as: .srt)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nŁukasz: Hello, everyone.\n"))
        let vtt = try TranscriptRenderer.render(transcript, as: .vtt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n<v Łukasz>Hello, everyone."))
        XCTAssertTrue(vtt.contains("01:02:05.400 --> 01:02:07.000"))
    }

    func testJSONRoundTrip() throws {
        let json = try TranscriptRenderer.render(transcript, as: .json)
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, transcript)
    }

    func testPlainText() {
        XCTAssertEqual(TranscriptRenderer.text(transcript), "Łukasz: Hello, everyone.\n\nSpeaker 1: Hi \"there\".\n")
    }

    func testSupportedLanguagesIncludePolish() {
        XCTAssertTrue(Scribe.supportedLanguages.contains("pl"))
        XCTAssertTrue(Scribe.supportedLanguages.contains("en"))
    }
}
