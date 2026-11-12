import AppKit
import SwiftUI

/// The transcript as one read-only TextKit 2 text view holding one attributed string.
///
/// TextKit 2 lays out only what is on screen, so a transcript of any length appears at once and
/// scrolls smoothly, and one text view gives selection across speakers, Find (Cmd+F), Look Up and
/// VoiceOver for free. It exists only while a transcript is shown.
struct TranscriptView: NSViewRepresentable {
    let transcript: Transcript
    let id: Int
    let times: Bool
    let size: Double

    final class Coordinator {
        var key = ""
        var id = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let text = ColumnTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.unregisterDraggedTypes()  // drops belong to the window, which starts a new transcription
        text.setAccessibilityLabel("Transcript")

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerInsets = NSEdgeInsets(top: 2, left: 0, bottom: 4, right: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let key = "\(id)|\(times)|\(size)"
        guard key != context.coordinator.key else { return }  // unrelated SwiftUI passes must not reset the text
        let fresh = context.coordinator.id != id
        (context.coordinator.key, context.coordinator.id) = (key, id)

        // Switching timestamps or text size keeps roughly the same place in the recording.
        let clip = scroll.contentView
        let place = (clip.bounds.minY + scroll.contentInsets.top) / max(1, text.frame.height - clip.bounds.height)
        // About 78 characters to a line at any text size; the timestamp gutter sits outside that measure.
        (text as? ColumnTextView)?.columnWidth = (CGFloat(size) * 37).rounded() + (times ? 58 : 0)
        text.textStorage?.setAttributedString(Typesetter.render(transcript, times: times, size: size))
        if fresh {
            text.scrollToBeginningOfDocument(nil)
        } else {
            DispatchQueue.main.async {
                let y = min(1, max(0, place)) * max(0, text.frame.height - clip.bounds.height) - scroll.contentInsets.top
                clip.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }
}

/// Keeps the text in a centred column of comfortable reading width however wide the window is.
final class ColumnTextView: NSTextView {
    var columnWidth: CGFloat = 540 {
        didSet { if columnWidth != oldValue { setFrameSize(frame.size) } }
    }

    /// Takes the keyboard as soon as it is shown, so Cmd+F and Cmd+A work straight away.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            if let self, let window = self.window { window.makeFirstResponder(self) }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let inset = NSSize(width: 23, height: 18)  // 28 from the window edge with the text container's own 5
        if textContainerInset != inset { textContainerInset = inset }
        // Lines start at the left edge like every other reading and stop at a comfortable measure.
        let width = max(100, min(newSize.width - 46, columnWidth + 10))
        if let container = textContainer, abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }
}

enum Typesetter {
    /// One colour per speaker, tuned to stay readable as small text on both the light and the dark page.
    static let palette: [NSColor] = [
        (0x0B62D6, 0x6CB2FF), (0xB4530A, 0xFFAB5C), (0x8B3FCF, 0xC79BFF),
        (0x0A7A6B, 0x5AD6C2), (0xC0286F, 0xFF86BC), (0x5C7200, 0xBBD653),
    ].map { light, dark in
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }
    }

    static func color(for speaker: Int) -> NSColor { palette[(max(speaker, 1) - 1) % palette.count] }

    static func render(_ t: Transcript, times: Bool, size: Double) -> NSAttributedString {
        let size = CGFloat(size)
        let out = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ color: NSColor, _ style: NSParagraphStyle, kern: CGFloat = 0) {
            out.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern]))
        }
        // Two tones: the main ink for what was said, a quieter one for everything about it.
        let white = NSColor.labelColor
        let grey = NSColor.secondaryLabelColor
        func style(_ configure: (NSMutableParagraphStyle) -> Void) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            configure(p)
            return p
        }
        let bodyFont = NSFont.systemFont(ofSize: size)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: size - 3, weight: .regular)
        let nameFont = NSFont.systemFont(ofSize: size - 3, weight: .semibold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: size - 2, weight: .regular)
        let leading = (size * 0.32).rounded()

        // Heading: the title, then one quiet line of readings.
        add(t.title + "\n", .systemFont(ofSize: size + 9, weight: .semibold), white, style { $0.paragraphSpacing = 5 })
        var facts = [Transcript.clock(t.audioSeconds)]
        if t.hasSpeakers { facts.append("\(t.speakerCount) speakers") }
        let words = t.fullText.split(separator: " ").count
        facts.append("\(words.formatted()) \(words == 1 ? "word" : "words")")
        if t.wallSeconds > 0 {
            let w = t.wallSeconds
            facts.append(w < 10 ? String(format: "%.1f s", w) : w < 100 ? "\(Int(w)) s" : Transcript.clock(w))
            facts.append(Engine.modelName)
        }
        add(facts.joined(separator: "  ·  ") + "\n", smallFont, grey, style { $0.paragraphSpacing = (size * 0.5).rounded() })
        if let note = t.speakerNote {
            add(note + "\n", smallFont, grey, style { $0.paragraphSpacing = (size * 0.5).rounded() })
        }

        let nameStyle = style {
            $0.paragraphSpacingBefore = (size * 1.2).rounded()
            $0.paragraphSpacing = 3
        }
        guard !t.sentences.isEmpty else {
            let text = t.fullText.isEmpty ? "No speech was found in this recording." : t.fullText
            add(text, bodyFont, t.fullText.isEmpty ? grey : white, style { $0.lineSpacing = leading; $0.paragraphSpacingBefore = size })
            return out
        }

        if times {
            // One sentence per row behind a gutter of times, the same shape as the timestamped export.
            let sample = t.audioSeconds >= 3600 ? "0:00:00" : "00:00"
            let gutter = ((sample as NSString).size(withAttributes: [.font: timeFont]).width + 16).rounded(.up)
            func row(gap: CGFloat) -> NSParagraphStyle {
                style {
                    $0.tabStops = [NSTextTab(textAlignment: .left, location: gutter)]
                    $0.headIndent = gutter
                    $0.lineSpacing = leading
                    $0.paragraphSpacing = (size * 0.4).rounded()
                    $0.paragraphSpacingBefore = gap
                }
            }
            let (tight, loose, first) = (row(gap: 0), row(gap: (size * 0.6).rounded()), row(gap: t.hasSpeakers ? 0 : size))
            var previous: Segment?
            for s in t.sentences {
                let newSpeaker = t.hasSpeakers && s.speaker != previous?.speaker
                if newSpeaker, let who = s.speaker {
                    add(Transcript.speakerName(who) + "\n", nameFont, grey, nameStyle)
                }
                let rowStyle = previous == nil ? first : !newSpeaker && s.start - previous!.end > 2 ? loose : tight
                add(Transcript.clock(s.start) + "\t", timeFont, grey, rowStyle)
                add(s.text + "\n", bodyFont, white, rowStyle)
                previous = s
            }
        } else {
            let body = style {
                $0.lineSpacing = leading
                $0.paragraphSpacing = (size * 0.7).rounded()
            }
            let opening = style {
                $0.lineSpacing = leading
                $0.paragraphSpacing = (size * 0.7).rounded()
                $0.paragraphSpacingBefore = size
            }
            for (i, turn) in t.turns.enumerated() {
                if t.hasSpeakers, let who = turn.speaker {
                    add(Transcript.speakerName(who) + "\n", nameFont, grey, nameStyle)
                }
                for (j, paragraph) in turn.paragraphs.enumerated() {
                    add(paragraph.text + "\n", bodyFont, white, i == 0 && j == 0 && !t.hasSpeakers ? opening : body)
                }
            }
        }
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))  // no trailing blank line
        return out
    }
}
