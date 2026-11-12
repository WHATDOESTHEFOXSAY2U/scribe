import AppKit
import SwiftUI

// One quiet readout. Monochrome, the system typeface, light or dark with the Mac. Every reading has
// the same form (a label, a number, a ten-segment bar) and colour appears only as a signal: amber
// when elevated, red when critical. Controls are small flat keys; nothing is shaded or blurred, and
// nothing moves unless work is in progress.

// MARK: - Language

enum Ink {
    static let white = Color.primary  // the main ink: near-black on a light page, near-white on a dark one
    static let grey = Color.secondary
    static let unlit = Color.primary.opacity(0.11)
    static let line = Color.primary.opacity(0.12)
    static let page = Color(nsColor: .textBackgroundColor)
    static let amber = Color(red: 0xEF / 255, green: 0x9F / 255, blue: 0x27 / 255)
    static let red = Color(red: 0xE2 / 255, green: 0x4B / 255, blue: 0x4A / 255)

    /// The system face; digits keep one width so numbers do not jitter as they change.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// How loud a reading is. The same rule colours every bar.
enum Level {
    case normal, elevated, critical

    var color: Color {
        switch self {
        case .normal: Ink.white
        case .elevated: Ink.amber
        case .critical: Ink.red
        }
    }
}

/// A small quiet label above or beside a value.
struct Tag: View {
    let text: String
    var color = Ink.grey

    init(_ text: String, color: Color = Ink.grey) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Ink.mono(12))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Ten segments, lit left to right. With no fraction to show, one segment steps along the bar.
struct Bar: View {
    let fraction: Double?
    var level = Level.normal

    var body: some View {
        if let fraction {
            segments(lit: { $0 < Int((min(max(fraction, 0), 1) * 10).rounded()) })
        } else {
            // Only exists while a stage has nothing measurable to report, so nothing ticks at rest.
            TimelineView(.periodic(from: .now, by: 0.12)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.12) % 10
                segments(lit: { $0 == step })
            }
        }
    }

    private func segments(lit: @escaping (Int) -> Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(lit(i) ? level.color : Ink.unlit)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One reading: label, value with its unit, bar.
struct Gauge: View {
    let label: String
    let value: String
    var unit = ""
    var fraction: Double? = 0
    var level = Level.normal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Tag(label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Ink.mono(24, .medium))
                    .foregroundStyle(Ink.white)
                    .contentTransition(.identity)
                if !unit.isEmpty { Text(unit).font(Ink.mono(12)).foregroundStyle(Ink.grey) }
            }
            .lineLimit(1)
            .padding(.top, 2)
            Bar(fraction: fraction, level: level).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }
}

/// Makes a real button fire the moment it is pressed rather than when it is let go, and draw
/// whatever `face` returns for (hovered, enabled). The button's own action still serves the
/// keyboard and assistive technology, without firing twice after a mouse press.
struct PressStyle<Face: View>: ButtonStyle {
    let fire: () -> Void
    @ViewBuilder let face: (_ hover: Bool, _ enabled: Bool) -> Face

    func makeBody(configuration: Configuration) -> some View {
        Pressable(isPressed: configuration.isPressed, fire: fire, face: face)
    }

    private struct Pressable: View {
        let isPressed: Bool
        let fire: () -> Void
        let face: (Bool, Bool) -> Face
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            face(hover && enabled, enabled)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onChange(of: isPressed) { _, pressed in if pressed, enabled { fire() } }
        }
    }
}

/// Tells a press (already acted on at mouse-down) from an activation by keyboard or VoiceOver.
final class PressLatch {
    private var pressed = false
    func press(_ action: () -> Void) {
        pressed = true
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.pressed = false }
    }
    func activate(_ action: () -> Void) {
        if pressed { pressed = false } else { action() }
    }
}

/// The control. Plain keys are quiet text that pick up a wash under the pointer; the one main
/// action on a screen is solid. A key that is a current choice keeps its wash.
struct Key: View {
    let title: String
    var boxed = false  // the screen's main action
    var on = false
    var enabled = true
    let action: () -> Void
    @State private var latch = PressLatch()

    init(_ title: String, boxed: Bool = false, on: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        (self.title, self.boxed, self.on, self.enabled, self.action) = (title, boxed, on, enabled, action)
    }

