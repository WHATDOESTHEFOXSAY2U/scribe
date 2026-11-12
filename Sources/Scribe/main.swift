import Foundation

// With no arguments this is the windowed app. With a file path or link it is a
// command-line tool (see `CommandLineTool`):  scribe <file-or-link>... [options]
let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }

// The CLI talks on a private copy of stderr and silences the original, which the audio library
// writes profiling lines to.
let terminal = FileHandle(fileDescriptor: dup(2))
func say(_ text: String) { terminal.write(Data(text.utf8)) }

if args.isEmpty {
    ScribeApp.main()
} else if args[0] == "--snapshot" {
    // Hidden: draws every window state to PNG files, for checking the design without a screen.
    MainActor.assumeIsolated { Snapshot.run(into: args.count > 1 ? args[1] : "snapshots") }
} else {
    CommandLineTool.run(args)
}

/// Scribe without the window: `scribe <file-or-link>…`. The transcript goes to standard output (or
/// to `-o`), progress and errors go to standard error, and the exit status says how it went, so it
/// works the same from a shell, a script or an AI agent.
enum CommandLineTool {
    static let help = """
        Scribe transcribes video and audio on this Mac. Nothing is uploaded.

        usage: scribe <file-or-link>... [options]

          scribe talk.mp4                          print the transcript
          scribe talk.mp4 -o talk.txt              save it
          scribe "https://youtu.be/ID" --json      structured output with timestamps
          scribe a.mp4 b.mp4 -o transcripts/       several recordings, one file each
          scribe <playlist-or-channel-link> --limit 5 -o transcripts/

        options:
          -o, --output <path>   a file for one recording, a folder for several
          --format <f>          txt (default), timestamps, srt or json
          --json, --srt, --timestamps   short for --format
          --limit <n>           recordings to take from a playlist or channel (default 10)
          --no-speakers         skip speaker labels (faster)
          --fast                skip the punctuation pass (faster, plainer punctuation)
          -q, --quiet           no progress on standard error
          --version             print the version
          -h, --help            print this

        The transcript is written to standard output unless -o is given; progress and errors go
        to standard error. Exit status: 0 done, 1 a recording failed, 2 bad usage, 130 cancelled.
        A failure prints one line starting "error:"; download failures are often momentary, so
        trying again is reasonable. Links are downloaded with yt-dlp; the audio never leaves this Mac.

        --json prints one object per recording (an array when there are several):
          title, source, durationSeconds, speakers (how many), model, text,
          segments: [{ start, end, text, speaker }]   times in seconds; speaker (1, 2, …) only
                                                       when more than one person is heard

        """

    struct Options {
        var inputs: [String] = []
        var output: String?
        var format = "txt"
        var limit = 10
        var speakers = true
        var quiet = false
        var job = false
    }

    /// What `--json` prints for one recording.
    struct Record: Encodable {
        struct Piece: Encodable {
            let start: Double
            let end: Double
            let speaker: Int?
            let text: String
        }
        let title: String
        let source: String
        let durationSeconds: Double
        let speakers: Int
        let model: String
        let text: String
        let segments: [Piece]
    }

    static func usageError(_ message: String) -> Never {
        say("scribe: \(message)\nTry: scribe --help\n")
        exit(2)
    }

