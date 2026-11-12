import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os

// MARK: - Public types

/// A stretch of transcript. `speaker` is 1-based (Speaker 1, Speaker 2 … in order of first
/// appearance) and nil whenever the recording has fewer than two speakers or speakers are off.
struct Segment: Sendable, Codable {
    let start: Double
    var end: Double
    var text: String
    var speaker: Int? = nil
}

/// Everything one speaker says until someone else speaks, split into readable paragraphs.
struct Turn: Sendable, Codable {
    let speaker: Int?
    let paragraphs: [Segment]
    var start: Double { paragraphs.first?.start ?? 0 }
    var end: Double { paragraphs.last?.end ?? 0 }
    var text: String { paragraphs.map(\.text).joined(separator: "\n\n") }
}

struct Transcript: Sendable, Codable {
    let title: String
    let fullText: String
    let sentences: [Segment]
    let cues: [Segment]
    /// Speaker turns in order. With one speaker (or speakers off) this is a single unlabelled turn.
    let turns: [Turn]
    /// Distinct speakers found: 0 when speakers were off or could not be identified.
    let speakerCount: Int
    /// Set when speaker labels were requested but could not be produced; the transcript is still complete.
    let speakerNote: String?
    let audioSeconds: Double
    let wallSeconds: Double

    var hasSpeakers: Bool { speakerCount > 1 }

    static func speakerName(_ speaker: Int) -> String { "Speaker \(speaker)" }

    /// Readable paragraphs; each turn is headed by its speaker when there are two or more.
    var plain: String {
        guard !sentences.isEmpty else { return fullText }
        return turns.map { turn in
            (turn.speaker.map { Self.speakerName($0) + "\n" } ?? "") + turn.text
        }.joined(separator: "\n\n")
    }

    var timestamped: String {
        guard !sentences.isEmpty else { return fullText }
        return sentences.map { s in
            "[\(Self.clock(s.start))] " + (s.speaker.map { Self.speakerName($0) + ": " } ?? "") + s.text
        }.joined(separator: "\n")
    }

    /// Subtitles; a cue is prefixed with its speaker whenever the speaker changes.
    var srt: String {
        var last: Int?
        return cues.enumerated().map { i, c in
            let label = c.speaker != last ? c.speaker.map { Self.speakerName($0) + ": " } ?? "" : ""
            last = c.speaker
            return "\(i + 1)\n\(Self.srtTime(c.start)) --> \(Self.srtTime(c.end))\n\(label)\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func srtTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

/// What the engine is doing right now. Stages only ever move forward in this order
/// (some are skipped: no download for a local file, no model download once cached).
enum Stage: Int, Sendable, Comparable, Codable {
    case downloading  // fetching a link's audio (real fraction once the size is known)
    case extractingAudio  // decoding to 16 kHz mono (real fraction when the length is known)
    case downloadingModel  // first run only (real fraction)
    case loadingModel  // a moment, no fraction (about half a minute the first time, while macOS prepares the model)
    case transcribing  // real fraction; speakers are identified at the same time
    case identifyingSpeakers  // speakers still being worked out after the words are done; at 1 only the unmeasured finish is left
    case done

    static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .downloading: return "Downloading"
        case .extractingAudio: return "Extracting audio"
        case .downloadingModel: return "Downloading model"
        case .loadingModel: return "Loading model"
        case .transcribing: return "Transcribing"
        case .identifyingSpeakers: return "Identifying speakers"
        case .done: return "Done"
        }
    }
}

struct Progress: Sendable, Codable {
    let stage: Stage
    /// 0...1 within `stage`, never decreasing; nil when the amount of work is not knowable.
    let fraction: Double?
    /// The media's title as soon as it is known (links learn it before the download starts).
    let title: String?
    /// While `stage` is `.transcribing`: how far speaker identification, which runs alongside, has
    /// got (0...1). Nil when speakers are off or nothing is known yet. Lets a display blend the two.
    var speakers: Double? = nil
    /// A picture for the recording, when the link has one.
    var thumbnail: String? = nil
    /// The recording's length, once its audio has been read.
    var audioSeconds: Double? = nil
    /// Memory the job is using right now, in megabytes.
    var memoryMB: Int? = nil
}

typealias ProgressHandler = @Sendable (Progress) -> Void

/// One recording in a playlist or channel.
struct LinkItem: Sendable {
    let title: String
    let url: String
    let seconds: Double?
    var thumbnail: String? = nil
}

/// A playlist or channel: its name and what it holds. `more` means the list was cut off at the limit.
struct LinkList: Sendable {
    let title: String
    let items: [LinkItem]
    let more: Bool
    /// A channel lists newest first; a playlist keeps its own order.
    var isChannel = false
}

enum ScribeError: LocalizedError {
    case missingTool(String)
    case notFound(String)
    case noAudio
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let t): return "\(t) is not installed. Run: brew install \(t)"
        case .notFound(let p): return "File not found: \(p)"
        case .noAudio: return "No audio could be read from that file."
        case .message(let m): return m
        }
    }
}