    var body: some View {
        Button(title) { latch.activate(action) }
            .buttonStyle(
                PressStyle(fire: { latch.press(action) }) { hover, enabled in
                    Text(title)
                        .font(Ink.mono(13, boxed ? .medium : .regular))
                        .foregroundStyle(boxed ? Ink.page : enabled ? Ink.white : Ink.grey.opacity(0.6))
                        .lineLimit(1)
                        .padding(.horizontal, boxed ? 12 : 8)
                        .frame(height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    boxed
                                        ? Ink.white.opacity(enabled ? (hover ? 0.8 : 1) : 0.3)
                                        : hover ? Color.primary.opacity(0.11) : on ? Color.primary.opacity(0.14) : Color.clear)
                        }
                }
            )
            .disabled(!enabled)
            .focusEffectDisabled()
    }
}

/// A switch: a small square (solid when on), the name, then On or Off.
struct Switch: View {
    let name: String
    @Binding var isOn: Bool
    @State private var latch = PressLatch()

    var body: some View {
        Button(name) { latch.activate { isOn.toggle() } }
            .buttonStyle(
                PressStyle(fire: { latch.press { isOn.toggle() } }) { hover, _ in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Ink.white.opacity(isOn ? 1 : 0.22))
                            .frame(width: 8, height: 8)
                        Text(name).foregroundStyle(Ink.white)
                        Text(isOn ? "On" : "Off").foregroundStyle(Ink.grey)
                    }
                    .font(Ink.mono(13))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.primary.opacity(0.11) : Color.clear) }
                }
            )
            .focusEffectDisabled()
            .accessibilityValue(isOn ? "on" : "off")
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1) }
}

/// A key the keyboard can press (Return, Escape) without drawing anything.
struct Shortcut: View {
    let key: KeyboardShortcut
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

// MARK: - Window

/// One black panel: a band of keys beside the window's own buttons, a hairline, then the readout.
struct RootView: View {
    @Bindable var model: Model

    static let margin: CGFloat = 28
    static let band: CGFloat = 38  // no toolbar: anything of the system's in this strip would sit on top of the keys

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                bandKeys
            }
            .padding(.leading, 72)  // clear of close, minimise and zoom
            .padding(.trailing, Self.margin - 8)
            .frame(height: 28)  // the title bar's own height, so the keys sit level with those buttons
            .padding(.bottom, Self.band - 28)
            Hairline()
            Group {
                switch model.phase {
                case .empty: StartView(model: model)
                case .working: WorkingView(model: model)
                case .looking: LookingView(model: model)
                case .choose(let list): ChooseView(model: model, list: list)
                case .batch: QueueView(model: model)
                case .result(let transcript):
                    TranscriptView(transcript: transcript, id: model.resultID, times: model.showTimes, size: model.textSize)
                case .failed(let message, let command): FailureView(model: model, message: message, command: command)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .containerBackground(Ink.page, for: .window)
        .overlay {
            // A file held over the window: the panel's edge lights, nothing else moves.
            if model.dropTargeted {
                ConcentricRectangle().stroke(Ink.white, lineWidth: 5).ignoresSafeArea().allowsHitTesting(false)  // the outer half falls outside the window
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            urls.forEach { model.open($0) }
            return true
        } isTargeted: {
            model.dropTargeted = $0
        }
        .navigationTitle(model.windowTitle)
    }

    /// The keys for the screen in view: the way back on the left, what can be done on the right.
    @ViewBuilder private var bandKeys: some View {
        switch model.phase {
        case .empty:
            Text("Scribe").font(Ink.mono(13, .medium)).foregroundStyle(Ink.white).padding(.leading, 8)
            Spacer()
            Tag(Engine.modelName).padding(.trailing, 8)
        case .working:
            Key("Back") { model.back() }
            Spacer()
            if model.waitingCount > 0 { Tag("\(model.waitingCount) waiting").padding(.trailing, 8) }
            Key("Stop", boxed: true) { model.cancel() }
            Shortcut(key: .cancelAction) { model.cancel() }
        case .looking:
            Key("Back") { model.back() }
            Spacer()
            Shortcut(key: .cancelAction) { model.back() }
        case .choose(let list):
            Key("Back") { model.reset() }
            Spacer()
            Key("Transcribe", boxed: true) { model.startBatch(list) }
            Shortcut(key: .defaultAction) { model.startBatch(list) }
            Shortcut(key: .cancelAction) { model.reset() }
        case .batch:
            Key("Back") { model.back() }
            Spacer()
            Key("Folder") { model.revealBatch() }
            Key("Clear", enabled: model.jobs.contains { $0.state != .waiting && $0.state != .working }) { model.clearFinished() }
            if model.running {
                Key("Stop", boxed: true) { model.cancel() }
            } else if model.waitingCount > 0 {
                Key("Resume", boxed: true) { model.resume() }
            }
        case .result:
            Key("Back") { model.back() }
            Spacer()
            Key("Timestamps", on: model.showTimes) { model.showTimes.toggle() }
            Key("Save text") { model.save(srt: false) }
            Key("Subtitles") { model.save(srt: true) }
            Key(model.copied ? "Copied" : "Copy", boxed: true) { model.copy() }
        case .failed:
            Key("Back") { model.reset() }
            Spacer()
            Key("Retry", boxed: true, enabled: model.canRetry) { model.retry() }
            Shortcut(key: .defaultAction) { model.retry() }
            Shortcut(key: .cancelAction) { model.reset() }
        }
    }
}

/// The frame every readout screen shares: the same margins, everything from the left edge.
struct Readout<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, RootView.margin)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Start

struct StartView: View {
    @Bindable var model: Model

