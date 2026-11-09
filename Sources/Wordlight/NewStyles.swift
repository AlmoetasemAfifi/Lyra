import AppKit
import QuartzCore

// Styles built on baked word sprites: Depth, Marker, Ribbon, Constellation.
// All motion is eased (no springs, no bounce); the window server plays it.

/// Shared word holder: a dim copy and a lit copy crossfaded when sung (plus an optional soft copy).
private final class WordSprite {
    let layer = CALayer()
    let dim: CALayer, lit: CALayer
    var soft: CALayer?
    let box: CGSize
    var home: CGPoint = .zero
    init(ctx: SceneContext, i: Int, size: CGFloat, dimAlpha: CGFloat = 0.4, litLook: SpriteLook? = nil, softBlur: CGFloat = 0) {
        quiet(layer)
        let t = ctx.lyrics.words[i].text + (ctx.emoji[i].map { " " + $0 } ?? "")
        let dS = ctx.sprite(t, size: size, look: SpriteLook(fill: .solid(ctx.lyricColor.withAlphaComponent(dimAlpha).rgba), shadow: true))
        let lS = ctx.sprite(t, size: size, look: litLook ?? ctx.shadowLook)
        box = CGSize(width: dS.text.width + size * 0.24, height: dS.text.height + size * 0.1)
        layer.bounds = CGRect(origin: .zero, size: box)
        let mid = CGPoint(x: box.width / 2, y: box.height / 2)
        dim = ctx.spriteLayer(dS); lit = ctx.spriteLayer(lS)
        dim.position = mid; lit.position = mid; lit.opacity = 0
        if softBlur > 0 {
            var look = SpriteLook(fill: .solid(ctx.lyricColor.withAlphaComponent(dimAlpha).rgba)); look.blur = softBlur
            let s = ctx.spriteLayer(ctx.sprite(t, size: size, look: look))
            s.position = mid; s.opacity = 0
            layer.addSublayer(s); soft = s
        }
        layer.addSublayer(dim); layer.addSublayer(lit)
    }
}

private let glide = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.2, 1)

// MARK: - Depth — lines float in 3D; the sung one sharp up front, finished lines fly past you

final class DepthScene: LyricScene {
    private let ctx: SceneContext
    private final class DLine { let layer = CALayer(); var words: [Int: WordSprite] = [:]; var sung = Set<Int>() }
    private var lines: [Int: DLine] = [:]
    private var current = Int.min
    private var size: CGFloat { ctx.base * 0.7 }

    init(ctx: SceneContext) { self.ctx = ctx }

    /// d = line distance from the current one (negative = already sung).
    private func pose(_ d: Int) -> (scale: CGFloat, opacity: Float, dy: CGFloat, soft: Float) {
        switch d {
        case ..<0: return (1.75, 0, -ctx.base * 1.4, 1)
        case 0: return (1, 1, 0, 0)
        case 1: return (0.6, 0.55, ctx.base * 1.25, 1)
        case 2: return (0.4, 0.25, ctx.base * 2.0, 1)
        default: return (0.3, 0, ctx.base * 2.5, 1)
        }
    }

    private func build(_ n: Int) -> DLine? {
        if let l = lines[n] { return l }
        let idx = ctx.words(inLine: n)
        guard !idx.isEmpty else { return nil }
        let l = DLine()
        quiet(l.layer)
        let b = ctx.bounds
        l.layer.bounds = b
        l.layer.anchorPoint = CGPoint(x: ctx.center.x / max(1, b.width), y: ctx.center.y / max(1, b.height))
        l.layer.position = ctx.center
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let lit = SpriteLook(fill: .solid(ctx.lyricColor.rgba), glow: 0.05, glowColor: ctx.highlightColor.rgba, shadow: true)
        let ws = idx.map { WordSprite(ctx: ctx, i: $0, size: size, dimAlpha: 0.5, litLook: lit, softBlur: 0.12) }
        let pos = ctx.rows(ws.map(\.box), maxWidth: min(ctx.bounds.width * 0.78, size * 15), gap: size * 0.05, rowGap: size * 0.08, rtl: ctx.rtl(n))
        for (k, w) in ws.enumerated() {
            w.home = CGPoint(x: ctx.center.x + pos[k].x, y: ctx.center.y + pos[k].y)
            w.layer.position = w.home
            l.layer.addSublayer(w.layer)
            l.words[idx[k]] = w
        }
        let p = pose(9)
        l.layer.opacity = 0
        l.layer.setValue(p.scale, forKeyPath: "transform.scale")
        ctx.host.insertSublayer(l.layer, at: 0)
        CATransaction.commit()
        lines[n] = l
        return l
    }

