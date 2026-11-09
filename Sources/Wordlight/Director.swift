import AppKit
import CoreImage
import QuartzCore

// MARK: - Textures (made once, shared)

enum Textures {
    /// Deterministic pseudo-random numbers so textures look the same every launch.
    private struct RNG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(UInt32.max >> 1) } }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// A light sprinkle of dust and specks on transparent — film grain.
    static let grain: CGImage? = {
        let w = 960, h = 600
        guard let c = context(w, h) else { return nil }
        var r = RNG(s: 7)
        for _ in 0..<420 {
            let x = r.next() * CGFloat(w), y = r.next() * CGFloat(h)
            let big = r.next() > 0.93
            let d = big ? 1.5 + r.next() * 2.5 : 0.6 + r.next() * 1.0
            c.setFillColor(NSColor(white: 1, alpha: 0.25 + r.next() * 0.55).cgColor)
            c.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d * (0.6 + r.next() * 0.8)))
        }
        // A few hair-like scratches.
        c.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
        for _ in 0..<6 {
            let x = r.next() * CGFloat(w), y = r.next() * CGFloat(h)
            c.setLineWidth(0.6)
            c.move(to: CGPoint(x: x, y: y))
            c.addCurve(to: CGPoint(x: x + (r.next() - 0.5) * 40, y: y + 20 + r.next() * 40),
                       control1: CGPoint(x: x + (r.next() - 0.5) * 30, y: y + 10), control2: CGPoint(x: x + (r.next() - 0.5) * 30, y: y + 25))
            c.strokePath()
        }
        return c.makeImage()
    }()

    /// Opaque mask with small holes and chipped specks — makes letters look hand-painted.
    static let distress: CGImage? = {
        let w = 512, h = 256
        guard let c = context(w, h) else { return nil }
        c.setFillColor(NSColor.black.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setBlendMode(.clear)
        var r = RNG(s: 11)
        for _ in 0..<520 {
            let x = r.next() * CGFloat(w), y = r.next() * CGFloat(h)
            let d = 0.8 + pow(r.next(), 3) * 7
            c.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d * (0.4 + r.next())))
        }
        // Dry-brush streaks: thin horizontal gaps.
        for _ in 0..<18 {
            let y = r.next() * CGFloat(h), x = r.next() * CGFloat(w)
            c.fill(CGRect(x: x, y: y, width: 10 + r.next() * 60, height: 0.6 + r.next() * 1.2))
        }
        return c.makeImage()
    }()
}

extension SceneContext {
    /// Dark, grainy backdrop for the gritty treatments (sits over the live wallpaper).
    func backdrop(darkness: Float) -> CALayer {
        let b = CALayer(); quiet(b)
        b.frame = bounds
        let shade = CALayer(); quiet(shade)
        shade.frame = bounds
        shade.backgroundColor = NSColor.black.cgColor
        shade.opacity = darkness
        b.addSublayer(shade)
        if let g = Textures.grain {
            let grain = CALayer(); quiet(grain)
            grain.frame = bounds.insetBy(dx: -40, dy: -40)
            grain.contents = g
            grain.contentsGravity = .resize
            grain.magnificationFilter = .nearest
            grain.opacity = 0.7
            // Jitter the grain a few times a second like film.
            let a = CAKeyframeAnimation(keyPath: "position")
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            var pts: [NSValue] = []
            for k in 0..<8 {
                let dx = CGFloat((k * 37) % 41 - 20)
                let dy = CGFloat((k * 53) % 37 - 18)
                pts.append(NSValue(point: CGPoint(x: c.x + dx, y: c.y + dy)))
            }
            a.values = pts
            a.calculationMode = .discrete
            a.duration = 0.8
            a.repeatCount = .infinity
            grain.add(a, forKey: "jitter")
            b.addSublayer(grain)
        }
        return b
    }

    /// Give a word layer the hand-painted, slightly broken edge.
    func distress(_ l: CALayer, seed: Int) {
        guard let d = Textures.distress else { return }
        let m = CALayer(); quiet(m)
        m.frame = l.bounds
        m.contents = d
        m.contentsGravity = .resize
        let ox = CGFloat((seed * 37) % 60) / 100, oy = CGFloat((seed * 53) % 50) / 100
        m.contentsRect = CGRect(x: ox * 0.4, y: oy * 0.4, width: 0.6, height: 0.6)
        l.mask = m
    }

