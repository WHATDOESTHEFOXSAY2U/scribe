import AppKit
import SwiftUI

/// `scribe --snapshot <dir>`: draws the real window in every state, light and dark, to PNG files
/// at 2x, using made-up sample text. Nothing is shown on screen. It also times a 30,000-word transcript.
@MainActor
enum Snapshot {
    static func run(into dir: String) -> Never {
        let folder = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let sample = sampleTranscript()
        let states: [(String, CGSize, (Model) -> Void)] = [
            ("1-empty", CGSize(width: 720, height: 600), { _ in }),
            ("2-drag-over", CGSize(width: 720, height: 600), { $0.dropTargeted = true }),
            ("3-working", CGSize(width: 720, height: 600), {
                $0.pose(.working, stage: .transcribing, percent: 41, title: "Weekly product sync")
                $0.pose(metrics: 64, memoryMB: 148, audioSeconds: 1013)
            }),
            ("3b-working-link", CGSize(width: 720, height: 600), {
                $0.pose(.working, stage: .transcribing, percent: 41, title: "How we cut onboarding time in half")
                $0.pose(metrics: 64, memoryMB: 148, audioSeconds: 1013, thumbnail: samplePicture(0))
            }),
            ("4-working-indeterminate", CGSize(width: 720, height: 600), {
                $0.pose(.working, stage: .loadingModel, percent: 9, determinate: false, title: "Weekly product sync")
            }),
            ("5-result", CGSize(width: 720, height: 600), { $0.pose(.result(sample)) }),
            ("6-result-timestamps", CGSize(width: 720, height: 600), {
                $0.showTimes = true
                $0.pose(.result(sample))
            }),
            ("7-error", CGSize(width: 720, height: 600), {
                $0.pose(.failed(message: "That link is unavailable. It may have been removed or the address is wrong.", command: nil))
            }),
            ("8-error-missing-tool", CGSize(width: 720, height: 600), {
                $0.pose(.failed(message: "Scribe needs yt-dlp for this. Install it in Terminal, then try again.", command: "brew install yt-dlp"))
            }),
            ("9-result-wide", CGSize(width: 1100, height: 700), { $0.pose(.result(sample)) }),
            ("10-result-small", CGSize(width: 480, height: 380), {
                $0.showTimes = true
                $0.pose(.result(sample))
            }),
            ("14-result-scrolled", CGSize(width: 720, height: 600), { $0.pose(.result(longTranscript())) }),
            ("15-result-scrolled-narrow", CGSize(width: 480, height: 420), {
                $0.showTimes = true
                $0.pose(.result(longTranscript()))
            }),
            ("16-batch-scrolled", CGSize(width: 720, height: 420), {
                var items = (0..<14).map {
                    Model.Job(id: $0, title: "Episode \($0 + 1): a conversation about building things", input: "https://example.com", seconds: 1500, thumbnail: samplePicture($0))
                }
                for i in 0..<9 { items[i].state = .done(words: 4000 + i * 137) }
                items[9].state = .working
                $0.pose(jobs: items, title: "The Product Podcast", running: true, percent: 41)
            }),
            ("11-choose", CGSize(width: 720, height: 600), {
                let items = (1...143).map {
                    LinkItem(title: "Episode \($0)", url: "https://example.com/\($0)", seconds: 1800, thumbnail: samplePicture($0))
                }
                $0.pose(.choose(LinkList(title: "The Product Podcast", items: items, more: false)))
            }),
            ("13-start-with-queue", CGSize(width: 720, height: 600), {
                var items = [
                    Model.Job(id: 0, title: "Weekly product sync", input: "/tmp/a.mp4", seconds: 1013),
                    Model.Job(id: 1, title: "Customer call", input: "/tmp/b.mp4", seconds: 2400),
                ]
                items[0].state = .working
                $0.pose(jobs: items, title: nil, running: true, percent: 41, phase: .empty)
            }),
            ("12-batch", CGSize(width: 720, height: 600), {
                let titles = [
                    "How we cut onboarding time in half", "Pricing experiments that failed", "An interview with our first customer",
                    "What the launch taught us", "Roadmap questions, answered", "Hiring the first ten people",
                ]
                var items = titles.enumerated().map {
                    Model.Job(
                        id: $0.offset, title: $0.element, input: "https://example.com", seconds: 1500 + Double($0.offset) * 317,
                        thumbnail: samplePicture($0.offset))
                }
                items[0].state = .done(words: 4812)
                items[1].state = .done(words: 6230)
                items[2].state = .failed("That video is private.")
                items[3].state = .working
                $0.pose(jobs: items, title: "The Product Podcast", running: true, percent: 41)
            }),
        ]
        for dark in [false, true] {
            for (name, size, configure) in states {
                let model = Model()
                configure(model)
                let window = makeWindow(model: model, size: size, dark: dark)
                settle(0.35)
                let frame = window.contentView!.superview!
                if name.contains("scrolled") {
                    // Part-way down, with the scroll bar showing, to check what happens under the toolbar.
                    func scrollView(in view: NSView) -> NSScrollView? {
                        if let s = view as? NSScrollView, s.documentView != nil { return s }
                        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
                    }
                    if let scroll = scrollView(in: frame) {
                        scroll.scrollerStyle = .overlay
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: 230))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        scroll.flashScrollers()
                        settle(0.3)
                    }
                }
                if let data = png(of: frame) {
                    try? data.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
                window.close()
            }
        }
        bench()
        print("snapshots written to \(folder.path)")
        exit(0)
    }

    /// Sends real mouse-down and mouse-up events to keys in an off-screen window and reports whether
    /// each fired: `scribe --clicktest`. Works with the screen locked, unlike the live check.
    static func clickTest() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = Model()
        model.pose(.result(sampleTranscript()))
        let size = CGSize(width: 720, height: 600)
        let window = makeWindow(model: model, size: size, dark: true)
        window.orderFrontRegardless()  // buttons only take events in an ordered-in window
        settle(0.5)
        func press(x: CGFloat, fromTop y: CGFloat, release: Bool = true) {
            let point = NSPoint(x: x < 0 ? size.width + x : x, y: window.frame.height - y)
            for type in [NSEvent.EventType.leftMouseDown] + (release ? [.leftMouseUp] : []) {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    window.sendEvent(event)
                }
                settle(0.15)
            }
        }
        var passed = true
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            passed = passed && ok
        }
        func under(_ x: CGFloat, _ y: CGFloat) -> String {
            let view = window.contentView?.superview?.hitTest(NSPoint(x: x < 0 ? size.width + x : x, y: window.frame.height - y))
            return view.map { String(describing: type(of: $0)) } ?? "nothing"
        }
        let y: CGFloat = 14  // the band's keys sit level with the window's own buttons
        check("nothing of the system's covers BACK", under(95, y).contains("NSHostingView"))
        check("nothing of the system's covers the right-hand keys", under(-60, y).contains("NSHostingView"))
        press(x: -192, fromTop: y)
        check("TIME toggles timestamps on", model.showTimes)
        settle(0.8)
        press(x: -192, fromTop: y)
        check("one press is one toggle (off again)", !model.showTimes)
        settle(0.8)
        press(x: -60, fromTop: y, release: false)
        check("COPY fires on mouse-down, before release", model.copied)
        press(x: -60, fromTop: y)
        press(x: 300, fromTop: y)
        check("a press on the empty band does nothing", model.transcript != nil)
        press(x: 95, fromTop: y)
        check("BACK returns to the start screen", model.isStart)
        model.pose(.empty)
        settle(0.4)
        let before = model.speakers
        press(x: 205, fromTop: 200)
        check("SPEAKERS switch toggles", model.speakers != before)
        exit(passed ? 0 : 1)
    }

    static func makeWindow(model: Model, size: CGSize, dark: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true  // what the app's hidden toolbar background gives the real window
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.backgroundColor = .black  // the app's window gets this from containerBackground
        let host = NSHostingView(rootView: RootView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setContentSize(size)
        return window
    }

    static func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func png(of view: NSView, scale: CGFloat = 2) -> Data? {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Sample content (invented; never a real recording)

    static func transcript(title: String, lines: [(Int, [String])], wall: Double) -> Transcript {
        var sentences: [Segment] = []
        var clock = 3.0
        for (speaker, texts) in lines {
            for text in texts {
                let length = Double(text.split(separator: " ").count) * 0.36
                sentences.append(Segment(start: clock, end: clock + length, text: text, speaker: speaker))
                clock += length + 0.4
            }
            clock += 0.9
        }
        let speakers = Set(lines.map(\.0)).count
        if speakers < 2 { sentences = sentences.map { Segment(start: $0.start, end: $0.end, text: $0.text) } }
        return Transcript(
            title: title, fullText: sentences.map(\.text).joined(separator: " "), sentences: sentences, cues: sentences,
            turns: Engine.turns(from: sentences), speakerCount: speakers, speakerNote: nil, audioSeconds: clock, wallSeconds: wall)
    }

    static func sampleTranscript() -> Transcript {
        transcript(
            title: "Weekly product sync",
            lines: [
                (1, ["Thanks for making the time.", "I wanted to start with the launch date, because the plan changed a little since we last spoke."]),
                (2, ["Sure.", "Is it still the first week of March, or did the review push it out?"]),
                (
                    1,
                    [
                        "It moved by six days.",
                        "The review itself went well, but we found two things in the onboarding flow that are worth fixing before anyone new sees it.",
                        "Neither is large. One is the import step, which is slower than it should be on older machines, and the other is the wording on the very first screen.",
                    ]
                ),
                (2, ["That sounds reasonable.", "Who is looking at the import step?"]),
                (1, ["Priya has it.", "She thinks most of the time goes into reading the file twice, so the fix is mostly deleting code."]),
                (2, ["The best kind of fix.", "And the wording?"]),
                (
                    1,
                    [
                        "I will send you three options this afternoon.",
                        "My favourite is the shortest one, but I would like a second opinion before we commit to it.",
                    ]
                ),
                (2, ["Happy to look.", "Send them over and I will reply before the end of the day."]),
                (1, ["Perfect.", "Then the only open question is the announcement, and that can wait until Thursday."]),
            ], wall: 9.8)
    }

    /// About 30,000 words across two speakers.
    static func longTranscript() -> Transcript {
        let stock = [
            "The first thing to say is that the numbers moved in the right direction this quarter, although not as quickly as anyone hoped.",
            "I agree with that.", "Could you say a little more about why the second region lagged behind the others for so long?",
            "Part of it was timing, part of it was that the team there was half the size, and part of it was simply bad luck with the weather.",
            "Right.", "So the plan for next quarter is to keep the same approach, add two people, and look again in six weeks.",
            "That seems sensible to me, as long as we write down what we expect to see so that we can tell whether it worked.",
        ]
        var lines: [(Int, [String])] = []
        var words = 0
        var i = 0
        while words < 30_000 {
            let count = 1 + (i * 7) % 5
            let texts = (0..<count).map { stock[(i + $0 * 3) % stock.count] }
            words += texts.reduce(0) { $0 + $1.split(separator: " ").count }
            lines.append((i % 2 + 1, texts))
            i += 1
        }
        return transcript(title: "Quarterly review", lines: lines, wall: 71)
    }

    /// Times the long transcript: building the text, first display, and redraws while scrolling.
    static func bench() {
        func ms(_ block: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            block()
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        let long = longTranscript()
        let words = long.fullText.split(separator: " ").count
        var rendered = NSAttributedString()
        let build = ms { rendered = Typesetter.render(long, times: false, size: 15) }
        let buildTimes = ms { _ = Typesetter.render(long, times: true, size: 15) }

        let model = Model()
        var window: NSWindow!
        var frame: NSView!
        let first = ms {
            model.pose(.result(long))
            window = makeWindow(model: model, size: CGSize(width: 720, height: 600), dark: false)
            frame = window.contentView!.superview!
            frame.layoutSubtreeIfNeeded()
            _ = png(of: frame, scale: 1)
        }
        settle(0.2)
        func find(_ view: NSView) -> NSScrollView? {
            if let s = view as? NSScrollView, s.documentView is NSTextView { return s }
            for sub in view.subviews { if let s = find(sub) { return s } }
            return nil
        }
        guard let scroll = find(frame), let text = scroll.documentView as? NSTextView else {
            print("bench: no text view found")
            return
        }
        var worst = 0.0
        var total = 0.0
        let steps = 60
        for step in 1...steps {
            let t = ms {
                let y = text.frame.height * Double(step) / Double(steps + 1)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                frame.layoutSubtreeIfNeeded()
                _ = png(of: frame, scale: 1)
            }
            worst = max(worst, t)
            total += t
        }
        let toggle = ms {
            model.showTimes = true
            settle(0.01)
            frame.layoutSubtreeIfNeeded()
            _ = png(of: frame, scale: 1)
        }
        print(
            String(
                format:
                    "bench: %d words, %d characters; build text %.1f ms (timestamps %.1f ms); window with first frame %.1f ms; "
                    + "scroll redraw avg %.1f ms, worst %.1f ms over %d jumps; timestamps toggle %.1f ms; TextKit 2: %@; top inset %.0f",
                words, rendered.length, build, buildTimes, first, total / Double(steps), worst, steps, toggle,
                text.textLayoutManager != nil ? "yes" : "NO", scroll.contentInsets.top))
        window.close()
    }

    // MARK: Live check

    /// With SCRIBE_LIVE_CHECK=<dir> the real app checks its own window and quits: it steps through
    /// sample states, writing what the window drew and a few facts (menus, insets) to that folder.
    /// Adding SCRIBE_LIVE_INPUT=<file or link> runs one real job instead and logs what the progress
    /// display showed and the memory afterwards (SCRIBE_LIVE_HOLD=<seconds> waits longer before measuring);
    /// SCRIBE_LIVE_CANCEL / SCRIBE_LIVE_QUIT=<seconds> stop it part-way.
    /// A stand-in picture on disk (a soft two-colour wash), so snapshots show thumbnails without the network.
    static func samplePicture(_ n: Int) -> String {
        let path = NSTemporaryDirectory() + "scribe-sample-\(n % 6).png"
        if FileManager.default.fileExists(atPath: path) { return path }
        let hues: [(Double, Double)] = [(0.58, 0.72), (0.08, 0.98), (0.36, 0.5), (0.78, 0.62), (0.02, 0.1), (0.5, 0.6)]
        let (a, b) = hues[n % 6]
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSGradient(
                starting: NSColor(hue: a, saturation: 0.55, brightness: 0.85, alpha: 1),
                ending: NSColor(hue: b, saturation: 0.6, brightness: 0.55, alpha: 1))?.draw(in: rect, angle: 35)
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    static func liveCheckIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SCRIBE_LIVE_CHECK"] else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = Model.shared
        var report: [String] = []
        func finish(_ name: String) -> Never {
            try? report.joined(separator: "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            exit(0)
        }
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        func shoot(_ name: String) {
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) }),
                let frame = window.contentView?.superview
            else { return report.append("\(name): no window") }
            if let data = png(of: frame) { try? data.write(to: folder.appendingPathComponent("live-\(name).png")) }
            var menus: [String] = []
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)  // what opening the menu does
                menu.update()
                for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty && !item.isHidden {
                    menus.append("\(top.title)>\(item.title)[\(item.isEnabled ? "on" : "off")\(item.state == .on ? ",checked" : "")]")
                }
            }
            var facts = "\(name): window \(window.frame.size), toolbar items \(window.toolbar?.items.count ?? 0)"
            if let text = textView(in: frame), let scroll = text.enclosingScrollView {
                facts += ", text top inset \(scroll.contentInsets.top), TextKit 2 \(text.textLayoutManager != nil), has keyboard \(window.firstResponder === text)"
            }
            report.append(facts + "\n  " + menus.joined(separator: " | "))
        }
        func footprint() -> String {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return "\(info.phys_footprint / 1_048_576) MB now, \(info.ledger_phys_footprint_peak / 1_048_576) MB peak"
        }
        Task { @MainActor in
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            await pause(0.9)
            if env["SCRIBE_LIVE_CLICKS"] != nil {
                // Real mouse events through the real window: do the keys fire on mouse-down?
                @MainActor func click(_ name: String, x: CGFloat, fromTop y: CGFloat) async {
                    guard let window = NSApp.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) }) else {
                        return report.append("\(name): no window")
                    }
                    let point = NSPoint(x: x < 0 ? window.frame.width + x : x, y: window.frame.height - y)
                    for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1)] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
                        {
                            window.sendEvent(event)
                        }
                        if type == .leftMouseDown { report.append("\(name) on mouse-down: showTimes \(model.showTimes), start screen \(model.isStart)") }
                        await pause(0.15)
                    }
                    await pause(0.4)
                }
                model.pose(.result(sampleTranscript()))
                await pause(0.9)
                let before = model.showTimes
                report.append("before: showTimes \(before), start screen \(model.isStart)")
                await click("TIME", x: -192, fromTop: 26)
                report.append("TIME key toggled timestamps: \(model.showTimes != before)")
                shoot("clicked-time")
                await click("BACK", x: 107, fromTop: 26)
                report.append("BACK key returned to start: \(model.isStart)")
                if model.showTimes != before { model.showTimes = before }
                finish("live-clicks.txt")
            }
            guard let input = env["SCRIBE_LIVE_INPUT"] else {
                let steps: [(String, () -> Void)] = [
                    ("empty", {}),
                    ("working", { model.pose(.working, stage: .transcribing, percent: 41, title: "Weekly product sync") }),
                    ("result", { model.pose(.result(sampleTranscript())) }),
                    ("result-timestamps", { model.showTimes.toggle() }),
                    ("error", {
                        model.showTimes.toggle()
                        model.pose(.failed(message: "That link is unavailable. It may have been removed or the address is wrong.", command: nil))
                    }),
                ]
                for (name, change) in steps {
                    change()
                    await pause(0.9)
                    shoot(name)
                }
                finish("live.txt")
            }
            let began = Date()
            var elapsed: Double { Date().timeIntervalSince(began) }
            var last = ""
            var midShot = false
            var queued = false
            var nextLeft = 1.0
            model.start(input)
            while model.isWorking {
                if let at = env["SCRIBE_LIVE_CANCEL"].flatMap(Double.init), elapsed >= at {
                    model.cancel()
                    report.append(String(format: "%6.2fs  cancelled from the window", elapsed))
                } else if let at = env["SCRIBE_LIVE_QUIT"].flatMap(Double.init), elapsed >= at {
                    report.append(String(format: "%6.2fs  quitting mid-job", elapsed))
                    try? report.joined(separator: "\n").write(to: folder.appendingPathComponent("live-job.txt"), atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
                if !midShot, model.percent >= 60 {
                    midShot = true
                    shoot("working-live")
                    report.append("mid-job: speed \(model.speed.map(String.init) ?? "nil")x, memory \(model.memoryMB.map(String.init) ?? "nil") MB, left \(model.secondsLeft.map(String.init) ?? "nil") s at \(String(format: "%.1f", elapsed)) s, audio \(model.audioSeconds.map { Transcript.clock($0) } ?? "nil"), thumbnail \(model.thumbnail != nil)")
                }
                if !queued, let second = env["SCRIBE_LIVE_QUEUE"], elapsed >= 3 {
                    queued = true
                    model.back()
                    await pause(0.7)
                    report.append("went back mid-job: start screen \(model.isStart), still running \(model.running), pill: \(model.queueSummary ?? "none")")
                    shoot("start-with-job")
                    model.start(second)
                    await pause(0.7)
                    report.append("queued a second: \(model.jobs.map { "\($0.state)" })")
                    shoot("queue")
                }
                if elapsed >= nextLeft {
                    nextLeft += 3
                    report.append(String(format: "eta at %5.1fs: %@ left (%@)", elapsed, model.secondsLeft.map(String.init) ?? "nil", model.stage.label))
                }
                let now = "\(model.stage.label) \(model.percent)%\(model.determinate ? "" : " (no fraction)")"
                if now != last, model.isWorking { report.append(String(format: "%6.2fs  %@", elapsed, now)) }
                last = now
                await pause(0.008)
            }
            // A playlist or channel: take the first few, wait for the list to finish, open one and come back.
            if case .choose(let list) = model.phase {
                report.append(String(format: "%6.2fs  listed \"%@\": %d videos%@", elapsed, list.title, list.items.count, list.more ? "+" : ""))
                shoot("choose")
                model.batchCount = min(env["SCRIBE_LIVE_COUNT"].flatMap(Int.init) ?? 2, list.items.count)
                model.batchFolder = folder.appendingPathComponent("saved")
                model.startBatch(list)
                var shot = false
                while model.running {
                    if let at = env["SCRIBE_LIVE_CANCEL"].flatMap(Double.init), elapsed >= at { model.cancel() }
                    if !shot, model.doneCount == 1 {
                        shot = true
                        await pause(0.5)
                        shoot("batch-running")
                    }
                    await pause(0.05)
                }
                for item in model.jobs { report.append(String(format: "%6.2fs  %@: %@", elapsed, "\(item.state)", item.title)) }
                await pause(0.6)
                shoot("batch-done")
                if let first = model.jobs.first { model.view(first.id) }
                await pause(0.9)
                shoot("batch-item")
                report.append("opened item 0: \(model.transcript.map { "\($0.sentences.count) sentences, from the queue" } ?? "nothing")")
                model.back()
                await pause(0.6)
                report.append("after back: \({ if case .batch = model.phase { "the list" } else { "not the list" } }())")
                model.back()
                await pause(0.6)
                report.append("after second back: \((model.isStart ? "start screen" : "not the start screen") + ", queue pill: " + (model.queueSummary ?? "none"))")
                finish("live-job.txt")
            }
            if queued {
                for item in model.jobs { report.append(String(format: "%6.2fs  %@: %@", elapsed, "\(item.state)", item.title)) }
                shoot("queue-done")
                if let last = model.jobs.last { model.view(last.id) }
                await pause(0.8)
                report.append("opened the last: \(model.transcript.map { "\($0.sentences.count) sentences" } ?? "nothing")")
                finish("live-job.txt")
            }
            var end = "back to the start screen"
            if let t = model.transcript {
                end = "transcript: \(t.turns.count) turns, \(t.speakerCount) speakers, \(t.sentences.count) sentences, engine \(String(format: "%.1f", t.wallSeconds)) s"
            } else if case .failed(let message, _) = model.phase {
                end = "failed: \(message)"
            }
            report.append(String(format: "%6.2fs  %@", elapsed, end))
            let hold = env["SCRIBE_LIVE_HOLD"].flatMap(Double.init) ?? 3
            await pause(hold)
            report.append("memory \(Int(hold)) s after the job: " + footprint())
            finish("live-job.txt")
        }
    }
}
