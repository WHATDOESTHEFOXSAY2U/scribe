import AppKit
import SwiftUI

/// The whole window: one surface, one centred column, one state at a time.
struct RootView: View {
    @Bindable var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    var body: some View {
        ZStack {
            switch model.phase {
            case .empty:
                StartView(model: model).transition(swap)
            case .working:
                WorkingView(model: model).transition(swap)
            case .looking:
                LookingView(model: model).transition(swap)
            case .choose(let list):
                ChooseView(model: model, list: list).transition(swap)
            case .batch:
                BatchView(model: model).transition(.opacity)
            case .result(let transcript):
                TranscriptView(transcript: transcript, id: model.resultID, times: model.showTimes, size: model.textSize)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
            case .failed(let message, let command):
                FailureView(model: model, message: message, command: command).transition(swap)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        // One opaque page colour as the window's own background: no material, so nothing behind the window is blurred.
        .containerBackground(Color(nsColor: .textBackgroundColor), for: .window)
        .overlay {
            if model.dropTargeted {
                // Drawn on the window's own edge: the outer half of the line falls outside and is clipped away.
                ConcentricRectangle()
                    .fill(.tint.opacity(0.07))
                    .stroke(.tint, lineWidth: 6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            urls.forEach { model.open($0) }
            return true
        } isTargeted: {
            model.dropTargeted = $0
        }
        .toolbar {
            if model.transcript != nil {
                ToolbarItem(placement: .navigation) { BackButton(model: model) }
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    Toggle(isOn: $model.showTimes) { Label("Timestamps", systemImage: "clock") }
                        .help("Show timestamps (⇧⌘T)")
                }
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Menu {
                        Button("Save as Text…") { model.save(srt: false) }
                        Button("Save as Subtitles…") { model.save(srt: true) }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .help("Save the transcript")
                }
                ToolbarItem {
                    Button { model.copy() } label: {
                        Label(model.copied ? "Copied" : "Copy Transcript", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    .help("Copy the whole transcript (⇧⌘C)")
                }
            } else if case .working = model.phase {
                ToolbarItem(placement: .navigation) { BackButton(model: model) }
            } else if case .batch = model.phase {
                ToolbarItem(placement: .navigation) { BackButton(model: model) }
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    Button { model.revealBatch() } label: { Label("Show in Finder", systemImage: "folder") }
                        .help("Open the folder the transcripts are saved in")
                }
                ToolbarItem {
                    Button { model.clearFinished() } label: { Label("Clear Finished", systemImage: "trash") }
                        .disabled(model.doneCount == 0 && !model.jobs.contains { if case .failed = $0.state { true } else { false } })
                        .help("Remove finished rows from this list (saved files stay)")
                }
            } else {
                // An invisible item keeps the toolbar, and with it the title bar's height, in every state:
                // without it the close, minimise and zoom buttons jump when a transcript appears.
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(model.windowTitle)
    }
}

// MARK: - Empty

struct StartView: View {
    @Bindable var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: model.dropTargeted ? "arrow.down" : "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(model.dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(height: 48)
                .accessibilityHidden(true)
            Text(model.dropTargeted ? "Release to transcribe" : "Drop a recording")
                .font(.system(size: 28, weight: .semibold))
                .padding(.top, 14)
            VStack(spacing: 0) {
                LinkField(model: model)
                    .padding(.top, 30)
                Button("Choose File…") { model.pickFile() }
                    .controlSize(.large)
                    .padding(.top, 16)
            }
            .opacity(model.dropTargeted ? 0.25 : 1)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 14) {
                if let summary = model.queueSummary {
                    Button { model.openQueue() } label: {
                        HStack(spacing: 8) {
                            if model.running { ProgressView().controlSize(.small) }
                            Text(summary).monospacedDigit()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(.primary.opacity(0.06), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show what is being transcribed")
                    .transition(.opacity)
                }
            HStack(spacing: 18) {
                Toggle("Identify speakers", isOn: $model.speakers)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Label who is speaking. Turning this off is faster and uses less memory, most of all on long recordings.")
                Button { model.showLibrary() } label: { Label("Transcripts", systemImage: "folder") }
                    .buttonStyle(.plain)
                    .help("Every transcript is saved here as a text file (⇧⌘O)")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            }
            .opacity(model.dropTargeted ? 0.25 : 1)
            .padding(.bottom, 22)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct LinkField: View {
    @Bindable var model: Model
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("", text: $model.link)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { model.start(model.link) }
                .accessibilityLabel("Link to transcribe")
                // The field's own prompt is drawn as dark as typed text; this one reads as the quiet second line it is.
                .background(alignment: .leading) {
                    if model.link.isEmpty {
                        Text("or paste a link: video, playlist or channel")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            if !model.link.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { model.start(model.link) } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Transcribe this link (Return)")
                .accessibilityLabel("Transcribe link")
                .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: 38)
        .frame(maxWidth: 360)
        .background(.primary.opacity(focused ? 0.1 : 0.075), in: Capsule())
        .animation(.easeOut(duration: 0.15), value: model.link.isEmpty)
        .animation(.easeOut(duration: 0.15), value: focused)
        // No caret blinking in an idle window: the field takes focus only when clicked.
        .onAppear { DispatchQueue.main.async { focused = false } }
    }
}

// MARK: - Working

struct WorkingView: View {
    let model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth = 280.0

    var body: some View {
        VStack(spacing: 0) {
            if let thumbnail = model.thumbnail {
                Thumb(url: thumbnail, width: 144)
                    .padding(.bottom, 22)
                    .transition(.opacity)
            }
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    // An unseen twin of the sign on the other side keeps the digits themselves on the centre line.
                    Text("%")
                        .font(.system(size: 26, weight: .light))
                        .hidden()
                        .accessibilityHidden(true)
                    Text("\(model.percent)")
                        .font(.system(size: 76, weight: .thin))
                        .monospacedDigit()
                        .tracking(-3)
                        // Deliberately no rolling-digit effect: at this size it rasterises every frame on the
                        // CPU and left about 40 MB of glyph caches behind. Steady digits read as a counter anyway.
                        .contentTransition(.identity)
                    Text("%")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 80)

                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(.primary).frame(width: max(0, barWidth * Double(model.percent) / 100))
                    if !model.determinate { Glide(animated: !reduceMotion) }
                }
                .frame(width: barWidth, height: 3)
                .clipShape(Capsule())
                .padding(.top, 18)

                Text(model.stage.label)
                    .font(.system(size: 15, weight: .medium))
                    .id(model.stage)
                    .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                    .padding(.top, 20)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.percent)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.stage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.stage.label)
            .accessibilityValue("\(model.percent) percent")

            Text(model.caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 340)
                .padding(.top, 5)

            Metrics(model: model)
                .padding(.top, 26)

            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .padding(.top, 30)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.thumbnail)
        .overlay(alignment: .bottom) {
            Text(Engine.modelLine + (model.waitingCount > 0 ? "  ·  \(model.waitingCount) more waiting" : ""))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 22)
        }
    }
}

/// The one way out of a job, a transcript or the queue. It never stops anything.
struct BackButton: View {
    let model: Model

    var body: some View {
        Button { model.back() } label: {
            Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
        }
        .help(model.running ? "Back (⌘[). The job keeps going." : "Back (⌘[)")
    }
}

/// Three quiet numbers under the bar: how fast the job is going, what it costs, how much there is.
/// A number that is not known yet shows as a dash, so the row never changes shape.
struct Metrics: View {
    let model: Model

    var body: some View {
        HStack(spacing: 0) {
            cell(model.speed.map { "\($0)×" } ?? "–", "real time")
            Divider().frame(height: 26)
            cell(model.memoryMB.map { "\($0) MB" } ?? "–", "memory")
            Divider().frame(height: 26)
            cell(model.audioSeconds.map { Transcript.clock($0) } ?? "–", "of audio")
            Divider().frame(height: 26)
            cell(model.secondsLeft.map { Model.duration(Double($0)) } ?? "–", "left")
        }
        .frame(width: 420)
        .accessibilityElement(children: .combine)
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .contentTransition(.identity)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small picture for a link, fetched once and kept only in memory. Shows a quiet tile until it arrives.
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
            RoundedRectangle(cornerRadius: width * 0.09, style: .continuous).fill(.primary.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: width * 0.22, weight: .light))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: width, height: (width * 9 / 16).rounded())
        .clipShape(RoundedRectangle(cornerRadius: width * 0.09, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: width * 0.09, style: .continuous).strokeBorder(.primary.opacity(0.08)))
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
                        kCGImageSourceThumbnailMaxPixelSize: max(320, width * 2),
                    ] as CFDictionary)
            else { return }
            let picture = NSImage(cgImage: small, size: .zero)
            Self.cache.setObject(picture, forKey: url as NSString)
            withAnimation(.easeOut(duration: 0.2)) { image = picture }
        }
    }
}