    /// Full-screen colour flash (on punch words and section changes).
    func flash(_ color: NSColor, strength: Float = 0.85, dur: Double = 0.28) {
        let f = CALayer(); quiet(f)
        f.frame = bounds
        f.backgroundColor = color.cgColor
        f.opacity = 0
        host.addSublayer(f)
        keyframes(f, "opacity", values: [0, strength, 0], times: [0, 0.12, 1], dur: dur)
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) { f.removeFromSuperlayer() }
    }

    func emphasized(_ i: Int, _ script: SongScript?) -> Bool { script?.emphasis.contains(i) ?? false }

    /// A sprite wrapped as a word object: `layer` is sized to the text box (for layout),
    /// with the baked image (incl. glow padding) centred inside it.
    func spriteGlyph(_ text: String, size: CGFloat, look: SpriteLook, scale sc: CGFloat? = nil) -> Glyphs {
        let s = sprite(text, size: size, look: look, scale: sc)
        let g = Glyphs()
        quiet(g.layer)
        g.size = CGSize(width: s.text.width + size * 0.2, height: s.text.height + size * 0.1)
        g.layer.bounds = CGRect(origin: .zero, size: g.size)
        let l = spriteLayer(s)
        l.position = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
        g.layer.addSublayer(l)
        g.letters = [l]
        return g
    }
}

// MARK: - Flash — one huge glowing word at a time, hard cuts, screen flashes on punch words

final class FlashScene: LyricScene {
    private let ctx: SceneContext
    private let script: SongScript?
    private var shown: CALayer?
    private var last = Int.min

    init(ctx: SceneContext, script: SongScript?) {
        self.ctx = ctx
        self.script = script
        ctx.host.addSublayer(ctx.backdrop(darkness: 0.8))
    }

    /// Poster-size: fit the word to ~60% of the screen width (bigger for punch words).
    /// Baked: thick painted stroke, chipped brush texture, tight glow + wide bloom.
    private func spec(_ index: Int) -> (String, CGFloat, SpriteLook) {
        let text = ctx.lyrics.words[index].text
        let punch = ctx.emphasized(index, script)
        let color = ctx.highlightColor
        let natural = ctx.measure(text, size: ctx.base).width
        let fit = ctx.bounds.width * (punch ? 0.72 : 0.58) / max(1, natural)
        let size = ctx.base * min(punch ? 3.6 : 3.0, max(1.5, fit))
        return (text + (ctx.emoji[index].map { " " + $0 } ?? ""), size,
                SpriteLook(fill: .solid(color.rgba), glow: 0.12, glowColor: color.rgba, bloom: true, stroke: -5, distress: true))
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard index >= 0, index != last else { return }
        last = index
        let punch = ctx.emphasized(index, script)
        let color = ctx.highlightColor
        let spec = self.spec(index)
        // Poster words are huge and glowing: standard resolution is plenty and ~4x cheaper to bake.
        let g = ctx.spriteGlyph(spec.0, size: spec.1, look: spec.2, scale: 1)
        // Bake the next few words in the background so cuts never wait on rendering.
        ctx.prefetch(exact: (index + 1 ..< min(ctx.lyrics.words.count, index + 6)).map(self.spec), scale: 1)
        let tilt = CGFloat((index * 7) % 9 - 4) * 0.012
        g.layer.position = CGPoint(x: ctx.center.x + CGFloat((index * 13) % 7 - 3) * ctx.base * 0.05, y: ctx.center.y)
        g.layer.setValue(tilt, forKeyPath: "transform.rotation.z")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ctx.host.addSublayer(g.layer)
        CATransaction.commit()
        // Hard cut: the old word vanishes almost instantly.
        if let old = shown {
            // The old word recedes a touch as it cuts away.
            if animated { animate(old, "transform.scale", from: nil, to: 0.93, dur: 0.12, curve: Curve.expoOut) }
            animate(old, "opacity", from: nil, to: 0, dur: animated ? 0.1 : 0, curve: Curve.linear)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { old.removeFromSuperlayer() }
        }
        shown = g.layer
        guard animated else { return }
        // Zoom in and settle once: fast attack, long smooth landing, no bounce.
        animate(g.layer, "transform.scale", from: punch ? 1.45 : 1.2, to: 1, dur: punch ? 0.55 : 0.4, curve: Curve.expoOut)
        animate(g.layer, "transform.rotation.z", from: tilt * 3, to: tilt, dur: 0.5, curve: Curve.expoOut)
        animate(g.layer, "opacity", from: 0, to: 1, dur: 0.06, curve: Curve.linear)
        if punch { ctx.flash(color); echo(g.layer) }
    }
}

extension FlashScene {
    /// A fading copy of the word that expands outward, like a shockwave of the word itself.
    fileprivate func echo(_ l: CALayer) { echoLayer(l, in: l.superlayer) }
}

