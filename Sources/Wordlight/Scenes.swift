import AppKit
import CoreText
import QuartzCore

// MARK: - Scene engine
//
// Every lyric style is a "scene": a little Core Animation choreography. Scenes only run code
// when the sung word changes (a few times a second); all motion in between is played by the
// window server, so even the fancy ones cost Wordlight almost nothing.

protocol LyricScene: AnyObject {
    /// Show `index` (the word being sung, -1 before the first). `animated` is false on first show.
    func show(index: Int, now: Double, playing: Bool, animated: Bool)
    /// Instrumental break started / ended.
    func setIdle(_ idle: Bool)
}
extension LyricScene { func setIdle(_ idle: Bool) {} }

/// Everything a scene needs to know, plus shared builders.
final class SceneContext {
    let host: CALayer
    let bounds: CGRect
    let center: CGPoint          // lyric centre, Core Animation coordinates (y up)
    let base: CGFloat            // "big word" font size
    let palette: Palette
    let fonts: FontPair
    let emoji: [Int: String]
    let lyrics: Lyrics
    let scale: CGFloat
    private(set) var lines: [Int: [Int]] = [:]

    init(host: CALayer, bounds: CGRect, center: CGPoint, base: CGFloat, palette: Palette, fonts: FontPair,
         emoji: [Int: String], lyrics: Lyrics, scale: CGFloat) {
        self.host = host; self.bounds = bounds; self.center = center; self.base = base
        self.palette = palette; self.fonts = fonts; self.emoji = emoji; self.lyrics = lyrics; self.scale = scale
        for (i, w) in lyrics.words.enumerated() { lines[w.line, default: []].append(i) }
    }

    var lyricColor: NSColor { NSColor(palette.lyric) }
    var highlightColor: NSColor { NSColor(palette.highlight) }
    var secondaryColor: NSColor { NSColor(palette.secondary) }

    func words(inLine l: Int) -> [Int] { lines[l] ?? [] }
    func line(of index: Int) -> Int { lyrics.words[max(0, min(index, lyrics.words.count - 1))].line }
    func rtl(_ line: Int) -> Bool { words(inLine: line).contains { LyricFonts.isArabic(lyrics.words[$0].text) } }
    func duration(_ i: Int) -> Double { max(0.08, lyrics.words[i].end - lyrics.words[i].start) }
}

private let noActions: [String: CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull(), "contents": NSNull(),
    "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "frame": NSNull(), "hidden": NSNull(),
    "backgroundColor": NSNull(), "shadowOpacity": NSNull(), "filters": NSNull(), "sublayerTransform": NSNull(),
]
func quiet(_ l: CALayer) { l.actions = noActions }

enum Curve {
    static let expoOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let expoIn = CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0)
    static let inOut = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
    static let soft = CAMediaTimingFunction(name: .easeInEaseOut)
    static let linear = CAMediaTimingFunction(name: .linear)
}

/// Basic animation that also sets the final model value. `delay` holds the start value until it begins.
func animate(_ l: CALayer, _ key: String, from: Any?, to: Any?, dur: Double, delay: Double = 0,
             curve: CAMediaTimingFunction = Curve.expoOut, name: String? = nil) {
    let a = CABasicAnimation(keyPath: key)
    a.fromValue = from ?? l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
    a.toValue = to
    a.duration = dur
    a.timingFunction = curve
    if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
    l.setValue(to, forKeyPath: key)
    l.add(a, forKey: name ?? key)
}

/// Spring that also sets the final model value.
func spring(_ l: CALayer, _ key: String, from: Any?, to: Any?, damping: CGFloat = 22, stiffness: CGFloat = 260,
            delay: Double = 0, name: String? = nil) {
    let a = CASpringAnimation(keyPath: key)
    a.fromValue = from ?? l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
    a.toValue = to
    a.damping = damping
    a.stiffness = stiffness
    a.mass = 1
    a.duration = a.settlingDuration
    if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
    l.setValue(to, forKeyPath: key)
    l.add(a, forKey: name ?? key)
}

func keyframes(_ l: CALayer, _ key: String, values: [Any], times: [NSNumber], dur: Double, delay: Double = 0, name: String? = nil) {
    let a = CAKeyframeAnimation(keyPath: key)
    a.values = values
    a.keyTimes = times
    a.duration = dur
    if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
    if let last = values.last { l.setValue(last, forKeyPath: key) }
    l.add(a, forKey: name ?? key)
}

/// A word as layers: either one text layer, or (Latin scripts) one layer per letter so letters
/// can move on their own. Arabic is never split: its letters join, so it always stays whole.
final class Glyphs {
    let layer = CALayer()
    var letters: [CALayer] = []
    var homes: [CGPoint] = []
    var size: CGSize = .zero
    var split = false
}