    private func place(_ l: DLine, _ d: Int, animated: Bool) {
        let p = pose(d)
        let dur = 0.75
        let pos = CGPoint(x: ctx.center.x, y: ctx.center.y + p.dy)
        l.layer.zPosition = CGFloat(-d)
        if animated {
            animate(l.layer, "transform.scale", from: nil, to: p.scale, dur: dur, curve: glide)
            animate(l.layer, "position", from: nil, to: NSValue(point: pos), dur: dur, curve: glide)
            animate(l.layer, "opacity", from: nil, to: p.opacity, dur: d < 0 ? 0.5 : dur, curve: Curve.soft)
        } else {
            l.layer.setValue(p.scale, forKeyPath: "transform.scale"); l.layer.position = pos; l.layer.opacity = p.opacity
        }
        for w in l.words.values {
            guard let s = w.soft else { continue }
            if animated {
                animate(s, "opacity", from: nil, to: p.soft, dur: dur * 0.8, curve: Curve.soft)
                animate(w.dim, "opacity", from: nil, to: 1 - p.soft, dur: dur * 0.8, curve: Curve.soft)
            } else { s.opacity = p.soft; w.dim.opacity = 1 - p.soft }
        }
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard !ctx.lyrics.words.isEmpty else { return }
        let n = index >= 0 ? ctx.line(of: index) : ctx.lyrics.words[0].line
        if n != current {
            current = n
            for k in n...(n + 2) { _ = build(k) }
            for (k, l) in lines { place(l, k - n, animated: animated) }
            for (k, l) in lines where k < n - 1 || k > n + 3 {
                lines[k] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { l.layer.removeFromSuperlayer() }
            }
            if let l = lines[n] { for i in l.words.keys where i < index { light(l, i, animated: false) } }
            ctx.prefetch(ctx.words(inLine: n + 3), size: size, looks: [])
        }
        if index >= 0, let l = lines[n], l.words[index] != nil { light(l, index, animated: animated) }
    }

    private func light(_ l: DLine, _ i: Int, animated: Bool) {
        guard let w = l.words[i], !l.sung.contains(i) else { return }
        l.sung.insert(i)
        guard animated else { w.lit.opacity = 1; return }
        let d = min(0.5, max(0.25, ctx.duration(i)))
        animate(w.lit, "opacity", from: 0, to: 1, dur: d, curve: Curve.soft)
        // The word comes forward a touch as it's sung.
        keyframes(w.layer, "transform.scale", values: [1, 1.06, 1], times: [0, 0.35, 1], dur: d + 0.35)
    }
}

// MARK: - Marker — a glowing pill glides behind each word as it's sung

final class MarkerScene: SpriteLineScene {
    override var sizeFactor: CGFloat { 0.66 }
    private var pills: [Int: CALayer] = [:]
    private var lastItem: [Int: Int] = [:]

