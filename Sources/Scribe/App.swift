import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// Everything the window shows. One instance drives the app; snapshots build their own.
@MainActor
@Observable
final class Model {
    enum Phase {
        case empty
        case working
        case looking  // reading what a playlist or channel holds
        case choose(LinkList)
        case batch
        case result(Transcript)
        case failed(message: String, command: String?)
    }

    static let shared = Model(persist: true)

    private(set) var phase: Phase = .empty
    var link = ""
    var dropTargeted = false

    // Progress, already reduced to what the eye can use: a whole percent and a stage.
    private(set) var stage: Stage = .extractingAudio
    private(set) var percent = 0
    private(set) var determinate = false
    private(set) var title: String?
    private(set) var slowLoad = false
    // What the job is doing to the machine, shown while it works.
    private(set) var thumbnail: String?
    private(set) var audioSeconds: Double?
    private(set) var memoryMB: Int?
    private(set) var speed: Int?
    /// Seconds this recording still needs, when that can be worked out honestly.
    private(set) var secondsLeft: Int?
    private(set) var copied = false

    // Preferences.
    var showTimes: Bool { didSet { store(showTimes, "showTimes") } }
    var speakers: Bool { didSet { store(speakers, "speakers") } }
    var textSize: Double { didSet { store(textSize, "textSize") } }
    /// The folder finished transcripts are saved in. Asked for once, before the first job, then remembered.
    private(set) var library: URL
    private(set) var libraryChosen: Bool
    @ObservationIgnored private var askingForLibrary = false
    @ObservationIgnored private var heldInputs: [String] = []

    // Every recording asked for this session, in the order it is (or was) worked on. One runs at a
    // time; the rest wait. Leaving a job's screen never stops it.
    struct Job: Identifiable {
        enum State: Equatable { case waiting, working, done(words: Int), failed(String) }
        let id: Int
        var title: String
        let input: String
        var seconds: Double?
        var thumbnail: String? = nil
        /// Where a playlist item's text is saved the moment it is done.
        var saveTo: URL? = nil
        var state = State.waiting
    }
    private(set) var jobs: [Job] = []
    private(set) var running = false
    /// The playlist or channel's name while the whole queue came from one.
    private(set) var queueTitle: String?
    private(set) var queueFolder: URL?
    /// The job whose progress or transcript the window is showing.
    private(set) var watching: Int?
    var batchCount = 10
    var batchFolder: URL?

    /// Changes with every new transcript, so the text view knows when to rebuild.
    private(set) var resultID = 0

    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private var engine: Task<Transcript, Error>?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lookupRun = 0
    @ObservationIgnored private var nextID = 0
    /// Downloads made ahead of their turn, by job. Two at most are ever in flight.
    @ObservationIgnored private var fetches: [Int: Task<Engine.Fetched, Error>] = [:]
    /// Finished transcripts wait here (one small file each) so the queue costs the app no memory.
    @ObservationIgnored private lazy var cache: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(getpid())-jobs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    @ObservationIgnored private var lastInput: String?
    @ObservationIgnored private var overall = 0.0
    @ObservationIgnored private var speakerProgress = 0.0
    @ObservationIgnored private var base: Double?
    @ObservationIgnored private var speedFrom: (time: Date, fraction: Double)?
    @ObservationIgnored private var downloadFrom: Date?

    /// The speed the last job reached on this Mac, for estimates made before the words begin.
    private var usualSpeed: Double {
        let saved = UserDefaults.standard.double(forKey: "usualSpeed")
        return saved > 5 ? saved : 60
    }