extension SceneContext {
    func attributes(_ text: String, size: CGFloat, color: NSColor, outline: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font(text, size), .foregroundColor: color]
        if LyricFonts.isArabic(text) { a[.paragraphStyle] = LyricFonts.rtlStyle }
        if outline != 0 { a[.strokeWidth] = outline; a[.strokeColor] = color }
        return a
    }

    func font(_ text: String, _ size: CGFloat) -> NSFont { fonts.font(for: text, size) }

    /// Measure a string: typographic width and line height.
    func measure(_ text: String, size: CGFloat) -> (width: CGFloat, height: CGFloat, line: CTLine) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(text, size)]
        if LyricFonts.isArabic(text) { attrs[.paragraphStyle] = LyricFonts.rtlStyle }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        return (ceil(w), ceil(asc + desc + max(0, lead)), line)
    }

    func textLayer(_ s: NSAttributedString, frame: CGRect) -> CATextLayer {
        let t = CATextLayer()
        t.string = s
        t.alignmentMode = .center
        t.contentsScale = scale
        t.frame = frame
        quiet(t)
        return t
    }

    /// Build a word. `split` breaks Latin words into letter layers.
    func glyphs(_ text: String, size: CGFloat, color: NSColor, split: Bool = false, outline: CGFloat = 0,
                emoji: String? = nil) -> Glyphs {
        let g = Glyphs()
        quiet(g.layer)
        let attrs = attributes(text, size: size, color: color, outline: outline)
        let m = measure(text, size: size)
        let pad = size * 0.14
        let emojiSize: CGSize = emoji.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size * 0.7)]) } ?? .zero
        let gap = emoji == nil ? 0 : size * 0.14
        let textW = m.width + pad * 2
        g.size = CGSize(width: textW + gap + ceil(emojiSize.width), height: max(m.height + pad, emojiSize.height))
        g.layer.bounds = CGRect(origin: .zero, size: g.size)
        let arabic = LyricFonts.isArabic(text)
        let textX: CGFloat = arabic && emoji != nil ? gap + ceil(emojiSize.width) : 0
        let textFrame = CGRect(x: textX, y: (g.size.height - m.height - pad) / 2, width: textW, height: m.height + pad)

        if split && !arabic && text.count <= 28 {
            g.split = true
            var idx = text.startIndex
            while idx < text.endIndex {
                let next = text.index(after: idx)
                let ch = String(text[idx..<next])
                let r = NSRange(idx..<next, in: text)
                let x0 = CTLineGetOffsetForStringIndex(m.line, r.location, nil)
                let x1 = CTLineGetOffsetForStringIndex(m.line, r.location + r.length, nil)
                if !ch.trimmingCharacters(in: .whitespaces).isEmpty {
                    let cw = max(x1 - x0, size * 0.2) + pad * 2
                    let t = textLayer(NSAttributedString(string: ch, attributes: attrs),
                                      frame: CGRect(x: 0, y: 0, width: cw, height: textFrame.height))
                    t.position = CGPoint(x: textFrame.minX + pad + (x0 + x1) / 2, y: textFrame.midY)
                    g.layer.addSublayer(t)
                    g.letters.append(t)
                    g.homes.append(t.position)
                }
                idx = next
            }
        } else {
            let t = textLayer(NSAttributedString(string: text, attributes: attrs), frame: textFrame)
            g.layer.addSublayer(t)
            g.letters = [t]
            g.homes = [t.position]
        }
        if let e = emoji {
            let ex: CGFloat = arabic ? 0 : textW + gap
            let el = textLayer(NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: size * 0.7)]),
                               frame: CGRect(x: ex, y: (g.size.height - emojiSize.height) / 2, width: ceil(emojiSize.width), height: ceil(emojiSize.height)))
            g.layer.addSublayer(el)
        }
        return g
    }

    /// Centred, wrapped rows for a line (offsets from the lyric centre; y up). Mirrors for RTL.
    func rows(_ sizes: [CGSize], maxWidth: CGFloat, gap: CGFloat, rowGap: CGFloat, rtl: Bool) -> [CGPoint] {
        var rows: [[Int]] = [[]]
        var w: CGFloat = 0
        for (k, s) in sizes.enumerated() {
            let add = (rows[rows.count - 1].isEmpty ? 0 : gap) + s.width
            if w + add > maxWidth, !rows[rows.count - 1].isEmpty { rows.append([]); w = 0 }
            w += (rows[rows.count - 1].isEmpty ? 0 : gap) + s.width
            rows[rows.count - 1].append(k)
        }
        let rowH = (sizes.map(\.height).max() ?? 0) + rowGap
        var out = [CGPoint](repeating: .zero, count: sizes.count)
        for (r, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + sizes[$1].width } + gap * CGFloat(max(0, row.count - 1))
            var x = -total / 2
            for k in (rtl ? row.reversed() : row) {
                out[k] = CGPoint(x: x + sizes[k].width / 2, y: (CGFloat(rows.count - 1) / 2 - CGFloat(r)) * rowH)
                x += sizes[k].width + gap
            }
        }
        return out
    }

    /// A full-screen container whose anchor sits on the lyric centre, so scaling / 3D turns
    /// happen around the text. Sublayer coordinates equal the host's.
    func groupLayer() -> CALayer {
        let g = CALayer()
        quiet(g)
        g.bounds = CGRect(origin: .zero, size: bounds.size)
        g.anchorPoint = CGPoint(x: center.x / max(1, bounds.width), y: center.y / max(1, bounds.height))
        g.position = center
        return g
    }
}