    override func makeItem(_ i: Int, size: CGFloat) -> Item {
        let it = Item()
        let t = ctx.lyrics.words[i].text + (ctx.emoji[i].map { " " + $0 } ?? "")
        let dim = ctx.sprite(t, size: size, look: SpriteLook(fill: .solid(ctx.lyricColor.withAlphaComponent(0.42).rgba), shadow: true))
        let lit = ctx.sprite(t, size: size, look: ctx.shadowLook)
        let ink = ctx.sprite(t, size: size, look: SpriteLook(fill: .solid(NSColor(white: 0.06, alpha: 1).rgba)))
        it.box = CGSize(width: dim.text.width + size * 0.34, height: dim.text.height + size * 0.16)
        it.layer.bounds = CGRect(origin: .zero, size: it.box)
        let mid = CGPoint(x: it.box.width / 2, y: it.box.height / 2)
        for (k, s) in [("dim", dim), ("lit", lit), ("ink", ink)] {
            let l = ctx.spriteLayer(s); l.position = mid; l.opacity = k == "dim" ? 1 : 0
            it.layer.addSublayer(l); it.parts[k] = l
        }
        return it
    }

    override func didLayout(_ l: Line) {
        let pill = CALayer(); quiet(pill)
        pill.backgroundColor = ctx.highlightColor.cgColor
        pill.shadowColor = ctx.highlightColor.cgColor
        pill.shadowOpacity = 0.75
        pill.shadowRadius = ctx.base * 0.22
        pill.shadowOffset = .zero
        pill.opacity = 0
        if let first = l.order.first, let it = l.items[first] {
            pill.bounds = CGRect(origin: .zero, size: CGSize(width: it.box.width * 0.6, height: it.box.height * 0.86))
            pill.cornerRadius = it.box.height * 0.43
            pill.position = it.home
        }
        l.layer.insertSublayer(pill, at: 0)
        pills[l.number] = pill
    }

    override func enter(_ l: Line, animated: Bool) {
        l.layer.opacity = 1
        guard animated else { return }
        for (k, i) in l.order.enumerated() {
            guard let it = l.items[i] else { continue }
            let delay = Double(k) * 0.035
            animate(it.layer, "opacity", from: 0, to: 1, dur: 0.45, delay: delay, curve: Curve.soft)
            animate(it.layer, "position", from: NSValue(point: CGPoint(x: it.home.x, y: it.home.y - ctx.base * 0.14)), to: NSValue(point: it.home), dur: 0.6, delay: delay, curve: glide)
        }
    }

    override func sing(_ l: Line, _ it: Item, animated: Bool, now: Double) {
        guard let pill = pills[l.number] else { return }
        let target = CGRect(origin: .zero, size: CGSize(width: max(it.box.width + ctx.base * 0.2, it.box.height * 1.6), height: it.box.height * 0.8))
        let d = animated ? min(0.32, max(0.16, ctx.duration(it.index) * 0.6)) : 0
        // Previous word: off the pill, now just lit.
        if let prev = lastItem[l.number], prev != it.index, let p = l.items[prev] {
            fade(p.parts["ink"]!, 0, d); fade(p.parts["lit"]!, 1, d); fade(p.parts["dim"]!, 0, d)
        }
        lastItem[l.number] = it.index
        fade(it.parts["ink"]!, 1, d); fade(it.parts["dim"]!, 0, d)
        if animated {
            animate(pill, "bounds", from: nil, to: NSValue(rect: target), dur: d * 1.3, curve: glide)
            animate(pill, "position", from: nil, to: NSValue(point: it.home), dur: d * 1.3, curve: glide)
            if pill.opacity < 1 { animate(pill, "opacity", from: 0, to: 1, dur: 0.2, curve: Curve.soft) }
        } else { pill.bounds = target; pill.position = it.home; pill.opacity = 1 }
        pill.cornerRadius = target.height / 2
    }

    private func fade(_ l: CALayer, _ to: Float, _ d: Double) {
        if d > 0 { animate(l, "opacity", from: nil, to: to, dur: d, curve: Curve.soft) } else { l.opacity = to }
    }

    override func exit(_ l: Line, animated: Bool) -> Double {
        if let prev = lastItem[l.number], let p = l.items[prev] { fade(p.parts["ink"]!, 0, animated ? 0.2 : 0); fade(p.parts["lit"]!, 1, animated ? 0.2 : 0) }
        if let pill = pills[l.number] { fade(pill, 0, animated ? 0.25 : 0) }
        pills[l.number] = nil
        guard animated else { l.layer.opacity = 0; return 0 }
        let p = l.layer.position
        animate(l.layer, "position", from: NSValue(point: p), to: NSValue(point: CGPoint(x: p.x, y: p.y + ctx.base * 0.35)), dur: 0.5, curve: glide)
        animate(l.layer, "opacity", from: 1, to: 0, dur: 0.4, curve: Curve.soft)
        return 0.5
    }
}

