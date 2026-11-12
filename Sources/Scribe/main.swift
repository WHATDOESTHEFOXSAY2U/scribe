import Foundation

// With no arguments this is the windowed app. With a file path or link it is a
// command-line tool:  scribe <file-or-link> [--srt | --timestamps] [--no-speakers] [--fast] [-o output]
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
    let usage = "usage: scribe <file-or-link> [--srt | --timestamps] [--no-speakers] [--fast] [-o output]\n"
    var input: String?
    var output: String?
    var format = "txt"  // or "srt", "times", "job"
    var speakers = true
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--srt": format = "srt"
        case "--timestamps": format = "times"
        case "--no-speakers": speakers = false
        case "--fast": Engine.polish = false
        case "--title":  // the window passes the real title of a recording it has already downloaded
            i += 1
            if i < args.count { Engine.titleOverride = args[i] }
        case "-o", "--job":  // --job <input> is how the window runs a job in a child process (see Engine.transcribeInChild)
            guard i + 1 < args.count else {
                say(usage)
                exit(2)
            }
            if args[i] == "-o" { output = args[i + 1] } else { (input, format) = (args[i + 1], "job") }
            i += 1
        case let flag where flag.hasPrefix("-"):
            say(usage)
            exit(flag == "--help" || flag == "-h" ? 0 : 2)
        default: input = args[i]
        }
        i += 1
    }
    guard let input else {
        say(usage)
        exit(2)
    }
    let asJob = format == "job"
    freopen("/dev/null", "w", stderr)
    let status = StatusLine()
    let wire = WireOut()
    // Ctrl-C, a closed terminal or a stop from the window cancels the job, so child tools stop and
    // temporary files are removed.
    nonisolated(unsafe) var job: Task<Void, Never>?
    var sources: [DispatchSourceProtocol] = [SIGINT, SIGTERM, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { job?.cancel() }
        source.resume()
        return source
    }
    if asJob {
        // A job run for the window must not outlive it, even if the window is force-quit.
        let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
        parent.setEventHandler { job?.cancel() }
        parent.resume()
        sources.append(parent)
    }
    job = Task { [output, format, speakers] in
        do {
            let t = try await Engine.transcribe(input: input, speakers: speakers) {
                if asJob { wire.send(Engine.Wire(progress: $0)) } else { status.show($0) }
            }
            if asJob {
                wire.send(Engine.Wire(transcript: t))
                exit(0)
            }
            status.finish()
            let text = format == "srt" ? t.srt : format == "times" ? t.timestamped : t.plain
            if let output {
                // Written whole or not at all; a device such as /dev/null cannot be swapped in, so it is written directly.
                let path = (output as NSString).expandingTildeInPath
                do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch let failure {
                    do { try text.write(toFile: path, atomically: false, encoding: .utf8) } catch { throw failure }
                }
            } else {
                print(text)
            }
            if t.fullText.isEmpty { say("No speech was found in this recording.\n") }
            if let note = t.speakerNote { say(note + "\n") }
            say(
                String(
                    format: "%@ of audio in %.1fs (%.0f× real time)%@\n",
                    Transcript.clock(t.audioSeconds), t.wallSeconds, t.audioSeconds / max(t.wallSeconds, 0.01),
                    t.hasSpeakers ? ", \(t.speakerCount) speakers" : ""))
            exit(0)
        } catch is CancellationError {
            status.finish()
            say("cancelled\n")
            exit(130)
        } catch {
            status.finish()
            var reply = Engine.Wire(error: error.localizedDescription)
            if case ScribeError.missingTool(let tool) = error { reply.missingTool = tool }
            if asJob { wire.send(reply) } else { say("error: \(error.localizedDescription)\n") }
            exit(1)
        }
    }
    withExtendedLifetime(sources) { dispatchMain() }
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
    private var stage: Stage?
    private var percent = -1

    func show(_ p: Progress) {
        lock.withLock {
            guard p.stage != .done else { return }
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