// MARK: - Line-based scene skeleton

/// Shared logic for scenes that show one line at a time: build lines ahead of time, swap lines
/// with an enter/exit choreography, and reveal words as they're sung.
class LineScene: LyricScene {
    final class Line {
        let layer: CALayer
        var words: [Int] = []
        var glyphs: [Int: Glyphs] = [:]
        var homes: [Int: CGPoint] = [:]
        var extras: [Int: [CALayer]] = [:]   // per-word extra layers (copies, masks, halves…)
        var sung: Set<Int> = []
        init(_ l: CALayer) { layer = l }
    }

    let ctx: SceneContext
    var lines: [Int: Line] = [:]
    var current = Int.min
    var lastWord = -1

    // Tunables for subclasses
    var sizeFactor: CGFloat { 0.6 }
    var splitLetters: Bool { false }
    var wrapWidth: CGFloat { ctx.bounds.width * 0.78 }

    required init(ctx: SceneContext) { self.ctx = ctx }

    // Hooks
    func build(_ l: Line, line: Int) {
        let size = ctx.base * sizeFactor
        let rtl = ctx.rtl(line)
        var gs: [Glyphs] = []
        for i in l.words {
            let g = ctx.glyphs(ctx.lyrics.words[i].text, size: size, color: ctx.lyricColor, split: splitLetters, emoji: ctx.emoji[i])
            gs.append(g)
            l.glyphs[i] = g
        }
        let pos = ctx.rows(gs.map(\.size), maxWidth: wrapWidth, gap: size * 0.26, rowGap: size * 0.12, rtl: rtl)
        for (k, i) in l.words.enumerated() {
            let p = CGPoint(x: ctx.center.x + pos[k].x, y: ctx.center.y + pos[k].y)
            l.homes[i] = p
            l.glyphs[i]!.layer.position = p
            l.layer.addSublayer(l.glyphs[i]!.layer)
        }
    }
    func idle(_ l: Line, _ i: Int) {}
    func sing(_ l: Line, _ i: Int, animated: Bool, now: Double) {}
    func enter(_ l: Line, animated: Bool) {
        if animated { animate(l.layer, "opacity", from: 0, to: 1, dur: 0.4) } else { l.layer.opacity = 1 }
    }
    func exit(_ l: Line, animated: Bool) -> Double {
        if animated { animate(l.layer, "opacity", from: nil, to: 0, dur: 0.35, curve: Curve.soft) }
        return 0.4
    }
    /// Called after the line changed and on every word.
    func wordChanged(_ l: Line, from old: Int, to new: Int, animated: Bool) {}

    func line(_ n: Int) -> Line? {
        if let l = lines[n] { return l }
        let words = ctx.words(inLine: n)
        guard !words.isEmpty else { return nil }
        let l = Line(ctx.groupLayer())
        l.words = words
        CATransaction.begin(); CATransaction.setDisableActions(true)
        build(l, line: n)
        for i in words { idle(l, i) }
        l.layer.opacity = 0
        ctx.host.addSublayer(l.layer)
        CATransaction.commit()
        lines[n] = l
        return l
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard !ctx.lyrics.words.isEmpty else { return }
        let n = index >= 0 ? ctx.line(of: index) : ctx.lyrics.words[0].line
        if n != current {
            if let old = lines[current] {
                let t = exit(old, animated: animated)
                lines[current] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { old.layer.removeFromSuperlayer() }
            }
            current = n
            guard let l = line(n) else { return }
            enter(l, animated: animated)
            // Jumped into the middle of a line (seek / first show): earlier words appear sung.
            for i in l.words where i < index && !l.sung.contains(i) { l.sung.insert(i); sing(l, i, animated: false, now: now) }
            _ = line(n + 1) // build the next line ahead of time, hidden
        }
        guard let l = lines[n] else { return }
        if index >= 0, l.words.contains(index), !l.sung.contains(index) {
            l.sung.insert(index)
            sing(l, index, animated: animated, now: now)
        }
        wordChanged(l, from: lastWord, to: index, animated: animated)
        lastWord = index
    }
}