/// Stage timings for tuning: set SCRIBE_TIMING to a file path and each mark is appended to it.
enum Mark {
    private static let path = ProcessInfo.processInfo.environment["SCRIBE_TIMING"]
    private static let zero = Date()
    private static let lock = NSLock()
    static func at(_ label: String) {
        guard let path else { return }
        let line = String(format: "%7.2f  %@\n", Date().timeIntervalSince(zero), label)
        lock.withLock {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Engine

enum Engine {
    static let modelVersion: AsrModelVersion = .ultra
    /// What the window says is doing the work.
    static let modelName = "Parakeet Ultra"
    /// The model whose punctuation and capitals are borrowed (see `copyPunctuation`).
    static let polishVersion: AsrModelVersion = .v2
    /// Off (`--fast`) skips the punctuation pass: about twice as quick, plainer punctuation.
    nonisolated(unsafe) static var polish = true
    /// The title to give a local file that is really a download made ahead of time.
    nonisolated(unsafe) static var titleOverride: String?

    /// Transcribes a file path or link. Runs at utility priority whatever the caller's priority,
    /// stops promptly when the calling task is cancelled (throwing `CancellationError`), and always
    /// removes its temporary files and unloads its models before returning.
    static func transcribe(
        input: String, speakers: Bool = true, progress: @escaping ProgressHandler
    ) async throws -> Transcript {
        let job = Task.detached(priority: .utility) {
            try await run(input: input, speakers: speakers, reporter: Reporter(progress))
        }
        // Wait through a continuation: awaiting `job.value` directly would raise the job to the caller's priority.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                Task.detached(priority: .utility) { cont.resume(with: await job.result) }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// What a job running in a child process says on its standard output, one JSON object per line.
    struct Wire: Codable {
        var progress: Progress?
        var transcript: Transcript?
        var error: String?
        var missingTool: String?
    }

    /// The same job in a child copy of this program (`scribe --job`), for the window. When the child
    /// exits, everything the models used goes back to the system at once (nothing of a job stays in
    /// the app, however many it runs), and the whole job, library threads included, is held to utility priority.
    static func transcribeInChild(
        input: String, title: String? = nil, speakers: Bool = true, progress: @escaping ProgressHandler
    ) async throws -> Transcript {
        guard let exe = Bundle.main.executableURL else {
            return try await transcribe(input: input, speakers: speakers, progress: progress)
        }
        var last = Wire()
        let decoder = JSONDecoder()
        _ = try await run(exe, ["--job", input] + (title.map { ["--title", $0] } ?? []) + (speakers ? [] : ["--no-speakers"])) { line in
            guard let wire = try? decoder.decode(Wire.self, from: Data(line.utf8)) else { return }
            if let p = wire.progress { progress(p) } else { last = wire }
        }
        if let transcript = last.transcript { return transcript }
        if let tool = last.missingTool { throw ScribeError.missingTool(tool) }
        throw ScribeError.message(last.error ?? "The transcription stopped unexpectedly. Try again.")
    }

    /// Removes work folders left behind by a copy of Scribe that was killed before it could tidy up.
    private static func sweepAbandoned(in tmp: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("scribe-") {
            if let pid = pid_t(name.dropFirst(7).prefix { $0 != "-" }), kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }

    private static func run(input rawInput: String, speakers: Bool, reporter: Reporter) async throws -> Transcript {
        let started = Date()
        Mark.at("job start")
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmp = FileManager.default.temporaryDirectory
        sweepAbandoned(in: tmp)
        // Named after this process, so a later run can tell the folder was abandoned if this one is killed.
        let work = tmp.appendingPathComponent("scribe-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var media: URL
        if let link = link(from: input) {
            reporter.report(.downloading, nil)
            Mark.at("download start")
            media = try await download(link, into: work, reporter: reporter)
            Mark.at("download done")
        } else {
            media =
                input.hasPrefix("file://")
                ? (URL(string: input) ?? URL(fileURLWithPath: input))
                : URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            // Opening the file (rather than asking whether it exists) is what makes macOS ask for
            // permission to a protected folder such as Desktop or Documents the first time.
            do { try FileHandle(forReadingFrom: media).close() } catch {
                let e = error as NSError
                let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? e.code
                if e.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                    throw ScribeError.message(
                        "Scribe is not allowed to read that file. Allow its folder under System Settings › Privacy & Security › Files and Folders, then try again.")
                }
                throw ScribeError.notFound(media.path)
            }
            reporter.setTitle(titleOverride ?? media.deletingPathExtension().lastPathComponent)
        }

        // One 16 kHz mono 16-bit wav in the work folder. The recogniser and the diarizer both
        // memory-map it in place, so the audio itself never sits in RAM.
        reporter.report(.extractingAudio, nil)
        let wav = work.appendingPathComponent("audio16k.wav")
        if (try? await decode(media, to: wav, reporter: reporter)) != true {
            try Task.checkCancellation()
            try await extractAudio(media, to: wav, reporter: reporter)
        }
        if media.path.hasPrefix(work.path) { try? FileManager.default.removeItem(at: media) }
        let wavBytes = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
        reporter.setAudio(seconds: Double(max(0, wavBytes - 44)) / 32_000)
        try Task.checkCancellation()
        Mark.at("audio decoded (\(wavBytes / 32_000) s of audio)")

        // Speakers are worked out alongside the words; both read the same mapped file.
        async let diarized: Result<[TimedSpeakerSegment], Error> =
            speakers ? diarize(wav, reporter: reporter) : .success([])

        // Two passes over the same file. The first model is the most accurate on words; the second hears
        // sentence ends more reliably, so only its punctuation and capitals are copied onto the first's words.
        let polishing = polish
        let polishCached = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: polishVersion), version: polishVersion)
        if polishing, !polishCached {
            reporter.report(.downloadingModel, nil)
            _ = try? await AsrModels.download(version: polishVersion)
            try Task.checkCancellation()
        }
        // The two passes run side by side on different parts of the chip: the first on the Neural
        // Engine, the second on the GPU. Progress is the slower of the two.
        let env = ProcessInfo.processInfo.environment
        let together = polishing && ["gpu", "ane"].contains(env["SCRIBE_V2"] ?? "")
        let pace = Pace(lanes: together ? 2 : 1) { reporter.report(.transcribing, $0) }
        async let early: ASRResult? =
            together
            ? (try? await recognise(wav, version: polishVersion, units: env["SCRIBE_V2"] == "gpu" ? .cpuAndGPU : nil, announce: false, reporter: reporter) { pace.set(1, $0) })
            : nil
        let result = try await recognise(wav, version: modelVersion, units: nil, announce: true, reporter: reporter) {
            pace.set(0, together || !polishing ? $0 : $0 / 2)
        }
        var words = Self.words(from: result.tokenTimings ?? [])
        var second = await early
        if polishing, !together, !words.isEmpty {
            second = try? await recognise(wav, version: polishVersion, units: nil, announce: false, reporter: reporter) { pace.set(0, 0.5 + $0 / 2) }
        }
        if let second, !words.isEmpty { copyPunctuation(from: Self.words(from: second.tokenTimings ?? []), onto: &words) }
        try Task.checkCancellation()

        reporter.speechDone(awaitingSpeakers: speakers)
        var speakerCount = 0
        var speakerNote: String?
        switch await diarized {
        case .success(let segments): speakerCount = assignSpeakers(&words, segments)
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Silence or a clip of a few words has no speakers to tell apart; that is not worth a warning.
            var silent = false
            if case OfflineDiarizationError.noSpeechDetected = error { silent = true }
            if !silent, words.count > 4 { speakerNote = "Speaker labels unavailable: \(error.localizedDescription)" }
        }
        try Task.checkCancellation()

        let sentences = group(words, maxChars: 320, maxSeconds: 60)
        // Subtitles: a cue too brief to read joins the one before it when there is room, no cue runs into
        // the next, and a short one stays up for a second if nothing follows sooner.
        var cues: [Segment] = []
        for cue in group(words, maxChars: 84, maxSeconds: 7) {
            if let last = cues.last, last.speaker == cue.speaker, cue.start - last.end < 0.3,
                min(cue.end - cue.start, last.end - last.start) < 0.5, last.text.count + cue.text.count < 84
            {
                cues[cues.count - 1] = Segment(start: last.start, end: cue.end, text: last.text + " " + cue.text, speaker: last.speaker)
            } else {
                cues.append(cue)
            }
        }
        for i in cues.indices {
            let next = i + 1 < cues.count ? cues[i + 1].start : .infinity
            cues[i].end = max(cues[i].start + 0.05, min(max(cues[i].end, cues[i].start + 1), next))
        }
        let transcript = Transcript(
            title: reporter.title ?? "Transcript",
            fullText: result.text,
            sentences: sentences,
            cues: cues,
            turns: turns(from: sentences),
            speakerCount: speakerCount,
            speakerNote: speakerNote,
            audioSeconds: result.duration,
            wallSeconds: Date().timeIntervalSince(started))
        Mark.at("finished")
        reporter.report(.done, 1)
        return transcript
    }

    // MARK: - Speakers

    /// Offline pyannote + VBx pipeline: the most accurate diarizer FluidAudio ships for whole recordings.
    private static func diarize(_ wav: URL, reporter: Reporter) async -> Result<[TimedSpeakerSegment], Error> {
        do {
            var config = OfflineDiarizerConfig.default
            config.postProcessing.exclusiveSegments = true  // one speaker at a time, to attribute words
            // Small batches and no GPU: the defaults peak near 900 MB, these stay near 150 MB for about 5% more time.
            let tune = ProcessInfo.processInfo.environment
            let batches = (tune["SCRIBE_DIAR_BATCH"] ?? "1,2").split(separator: ",").compactMap { Int($0) }
            config.segmentation.batchSize = batches.first ?? 1
            config.embedding.batchSize = batches.last ?? 2
            config.embedding.minSegmentDurationSeconds = 0  // keep short interjections ("Yeah.") as their own segments
            let units = MLModelConfiguration()
            units.computeUnits = ["gpu": .cpuAndGPU, "all": .all, "cpu": .cpuOnly][tune["SCRIBE_DIAR_UNITS"] ?? ""] ?? .cpuAndNeuralEngine
            // The first run also fetches these models (21 MB); the speech model's download owns the progress display.
            let models = try await OfflineDiarizerModels.load(configuration: units)
            try Task.checkCancellation()
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            Mark.at("diarizer loaded")
            let result = try await manager.process(wav) { done, total in
                reporter.speakers(Double(done) / Double(max(total, 1)))
            }
            Mark.at("diarizer done")
            return .success(result.segments)  // manager and models are released here
        } catch {
            return .failure(error)
        }
    }

    /// Labels each word with a speaker (numbered by first appearance) and returns how many there
    /// are; words stay unlabelled when it is below two.
    ///
    /// Diarizer boundaries land a few words off far more often than people swap mid-sentence. So
    /// instead of trusting each word's own overlap, this finds the cheapest labelling of the whole
    /// recording: giving a word to anyone but the speaker heard over it costs the word's length,
    /// and changing speaker is cheap after a sentence or a pause and dear mid-phrase.
    private static func assignSpeakers(_ words: inout [Segment], _ unsorted: [TimedSpeakerSegment]) -> Int {
        let segments = unsorted.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        guard !segments.isEmpty, !words.isEmpty else { return 0 }
        var ids: [String: Int] = [:]
        let segmentSpeaker = segments.map { s -> Int in
            if let id = ids[s.speakerId] { return id }
            ids[s.speakerId] = ids.count
            return ids.count - 1
        }
        let n = ids.count

        // top[i]: the speaker heard longest over word i, or -1 for a word in a gap between segments.
        var top = [Int](repeating: -1, count: words.count)
        var votes = [Int](repeating: 0, count: n)
        var heard = [Double](repeating: 0, count: n)
        var j = 0
        for (i, w) in words.enumerated() {
            let (start, end) = (w.start, max(w.end, w.start + 0.08))
            while j < segments.count - 1, Double(segments[j].endTimeSeconds) <= start { j += 1 }
            for s in 0..<n { heard[s] = 0 }
            var k = j
            while k < segments.count, Double(segments[k].startTimeSeconds) < end {
                heard[segmentSpeaker[k]] += max(
                    0, min(end, Double(segments[k].endTimeSeconds)) - max(start, Double(segments[k].startTimeSeconds)))
                k += 1
            }
            if let best = (0..<n).max(by: { heard[$0] < heard[$1] }), heard[best] > 0 {
                top[i] = best
                votes[best] += 1
            }
        }
        // A voice behind fewer than 1% of the words (and under 20 of them) is a stray cluster, not a
        // person: its words go to whoever is speaking around them.
        let voices = (0..<n).filter { votes[$0] >= 20 || (votes[$0] > 0 && votes[$0] * 100 >= words.count) }
        guard voices.count > 1 else { return voices.count }

        let m = voices.count
        var cost = [Double](repeating: 0, count: m)
        var from = [UInt8](repeating: 0, count: words.count * m)
        for (i, w) in words.enumerated() {
            let cheapest = cost.indices.min { cost[$0] < cost[$1] } ?? 0
            var change = Double.infinity
            if i > 0 {
                let pause = max(0, w.start - words[i - 1].end)
                change = endsSentence(words, i - 1) ? Tuning.afterSentence : max(Tuning.afterPause, Tuning.midPhrase - Tuning.perSecond * pause)
            }
            let weight = max(w.end - w.start, Tuning.shortest)
            let arriving = cost[cheapest] + change
            for v in 0..<m {
                if arriving < cost[v] {
                    cost[v] = arriving
                    from[i * m + v] = UInt8(cheapest)
                } else {
                    from[i * m + v] = UInt8(v)
                }
                if top[i] != voices[v], voices.contains(top[i]) { cost[v] += weight }
            }
        }
        var v = cost.indices.min { cost[$0] < cost[$1] } ?? 0
        var label = [Int](repeating: 0, count: words.count)
        for i in words.indices.reversed() {
            label[i] = v
            v = Int(from[i * m + v])
        }

        var order: [Int: Int] = [:]
        for l in label where order[l] == nil { order[l] = order.count + 1 }
        if order.count > 1 {
            for i in words.indices { words[i].speaker = order[label[i]] }
        }
        return order.count
    }

    /// Costs for `assignSpeakers`, in seconds of mislabelled speech.
    private enum Tuning {
        static let afterSentence = 0.08  // changing speaker after a sentence end
        static let midPhrase = 2.0  // ... between two words with no pause
        static let perSecond = 2.5  // ... less this much per second of pause
        static let afterPause = 0.3  // ... but never below this
        static let shortest = 0.2  // a word counts for at least this long, so "Yeah." survives as its own turn
    }

    private static let titles: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "sr.", "jr."]

    /// Whether word `i` closes a sentence. A title ("Mr.") never does, and a dotted abbreviation
    /// ("a.m.", "e.g.") only does when a capital letter follows.
    private static func endsSentence(_ words: [Segment], _ i: Int) -> Bool {
        let text = words[i].text
        guard let last = text.last, ".?!".contains(last) else { return false }
        guard last == "." else { return true }
        let lower = text.lowercased()
        if titles.contains(lower) { return false }
        if lower.dropLast().contains("."), lower.contains(where: \.isLetter), i + 1 < words.count {
            return words[i + 1].text.first?.isUppercase ?? true
        }
        return true
    }

    static func turns(from sentences: [Segment]) -> [Turn] {
        var turns: [Turn] = []
        var paragraphs: [Segment] = []
        var current: [Segment] = []
        func endParagraph() {
            guard let first = current.first, let last = current.last else { return }
            paragraphs.append(
                Segment(
                    start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "),
                    speaker: first.speaker))
            current = []
        }
        func endTurn() {
            endParagraph()
            if let first = paragraphs.first { turns.append(Turn(speaker: first.speaker, paragraphs: paragraphs)) }
            paragraphs = []
        }
        var chars = 0
        for s in sentences {
            if let last = current.last {
                // A long turn breaks into paragraphs at a long pause, or once it is long enough and a sentence has just ended.
                let closed = last.text.last.map { ".?!".contains($0) } ?? false
                if s.speaker != last.speaker {
                    endTurn()
                    chars = 0
                } else if s.start - last.end > 2.0 || (chars > 600 && closed) {
                    endParagraph()
                    chars = 0
                }
            }
            current.append(s)
            chars += s.text.count + 1
        }
        endTurn()
        return turns
    }

    // MARK: - Words and segments

    // MARK: - Words

    /// One pass of a speech model over the whole file. The model is loaded for the pass and freed straight after.
    private static func recognise(
        _ wav: URL, version: AsrModelVersion, units: MLComputeUnits?, announce first: Bool, reporter: Reporter,
        tick: @escaping @Sendable (Double) -> Void
    ) async throws -> ASRResult {
        // "Complete", not "the folder exists": an interrupted first download leaves the folder behind.
        let cached = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        if first { reporter.report(cached ? .loadingModel : .downloadingModel, nil) }
        let asr = AsrManager(config: .default)
        do {
            let models = try await AsrModels.downloadAndLoad(version: version, encoderComputeUnits: units) { p in
                guard first else { return }
                // The library counts the download as the first half and preparing the model as the second.
                switch p.phase {
                case .downloading(_, let files) where files > 0: reporter.report(.downloadingModel, p.fractionCompleted * 2)
                case .compiling: reporter.report(.loadingModel, nil)
                default: break
                }
            }
            try Task.checkCancellation()
            try await asr.loadModels(models)
            Mark.at("asr \(version) loaded")
            tick(0)
            let ticks = Task {
                for try await f in await asr.transcriptionProgressStream { tick(f) }
            }
            defer { ticks.cancel() }
            var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribeDiskBacked(wav, decoderState: &state)
            await asr.cleanup()  // free the model's memory as soon as the pass is done
            Mark.at("asr \(version) done")
            tick(1)
            return result
        } catch {
            await asr.cleanup()
            if Task.isCancelled { throw CancellationError() }
            if case ASRError.invalidAudioData = error {
                throw ScribeError.message("That recording is too short to transcribe.")
            }
            throw error
        }
    }

    /// Copies sentence punctuation and capitals from a second transcript of the same audio onto the
    /// first one's words. Only a word both heard at the same moment is touched, and its letters never change.
    private static func copyPunctuation(from donor: [Segment], onto words: inout [Segment]) {
        func core(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        let donorCores = donor.map { core($0.text) }
        let marks: Set<Character> = [".", "?", "!", ","]
        var from = 0
        for i in words.indices {
            let c = core(words[i].text)
            guard !c.isEmpty else { continue }
            while from < donor.count, donor[from].end < words[i].start - 0.6 { from += 1 }
            var j = from
            var match: Int?
            while j < donor.count, donor[j].start <= words[i].end + 0.6 {
                if donorCores[j] == c {
                    match = j
                    break
                }
                j += 1
            }
            guard let match else { continue }
            from = match + 1
            let d = donor[match].text
            var w = words[i].text
            if let last = w.last, !marks.contains(last) {
                w += String(d.reversed().prefix { marks.contains($0) }.reversed())
            }
            // A capital the donor used only because it began a sentence there is not copied into the
            // middle of a sentence here; a name or "I" is.
            let ends: Set<Character> = [".", "?", "!"]
            let donorStarts = match == 0 || donor[match - 1].text.last.map(ends.contains) == true
            let baseStarts = i == 0 || words[i - 1].text.last.map(ends.contains) == true
            if let dFirst = d.first(where: { $0.isLetter }), dFirst.isUppercase, baseStarts || !donorStarts,
                let at = w.firstIndex(where: { $0.isLetter }), w[at].isLowercase
            {
                w.replaceSubrange(at...at, with: w[at].uppercased())
            }
            words[i].text = w
        }
    }

    private static func words(from tokens: [TokenTiming]) -> [Segment] {
        var words: [Segment] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { words.append(Segment(start: start, end: end, text: t)) }
            text = ""
        }
        for tok in tokens {
            let piece = tok.token.replacingOccurrences(of: "▁", with: " ")
            if piece.hasPrefix(" ") || text.isEmpty {
                flush()
                start = tok.startTime
            }
            text += piece
            end = tok.endTime
        }
        flush()
        return words
    }

    /// Groups words into pieces that end at a sentence end, a long pause or a change of speaker, and
    /// are never longer than the limits. The first piece of each speaker's turn starts with a capital.
    private static func group(_ words: [Segment], maxChars: Int, maxSeconds: Double) -> [Segment] {
        var out: [Segment] = []
        var from = 0
        var chars = 0
        func flush(_ to: Int) {
            guard to > from else { return }
            var text = words[from..<to].map(\.text).joined(separator: " ")
            if out.last?.speaker != words[from].speaker || out.isEmpty { text = text.prefix(1).uppercased() + text.dropFirst() }
            out.append(Segment(start: words[from].start, end: words[to - 1].end, text: text, speaker: words[from].speaker))
            from = to
            chars = 0
        }
        for (i, w) in words.enumerated() {
            if i > from {
                if w.speaker != words[from].speaker {
                    flush(i)
                } else if chars + w.text.count + 1 > maxChars || w.end - words[from].start > maxSeconds {
                    // Too long with no sentence end in sight: break at the widest pause in the later
                    // half of the run (a comma counts as a short pause) instead of wherever the limit fell.
                    var (cut, widest) = (i, -1.0)
                    for k in max(from + 1, (from + i + 1) / 2)...i {
                        let pause = words[k].start - words[k - 1].end + (words[k - 1].text.hasSuffix(",") ? 0.2 : 0)
                        if pause >= widest { (cut, widest) = (k, pause) }
                    }
                    flush(cut)
                    chars = words[cut..<i].reduce(0) { $0 + $1.text.count + 1 }
                }
            }
            chars += w.text.count + 1
            let pauseAfter = i + 1 < words.count ? words[i + 1].start - w.end : 0
            if endsSentence(words, i) || pauseAfter > 1.2 { flush(i + 1) }
        }
        flush(words.count)
        return out
    }

    // MARK: - Audio

    /// Decodes anything macOS can read into the 16 kHz mono wav: what you would hear playing the
    /// file, with every channel mixed in. Returns false (or throws) when it cannot, and the caller
    /// falls back to ffmpeg.
    private static func decode(_ media: URL, to wav: URL, reporter: Reporter) async throws -> Bool {
        // Screen recorders often keep the microphone and the computer's sound as two tracks that play
        // together. Those need the (slower) mixing reader; everything else takes the fast path.
        var playing: [AVAssetTrack] = []
        let asset = AVURLAsset(url: media)
        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] where (try? await track.load(.isEnabled)) == true {
            playing.append(track)
        }
        guard FileManager.default.createFile(atPath: wav.path, contents: wavHeader(dataBytes: 0)) else { return false }
        let handle = try FileHandle(forWritingTo: wav)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var bytes = 0

        if playing.count > 1 {
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: playing,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            // The mixer adds channels and tracks at full level, which clips; this keeps the sum in range.
            let mix = AVMutableAudioMix()
            mix.inputParameters = playing.map {
                let level = AVMutableAudioMixInputParameters(track: $0)
                level.setVolume(0.7071 / Float(playing.count).squareRoot(), at: .zero)
                return level
            }
            output.audioMix = mix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading() else { return false }
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let data = try sample.dataBuffer?.dataBytes() else { continue }
                try handle.write(contentsOf: data)
                bytes += data.count
                if seconds > 0 { reporter.report(.extractingAudio, sample.presentationTimeStamp.seconds / seconds) }
            }
            guard reader.status == .completed else { return false }
        } else {
            let file = try AVAudioFile(forReading: media)
            let source = file.processingFormat
            guard file.length > 0,
                let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                let converter = AVAudioConverter(from: source, to: target),
                let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 32_768),
                let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768)
            else { return false }
            converter.downmix = true  // mix the channels; the default keeps only the left one
            var failure: Error?
            var status = AVAudioConverterOutputStatus.haveData
            while status != .endOfStream {
                try Task.checkCancellation()
                outBuffer.frameLength = 0
                var convertError: NSError?
                status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
                    let remaining = file.length - file.framePosition
                    do {
                        if remaining > 0 { try file.read(into: inBuffer, frameCount: AVAudioFrameCount(min(remaining, 32_768))) }
                    } catch { failure = error }
                    guard remaining > 0, failure == nil, inBuffer.frameLength > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
                if let error = failure ?? convertError { throw error }
                if status == .error { return false }
                let count = Int(outBuffer.frameLength) * 2
                if count > 0, let samples = outBuffer.int16ChannelData?.pointee {
                    try handle.write(contentsOf: Data(bytes: samples, count: count))
                    bytes += count
                }
                reporter.report(.extractingAudio, Double(file.framePosition) / Double(file.length))
            }
        }
        guard bytes > 0 else { return false }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(dataBytes: bytes))
        return true
    }

    private static func wavHeader(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    // MARK: - External tools (yt-dlp for links, ffmpeg for formats macOS can't read)

    private static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    private static func tool(_ name: String) throws -> URL {
        for dir in toolPath.split(separator: ":") {
            let url = URL(fileURLWithPath: "\(dir)/\(name)")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw ScribeError.missingTool(name)
    }

    /// The input as a link, or nil when it is a file path. Accepts a link typed without a scheme
    /// ("www.example.com", "youtu.be/…") and one pasted with other text around it.
    private static func link(from input: String) -> String? {
        if input.hasPrefix("/") || input.hasPrefix("~") || input.hasPrefix("file://") { return nil }
        if let r = input.range(of: "https://", options: .caseInsensitive) ?? input.range(of: "http://", options: .caseInsensitive) {
            return String(input[r.lowerBound...].prefix { !$0.isWhitespace })
        }
        if input.contains(" ") || FileManager.default.fileExists(atPath: input) { return nil }
        let host = input.prefix { $0 != "/" }
        let looksLikeOne = host.contains(".") && (input.contains("/") || input.lowercased().hasPrefix("www."))
        return looksLikeOne && URL(string: "https://" + input)?.host != nil ? "https://" + input : nil
    }

    // MARK: - Playlists and channels

    /// A recording downloaded ahead of its turn, in a folder of its own.
    struct Fetched: Sendable {
        let file: URL
        let folder: URL
        let title: String?
        let thumbnail: String?
    }

    /// Downloads a link's audio now so that its job can start on it the moment the one before finishes.
    static func fetch(_ link: String) async throws -> Fetched {
        // Named after this process so a later run removes it if the app is killed first.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(getpid())-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seen = OSAllocatedUnfairLock<(title: String?, thumbnail: String?)>(initialState: (nil, nil))
        let reporter = Reporter { p in seen.withLock { $0 = (p.title ?? $0.title, p.thumbnail ?? $0.thumbnail) } }
        reporter.report(.downloading, nil)
        do {
            let file = try await download(link, into: folder, reporter: reporter)
            let (title, thumbnail) = seen.withLock { $0 }
            return Fetched(file: file, folder: folder, title: title, thumbnail: thumbnail)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// True for a link that names many recordings (a playlist or a channel) rather than one.
    /// A video opened from inside a playlist ("watch?v=…&list=…") still counts as that one video.
    static func isCollection(_ input: String) -> Bool {
        guard let link = link(from: input), let parts = URLComponents(string: link), let host = parts.host?.lowercased()
        else { return false }
        let path = parts.path.lowercased()
        if host.hasSuffix("youtube.com") {
            return path == "/playlist" || ["/@", "/channel/", "/c/", "/user/"].contains { path.hasPrefix($0) }
        }
        if host.hasSuffix("soundcloud.com") { return path.contains("/sets/") }
        return path.contains("/playlist")
    }

    /// Lists what a playlist or channel holds, in the site's own order (channels: newest first),
    /// without downloading anything.
    static func list(_ input: String, limit: Int = 500) async throws -> LinkList {
        guard var link = link(from: input) else { throw ScribeError.message("That is not a link.") }
        var isChannel = false
        // A bare channel address lists its videos, then its shorts, then its streams; ask for the videos.
        if let parts = URLComponents(string: link), parts.host?.lowercased().hasSuffix("youtube.com") == true {
            let pieces = parts.path.split(separator: "/")
            let isRoot = pieces.count == 1 && pieces[0].hasPrefix("@")
                || pieces.count == 2 && ["channel", "c", "user"].contains(pieces[0].lowercased())
            if isRoot { link = "https://www.youtube.com" + parts.path + "/videos" }
            isChannel = parts.path.lowercased() != "/playlist"
        }
        var items: [LinkItem] = []
        var title: String?
        let result = try await run(
            try tool("yt-dlp"),
            [
                "--ignore-config", "--no-warnings", "--flat-playlist", "--playlist-end", "\(limit + 1)",
                "--socket-timeout", "20", "--retries", "3",
                "--print", "%(playlist_title)s\t%(duration)s\t%(url)s\t%(webpage_url)s\t%(thumbnails.0.url)s\t%(title)s",
                link,
            ]
        ) { line in
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let url = [f[2], f[3]].first(where: { $0.hasPrefix("http") }) else { return }
            if f[5].hasPrefix("[Private video]") || f[5].hasPrefix("[Deleted video]") { return }
            if title == nil, f[0] != "NA" { title = f[0] }
            items.append(
                LinkItem(
                    title: f[5] == "NA" ? url : f[5], url: url, seconds: Double(f[1]),
                    thumbnail: f[4].hasPrefix("http") ? f[4] : nil))
        }
        if items.isEmpty {
            throw ScribeError.message(result.status == 0 ? "No videos were found at that link." : linkError(result.errors))
        }
        var name = title ?? "Playlist"
        for suffix in [" - Videos", " - Shorts", " - Live"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return LinkList(title: name, items: Array(items.prefix(limit)), more: items.count > limit, isChannel: isChannel)
    }

    /// Downloads a link's audio. A site that refuses or drops the connection is asked once more
    /// after a short pause, since that is usually momentary.
    private static func download(_ link: String, into dir: URL, reporter: Reporter) async throws -> URL {
        do { return try await downloadOnce(link, into: dir, reporter: reporter) } catch let error as ScribeError {
            guard case .message(let why) = error, why.contains("refused the download") || why.contains("connection failed") else { throw error }
            try await Task.sleep(for: .seconds(2))
            return try await downloadOnce(link, into: dir, reporter: reporter)
        }
    }

    private static func downloadOnce(_ link: String, into dir: URL, reporter: Reporter) async throws -> URL {
        var path: String?
        let result = try await run(
            try tool("yt-dlp"),
            [
                "--ignore-config", "--no-playlist", "--playlist-items", "1", "--match-filter", "!is_live",
                "--no-warnings", "--quiet", "--no-simulate", "--no-cache-dir", "--no-mtime",
                "--socket-timeout", "20", "--retries", "3",
                // The smallest audio-only stream that still transcribes well, in the original language.
                "-S", "lang,+abr", "-f", "ba[abr>=44]/ba/b",
                "-P", dir.path, "-o", "media.%(ext)s",
                "--progress", "--newline",
                "--progress-template",
                "download:P|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
                "--print", "before_dl:T|%(title)s", "--print", "before_dl:I|%(thumbnail)s", "--print", "before_dl:D|%(duration)s", "--print", "after_move:F|%(filepath)s",
                link,
            ]
        ) { line in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "T": reporter.setTitle(String(parts[1]))
            case "I": if parts[1].hasPrefix("http") { reporter.setThumbnail(String(parts[1])) }
            case "D": if let seconds = Double(parts[1]) { reporter.setAudio(seconds: seconds) }
            case "F": path = String(parts[1])
            case "P":
                let n = parts[1].split(separator: "|").map { Double($0) }
                if n.count == 3, let got = n[0], let total = n[1] ?? n[2], total > 0 {
                    reporter.report(.downloading, got / total)
                }
            default: break
            }
        }
        if result.status != 0 { throw ScribeError.message(linkError(result.errors)) }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            throw ScribeError.message("There is no video or audio at that link.")
        }
        return URL(fileURLWithPath: path)
    }

    /// Turns yt-dlp's error output into one plain sentence.
    private static func linkError(_ stderr: String) -> String {
        let raw = stderr.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? stderr
        let e = raw.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { e.contains($0) } }
        if has("nodename nor servname", "name or service not known", "failed to resolve", "name resolution") {
            return "Could not reach that site. Check the address and your internet connection."
        }
        if has("network is unreachable", "no route to host", "timed out", "connection refused", "connection reset",
            "connection aborted", "network is down") {
            return "The connection failed. Check your internet connection and try again."
        }
        if has("private video", "is private", "video is private") { return "That video is private." }
        if has("http error 404", "http error 410") { return "Nothing was found at that link. Check the address." }
        if has("members-only", "members only", "join this channel", "premium members", "subscribers only", "requires payment",
            "purchase", "rental", "paywall") {
            return "That link is only available to paying members."
        }
        if has("not available in your country", "geo-restrict", "geo restrict", "from your location", "in your region") {
            return "That link is not available in your region."
        }
        if has("does not pass filter", "live event", "is live", "premieres in", "will begin in") {
            return "That is a live or upcoming stream. Try again once it has finished."
        }
        if has("sign in", "logged-in", "logged in", "log in", "login required", "--cookies", "age-restricted", "confirm your age",
            "http error 401") {
            return "That link needs a signed-in account, so it cannot be downloaded."
        }
        if has("drm") { return "That link is copy-protected and cannot be downloaded." }
        if has("unsupported url", "no video formats", "no media found") { return "There is no video or audio at that link." }
        if has("unavailable", "has been removed", "been deleted", "does not exist", "account associated", "terminated") {
            return "That link is unavailable. It may have been removed or the address is wrong."
        }
        if has("http error 403", "http error 429", "forbidden") {
            return "That site refused the download. Try again later."
        }
        let detail = raw.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? "That link could not be downloaded." : "That link could not be downloaded: \(detail.prefix(200))"
    }

    private static func extractAudio(_ media: URL, to wav: URL, reporter: Reporter) async throws {
        var total = 0.0
        func seconds(_ clock: Substring) -> Double {
            clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        let result = try await run(
            try tool("ffmpeg"),
            [
                "-nostdin", "-y", "-hide_banner", "-nostats", "-progress", "pipe:1", "-i", media.path,
                "-vn", "-sn", "-dn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav", wav.path,
            ],
            onError: { line in
                // "  Duration: 00:16:53.42, start: ..."
                if total == 0, let r = line.range(of: "Duration: ") {
                    total = seconds(line[r.upperBound...].prefix { $0 != "," })
                }
            }
        ) { line in
            if total > 0, line.hasPrefix("out_time="), !line.contains("N/A") {
                reporter.report(.extractingAudio, seconds(line.dropFirst(9)) / total)
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
        if result.status != 0 || size <= 44 {
            let e = result.errors.lowercased()
            if e.contains("does not contain any stream") || e.contains("matches no streams") || (result.status == 0 && size <= 44) {
                throw ScribeError.noAudio
            }
            if e.contains("invalid data found") || e.contains("moov atom not found") {
                throw ScribeError.message("That file is not a video or audio file Scribe can read.")
            }
            let last = result.errors.split(separator: "\n").last.map(String.init) ?? "unknown error"
            throw ScribeError.message("Could not read that file: \(last.prefix(200))")
        }
    }

    /// Runs a tool at utility priority, feeding its output a line at a time. Cancelling the task
    /// terminates the tool and throws `CancellationError`.
    private static func run(
        _ exe: URL, _ args: [String], onError: ((String) -> Void)? = nil, onLine: @escaping (String) -> Void
    ) async throws -> (status: Int32, errors: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.qualityOfService = .utility
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let process = p
        nonisolated(unsafe) let (onLine, onError) = (onLine, onError)
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        let result: (Int32, String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    do { try process.run() } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    // Cancelled in the instant before the tool started: the handler below found nothing to stop.
                    if cancelled.withLock({ $0 }) { process.terminate() }
                    func lines(_ handle: FileHandle, _ each: (String) -> Void) {
                        var pending = Data()
                        while case let chunk = handle.availableData, !chunk.isEmpty {
                            var rest = chunk[...]
                            while let nl = rest.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                                pending.append(rest[..<nl])
                                if !pending.isEmpty { each(String(decoding: pending, as: UTF8.self)) }
                                pending.removeAll(keepingCapacity: true)
                                rest = rest[(nl + 1)...]
                            }
                            pending.append(rest)
                        }
                        if !pending.isEmpty { each(String(decoding: pending, as: UTF8.self)) }
                    }
                    var errors: [String] = []
                    let group = DispatchGroup()
                    DispatchQueue.global(qos: .utility).async(group: group) {
                        lines(err.fileHandleForReading) { line in
                            onError?(line)
                            errors.append(line)
                            if errors.count > 40 { errors.removeFirst() }
                        }
                    }
                    lines(out.fileHandleForReading, onLine)
                    group.wait()
                    process.waitUntilExit()
                    cont.resume(returning: (process.terminationStatus, errors.joined(separator: "\n")))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return result
    }
}

/// Several pieces of work that must all finish: the reported fraction is that of the one furthest behind.
private final class Pace: @unchecked Sendable {
    private let lock = NSLock()
    private var done: [Double]
    private let report: @Sendable (Double) -> Void

    init(lanes: Int, _ report: @escaping @Sendable (Double) -> Void) {
        done = Array(repeating: 0, count: lanes)
        self.report = report
    }

    func set(_ lane: Int, _ fraction: Double) {
        let slowest = lock.withLock { () -> Double in
            if lane < done.count { done[lane] = max(done[lane], fraction) }
            return done.min() ?? 0
        }
        report(slowest)
    }
}

/// Funnels progress from concurrent work into one forward-only, lightly throttled stream.
private final class Reporter: @unchecked Sendable {
    private let handler: ProgressHandler
    private let lock = NSLock()
    private var stage: Stage?
    private var fraction: Double?
    private var storedTitle: String?
    private var speakerFraction = 0.0
    private var speakerSent = 0.0
    private var wordsDone = false

    init(_ handler: @escaping ProgressHandler) { self.handler = handler }

    var title: String? { lock.withLock { storedTitle } }

    private var thumbnail: String?
    private var audioSeconds: Double?

    /// Every report carries what is known about the recording and what the job is costing right now.
    private func make(_ stage: Stage, _ fraction: Double?, speakers: Double? = nil) -> Progress {
        Progress(
            stage: stage, fraction: fraction, title: storedTitle, speakers: speakers,
            thumbnail: thumbnail, audioSeconds: audioSeconds, memoryMB: Self.footprintMB())
    }

    private static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }

    func setTitle(_ title: String) {
        let update = lock.withLock { () -> Progress? in
            storedTitle = title
            return stage.map { make($0, fraction) }
        }
        if let update { handler(update) }
    }

    func setThumbnail(_ url: String) {
        let update = lock.withLock { () -> Progress? in
            thumbnail = url
            return stage.map { make($0, fraction) }
        }
        if let update { handler(update) }
    }

    func setAudio(seconds: Double) {
        lock.withLock { audioSeconds = seconds > 0 ? seconds : nil }
    }

    func report(_ newStage: Stage, _ newFraction: Double?) {
        let update = lock.withLock { () -> Progress? in
            if let stage, newStage < stage { return nil }
            let f = newFraction.map { min(max($0, 0), 1) }
            if newStage == stage {
                guard let f else { return nil }
                if let fraction, f < fraction + 0.004, f < 1 || fraction >= 1 { return nil }
            }
            stage = newStage
            fraction = f
            return make(newStage, f, speakers: newStage == .transcribing && speakerFraction > 0 ? speakerFraction : nil)
        }
        if let update { handler(update) }
    }

    /// Diarization progress only becomes the visible stage once the words are finished; until then
    /// it rides along on the transcribing stage as `Progress.speakers`.
    func speakers(_ f: Double) {
        var update: Progress?
        let visible = lock.withLock { () -> Bool in
            speakerFraction = f
            if !wordsDone, stage == .transcribing, f >= speakerSent + 0.01 {
                speakerSent = f
                update = make(.transcribing, fraction, speakers: f)
            }
            return wordsDone
        }
        if let update { handler(update) }
        if visible { report(.identifyingSpeakers, f) }
    }

    /// The words are finished. If speakers are still being worked out, that becomes the visible stage:
    /// with no fraction until the diarizer reports, and at 1 while it finishes the part it does not measure.
    func speechDone(awaitingSpeakers: Bool) {
        let f = lock.withLock { () -> Double in
            wordsDone = true
            return speakerFraction
        }
        if awaitingSpeakers { report(.identifyingSpeakers, f > 0 ? min(f, 1) : nil) }
    }
}