// MARK: - Ribbon — an endless ribbon of words flowing past a fixed reading point

final class RibbonScene: LyricScene {
    private let ctx: SceneContext
    private let script: SongScript?
    private let row = CALayer()
    private var words: [Int: WordSprite] = [:]
    private var xs: [Int: CGFloat] = [:]       // centre of each word along the ribbon
    private var widths: [Int: CGFloat] = [:]
    private var lastIndex = Int.min
    private let rtl: Bool
    private var size: CGFloat { ctx.base * 0.95 }
    private var focusX: CGFloat { ctx.bounds.width * (rtl ? 0.64 : 0.36) }

    init(ctx: SceneContext, script: SongScript?) {
        self.ctx = ctx
        self.script = script
        let sample = ctx.lyrics.words.prefix(40)
        rtl = sample.filter { LyricFonts.isArabic($0.text) }.count * 2 > sample.count
        quiet(row)
        row.frame = ctx.bounds
        ctx.host.addSublayer(row)
        // Soft edges: the ribbon fades out toward both sides of the screen.
        let m = CAGradientLayer()
        m.frame = ctx.bounds
        m.startPoint = CGPoint(x: 0, y: 0.5); m.endPoint = CGPoint(x: 1, y: 0.5)
        m.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        m.locations = [0.02, 0.2, 0.8, 0.98]
        ctx.host.mask = m
    }

    private func width(_ i: Int) -> CGFloat {
        if let w = widths[i] { return w }
        let t = ctx.lyrics.words[i].text + (ctx.emoji[i].map { " " + $0 } ?? "")
        let w = ctx.measure(t, size: size).width + size * 0.24
        widths[i] = w
        return w
    }

    /// Position along the ribbon (grows away from the reading point; lines get a wider gap).
    private var computed = -1
    private func x(_ i: Int) -> CGFloat {
        let words = ctx.lyrics.words
        while computed < i {
            let j = computed + 1
            if j == 0 { xs[0] = 0 } else {
                let gap = size * (words[j].line != words[j - 1].line ? 0.85 : 0.08)
                xs[j] = xs[j - 1]! + width(j - 1) / 2 + gap + width(j) / 2
            }
            computed = j
        }
        return xs[i] ?? 0
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        let focus = max(0, index)
        guard focus != lastIndex, !ctx.lyrics.words.isEmpty else { return }
        let lo = max(0, focus - 8), hi = min(ctx.lyrics.words.count - 1, focus + 16)
        let dir: CGFloat = rtl ? -1 : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in lo...hi where words[i] == nil {
            let punch = ctx.emphasized(i, script)
            let lit = SpriteLook(fill: .solid((punch ? ctx.highlightColor : ctx.lyricColor).rgba), glow: punch ? 0.08 : 0.03, glowColor: ctx.highlightColor.rgba, shadow: true)
            let w = WordSprite(ctx: ctx, i: i, size: size, dimAlpha: 0.38, litLook: lit)
            w.layer.position = CGPoint(x: dir * x(i), y: ctx.center.y)
            if i < focus || (index >= 0 && i == focus) { w.lit.opacity = 1; w.dim.opacity = 0 }
            row.addSublayer(w.layer)
            words[i] = w
        }
        CATransaction.commit()
        // Slide the ribbon so the sung word sits at the reading point.
        let target = CGPoint(x: focusX - dir * x(focus) + ctx.bounds.width / 2, y: ctx.bounds.height / 2)
        if animated && lastIndex != Int.min {
            let d = min(0.55, max(0.3, index >= 0 ? ctx.duration(focus) : 0.4))
            animate(row, "position", from: nil, to: NSValue(point: target), dur: d, curve: glide)
        } else { row.position = target }
        for (i, w) in words {
            let dist = i - focus
            // Behind the reading point words dim away; ahead they wait at half brightness.
            let o: Float = dist < 0 ? max(0, 0.75 + Float(dist) * 0.2) : (dist == 0 ? 1 : max(0.1, 0.7 - Float(dist) * 0.09))
            if animated { animate(w.layer, "opacity", from: nil, to: o, dur: 0.4, curve: Curve.soft) } else { w.layer.opacity = o }
        }
        if index >= 0, let w = words[focus], w.lit.opacity < 1 {
            if animated {
                animate(w.lit, "opacity", from: 0, to: 1, dur: 0.22, curve: Curve.soft)
                animate(w.dim, "opacity", from: 1, to: 0, dur: 0.22, curve: Curve.soft)
                keyframes(w.layer, "transform.scale", values: [1, 1.08, 1], times: [0, 0.3, 1], dur: 0.6)
            } else { w.lit.opacity = 1; w.dim.opacity = 0 }
        }
        for (i, w) in words where i < lo || i > hi {
            words[i] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { w.layer.removeFromSuperlayer() }
        }
        lastIndex = focus
    }
}