    /// "20 s", "3 min", "1 h 10 min": rounded the way a person would say it.
    static func duration(_ seconds: Double) -> String {
        let s = max(1, seconds)
        if s < 10 { return "\(Int(s.rounded(.up))) s" }
        if s < 55 { return "\(Int((s / 5).rounded(.up)) * 5) s" }
        let minutes = Int((s / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
    @ObservationIgnored private var modelDownload: (from: Double, to: Double)?

    init(persist: Bool = false) {
        self.persist = persist
        let d = UserDefaults.standard
        showTimes = persist && d.bool(forKey: "showTimes")
        speakers = !persist || d.object(forKey: "speakers") == nil || d.bool(forKey: "speakers")
        let size = persist ? d.double(forKey: "textSize") : 0
        textSize = size >= 12 && size <= 22 ? size : 15
        let saved = persist ? d.string(forKey: "library") : nil
        library = saved.map { URL(fileURLWithPath: $0) } ?? Self.defaultLibrary
        // Automated self-checks never stop to ask.
        libraryChosen = !persist || saved != nil || ProcessInfo.processInfo.environment["SCRIBE_LIVE_CHECK"] != nil
    }

    private func store(_ value: Any, _ key: String) {
        if persist { UserDefaults.standard.set(value, forKey: key) }
    }

    /// Something is in progress that Stop would stop.
    var isWorking: Bool { if case .looking = phase { true } else { running } }
    var transcript: Transcript? { if case .result(let t) = phase { t } else { nil } }
    var canRetry: Bool { lastInput != nil }
    var isStart: Bool { if case .empty = phase { true } else { false } }
    var doneCount: Int { jobs.count { if case .done = $0.state { true } else { false } } }
    var waitingCount: Int { jobs.count { $0.state == .waiting } }
    var listTitle: String { queueTitle ?? "Transcripts" }
    var windowTitle: String {
        if let transcript { return transcript.title }
        if case .batch = phase { return listTitle }
        return "Scribe"
    }
    /// One line for the start screen saying what is going on behind it; nil when the queue is empty.
    var queueSummary: String? {
        guard !jobs.isEmpty else { return nil }
        if running {
            var text = "Transcribing · \(percent)%"
            if let left = queueTimeLeft { text += " · \(left)" }
            if waitingCount > 0 { text += " · \(waitingCount) waiting" }
            return text
        }
        if waitingCount > 0 { return "\(waitingCount) waiting · stopped" }
        return doneCount == 1 ? "1 transcript" : "\(doneCount) transcripts"
    }

    /// The quiet line under the stage: the recording's name, or what a long one-time step is doing.
    var caption: String {
        switch stage {
        case .downloadingModel: "One-time download of the speech model"
        case .loadingModel where slowLoad: "Preparing the speech model. This takes a moment the first time."
        default: title ?? " "
        }
    }

    private var motion: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)
    }

    // MARK: Jobs

    /// Adds a file or link. Nothing has to finish first: with a job already going, this one waits its turn.
    func start(_ raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .looking = phase { return }
        guard !input.isEmpty else { return }
        // First use: where the transcripts go is the user's call, so ask before doing anything.
        // Everything dropped or pasted meanwhile waits for the answer.
        guard libraryChosen else {
            heldInputs.append(input)
            if !askingForLibrary {
                chooseLibrary { [weak self] in
                    guard let self else { return }
                    let held = self.heldInputs
                    self.heldInputs = []
                    held.forEach { self.start($0) }
                }
            }
            return
        }
        lastInput = input
        link = ""
        if Engine.isCollection(input) { return lookUp(input) }
        let isFile = input.hasPrefix("/") || input.hasPrefix("~") || input.hasPrefix("file://")
        let name = isFile ? URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent : input
        nextID += 1
        add([Job(id: nextID, title: name, input: input)], from: nil)
    }

    private func add(_ new: [Job], from list: (title: String, folder: URL)?) {
        queueTitle = jobs.isEmpty ? list?.title : nil
        if let list { queueFolder = list.folder }
        jobs.append(contentsOf: new)
        // One recording with nothing else going on is watched directly; anything more shows the queue.
        let alone = new.count == 1 && !running && waitingCount == 1
        watching = alone ? new[0].id : nil
        kick()
        withAnimation(motion) { phase = alone ? .working : .batch }
    }

    /// Works through whatever is waiting, one recording at a time, until nothing is.
    private func kick() {
        guard !running, jobs.contains(where: { $0.state == .waiting }) else { return }
        running = true
        generation += 1
        let run = generation
        func index(_ id: Int) -> Int? { jobs.firstIndex { $0.id == id } }
        Task {
            // Without this macOS naps the app when its window is covered, and a job can take ten times longer.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Transcribing")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            while run == generation, let next = jobs.first(where: { $0.state == .waiting }) {
                let id = next.id
                if let i = index(id) { jobs[i].state = .working }
                fetchAhead()
                // A link downloaded while the one before it was being transcribed starts from the file.
                var input = next.input
                var title: String?
                var folder: URL?
                if let early = fetches.removeValue(forKey: id) {
                    resetProgress(for: next.input)
                    if let got = try? await early.value {
                        (input, title, folder) = (got.file.path, got.title ?? next.title, got.folder)
                    }
                }
                defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
                guard run == generation else { return }
                do {
                    let work = job(input, title: title, run: run)
                    if folder != nil { thumbnail = next.thumbnail }
                    let t = try await work.value
                    guard run == generation, let i = index(id) else { return }
                    try? JSONEncoder().encode(t).write(to: cache.appendingPathComponent("\(id).json"))
                    // Every transcript is kept as a text file without being asked: a playlist's in its own
                    // folder, anything else straight in the transcripts folder.
                    let file = next.saveTo ?? library.appendingPathComponent(Self.fileName(t.title) + ".txt")
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let source = next.input.lowercased().hasPrefix("http") ? next.input + "\n" : ""
                    try? "\(t.title)\n\(source)\n\(t.plain)\n".write(to: file, atomically: true, encoding: .utf8)
                    if next.saveTo == nil { jobs[i].title = t.title }
                    jobs[i].seconds = t.audioSeconds
                    jobs[i].state = .done(words: t.sentences.reduce(0) { $0 + $1.text.split(separator: " ").count })
                    if watching == id, case .working = phase {
                        resultID += 1
                        withAnimation(motion) { phase = .result(t) }
                    }
                    announce("Transcript ready")
                } catch is CancellationError {
                    return  // whoever cancelled has already put things in order
                } catch {
                    guard run == generation, let i = index(id) else { return }
                    if watching == id, case .working = phase {
                        if jobs.count == 1 {
                            // The only job: its own screen says what went wrong and offers another try.
                            jobs.remove(at: i)
                            watching = nil
                            fail(error)
                            continue
                        }
                        watching = nil
                        withAnimation(motion) { phase = .batch }
                    }
                    jobs[i].state = .failed(error.localizedDescription)
                }
            }
            guard run == generation else { return }
            running = false
            engine = nil
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// Starts downloading the next two links in the queue, so the network is never what a job waits for.
    private func fetchAhead() {
        let ahead = jobs.filter { $0.state == .waiting && $0.input.lowercased().hasPrefix("http") }.prefix(2)
        for job in ahead where fetches[job.id] == nil {
            let link = job.input
            fetches[job.id] = Task.detached(priority: .utility) { try await Engine.fetch(link) }
        }
    }

    /// Stops downloads made ahead of time and removes whatever they had fetched.
    private func dropFetches(_ ids: [Int]? = nil) {
        for id in ids ?? Array(fetches.keys) {
            guard let task = fetches.removeValue(forKey: id) else { continue }
            task.cancel()
            Task.detached { if let got = try? await task.value { try? FileManager.default.removeItem(at: got.folder) } }
        }
    }

    private func resetProgress(for input: String) {
        (overall, speakerProgress, base, modelDownload, percent, determinate, title, slowLoad) = (0, 0, nil, nil, 0, false, nil, false)
        if let speed, persist { UserDefaults.standard.set(Double(speed), forKey: "usualSpeed") }
        (thumbnail, audioSeconds, memoryMB, speed, speedFrom, secondsLeft, downloadFrom) = (nil, nil, nil, nil, nil, nil, nil)
        stage = input.lowercased().hasPrefix("http") ? .downloading : .extractingAudio
    }

    /// Starts one recording's job with a fresh progress bar and returns its task.
    private func job(_ input: String, title known: String? = nil, run: Int) -> Task<Transcript, Error> {
        let withSpeakers = speakers
        resetProgress(for: input)
        let relay = ProgressRelay { [weak self] p in
            guard let self, run == self.generation else { return }
            self.show(p, speakers: withSpeakers)
        }
        // The job runs in a child process, so none of the memory the models use is ever the app's to
        // give back. Its task is kept so quitting can wait for it to tidy up.
        let work = Task.detached(priority: .utility) {
            try await Engine.transcribeInChild(input: input, title: known, speakers: withSpeakers) { relay.send($0) }
        }
        engine = work
        return work
    }

    private func fail(_ error: Error) {
        var command: String?
        var message = error.localizedDescription
        if case ScribeError.missingTool(let tool) = error {
            message = "Scribe needs \(tool) for this. Install it in Terminal, then try again."
            command = "brew install \(tool)"
        }
        withAnimation(motion) { phase = .failed(message: message, command: command) }
        announce("Could not transcribe. \(message)")
    }

    // MARK: Playlists and channels

    /// How many recordings the choice screen offers: a few round numbers, then everything listed.
    var batchChoices: [Int] {
        guard case .choose(let list) = phase else { return [] }
        return [5, 10, 25, 50, 100].filter { $0 < list.items.count } + [list.items.count]
    }

    /// Roughly how long everything still queued will take: the recording in hand plus the ones waiting.
    var queueTimeLeft: String? {
        guard running else { return nil }
        let known = jobs.compactMap(\.seconds)
        let typical = known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
        var total = 0.0
        for item in jobs {
            switch item.state {
            case .waiting:
                guard let seconds = item.seconds ?? typical else { return nil }  // a local file of unknown length: no honest total
                total += seconds / usualSpeed + 4  // a few seconds each to fetch and load
            case .working:
                if let secondsLeft { total += Double(secondsLeft) } else if waitingCount == 0 { return nil }
            default: break
            }
        }
        return total > 0 ? "about \(Self.duration(total)) left" : nil
    }

    /// Where transcripts go until the user says otherwise: Documents/Scribe.
    static let defaultLibrary = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scribe")

    /// The folder's path the way a person would write it.
    var libraryPath: String { library.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    func defaultFolder(for list: LinkList) -> URL {
        library.appendingPathComponent(Self.fileName(list.title))
    }

    func showLibrary() {
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library)
    }

    /// Asks where transcripts should be saved. Closing the panel without choosing keeps the current
    /// folder; either way the question is not asked again, and the answer can be changed at any time.
    func chooseLibrary(then done: (() -> Void)? = nil) {
        guard !askingForLibrary else { return }
        askingForLibrary = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where Scribe saves your transcripts. You can change this later."
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        panel.directoryURL = library
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url { self.library = url }
            self.libraryChosen = true
            self.askingForLibrary = false
            if self.persist { UserDefaults.standard.set(self.library.path, forKey: "library") }
            done?()
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else {
            finish(panel.runModal())
        }
    }

    static func fileName(_ title: String) -> String {
        let clean = title.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let name = String(String(clean).trimmingCharacters(in: .whitespaces).prefix(110))
        return name.isEmpty || name.hasPrefix(".") ? "Untitled" : name
    }

    private func lookUp(_ input: String) {
        lookupRun += 1
        let run = lookupRun
        let before = phase
        withAnimation(motion) { phase = .looking }
        lookup = Task {
            do {
                let list = try await Engine.list(input)
                guard run == lookupRun else { return }
                if list.items.count == 1 {
                    phase = before
                    return start(list.items[0].url)
                }
                batchCount = min(10, list.items.count)
                batchFolder = nil
                withAnimation(motion) { phase = .choose(list) }
            } catch is CancellationError {
            } catch {
                guard run == lookupRun else { return }
                fail(error)
            }
        }
    }

    func chooseFolder(for list: LinkList) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where the transcripts are saved"
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.batchFolder = url }
        }
    }

    /// Queues the first `batchCount` recordings; each is saved as a text file as it finishes.
    func startBatch(_ list: LinkList) {
        let folder = batchFolder ?? defaultFolder(for: list)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return fail(error) }
        let chosen = list.items.prefix(batchCount)
        let digits = max(2, String(chosen.count).count)
        let new = chosen.enumerated().map { n, item -> Job in
            nextID += 1
            let number = String(format: "%0\(digits)d", n + 1)
            return Job(
                id: nextID, title: item.title, input: item.url, seconds: item.seconds, thumbnail: item.thumbnail,
                saveTo: folder.appendingPathComponent("\(number) \(Self.fileName(item.title)).txt"))
        }
        add(new, from: (list.title, folder))
    }

    /// Opens a row of the queue: the transcript of a finished one, the progress of the one in hand.
    func view(_ id: Int) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .working:
            watching = id
            withAnimation(motion) { phase = .working }
        case .done:
            guard let data = try? Data(contentsOf: cache.appendingPathComponent("\(id).json")),
                let t = try? JSONDecoder().decode(Transcript.self, from: data)
            else { return }
            watching = id
            resultID += 1
            withAnimation(motion) { phase = .result(t) }
        default: break
        }
    }

    /// From the start screen back to what is going on: straight to the only job, or to the queue.
    func openQueue() {
        if jobs.count == 1, jobs[0].state != .waiting, !({ if case .failed = jobs[0].state { true } else { false } }()) {
            view(jobs[0].id)
        } else if !jobs.isEmpty {
            withAnimation(motion) { phase = .batch }
        }
    }

    func revealBatch() {
        if let queueFolder { NSWorkspace.shared.open(queueFolder) } else { showLibrary() }
    }

    /// Back never stops anything: from a job or transcript to the queue (when there is more than one
    /// thing in it), otherwise to the start screen, where the queue stays one click away.
    func back() {
        lookup?.cancel()
        lookupRun += 1
        let toList: Bool
        switch phase {
        case .working, .result: toList = jobs.count > 1
        default: toList = false
        }
        watching = nil
        withAnimation(motion) { phase = toList ? .batch : .empty }
    }

    /// Stop: the lookup in progress, the job on screen (the queue moves on to the next), or, from the list, the whole queue.
    func cancel() {
        if case .looking = phase { return back() }
        guard running else { return }
        engine?.cancel()
        generation += 1
        running = false
        guard let i = jobs.firstIndex(where: { $0.state == .working }) else { return }
        if case .working = phase {
            jobs.remove(at: i)
            watching = nil
            withAnimation(motion) { phase = jobs.isEmpty ? .empty : .batch }
            kick()
        } else {
            jobs[i].state = .waiting  // stopped, not thrown away: Resume picks it up again
            dropFetches()
        }
    }

    func resume() { kick() }

    func remove(_ id: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .working else { return }
        try? FileManager.default.removeItem(at: cache.appendingPathComponent("\(id).json"))
        dropFetches([id])
        jobs.remove(at: i)
        if jobs.isEmpty { back() }
    }

    /// Forgets everything finished or failed. Saved files stay where they are.
    func clearFinished() {
        for job in jobs where job.state != .working && job.state != .waiting {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("\(job.id).json"))
        }
        jobs.removeAll { $0.state != .working && $0.state != .waiting }
        if jobs.isEmpty {
            queueTitle = nil
            back()
        }
    }

    /// Quitting: stops any job and hands back the engine's task, so the caller can wait for its temporary files to go.
    func stopForQuit() -> Task<Transcript, Error>? {
        try? FileManager.default.removeItem(at: cache)
        dropFetches()
        engine?.cancel()
        return engine
    }

    /// The start screen, to add something. Whatever is running keeps running.
    func reset() {
        link = ""
        watching = nil
        withAnimation(motion) { phase = .empty }
    }

    func retry() {
        if let lastInput { start(lastInput) }
    }

    /// Maps a stage's own fraction onto one bar for the whole job that only moves forward.
    private func show(_ p: Progress, speakers: Bool) {
        guard running, p.stage != .done else { return }
        // What is learnt about the recording along the way also fills in its row in the queue.
        let row = jobs.firstIndex { $0.state == .working }
        if let t = p.title, t != title {
            title = t
            if let row, jobs[row].saveTo == nil { jobs[row].title = t }
        }
        if let t = p.thumbnail, t != thumbnail {
            thumbnail = t
            if let row { jobs[row].thumbnail = t }
        }
        if let a = p.audioSeconds, a != audioSeconds {
            audioSeconds = a
            if let row { jobs[row].seconds = a }
        }
        if let m = p.memoryMB, m != memoryMB { memoryMB = m }
        // Speed: how much audio has been turned into words per second of waiting, since the words began.
        if p.stage == .transcribing, let f = p.fraction, let audio = audioSeconds {
            if let from = speedFrom {
                let waited = Date().timeIntervalSince(from.time)
                if waited > 0.4, f > from.fraction {
                    let now = Int((audio * (f - from.fraction) / waited).rounded())
                    if now != speed { speed = now }
                }
            } else {
                speedFrom = (Date(), f)
            }
        }
        // Time left: what remains of the download at its own pace, plus the audio at the pace the words
        // are going (or went last time, before they start). Nothing is shown while that would be a guess.
        var left: Double?
        if let audio = audioSeconds {
            switch p.stage {
            case .downloading:
                if downloadFrom == nil { downloadFrom = Date() }
                if let f = p.fraction, f > 0.05, let from = downloadFrom {
                    left = Date().timeIntervalSince(from) * (1 - f) / f + audio / usualSpeed + 2
                }
            case .extractingAudio, .loadingModel: left = audio / usualSpeed + 1
            case .transcribing: left = audio * (1 - (p.fraction ?? 0)) / max(1, speed.map(Double.init) ?? usualSpeed)
            default: break
            }
        }
        // Speakers are worked out alongside the words and, on long recordings, finish after them. Their
        // measured part is about 85% of that work, so the job ends when the later of the two does.
        if speakers, let from = speedFrom, p.stage == .transcribing || p.stage == .identifyingSpeakers {
            let done = 0.85 * (p.stage == .transcribing ? speakerProgress : p.fraction ?? speakerProgress)
            let waited = Date().timeIntervalSince(from.time)
            if p.stage == .identifyingSpeakers, (p.fraction ?? 0) >= 1 {
                left = nil  // only the unmeasured finish remains: a moment, not a number
            } else if done > 0.04, waited > 0.4 {
                left = max(left ?? 0, waited * (1 - done) / done)
            } else if p.stage == .identifyingSpeakers {
                left = nil
            }
        }
        let remaining = left.map { Int($0.rounded(.up)) }
        if remaining != secondsLeft { secondsLeft = remaining }
        var fraction = p.fraction ?? 0
        var measured = p.fraction != nil
        // Words and speakers are worked out side by side. The diarizer only reports its first pass, so
        // the last 15% of the stretch is its unmeasured finish, shown as movement rather than a stuck number.
        if speakers, p.stage == .transcribing {
            speakerProgress = max(speakerProgress, p.speakers ?? 0)
            fraction = 0.5 * fraction + 0.35 * speakerProgress
        } else if p.stage == .identifyingSpeakers {
            measured = measured && fraction < 1
            fraction = 0.5 + 0.35 * fraction
        }
        let start = base ?? (p.stage == .downloading ? 0 : Stage.extractingAudio.span.lowerBound)
        base = start
        func place(_ x: Double) -> Double { (x - start) / (1 - start) }
        let span = p.stage.span
        var shown = place(span.lowerBound + (span.upperBound - span.lowerBound) * fraction)
        if p.stage == .downloadingModel {
            // First run only: the model download is most of the wait, so it takes most of what is left of the bar.
            let from = modelDownload?.from ?? overall
            modelDownload = (from, from + (1 - from) * 0.7)
            shown = from + (1 - from) * 0.7 * fraction
        } else if let modelDownload, p.stage > .downloadingModel {
            let after = place(Stage.loadingModel.span.lowerBound)
            shown = modelDownload.to + (1 - modelDownload.to) * max(0, shown - after) / (1 - after)
        }
        overall = max(overall, shown)
        let whole = min(99, max(0, Int(overall * 100)))  // 100 is the transcript appearing
        if whole != percent { percent = whole }
        if measured != determinate { determinate = measured }
        if p.stage != stage {
            stage = p.stage
            announce(p.stage.label)
            if p.stage == .loadingModel {
                // Normally a blink. The first time, macOS spends about half a minute preparing the model: say so.
                let run = generation
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if run == generation, isWorking, stage == .loadingModel { slowLoad = true }
                }
            }
        }
    }

    private func announce(_ text: String) {
        if NSWorkspace.shared.isVoiceOverEnabled { AccessibilityNotification.Announcement(text).post() }
    }

    // MARK: Input

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose video or audio files to transcribe"
        panel.prompt = "Transcribe"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { panel.urls.forEach { self?.start($0.path) } }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: done) } else {
            done(panel.runModal())
        }
    }

    func open(_ url: URL) {
        start(url.isFileURL ? url.path : url.absoluteString)
    }

    /// Cmd+V on the start or error screen: a copied file or link starts straight away. Returns false to
    /// let an ordinary paste through, which is always the case while a transcript is showing, so
    /// pasting into the find bar works and a finished transcript is never replaced by accident.
    func pasteAndGo() -> Bool {
        switch phase {
        case .empty, .failed: break
        default: return false
        }
        let board = NSPasteboard.general
        if let file = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            start(file.path)
            return true
        }
        guard let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            text.count < 2000, !text.contains(where: \.isWhitespace),
            text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") || text.lowercased().hasPrefix("www.")
        else { return false }
        link = text
        start(text)
        return true
    }

    // MARK: Output

    func copy() {
        guard let t = transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(showTimes ? t.timestamped : t.plain, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    func save(srt: Bool) {
        guard let t = transcript, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let text = srt ? t.srt : showTimes ? t.timestamped : t.plain
        let panel = NSSavePanel()
        let name = t.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = name + (srt ? ".srt" : ".txt")
        if !srt { panel.allowedContentTypes = [.plainText] }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    func zoom(_ step: Double) {
        textSize = step == 0 ? 15 : min(22, max(12, textSize + step))
    }

    // MARK: Snapshot support

    /// Puts the model in a fixed state without running anything (used by `--snapshot`).
    func pose(jobs: [Job], title: String?, running: Bool, stage: Stage = .transcribing, percent: Int = 0, phase: Phase = .batch) {
        (self.jobs, queueTitle, self.running, self.phase, self.stage, self.percent) = (jobs, title, running, phase, stage, percent)
        (speed, memoryMB, secondsLeft, queueFolder) = (64, 148, 21, FileManager.default.temporaryDirectory)
    }

    func pose(metrics speed: Int?, memoryMB: Int?, audioSeconds: Double?, thumbnail: String? = nil) {
        (self.speed, self.memoryMB, self.audioSeconds, self.thumbnail) = (speed, memoryMB, audioSeconds, thumbnail)
        secondsLeft = speed == nil ? nil : 9
    }

    func pose(_ phase: Phase, stage: Stage = .transcribing, percent: Int = 0, determinate: Bool = true, title: String? = nil) {
        (self.phase, self.stage, self.percent, self.determinate, self.title) = (phase, stage, percent, determinate, title)
        resultID += 1
    }
}

extension Stage {
    /// The share of the whole job's bar each stage owns. Jobs that skip the download start at the extract stage.
    var span: ClosedRange<Double> {
        switch self {
        case .downloading: return 0...0.30
        case .extractingAudio: return 0.30...0.37
        case .downloadingModel, .loadingModel: return 0.37...0.39
        case .transcribing, .identifyingSpeakers: return 0.39...1
        case .done: return 1...1
        }
    }
}

/// Keeps only the newest progress report and hands the main thread at most about 30 a second.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Progress?
    private var scheduled = false
    private let deliver: @MainActor (Progress) -> Void

    init(_ deliver: @escaping @MainActor (Progress) -> Void) { self.deliver = deliver }

    func send(_ p: Progress) {
        let schedule = lock.withLock { () -> Bool in
            latest = p
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) {
            let p = self.lock.withLock { () -> Progress? in
                self.scheduled = false
                return self.latest
            }
            if let p { MainActor.assumeIsolated { self.deliver(p) } }
        }
    }
}

// MARK: - App

struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Model.shared

    var body: some Scene {
        Window("Scribe", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)  // no saved window snapshot: that alone held 6 MB while idle
        .commands { ScribeCommands(model: model) }
    }
}