/// Shared by Poster and Brush: a ghost of the word ring expands and fades.
func echoLayer(_ l: CALayer, in parent: CALayer?, grow: CGFloat = 1.5) {
    guard let parent, let content = l.sublayers?.first?.contents else { return }
    let ghost = CALayer(); quiet(ghost)
    ghost.contents = content
    ghost.contentsScale = l.sublayers?.first?.contentsScale ?? 2
    ghost.contentsGravity = .resize
    ghost.bounds = l.sublayers?.first?.bounds ?? l.bounds
    ghost.position = parent.convert(l.position, from: l.superlayer)
    ghost.transform = l.transform
    ghost.opacity = 0
    parent.insertSublayer(ghost, below: l)
    animate(ghost, "transform.scale", from: 1, to: grow, dur: 0.6, curve: Curve.expoOut)
    keyframes(ghost, "opacity", values: [0.55, 0], times: [0, 1], dur: 0.6)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { ghost.removeFromSuperlayer() }
}

// MARK: - Brush Stack — painted words slam in and build a tilted block; it clears when full

final class BrushStackScene: LyricScene {
    private let ctx: SceneContext
    private let script: SongScript?
    private var block: CALayer?
    private var rows: [[CALayer]] = []
    private var rowWidth: [CGFloat] = []
    private var last = -1
    private let maxRows = 3
    private var width: CGFloat { min(ctx.bounds.width * 0.78, ctx.base * 11) }
    private var rowH: CGFloat { ctx.base * 1.4 }

    init(ctx: SceneContext, script: SongScript?) {
        self.ctx = ctx
        self.script = script
        ctx.host.addSublayer(ctx.backdrop(darkness: 0.35))
    }