// MARK: - Constellation — every sung word becomes a star, linked to the last one; repeats link back and grow

final class ConstellationScene: LyricScene {
    private let ctx: SceneContext
    private let script: SongScript?
    private final class Star {
        let holder = CALayer()
        let dot = CAShapeLayer()
        let dim: CALayer, lit: CALayer
        var hits = 1
        var pos: CGPoint = .zero
        init(dim: CALayer, lit: CALayer) { self.dim = dim; self.lit = lit }
    }
    private var group: CALayer?
    private var stars: [String: Star] = [:]
    private var last: Star?
    private var column = 0
    private var lastIndex = Int.min
    private var lastLine = -1
    private let ring = CAShapeLayer()
    private let rtl: Bool
    /// Each new constellation runs the other way (and starts a little differently), so it never always begins on the left.
    private var flip = false
    private var startShift: CGFloat = 0
    private var ringR: CGFloat { ctx.base * 0.13 }
    private var area: CGRect {
        let w = min(ctx.bounds.width * 0.74, ctx.base * 16), h = min(ctx.bounds.height * 0.5, ctx.base * 4.6)
        return CGRect(x: ctx.center.x - w / 2, y: ctx.center.y - h / 2, width: w, height: h)
    }
    private let columns = 8

    init(ctx: SceneContext, script: SongScript?) {
        self.ctx = ctx
        self.script = script
        let sample = ctx.lyrics.words.prefix(40)
        rtl = sample.filter { LyricFonts.isArabic($0.text) }.count * 2 > sample.count
        flip = !rtl   // toggled on the first constellation: Arabic songs start on the right
        quiet(ring)
        let r = ctx.base * 0.13
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = ctx.highlightColor.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 1.6
        ring.shadowColor = ctx.highlightColor.cgColor; ring.shadowOpacity = 1; ring.shadowRadius = 6; ring.shadowOffset = .zero
        ring.shadowPath = CGPath(ellipseIn: CGRect(x: -r - 1, y: -r - 1, width: r * 2 + 2, height: r * 2 + 2), transform: nil)
        ring.opacity = 0
        ctx.host.addSublayer(ring)
    }