struct ScribeCommands: Commands {
    @Bindable var model: Model

    /// Drives the transcript's built-in find bar.
    private func find(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Transcription") { model.reset() }
                .keyboardShortcut("n")
                .disabled(model.isStart)
            Button("Back") { model.back() }
                .keyboardShortcut("[")
                .disabled(model.isStart)
            Button("Open…") { model.pickFile() }
                .keyboardShortcut("o")
            Button("Show Transcripts Folder") { model.showLibrary() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Change Transcripts Folder…") { model.chooseLibrary() }
        }
        CommandGroup(after: .saveItem) {
            Button("Save as Text…") { model.save(srt: false) }
                .keyboardShortcut("s")
                .disabled(model.transcript == nil)
            Button("Save as Subtitles…") { model.save(srt: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.transcript == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Group {
                Button("Find…") { find(.showFindInterface) }.keyboardShortcut("f")
                Button("Find Next") { find(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(model.transcript == nil)
        }
        CommandGroup(replacing: .help) {}
        CommandGroup(before: .toolbar) {
            Button("Bigger Text") { model.zoom(1) }.keyboardShortcut("+")
            Button("Smaller Text") { model.zoom(-1) }.keyboardShortcut("-")
            Button("Actual Size") { model.zoom(0) }.keyboardShortcut("0")
            Divider()
        }
        CommandMenu("Transcript") {
            Button("Copy Transcript") { model.copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.transcript == nil)
            Divider()
            Toggle("Show Timestamps", isOn: $model.showTimes)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Toggle("Identify Speakers", isOn: $model.speakers)
            Divider()
            Button("Try Again") { model.retry() }
                .keyboardShortcut("r")
                .disabled(!model.canRetry)
            Button("Stop Transcribing") { model.cancel() }
                .keyboardShortcut(".")
                .disabled(!model.isWorking)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pasteMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cmd+V with a link or file on the clipboard starts a transcription from the start screen,
        // whatever has the keyboard. It costs nothing while idle: the closure only runs on a key press.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "v",
                let window = event.window, !(window is NSPanel), window.attachedSheet == nil
            else { return event }
            return Model.shared.pasteAndGo() ? nil : event
        }
        Snapshot.liveCheckIfRequested()
    }

    /// Files dropped on the Dock icon or sent with Open With.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Model.shared.open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting in the middle of a job waits (two seconds at most, normally a few hundredths) for the
    /// engine to stop its tools and delete its temporary files.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let work = Model.shared.stopForQuit() else { return .terminateNow }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await work.result
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 2)
        return .terminateNow
    }
}
