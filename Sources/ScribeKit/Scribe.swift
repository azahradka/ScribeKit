@preconcurrency import FluidAudio
import Foundation

/// Model download and load progress.
public struct ModelProgress: Sendable {
    public enum Model: String, Sendable {
        case speechRecognition = "Speech recognition"
        case speakerDiarization = "Speaker recognition"
    }

    public let model: Model
    /// 0…1 when known.
    public let fraction: Double?
    public let detail: String
}

/// Transcription options.
public struct TranscriptionOptions: Sendable, Equatable {
    /// ISO 639-1 code (`"pl"`, `"en"`, …) or nil to detect automatically.
    /// Parakeet v3 covers 25 European languages; a hint mainly prevents words
    /// being spelled in the wrong script.
    public var language: String?
    /// Label speakers. Costs roughly one extra pass over the audio.
    public var diarize: Bool
    /// Exact number of speakers when known; improves diarization.
    public var speakerCount: Int?
    /// Name used for the local speaker in ``Scribe/transcribeConversation(microphone:system:options:progress:)``.
    public var localSpeakerName: String
    /// Template for other speakers; `%d` becomes the number.
    public var remoteSpeakerTemplate: String

    public init(language: String? = nil, diarize: Bool = true, speakerCount: Int? = nil,
                localSpeakerName: String = "Me", remoteSpeakerTemplate: String = "Speaker %d") {
        self.language = language
        self.diarize = diarize
        self.speakerCount = speakerCount
        self.localSpeakerName = localSpeakerName
        self.remoteSpeakerTemplate = remoteSpeakerTemplate
    }
}

/// Progress of ``Scribe/diarize(url:minSpeakers:maxSpeakers:exclusive:progress:)``.
public enum DiarizationProgress: Sendable, Equatable {
    /// Downloading (first time) or loading the speaker model; `fraction` is 0…1 when known.
    case model(fraction: Double?, detail: String)
    /// Finding speakers; `fraction` of the audio done, 0…1.
    case diarizing(fraction: Double)
}

/// Stage of a running transcription, for progress UI.
public enum TranscriptionStage: Sendable, Equatable {
    case loadingModels
    case transcribing(track: String)
    case identifyingSpeakers
    case finishing
}

public enum ScribeError: LocalizedError, Sendable {
    case unsupportedLanguage(String)
    case noAudio
    case invalidSpeakerRange(min: Int?, max: Int?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let code): return "Parakeet v3 does not support the language '\(code)'."
        case .noAudio: return "There is no audio to transcribe."
        case .invalidSpeakerRange(let min, let max):
            return "The speaker range \(min.map(String.init) ?? "any")–\(max.map(String.init) ?? "any") is not valid."
        }
    }
}