    static func run(_ args: [String]) -> Never {
        var o = Options()
        var i = 0
        func value(_ flag: String) -> String {
            i += 1
            guard i < args.count else { usageError("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help":
                print(help, terminator: "")
                exit(0)
            case "--version":
                print("scribe " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") + " (" + Engine.modelName + ")")
                exit(0)
            case "--srt": o.format = "srt"
            case "--json": o.format = "json"
            case "--timestamps": o.format = "timestamps"
            case "--format":
                o.format = value(a)
                guard ["txt", "timestamps", "srt", "json"].contains(o.format) else { usageError("unknown format \"\(o.format)\"") }
            case "--limit":
                guard let n = Int(value(a)), n > 0 else { usageError("--limit needs a number above zero") }
                o.limit = n
            case "--no-speakers": o.speakers = false
            case "--fast": Engine.polish = false
            case "-q", "--quiet": o.quiet = true
            case "-o", "--output": o.output = value(a)
            case "--title": Engine.titleOverride = value(a)  // the window passes the real title of a recording it downloaded
            case "--job":  // how the window runs one job in a child process (see Engine.transcribeInChild)
                o.inputs = [value(a)]
                o.job = true
            case _ where a.hasPrefix("-") && a.count > 1: usageError("unknown option \(a)")
            default: o.inputs.append(a)
            }
            i += 1
        }
        guard !o.inputs.isEmpty else { usageError("nothing to transcribe") }

        freopen("/dev/null", "w", stderr)
        // Ctrl-C, a closed terminal or a stop from the window cancels the work, so child tools stop
        // and temporary files are removed.
        nonisolated(unsafe) var work: Task<Void, Never>?
        var sources: [DispatchSourceProtocol] = [SIGINT, SIGTERM, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { work?.cancel() }
            source.resume()
            return source
        }
        if o.job {
            // A job run for the window must not outlive it, even if the window is force-quit.
            let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
            parent.setEventHandler { work?.cancel() }
            parent.resume()
            sources.append(parent)
        }
        let options = o
        work = Task { options.job ? await runJob(options) : await transcribeAll(options) }
        withExtendedLifetime(sources) { dispatchMain() }
    }

    /// One recording for the window: progress and the result as JSON lines on standard output.
    static func runJob(_ o: Options) async -> Never {
        let wire = WireOut()
        do {
            let t = try await Engine.transcribe(input: o.inputs[0], speakers: o.speakers) { wire.send(Engine.Wire(progress: $0)) }
            wire.send(Engine.Wire(transcript: t))
            exit(0)
        } catch is CancellationError {
            exit(130)
        } catch {
            var reply = Engine.Wire(error: error.localizedDescription)
            if case ScribeError.missingTool(let tool) = error { reply.missingTool = tool }
            wire.send(reply)
            exit(1)
        }
    }

    static func transcribeAll(_ o: Options) async -> Never {
        func note(_ text: String) { if !o.quiet { say(text) } }
        // Playlists and channels open out into their recordings.
        var items: [(input: String, name: String?)] = []
        for input in o.inputs {
            if Engine.isCollection(input) {
                do {
                    note("Reading the list…\n")
                    let list = try await Engine.list(input, limit: o.limit)
                    note("\(list.title): taking \(list.more ? "the first \(list.items.count)" : "all \(list.items.count)")\n")
                    let digits = max(2, String(min(o.limit, list.items.count)).count)
                    for (n, item) in list.items.prefix(o.limit).enumerated() {
                        items.append((item.url, String(format: "%0\(digits)d ", n + 1) + item.title))
                    }
                } catch is CancellationError {
                    say("cancelled\n")
                    exit(130)
                } catch {
                    say("error: \(error.localizedDescription)\n")
                    exit(1)
                }
            } else {
                items.append((input, nil))
            }
        }

        // Where the text goes: a folder (one file per recording), one file, or standard output.
        let ext = ["txt": "txt", "timestamps": "txt", "srt": "srt", "json": "json"][o.format] ?? "txt"
        var folder: URL?
        var file: String?
        if let output = o.output {
            let path = (output as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if items.count > 1 || output.hasSuffix("/") || (exists && isDirectory.boolValue) {
                folder = URL(fileURLWithPath: path)
                do { try FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true) } catch {
                    say("error: \(error.localizedDescription)\n")
                    exit(1)
                }
            } else {
                file = path
            }
        }

        var failed = 0
        var records: [String] = []
        for (n, item) in items.enumerated() {
            if items.count > 1 { note("[\(n + 1)/\(items.count)] \(item.name ?? item.input)\n") }
            let status = StatusLine(quiet: o.quiet)
            do {
                let t = try await Engine.transcribe(input: item.input, speakers: o.speakers) { status.show($0) }
                status.finish()
                let text: String
                switch o.format {
                case "srt": text = t.srt
                case "timestamps": text = t.timestamped
                case "json":
                    let record = Record(
                        title: t.title, source: item.input, durationSeconds: (t.audioSeconds * 100).rounded() / 100,
                        speakers: t.speakerCount, model: Engine.modelName, text: t.plain,
                        segments: t.sentences.map {
                            Record.Piece(start: ($0.start * 100).rounded() / 100, end: ($0.end * 100).rounded() / 100, speaker: $0.speaker, text: $0.text)
                        })
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                    text = String(decoding: try encoder.encode(record), as: UTF8.self)
                default: text = t.plain
                }
                if let folder {
                    let name = Model.fileName(item.name ?? t.title) + "." + ext
                    try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    note("saved \(folder.appendingPathComponent(name).path)\n")
                } else if let file {
                    try? FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: file).deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Written whole or not at all; a device such as /dev/null cannot be swapped in, so it is written directly.
                    do { try text.write(toFile: file, atomically: true, encoding: .utf8) } catch let failure {
                        do { try text.write(toFile: file, atomically: false, encoding: .utf8) } catch { throw failure }
                    }
                } else if o.format == "json" {
                    records.append(text)
                } else {
                    // Several recordings on standard output are told apart by a title line.
                    print(items.count > 1 ? "# \(t.title)\n\n\(text)\n" : text)
                }
                if t.fullText.isEmpty { note("No speech was found in this recording.\n") }
                if let warning = t.speakerNote { note(warning + "\n") }
                note(
                    String(
                        format: "%@ of audio in %.1fs (%.0f× real time)%@\n",
                        Transcript.clock(t.audioSeconds), t.wallSeconds, t.audioSeconds / max(t.wallSeconds, 0.01),
                        t.hasSpeakers ? ", \(t.speakerCount) speakers" : ""))
            } catch is CancellationError {
                status.finish()
                say("cancelled\n")
                exit(130)
            } catch {
                status.finish()
                failed += 1
                say("error: \(items.count > 1 ? (item.name ?? item.input) + ": " : "")\(error.localizedDescription)\n")
            }
        }
        // JSON on standard output is always one valid document: an object for one recording, an array for several.
        if !records.isEmpty { print(items.count > 1 ? "[\n" + records.joined(separator: ",\n") + "\n]" : records[0]) }
        exit(failed == 0 ? 0 : 1)
    }
}

/// Writes one JSON line at a time to standard output, for the window that started this job.
final class WireOut: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    func send(_ wire: Engine.Wire) {
        guard var data = try? encoder.encode(wire) else { return }
        data.append(10)
        lock.withLock { FileHandle.standardOutput.write(data) }
    }
}

/// Prints each stage once; on a terminal it also keeps a live percentage on the line.
final class StatusLine: @unchecked Sendable {
    private let lock = NSLock()
    private let live = isatty(terminal.fileDescriptor) != 0
    private let quiet: Bool
    private var stage: Stage?
    private var percent = -1

    init(quiet: Bool = false) { self.quiet = quiet }

    func show(_ p: Progress) {
        lock.withLock {
            guard !quiet, p.stage != .done else { return }
            let pct = p.fraction.map { Int($0 * 100) } ?? -1
            if p.stage != stage {
                if live, stage != nil { say("\n") }
                say(live ? "\r\(p.stage.label)…" : "\(p.stage.label)…\n")
            } else if !live || pct == percent {
                return
            }
            if live, pct >= 0 { say("\r\(p.stage.label)… \(pct)%") }
            (stage, percent) = (p.stage, pct)
        }
    }

    func finish() {
        lock.withLock { if live, stage != nil { say("\n") } }
    }
}