    private func newBlock(animated: Bool) {
        if let old = block {
            if animated {
                let p = old.position
                animate(old, "position", from: NSValue(point: p), to: NSValue(point: CGPoint(x: p.x, y: p.y + ctx.base * 2.2)), dur: 0.38, curve: Curve.expoIn)
                animate(old, "opacity", from: 1, to: 0, dur: 0.32, curve: Curve.expoIn)
            } else { old.opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { old.removeFromSuperlayer() }
        }
        let b = ctx.groupLayer()
        // The whole block leans a little, like the video.
        b.setValue(-0.035, forKeyPath: "transform.rotation.z")
        ctx.host.addSublayer(b)
        block = b
        rows = []; rowWidth = []
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard index >= 0, index != last else { return }
        let from = last < 0 ? max(0, index - 3) : last + 1
        last = index
        for i in from...index { add(i, animated: animated && i == index) }
    }

    private func spec(_ i: Int) -> (String, CGFloat, SpriteLook) {
        let w = ctx.lyrics.words[i]
        let punch = ctx.emphasized(i, script)
        return (w.text + (ctx.emoji[i].map { " " + $0 } ?? ""), ctx.base * (punch ? 1.65 : 1.3),
                SpriteLook(fill: .solid((punch ? ctx.highlightColor : ctx.lyricColor).rgba),
                           glow: punch ? 0.1 : 0, glowColor: ctx.highlightColor.rgba, stroke: -5, shadow: true, distress: true))
    }

    private func add(_ i: Int, animated: Bool) {
        let w = ctx.lyrics.words[i]
        let punch = ctx.emphasized(i, script)
        let rtl = LyricFonts.isArabic(w.text)
        let spec = self.spec(i)
        let size = spec.1
        let g = ctx.spriteGlyph(spec.0, size: size, look: spec.2)
        if animated { ctx.prefetch(exact: (i + 1 ..< min(ctx.lyrics.words.count, i + 7)).map(self.spec)) }
        let newLine = i > 0 && ctx.lyrics.words[i - 1].line != w.line
        // Start a new row for a new lyric line or when the row is full (max 2 words per row).
        let needRow = rows.isEmpty || newLine || (rows.last?.count ?? 0) >= 2 || (rowWidth.last ?? 0) + g.size.width > width
        if needRow {
            if block == nil || rows.count >= maxRows { newBlock(animated: animated) }
            rows.append([]); rowWidth.append(0)
        }
        let r = rows.count - 1
        // Rows are anchored to the reading edge (right for Arabic), stepping down the block.
        let top = ctx.center.y + rowH * CGFloat(maxRows - 1) / 2
        let y = top - rowH * CGFloat(r)
        let edge = rtl ? ctx.center.x + width / 2 : ctx.center.x - width / 2
        let used = rowWidth[r] + (rows[r].isEmpty ? 0 : size * 0.18)
        let x = rtl ? edge - used - g.size.width / 2 : edge + used + g.size.width / 2
        // Alternate rows nudge in a little for a hand-placed look.
        let nudge = CGFloat(r % 2) * ctx.base * 0.35 * (rtl ? -1 : 1)
        let pos = CGPoint(x: x + nudge, y: y)
        g.layer.position = pos
        g.layer.setValue(CGFloat((i * 11) % 9 - 4) * 0.014, forKeyPath: "transform.rotation.z")
        rowWidth[r] = used + g.size.width
        rows[r].append(g.layer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        block?.addSublayer(g.layer)
        CATransaction.commit()
        guard animated else { return }
        // Painted on: the word presses down onto the wall and stays, no bounce.
        animate(g.layer, "transform.scale", from: punch ? 1.32 : 1.16, to: 1, dur: punch ? 0.5 : 0.38, curve: Curve.expoOut)
        animate(g.layer, "position", from: NSValue(point: CGPoint(x: pos.x, y: pos.y + ctx.base * 0.12)), to: NSValue(point: pos), dur: 0.42, curve: Curve.expoOut)
        animate(g.layer, "opacity", from: 0, to: 1, dur: 0.08, curve: Curve.linear)
        if punch { ctx.flash(ctx.highlightColor, strength: 0.35, dur: 0.22); echoLayer(g.layer, in: g.layer.superlayer, grow: 1.35) }
    }
}

// MARK: - Director — a different treatment for each section of the song

final class DirectorScene: LyricScene {
    private let ctx: SceneContext
    private let script: SongScript
    private let profile: SongProfile
    private var section = -1
    private var active: (container: CALayer, scene: LyricScene)?
    private var idle = false

    init(ctx: SceneContext, script: SongScript, profile: SongProfile) {
        self.ctx = ctx
        self.script = script
        self.profile = profile
    }

    /// Brush treatments use painted fonts; the smooth ones keep the song's chosen fonts.
    private func fonts(for t: String) -> FontPair {
        switch t {
        case "poster", "flash", "brush":
            return FontPair(english: [.rap, .mahraganat].contains(profile.kind) ? .marker : .chalk, arabic: .farah)
        case "motion" where [.rap, .mahraganat, .dance].contains(profile.kind):
            return FontPair(english: .marker, arabic: .farah)
        default: return ctx.fonts
        }
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard !ctx.lyrics.words.isEmpty else { return }
        let line = index >= 0 ? ctx.line(of: index) : ctx.lyrics.words[0].line
        let s = script.section(forLine: line)
        if s != section {
            let firstShow = section == -1
            section = s
            switchTo(script.sections.isEmpty ? "scroll" : script.sections[s].treatment, animated: animated && !firstShow)
        }
        active?.scene.show(index: index, now: now, playing: playing, animated: animated)
    }

    func setIdle(_ idle: Bool) {
        self.idle = idle
        active?.scene.setIdle(idle)
        if !(active?.scene is ListScene) { animate(ctx.host, "opacity", from: nil, to: Float(idle ? 0.3 : 1), dur: 0.6, curve: Curve.soft) }
    }

    private func switchTo(_ treatment: String, animated: Bool) {
        let container = CALayer(); quiet(container)
        container.frame = ctx.bounds
        let sub = SceneContext(host: container, bounds: ctx.bounds, center: ctx.center, base: ctx.base, palette: ctx.palette,
                               fonts: fonts(for: treatment), emoji: ctx.emoji, lyrics: ctx.lyrics, scale: ctx.scale)
        let scene: LyricScene
        let gritty = ["poster", "brush", "motion"].contains(treatment) && [.rap, .mahraganat, .dance].contains(profile.kind)
        switch treatment {
        case "poster", "flash": scene = FlashScene(ctx: sub, script: script)
        case "brush": scene = BrushStackScene(ctx: sub, script: script)
        case "motion", "sweep": scene = MotionScene(ctx: sub, script: script, gritty: gritty)
        default: scene = LyricStage.make(DisplayStyle(rawValue: treatment.capitalized) ?? .glow, sub, script: script, profile: profile)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ctx.host.addSublayer(container)
        CATransaction.commit()
        if let old = active {
            if animated {
                animate(old.container, "opacity", from: 1, to: 0, dur: 0.3, curve: Curve.soft)
                animate(container, "opacity", from: 0, to: 1, dur: 0.25, curve: Curve.soft)
                // Gritty sections cut in with a flash, like the video's section changes.
                if ["poster", "brush", "motion"].contains(treatment) { ctx.flash(ctx.highlightColor, strength: 0.5, dur: 0.25) }
            }
            let c = old.container
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { c.removeFromSuperlayer() }
        }
        active = (container, scene)
        if idle { scene.setIdle(true) }
    }
}