/// On-device speech recognition (NVIDIA Parakeet TDT v3) and speaker diarization
/// (pyannote community-1), both through FluidAudio on the Apple Neural Engine.
///
/// Models are downloaded from Hugging Face on first use (about 500 MB for recognition,
/// 30 MB for diarization) and cached in `~/Library/Application Support/FluidAudio`.
/// Share one instance: models load once and stay in memory.
///
/// ```swift
/// let scribe = Scribe()
/// let text = try await scribe.transcribeText(url, language: "pl")
/// let transcript = try await scribe.transcribe(url, options: .init(diarize: true))
/// ```
public actor Scribe {
    public static let shared = Scribe()

    /// Languages Parakeet v3 recognizes, ISO 639-1.
    public static let supportedLanguages: [String] = Language.allCases.map(\.rawValue)

    private var asr: AsrManager?
    private var asrLoading: Task<AsrManager, Error>?
    private var diarizer: DiarizerBox?
    private var diarizerLoading: Task<DiarizerBox, Error>?
    /// Diarizers configured for a fixed speaker count, keyed by that count.
    private var countedDiarizers: [Int: DiarizerBox] = [:]
    /// The offline diarizer's Core ML models, shared by every ``diarize(url:minSpeakers:maxSpeakers:exclusive:progress:)``
    /// call whatever its configuration. Loaded without the speech model.
    private var speakerModels: OfflineDiarizerModels?
    private var speakerModelsLoading: Task<OfflineDiarizerModels, Error>?

    public init() {}

    public var isSpeechModelLoaded: Bool { asr != nil }
    public var isDiarizationModelLoaded: Bool { diarizer != nil }

    // MARK: - Models

    /// Downloads (first time) and loads the models ahead of use, so the first
    /// transcription does not wait. Safe to call repeatedly.
    public func prepare(diarization: Bool = false,
                        progress: (@Sendable (ModelProgress) -> Void)? = nil) async throws {
        _ = try await speechModel(progress: progress)
        if diarization { _ = try await diarizationModel(progress: progress) }
    }

    /// Frees model memory. The next transcription loads them again.
    public func unload() {
        asr = nil
        diarizer = nil
        countedDiarizers = [:]
        speakerModels = nil
    }

    /// Downloads (first time, about 30 MB) and loads only the speaker diarization model, not the
    /// speech model. Safe to call repeatedly. ``diarize(url:minSpeakers:maxSpeakers:exclusive:progress:)``
    /// calls it itself; call it ahead to download the model at a time of your choosing.
    public func prepareDiarizationModel(progress: (@Sendable (ModelProgress) -> Void)? = nil) async throws {
        _ = try await speakerModel(progress: progress)
    }

    private func speakerModel(progress: (@Sendable (ModelProgress) -> Void)?) async throws -> OfflineDiarizerModels {
        if let speakerModels { return speakerModels }
        if let speakerModelsLoading { return try await speakerModelsLoading.value }
        let task = Task<OfflineDiarizerModels, Error> {
            progress?(ModelProgress(model: .speakerDiarization, fraction: nil, detail: "Loading speaker model…"))
            let models = try await OfflineDiarizerModels.load(progressHandler: { update in
                progress?(ModelProgress(model: .speakerDiarization, fraction: update.fractionCompleted,
                                        detail: Self.describe(update.phase)))
            })
            progress?(ModelProgress(model: .speakerDiarization, fraction: 1, detail: "Speaker model ready"))
            return models
        }
        speakerModelsLoading = task
        defer { speakerModelsLoading = nil }
        let models = try await task.value
        speakerModels = models
        return models
    }

    private func speechModel(progress: (@Sendable (ModelProgress) -> Void)?) async throws -> AsrManager {
        if let asr { return asr }
        if let asrLoading { return try await asrLoading.value }
        let task = Task<AsrManager, Error> {
            let version = AsrModelVersion.v3
            let models = try await AsrModels.downloadAndLoad(
                version: version,
                encoderPrecision: .int8,
                progressHandler: { update in
                    progress?(ModelProgress(model: .speechRecognition, fraction: update.fractionCompleted,
                                            detail: Self.describe(update.phase)))
                }
            )
            let config = ASRConfig(
                tdtConfig: TdtConfig(blankId: version.blankId),
                encoderHiddenSize: version.encoderHiddenSize
            )
            let manager = AsrManager(config: config)
            try await manager.loadModels(models)
            return manager
        }
        asrLoading = task
        defer { asrLoading = nil }
        let manager = try await task.value
        asr = manager
        return manager
    }

    private func diarizationModel(progress: (@Sendable (ModelProgress) -> Void)?) async throws -> DiarizerBox {
        if let diarizer { return diarizer }
        if let diarizerLoading { return try await diarizerLoading.value }
        let task = Task<DiarizerBox, Error> {
            progress?(ModelProgress(model: .speakerDiarization, fraction: nil, detail: "Loading speaker models…"))
            let box = try await DiarizerBox.load(config: .default)
            progress?(ModelProgress(model: .speakerDiarization, fraction: 1, detail: "Speaker models ready"))
            return box
        }
        diarizerLoading = task
        defer { diarizerLoading = nil }
        let box = try await task.value
        diarizer = box
        return box
    }

    nonisolated static func describe(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing: return "Checking model files…"
        case .downloading(let done, let total):
            return total > 0 ? "Downloading model (\(done)/\(total) files)…" : "Loading model…"
        case .compiling(let name):
            let model = name.replacingOccurrences(of: ".mlmodelc", with: "")
            return model.isEmpty ? "Preparing model…" : "Preparing \(model)…"
        }
    }

    // MARK: - Model downloads

    /// Downloads models only from `baseURL`, ignoring the `REGISTRY_URL` and `MODEL_REGISTRY_URL`
    /// environment variables, and fetches the speech model at commit `speechModelRevision`
    /// instead of `main`. Call before ``prepare(diarization:progress:)``.
    public nonisolated static func pinDownloads(baseURL: String, speechModelRevision: String) {
        ModelRegistry.baseURL = baseURL
        ModelRegistry.revisionOverrides[Repo.parakeetV3.remotePath] = speechModelRevision
    }

    /// When true, models load only from the cache and nothing is downloaded.
    public nonisolated static var offlineMode: Bool {
        get { ModelHub.offlineMode }
        set { ModelHub.offlineMode = newValue }
    }

    /// Whether the models ``prepare(diarization:progress:)`` loads are already cached at the
    /// revisions FluidAudio would download, so preparing them needs no network.
    public nonisolated static func modelsAreCached(diarization: Bool) -> Bool {
        let speech = MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV3)
        guard AsrModels.modelsExist(at: speech, version: .v3, encoderPrecision: .int8),
              cachedRevisionMatches(.parakeetV3, at: speech) else { return false }
        return !diarization || diarizationModelIsCached()
    }

    /// Whether the speaker diarization model alone is cached at the revision FluidAudio would
    /// download, so ``prepareDiarizationModel(progress:)`` needs no network. Says nothing about
    /// the speech model.
    public nonisolated static func diarizationModelIsCached() -> Bool {
        let speakers = MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: speakers.appendingPathComponent($0).path)
        } && cachedRevisionMatches(.diarizer, at: speakers)
    }

    /// Drops FluidAudio log messages below warning level and stops copying them to stderr.
    /// FluidAudio's debug lines can contain transcript text.
    public nonisolated static func quietModelLogs() {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
    }

    /// Same rule as FluidAudio's internal `ModelCache.matchesRevision`: a cache without a
    /// revision marker holds `main`, and a pinned revision needs a matching marker.
    private nonisolated static func cachedRevisionMatches(_ repo: Repo, at folder: URL) -> Bool {
        let expected = ModelRegistry.revisionOverrides[repo.remotePath] ?? repo.revision
        let marker = try? String(contentsOf: folder.appendingPathComponent(".fluidaudio-revision"), encoding: .utf8)
        return (marker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main") == expected
    }

    // MARK: - Transcription

    /// Plain text of a file, no speakers. For dictation-style use.
    public func transcribeText(_ url: URL, language: String? = nil) async throws -> String {
        let result = try await recognize(url, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Timed words of a file.
    public func words(_ url: URL, language: String? = nil) async throws -> [Word] {
        let result = try await recognize(url, language: language)
        return Self.words(from: result)
    }

    /// Transcribes one file, optionally labeling speakers.
    public func transcribe(_ url: URL, options: TranscriptionOptions = .init(),
                           progress: (@Sendable (TranscriptionStage) -> Void)? = nil) async throws -> Transcript {
        progress?(.loadingModels)
        _ = try await speechModel(progress: nil)
        progress?(.transcribing(track: url.lastPathComponent))
        let result = try await recognize(url, language: options.language)
        let words = Self.words(from: result)

        guard options.diarize, !words.isEmpty else {
            return Transcript(segments: SegmentBuilder.group(words.map { ($0, nil) }),
                              language: options.language, duration: result.duration)
        }

        progress?(.identifyingSpeakers)
        let turns = try await diarize(url, speakerCount: options.speakerCount)
        progress?(.finishing)
        let (renamed, speakers) = Self.nameSpeakers(turns: turns, words: words, prefix: nil,
                                                    template: options.remoteSpeakerTemplate)
        return Transcript(segments: SegmentBuilder.segments(words: words, turns: renamed),
                          speakers: speakers, language: options.language, duration: result.duration)
    }

    /// Transcribes a call recorded as two aligned tracks (see SystemAudioKit): everything on the
    /// microphone is the local speaker, the system track is diarized into the other participants.
    /// Echo of the other side picked up by the microphone is removed.
    public func transcribeConversation(microphone: URL?, system: URL?,
                                       options: TranscriptionOptions = .init(),
                                       progress: (@Sendable (TranscriptionStage) -> Void)? = nil) async throws -> Transcript {
        guard microphone != nil || system != nil else { throw ScribeError.noAudio }
        progress?(.loadingModels)
        _ = try await speechModel(progress: nil)

        var micWords: [Word] = []
        var duration: TimeInterval = 0
        if let microphone {
            progress?(.transcribing(track: "microphone"))
            let result = try await recognize(microphone, language: options.language)
            micWords = Self.words(from: result)
            duration = max(duration, result.duration)
        }

        var systemWords: [Word] = []
        if let system {
            progress?(.transcribing(track: "system audio"))
            let result = try await recognize(system, language: options.language)
            systemWords = Self.words(from: result)
            duration = max(duration, result.duration)
        }

        micWords = SegmentBuilder.removeEcho(microphone: micWords, system: systemWords)

        var speakers: [Speaker] = []
        var tracks: [[Segment]] = []
        if !micWords.isEmpty {
            let me = Speaker(id: "local", name: options.localSpeakerName, isLocal: true)
            speakers.append(me)
            tracks.append(SegmentBuilder.group(micWords.map { ($0, me.id) }))
        }

        if let system, !systemWords.isEmpty {
            if options.diarize {
                progress?(.identifyingSpeakers)
                let remoteCount = options.speakerCount.map { max(1, $0 - (micWords.isEmpty ? 0 : 1)) }
                let turns = try await diarize(system, speakerCount: remoteCount)
                let (renamed, remote) = Self.nameSpeakers(turns: turns, words: systemWords, prefix: "remote-",
                                                          template: options.remoteSpeakerTemplate)
                speakers += remote
                tracks.append(SegmentBuilder.segments(words: systemWords, turns: renamed))
            } else {
                let others = Speaker(id: "remote", name: String(format: options.remoteSpeakerTemplate, 1))
                speakers.append(others)
                tracks.append(SegmentBuilder.group(systemWords.map { ($0, others.id) }))
            }
        }

        progress?(.finishing)
        return Transcript(segments: SegmentBuilder.interleave(tracks), speakers: speakers,
                          language: options.language, duration: duration)
    }

    /// Speaker turns of a file, without transcription.
    public func diarize(_ url: URL, speakerCount: Int? = nil) async throws -> [SegmentBuilder.Turn] {
        var box = try await diarizationModel(progress: nil)
        if let speakerCount {
            if let cached = countedDiarizers[speakerCount] {
                box = cached
            } else {
                var config = OfflineDiarizerConfig.default
                config.clustering.numSpeakers = speakerCount
                box = try await DiarizerBox.load(config: config)
                countedDiarizers[speakerCount] = box
            }
        }
        return try await box.turns(for: url)
    }

    /// Speaker turns of a file from FluidAudio's offline (pyannote community-1, VBx) diarizer alone:
    /// no speech recognition, and the speech model is never downloaded or loaded.
    ///
    /// - Parameters:
    ///   - minSpeakers, maxSpeakers: bounds on the number of speakers, nil for no bound. Equal
    ///     bounds ask for exactly that many speakers.
    ///   - exclusive: when true, turns never overlap (later overlapping speech is trimmed).
    /// - Returns: turns sorted by start, with FluidAudio's own speaker IDs (arbitrary labels).
    public func diarize(url: URL, minSpeakers: Int? = nil, maxSpeakers: Int? = nil, exclusive: Bool = true,
                        progress: (@Sendable (DiarizationProgress) -> Void)? = nil) async throws -> [SegmentBuilder.Turn] {
        let config = try Self.diarizerConfig(minSpeakers: minSpeakers, maxSpeakers: maxSpeakers, exclusive: exclusive)
        let modelProgress: (@Sendable (ModelProgress) -> Void)? = progress.map { report in
            { @Sendable update in report(.model(fraction: update.fraction, detail: update.detail)) }
        }
        let models = try await speakerModel(progress: modelProgress)
        progress?(.diarizing(fraction: 0))
        let box = DiarizerBox(models: models, config: config)
        let turns = try await box.turns(for: url) { done, total in
            progress?(.diarizing(fraction: total > 0 ? min(1, Double(done) / Double(total)) : 0))
        }
        return turns.filter { $0.end > $0.start }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The offline diarizer configuration for a speaker range: community-1 defaults otherwise.
    nonisolated static func diarizerConfig(minSpeakers: Int?, maxSpeakers: Int?, exclusive: Bool) throws -> OfflineDiarizerConfig {
        if let minSpeakers, minSpeakers < 1 { throw ScribeError.invalidSpeakerRange(min: minSpeakers, max: maxSpeakers) }
        if let maxSpeakers, maxSpeakers < max(1, minSpeakers ?? 1) {
            throw ScribeError.invalidSpeakerRange(min: minSpeakers, max: maxSpeakers)
        }
        var config = OfflineDiarizerConfig.default
        if let minSpeakers, minSpeakers == maxSpeakers {
            config.clustering.numSpeakers = minSpeakers
        } else {
            config.clustering.minSpeakers = minSpeakers
            config.clustering.maxSpeakers = maxSpeakers
        }
        config.postProcessing.exclusiveSegments = exclusive
        try config.validate()
        return config
    }

    // MARK: - Internals

    private func recognize(_ url: URL, language code: String?) async throws -> ASRResult {
        let manager = try await speechModel(progress: nil)
        var language: Language?
        if let code, code != "auto" {
            guard let parsed = Language(rawValue: code) else { throw ScribeError.unsupportedLanguage(code) }
            language = parsed
        }
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        return try await manager.transcribe(url, decoderState: &state, language: language)
    }

    static func words(from result: ASRResult) -> [Word] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [Word(text: text, start: 0, end: result.duration)]
        }
        return buildWordTimings(from: timings).map {
            Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }

    /// Numbers speakers in order of first speech (the diarizer's own IDs are arbitrary)
    /// and drops speakers that end up with no words.
    static func nameSpeakers(turns: [SegmentBuilder.Turn], words: [Word], prefix: String?,
                             template: String) -> ([SegmentBuilder.Turn], [Speaker]) {
        let attributed = words.compactMap { SegmentBuilder.speaker(for: $0, in: turns) }
        var order: [String] = []
        for id in attributed where !order.contains(id) { order.append(id) }
        var mapping: [String: String] = [:]
        var speakers: [Speaker] = []
        for (index, original) in order.enumerated() {
            let id = "\(prefix ?? "")s\(index + 1)"
            mapping[original] = id
            speakers.append(Speaker(id: id, name: String(format: template, index + 1)))
        }
        let renamed = turns.compactMap { turn in
            mapping[turn.speakerID].map { SegmentBuilder.Turn(speakerID: $0, start: turn.start, end: turn.end) }
        }
        return (renamed, speakers)
    }
}

/// Holds FluidAudio's diarizer, which is a non-Sendable class. It is only ever used from
/// inside the ``Scribe`` actor, one call at a time, so crossing into it is safe.
final class DiarizerBox: @unchecked Sendable {
    private let manager: OfflineDiarizerManager

    private init(manager: OfflineDiarizerManager) {
        self.manager = manager
    }

    /// A diarizer with `config` over models that are already loaded.
    convenience init(models: OfflineDiarizerModels, config: OfflineDiarizerConfig) {
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        self.init(manager: manager)
    }

    static func load(config: OfflineDiarizerConfig) async throws -> DiarizerBox {
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        return DiarizerBox(manager: manager)
    }

    func turns(for url: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [SegmentBuilder.Turn] {
        let result = try await manager.process(url, progressCallback: progress)
        return result.segments.map {
            SegmentBuilder.Turn(speakerID: $0.speakerId, start: TimeInterval($0.startTimeSeconds),
                                end: TimeInterval($0.endTimeSeconds))
        }
    }
}