    /// A four-point sparkle.
    private static func sparkle(_ r: CGFloat) -> CGPath {
        let p = CGMutablePath(), k = r * 0.22
        p.move(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: k))
        p.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: k, y: -k))
        p.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: -k))
        p.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: -k, y: k))
        return p
    }

    private static func key(_ t: String) -> String {
        t.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Where the n-th new star goes: columns march across the area, rows zig-zag with a seeded jitter.
    private func spot(_ n: Int, seed: Int) -> CGPoint {
        let a = area
        var rng = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ n &* 40503)
        func rand() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 33) / CGFloat(UInt32.max >> 1) }
        // Mostly forward, sometimes doubling back a little, like a hand-drawn constellation.
        let fx = min(0.98, max(0.02, (CGFloat(n) + 0.5 + (rand() - 0.5) * 0.45) / CGFloat(columns)))
        let f = min(0.98, fx * (1 - startShift) + startShift * 0.5)
        let x = flip ? a.maxX - f * a.width : a.minX + f * a.width
        // Of a few heights, take the one farthest from the stars already placed, so words never pile up.
        let rows: [CGFloat] = [0.1, 0.3, 0.5, 0.7, 0.9]
        let jitter = (rand() - 0.5) * 0.08
        let others = stars.values.map(\.pos)
        func room(_ p: CGPoint) -> CGFloat {
            others.map { hypot(($0.x - p.x) * 0.6, $0.y - p.y) }.min() ?? .greatestFiniteMagnitude
        }
        let start = (n + seed) % rows.count
        let candidates = (0..<rows.count).map { k -> CGPoint in
            let fy = min(0.97, max(0.03, rows[(start + k) % rows.count] + jitter))
            return CGPoint(x: x, y: a.minY + fy * a.height)
        }
        return candidates.max { room($0) < room($1) } ?? candidates[0]
    }

    private func newGroup(animated: Bool) {
        if let old = group {
            if animated {
                animate(old, "opacity", from: nil, to: 0, dur: 0.7, curve: Curve.soft)
                animate(old, "transform.scale", from: 1, to: 1.06, dur: 0.8, curve: glide)
            } else { old.opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { old.removeFromSuperlayer() }
        }
        let g = CALayer(); quiet(g)
        g.frame = ctx.bounds
        ctx.host.insertSublayer(g, below: ring)
        group = g
        stars = [:]
        last = nil
        column = 0
        flip.toggle()
        startShift = CGFloat((stars.count + lastIndex.magnitude.hashValue) % 3) * 0.08
    }

    /// Text, font and looks for a word's label (star labels read best in a clean sans; Arabic keeps its font).
    private func label(_ i: Int) -> (String, NSFont, SpriteLook, SpriteLook) {
        let w = ctx.lyrics.words[i]
        let size = ctx.base * (ctx.emphasized(i, script) ? 0.34 : 0.28)
        let text = w.text + (ctx.emoji[i].map { " " + $0 } ?? "")
        let font = LyricFonts.isArabic(text) ? ctx.font(text, size * 1.1) : NSFont.systemFont(ofSize: size, weight: .semibold)
        let hi = ctx.highlightColor
        return (text, font, SpriteLook(fill: .solid(hi.withAlphaComponent(0.8).rgba)),
                SpriteLook(fill: .solid(NSColor.white.rgba), glow: 0.1, glowColor: hi.rgba))
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard index >= 0, index != lastIndex, index < ctx.lyrics.words.count else { return }
        // Draw the next words' labels in the background, so a new star never waits on drawing.
        let ahead = (index + 1 ..< min(ctx.lyrics.words.count, index + 9)).flatMap { j -> [(String, NSFont, SpriteLook)] in
            let (t, f, d, l) = label(j); return [(t, f, d), (t, f, l)]
        }
        Sprites.prefetch(ahead, scale: ctx.scale)
        let words = ctx.lyrics.words
        let from = (lastIndex == Int.min || index < lastIndex) ? index : lastIndex + 1
        for i in from...index { place(i, animated: animated && i == index, now: now, words: words) }
        lastIndex = index
    }

    private func place(_ i: Int, animated: Bool, now: Double, words: [LyricWord]) {
        let w = words[i]
        // A new constellation after a pause in the singing or when this one is full.
        let pause = i > 0 && w.start - words[i - 1].end > 2.8
        if group == nil || pause || (column >= columns && stars[Self.key(w.text)] == nil) { newGroup(animated: animated) }
        lastLine = w.line
        guard let g = group else { return }
        let k = Self.key(w.text)
        let hi = ctx.highlightColor
        let star: Star
        if let existing = stars[k], !k.isEmpty {
            // A repeat: link back to the same star, and let its word grow.
            star = existing
            star.hits += 1
            let s = min(1.8, 1 + CGFloat(star.hits - 1) * 0.28)
            animated ? animate(star.holder, "transform.scale", from: nil, to: s, dur: 0.5, curve: glide) : star.holder.setValue(s, forKeyPath: "transform.scale")
        } else {
            let (text, font, dimLook, litLook) = label(i)
            let dimS = Sprites.get(text, font: font, look: dimLook, scale: ctx.scale)
            let litS = Sprites.get(text, font: font, look: litLook, scale: ctx.scale)
            star = Star(dim: ctx.spriteLayer(dimS), lit: ctx.spriteLayer(litS))
            quiet(star.holder)
            star.pos = spot(column, seed: w.line &* 31 &+ i)
            column += 1
            star.holder.position = star.pos
            let r = ctx.base * 0.085
            star.dot.path = Self.sparkle(r)
            star.dot.fillColor = (hi.blended(withFraction: 0.35, of: .white) ?? hi).cgColor
            star.dot.shadowColor = hi.cgColor; star.dot.shadowOpacity = 0.9; star.dot.shadowRadius = 4; star.dot.shadowOffset = .zero
            star.dot.shadowPath = star.dot.path
            quiet(star.dot)
            // The word sits just above its star.
            // The word sits clear above the ring, never under it.
            let off = CGPoint(x: 0, y: ringR + dimS.text.height * 0.5 + 2)
            star.dim.position = off; star.lit.position = off; star.lit.opacity = 0
            star.holder.addSublayer(star.dot); star.holder.addSublayer(star.dim); star.holder.addSublayer(star.lit)
            g.addSublayer(star.holder)
            stars[k] = star
            if animated {
                animate(star.holder, "opacity", from: 0, to: 1, dur: 0.3, curve: Curve.soft)
                animate(star.dot, "transform.scale", from: 2.2, to: 1, dur: 0.5, curve: Curve.expoOut)
                animate(star.dot, "transform.rotation.z", from: -0.8, to: 0, dur: 0.6, curve: Curve.expoOut)
            }
        }
        // The link from the previous star, drawn in as it's sung.
        if let prev = last, prev !== star {
            let link = CAShapeLayer(); quiet(link)
            let p = CGMutablePath(); p.move(to: prev.pos); p.addLine(to: star.pos)
            link.path = p
            link.strokeColor = hi.withAlphaComponent(0.55).cgColor
            link.lineWidth = 1
            link.fillColor = nil
            g.insertSublayer(link, at: 0)
            if animated { animate(link, "strokeEnd", from: 0, to: 1, dur: min(0.35, max(0.15, ctx.duration(i) * 0.6)), curve: glide) }
        }
        // Light this word, dim the last one; the ring glides to the new star.
        if let prev = last, prev !== star {
            animated ? animate(prev.lit, "opacity", from: nil, to: 0, dur: 0.3, curve: Curve.soft) : (prev.lit.opacity = 0)
            animated ? animate(prev.dim, "opacity", from: nil, to: 1, dur: 0.3, curve: Curve.soft) : (prev.dim.opacity = 1)
        }
        if animated {
            animate(star.lit, "opacity", from: nil, to: 1, dur: 0.2, curve: Curve.soft)
            animate(star.dim, "opacity", from: nil, to: 0, dur: 0.2, curve: Curve.soft)
            keyframes(star.dot, "transform.scale", values: [1, 1.7, 1], times: [0, 0.3, 1], dur: 0.55)
            animate(ring, "position", from: ring.opacity > 0 ? nil : NSValue(point: star.pos), to: NSValue(point: star.pos), dur: 0.3, curve: glide)
            if ring.opacity < 1 { animate(ring, "opacity", from: 0, to: 1, dur: 0.3, curve: Curve.soft) }
            keyframes(ring, "transform.scale", values: [0.4, 1.15, 1], times: [0, 0.6, 1], dur: 0.4)
        } else { star.lit.opacity = 1; star.dim.opacity = 0; ring.position = star.pos; ring.opacity = 1 }
        last = star
    }
}