/// A soft highlight that travels along the bar while a stage has nothing measurable to report.
/// It exists only during such a stage, so nothing animates once the work stops.
struct Glide: View {
    let animated: Bool
    @State private var travelled = false

    var body: some View {
        GeometryReader { geo in
            Capsule()
                // Mid grey shows against both the filled part of the bar and the empty track, light or dark.
                .fill(LinearGradient(colors: [.clear, .gray, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: 96)
                .offset(x: animated ? (travelled ? geo.size.width : -96) : (geo.size.width - 96) / 2)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false)) { travelled = true }
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
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 48)
                .accessibilityHidden(true)
            Text("Couldn’t transcribe")
                .font(.system(size: 28, weight: .semibold))
                .padding(.top, 14)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: 360)
                .padding(.top, 6)
            if let command {
                HStack(spacing: 10) {
                    Text(command)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy the command")
                    .accessibilityLabel("Copy the install command")
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(.primary.opacity(0.045), in: Capsule())
                .padding(.top, 20)
            }
            HStack(spacing: 10) {
                Button("Start Over") { model.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { model.retry() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 28)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - Playlists and channels

/// Shown for the second or two it takes to read what a playlist or channel holds.
struct LookingView: View {
    let model: Model

    var body: some View {
        VStack(spacing: 0) {
            ProgressView().controlSize(.regular).frame(height: 48)
            Text("Reading the list")
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 14)
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .padding(.top, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// A playlist or channel was pasted: how many of its recordings to transcribe, and where they go.
struct ChooseView: View {
    @Bindable var model: Model
    let list: LinkList

    private var folder: URL { model.batchFolder ?? model.defaultFolder(for: list) }

    var body: some View {
        VStack(spacing: 0) {
            // The first few pictures, fanned like a small pile, say "many" without a word.
            ZStack {
                ForEach(Array(list.items.prefix(3).enumerated().reversed()), id: \.offset) { i, item in
                    Thumb(url: item.thumbnail, width: 168)
                        .scaleEffect(1 - Double(i) * 0.07)
                        .offset(y: Double(i) * -11)
                        .opacity(1 - Double(i) * 0.3)
                }
            }
            .padding(.top, 22)
            Text(list.title)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 20)
            Text(list.more ? "More than \(list.items.count) videos" : "\(list.items.count) videos")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(spacing: 8) {
                Text(list.isChannel ? "Transcribe the newest" : "Transcribe the first")
                Picker("How many", selection: $model.batchCount) {
                    ForEach(model.batchChoices, id: \.self) { n in
                        Text(n == list.items.count && !list.more ? "\(n) (all)" : "\(n)").tag(n)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(.system(size: 14))
            .padding(.top, 28)

            HStack(spacing: 6) {
                Text("Saved to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { model.chooseFolder(for: list) }
                    .buttonStyle(.link)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)
            .padding(.top, 12)

            HStack(spacing: 10) {
                Button("Cancel") { model.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe") { model.startBatch(list) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 28)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The queue: everything asked for this session. The row in hand opens its progress, finished rows their transcript.
struct BatchView: View {
    let model: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.listTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if model.running {
                        Button("Stop") { model.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.small)
                    } else if model.waitingCount > 0 {
                        Button("Resume") { model.resume() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 18)
                LazyVStack(spacing: 0) {
                    ForEach(model.jobs) { item in
                        BatchRow(model: model, item: item)
                        Divider().opacity(0.5)
                    }
                }
                Text(Engine.modelLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 64)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var summary: String {
        let failed = model.jobs.count { if case .failed = $0.state { true } else { false } }
        var text = "\(model.doneCount) of \(model.jobs.count) transcribed"
        if failed > 0 { text += " · \(failed) failed" }
        if !model.running, model.waitingCount > 0 { text += " · stopped" }
        if let left = model.queueTimeLeft { text += " · \(left)" }
        return text
    }
}

struct BatchRow: View {
    let model: Model
    let item: Model.Job

    private var opens: Bool {
        switch item.state {
        case .done, .working: true
        default: false
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { model.view(item.id) } label: {
                HStack(spacing: 12) {
                    Thumb(url: item.thumbnail, width: 72)
                        .opacity(item.state == .waiting ? 0.55 : 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14))
                            .foregroundStyle(item.state == .waiting ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Group {
                            switch item.state {
                            case .failed(let why): Text(why).lineLimit(2)
                            case .working:
                                Text("\(model.stage.label) · \(model.percent)%" + (model.secondsLeft.map { " · \(Model.duration(Double($0))) left" } ?? ""))
                            case .done(let words):
                                Text("\(words.formatted()) words" + (item.seconds.map { " · \(Transcript.clock($0))" } ?? ""))
                            case .waiting: Text(item.seconds.map { Transcript.clock($0) } ?? "Waiting")
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    Group {
                        switch item.state {
                        case .waiting: EmptyView()
                        case .working: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 18)
                    .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(opens)  // not `disabled`, which would grey out the row that is being worked on
            .accessibilityHint(opens ? "Opens it" : "")
            if item.state == .waiting {
                Button { model.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from the queue")
                .accessibilityLabel("Remove from the queue")
            }
        }
    }
}