    var body: some View {
        Readout {
            Tag("New transcription")
            Text(model.dropTargeted ? "Release to transcribe" : "Drop a recording")
                .font(Ink.mono(24, .semibold))
                .foregroundStyle(Ink.white)
                .padding(.top, 3)
            LinkField(model: model).padding(.top, 18)

            Hairline().padding(.top, 14).padding(.bottom, 12)
            HStack(spacing: 4) {
                Key("Choose file…", boxed: true) { model.pickFile() }
                Switch(name: "Speakers", isOn: $model.speakers).padding(.leading, 6)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Tag("Saved to \(model.libraryPath)").truncationMode(.middle)
                Key("Open") { model.showLibrary() }
                Key("Change…") { model.chooseLibrary() }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)

            Spacer(minLength: 0)
            if let summary = model.queueSummary {
                Hairline().padding(.bottom, 12)
                HStack(spacing: 4) {
                    Tag("In progress").padding(.trailing, 6)
                    Key(summary) { model.openQueue() }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct LinkField: View {
    @Bindable var model: Model
    @FocusState private var focused: Bool

    private var hasLink: Bool { !model.link.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("", text: $model.link)
                    .textFieldStyle(.plain)
                    .font(Ink.mono(14))
                    .foregroundStyle(Ink.white)
                    .focused($focused)
                    .onSubmit { model.start(model.link) }
                    .accessibilityLabel("Link to transcribe")
                    .background(alignment: .leading) {
                        if model.link.isEmpty {
                            Text("or paste a link: video, playlist or channel")
                                .font(Ink.mono(14))
                                .foregroundStyle(Ink.grey)
                                .accessibilityHidden(true)
                        }
                    }
                if hasLink { Key("Go", boxed: true) { model.start(model.link) } }
            }
            .frame(height: 30)
            Rectangle().fill(focused ? Ink.white : Ink.line).frame(height: 1)
        }
        // No caret blinking in an idle window: the field takes focus only when clicked.
        .onAppear { DispatchQueue.main.async { focused = false } }
    }
}

// MARK: - Working

struct WorkingView: View {
    let model: Model

    /// Memory is the one reading here with a ceiling worth warning about.
    private var memoryLevel: Level {
        guard let mb = model.memoryMB else { return .normal }
        return mb >= 1200 ? .critical : mb >= 600 ? .elevated : .normal
    }

    var body: some View {
        Readout {
            Tag(model.stage.label)
            Text(model.title ?? "—")
                .font(Ink.mono(24, .semibold))
                .foregroundStyle(Ink.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 3)

            HStack(alignment: .top, spacing: 16) {
                Gauge(label: "Progress", value: "\(model.percent)", unit: "%", fraction: model.determinate ? Double(model.percent) / 100 : nil)
                Gauge(
                    label: "Speed", value: model.speed.map(String.init) ?? "—", unit: "× real time",
                    fraction: model.speed.map { Double($0) / 200 } ?? 0)
                Gauge(
                    label: "Memory", value: model.memoryMB.map(String.init) ?? "—", unit: "MB",
                    fraction: model.memoryMB.map { Double($0) / 1000 } ?? 0, level: memoryLevel)
                Gauge(
                    label: "Time left", value: left.value, unit: left.unit,
                    fraction: model.secondsLeft == nil ? 0 : 1 - Double(model.percent) / 100)
            }
            .padding(.top, 22)

            Hairline().padding(.top, 14).padding(.bottom, 12)
            HStack(spacing: 16) {
                Tag("\(model.audioSeconds.map { Transcript.clock($0) } ?? "—") of audio")
                Tag(Engine.modelName)
                Tag("On this Mac")
                Spacer(minLength: 0)
            }
            if model.stage == .downloadingModel || (model.stage == .loadingModel && model.slowLoad) {
                Tag(model.stage == .downloadingModel ? "First run: downloading the speech model" : "First run: preparing the speech model").padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private var left: (value: String, unit: String) {
        guard let s = model.secondsLeft else { return ("—", "") }
        let parts = Model.duration(Double(s)).split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "—", parts.count > 1 ? parts[1] : "")
    }
}

// MARK: - Playlists and channels

/// The second or two it takes to read what a playlist or channel holds.
struct LookingView: View {
    let model: Model

    var body: some View {
        Readout {
            Tag("Reading the list")
            Text("One moment").font(Ink.mono(24, .semibold)).foregroundStyle(Ink.white).padding(.top, 3)
            Bar(fraction: nil).frame(maxWidth: 160).padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

/// A playlist or channel was pasted: how many of its recordings to take, and where they go.
struct ChooseView: View {
    @Bindable var model: Model
    let list: LinkList

    private var folder: URL { model.batchFolder ?? model.defaultFolder(for: list) }

    var body: some View {
        Readout {
            Tag(list.isChannel ? "Channel" : "Playlist")
            Text(list.title)
                .font(Ink.mono(24, .semibold))
                .foregroundStyle(Ink.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 3)

            HStack(alignment: .top, spacing: 16) {
                Gauge(label: "Found", value: "\(list.items.count)", unit: list.more ? "+" : "", fraction: 1)
                Gauge(
                    label: "Take", value: "\(model.batchCount)", unit: list.isChannel ? "newest" : "first",
                    fraction: Double(model.batchCount) / Double(max(list.items.count, 1)))
                Gauge(label: "Audio", value: audio.value, unit: audio.unit, fraction: 0)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
            .padding(.top, 22)

            Hairline().padding(.top, 14).padding(.bottom, 12)
            HStack(spacing: 4) {
                Tag("Transcribe").padding(.trailing, 6)
                ForEach(model.batchChoices, id: \.self) { n in
                    Key(n == list.items.count && !list.more ? "All" : "\(n)", on: model.batchCount == n) { model.batchCount = n }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Tag("Saved to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .truncationMode(.middle)
                Key("Change…") { model.chooseFolder(for: list) }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)

            // What is about to be taken, as a strip of pictures: content, not decoration.
            HStack(spacing: 4) {
                ForEach(Array(list.items.prefix(min(model.batchCount, 8)).enumerated()), id: \.offset) { _, item in
                    Thumb(url: item.thumbnail, width: 70)
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }

    /// Total running time of what would be taken, when the site gave lengths.
    private var audio: (value: String, unit: String) {
        let lengths = list.items.prefix(model.batchCount).compactMap(\.seconds)
        guard !lengths.isEmpty else { return ("—", "") }
        let minutes = Int((lengths.reduce(0, +) / 60).rounded())
        return minutes >= 120 ? (String(format: "%.1f", Double(minutes) / 60), "h") : ("\(minutes)", "min")
    }
}

// MARK: - Queue

/// Everything asked for this session. The row in hand opens its progress, finished rows their transcript.
struct QueueView: View {
    let model: Model

    private var failed: Int { model.jobs.count { if case .failed = $0.state { true } else { false } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Tag(model.running ? "Queue · running" : model.waitingCount > 0 ? "Queue · stopped" : "Queue")
                Text(model.listTitle)
                    .font(Ink.mono(24, .semibold))
                    .foregroundStyle(Ink.white)
                    .lineLimit(1)
                    .padding(.top, 3)
                HStack(alignment: .top, spacing: 16) {
                    Gauge(
                        label: "Done", value: "\(model.doneCount)", unit: "of \(model.jobs.count)",
                        fraction: Double(model.doneCount) / Double(max(model.jobs.count, 1)))
                    Gauge(label: "Now", value: model.running ? "\(model.percent)" : "—", unit: model.running ? "%" : "", fraction: model.running ? Double(model.percent) / 100 : 0)
                    Gauge(
                        label: "Failed", value: "\(failed)", fraction: Double(failed) / Double(max(model.jobs.count, 1)),
                        level: failed > 0 ? .critical : .normal)
                    Gauge(label: "Time left", value: left.value, unit: left.unit, fraction: 0)
                }
                .padding(.top, 22)
                Hairline().padding(.top, 14)
            }
            .padding(.horizontal, RootView.margin)
            .padding(.top, 22)
            .frame(maxWidth: 720, alignment: .leading)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.jobs.enumerated()), id: \.element.id) { n, item in
                        QueueRow(model: model, item: item, number: n + 1)
                    }
                }
                .padding(.horizontal, RootView.margin - 8)
                .padding(.vertical, 6)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var left: (value: String, unit: String) {
        guard let text = model.queueTimeLeft else { return ("—", "") }
        // "about 4 min left" → "4", "min"
        let words = text.split(separator: " ").map(String.init).filter { $0 != "about" && $0 != "left" }
        return (words.first ?? "—", words.dropFirst().joined(separator: " "))
    }
}

/// One line of the queue, a full-width key when it leads somewhere.
struct QueueRow: View {
    let model: Model
    let item: Model.Job
    let number: Int
    @State private var latch = PressLatch()

    private var opens: Bool {
        switch item.state {
        case .done, .working: true
        default: false
        }
    }

    private var status: (text: String, color: Color) {
        switch item.state {
        case .waiting: (item.seconds.map { "Waiting · \(Transcript.clock($0))" } ?? "Waiting", Ink.grey)
        case .working: ("\(model.stage.label) \(model.percent)%" + (model.secondsLeft.map { " · \(Model.duration(Double($0))) left" } ?? ""), Ink.white)
        case .done(let words): ("\(words.formatted()) words", Ink.grey)
        case .failed(let why): (why, Ink.red)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(item.title) { latch.activate { model.view(item.id) } }
                .buttonStyle(
                    PressStyle(fire: { latch.press { model.view(item.id) } }) { hover, _ in
                        let lit = hover && opens
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", number)).foregroundStyle(Ink.grey)
                            Thumb(url: item.thumbnail, width: 46).opacity(item.state == .waiting ? 0.5 : 1)
                            Text(item.title)
                                .foregroundStyle(item.state == .waiting ? Ink.grey : Ink.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(status.text)
                                .foregroundStyle(status.color)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                                .frame(maxWidth: 300, alignment: .trailing)
                        }
                        .font(Ink.mono(13))
                        .padding(.horizontal, 8)
                        .frame(height: 40)
                        .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.primary.opacity(0.08) : Color.clear) }
                    }
                )
                .allowsHitTesting(opens)  // not `disabled`: a waiting or failed row is information, not a dimmed control
                .focusEffectDisabled()
            if item.state == .waiting { Key("Remove") { model.remove(item.id) } }
        }
        .overlay(alignment: .bottom) { Hairline().padding(.horizontal, 8) }
    }
}

/// A recording's picture, square-cornered and small, fetched once and kept only in memory.
struct Thumb: View {
    let url: String?
    var width: Double = 64
    @State private var image: NSImage?

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        return cache
    }()
    private static let session = URLSession(configuration: .ephemeral)

    init(url: String?, width: Double = 64) {
        self.url = url
        self.width = width
        // Already fetched, or a file on disk: there from the first frame.
        if let url {
            _image = State(initialValue: Self.cache.object(forKey: url as NSString) ?? (url.hasPrefix("/") ? NSImage(contentsOfFile: url) : nil))
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Ink.unlit)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: width, height: (width * 9 / 16).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard image == nil, let url, let address = URL(string: url), address.scheme?.hasPrefix("http") == true else { return }
            guard let (data, _) = try? await Self.session.data(from: address),
                // Decoded at the size it is shown, so a large picture costs no more memory than a small one.
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let small = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: max(160, width * 2),
                    ] as CFDictionary)
            else { return }
            let picture = NSImage(cgImage: small, size: .zero)
            Self.cache.setObject(picture, forKey: url as NSString)
            image = picture
        }
    }
}

// MARK: - Error

struct FailureView: View {
    let model: Model
    let message: String
    let command: String?
    @State private var copied = false

    var body: some View {
        Readout {
            Tag("Something went wrong", color: Ink.red)
            Text("Couldn’t transcribe")
                .font(Ink.mono(24, .semibold))
                .foregroundStyle(Ink.white)
                .padding(.top, 3)
            Bar(fraction: 1, level: .critical).frame(maxWidth: 160).padding(.top, 6)

            Hairline().padding(.top, 14).padding(.bottom, 12)
            Text(message)
                .font(Ink.mono(14))
                .foregroundStyle(Ink.white)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: .leading)
            if let command {
                HStack(spacing: 4) {
                    Tag("Run").padding(.trailing, 6)
                    Text(command).font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.white).textSelection(.enabled)
                    Key(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .padding(.leading, 8)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
            }
            Spacer(minLength: 0)
        }
    }
}
