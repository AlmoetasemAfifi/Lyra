import AppKit
import QuartzCore

/// What sits over the lyrics when nobody is singing:
///  - intro: a title card (song + artist) with a thin line that fills until the first lyric,
///  - interlude: three dots that breathe and fill in time with the instrumental break,
///  - outro: the title card again, quietly, after the last line.
/// Works the same over every lyric style; the scene underneath dims while it shows.
final class StageOverlay {
    enum Mode: Equatable { case none, intro, interlude, outro }

    let layer = CALayer()
    private(set) var mode: Mode = .none
    private let ctx: SceneContext
    private var group: CALayer?

    init(ctx: SceneContext) {
        self.ctx = ctx
        quiet(layer)
        layer.frame = ctx.bounds
    }

    /// `gap`: seconds until the lyrics come back (for the fill timing).
    func set(_ mode: Mode, title: String, artist: String, gap: Double, animated: Bool) {
        guard mode != self.mode else { return }
        let old = group
        self.mode = mode
        group = nil
        if let old { dismiss(old, animated: animated) }
        switch mode {
        case .none: break
        case .intro: group = titleCard(title: title, artist: artist, gap: gap, big: true, animated: animated)
        case .outro: group = titleCard(title: title, artist: artist, gap: 0, big: false, animated: animated)
        case .interlude: group = dots(gap: gap, animated: animated)
        }
        if let g = group { layer.addSublayer(g) }
    }

    private func dismiss(_ g: CALayer, animated: Bool) {
        guard animated else { g.removeFromSuperlayer(); return }
        // Out through the viewer: a gentle push forward while it fades.
        animate(g, "transform.scale", from: 1, to: 1.12, dur: 0.6, curve: Curve.expoIn)
        animate(g, "opacity", from: 1, to: 0, dur: 0.55, curve: Curve.soft)
        g.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { g.removeFromSuperlayer() }
    }

    // MARK: Title card

    private func titleCard(title: String, artist: String, gap: Double, big: Bool, animated: Bool) -> CALayer? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let g = CALayer(); quiet(g)
        g.frame = ctx.bounds
        let c = ctx.center
        let base = ctx.base * (big ? 1.25 : 0.85)
        // Fit long titles to 80% of the width.
        let natural = ctx.measure(t, size: base).width
        let size = base * min(1, ctx.bounds.width * 0.8 / max(1, natural))
        let lyric = ctx.lyricColor, hi = ctx.highlightColor

        let sharpLook = SpriteLook(fill: .solid(lyric.rgba), glow: 0.07, glowColor: hi.rgba, shadow: true)
        var softLook = sharpLook; softLook.blur = 0.16
        let titleY = c.y + ctx.base * (big ? 0.3 : 0.2)
        let sharp = ctx.spriteLayer(ctx.sprite(t, size: size, look: sharpLook))
        let soft = ctx.spriteLayer(ctx.sprite(t, size: size, look: softLook))
        for l in [soft, sharp] { l.position = CGPoint(x: c.x, y: titleY); g.addSublayer(l) }

        var artistLayer: CALayer?
        let a = artist.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty {
            let look = SpriteLook(fill: .solid(lyric.withAlphaComponent(0.66).rgba), shadow: true)
            let asize = ctx.base * (big ? 0.3 : 0.26)
            let s: Sprite
            if LyricFonts.isArabic(a) {
                s = ctx.sprite(a, size: asize * 1.2, look: look)
            } else {
                // Clean, widely spaced capitals, like a film credit.
                let spaced = a.uppercased().map(String.init).joined(separator: "\u{2009}")
                s = Sprites.get(spaced, font: NSFont.systemFont(ofSize: asize, weight: .semibold), look: look, scale: ctx.scale)
            }
            let l = ctx.spriteLayer(s)
            l.position = CGPoint(x: c.x, y: titleY - size * 0.5 - ctx.base * 0.45)
            g.addSublayer(l)
            artistLayer = l
        }

        // The thin line that fills up until the first lyric.
        var fill: CALayer?
        var track: CALayer?
        if big, gap > 1.2 {
            let w = min(ctx.base * 4.5, ctx.bounds.width * 0.3)
            let y = (artistLayer?.position.y ?? titleY - size * 0.5) - ctx.base * 0.55
            let tr = CALayer(); quiet(tr)
            tr.bounds = CGRect(x: 0, y: 0, width: w, height: 2)
            tr.cornerRadius = 1
            tr.backgroundColor = lyric.withAlphaComponent(0.16).cgColor
            tr.position = CGPoint(x: c.x, y: y)
            let f = CALayer(); quiet(f)
            f.anchorPoint = CGPoint(x: LyricFonts.isArabic(t) ? 1 : 0, y: 0.5)
            f.bounds = CGRect(x: 0, y: 0, width: w, height: 2)
            f.cornerRadius = 1
            f.backgroundColor = hi.withAlphaComponent(0.95).cgColor
            f.position = CGPoint(x: LyricFonts.isArabic(t) ? w : 0, y: 1)
            f.shadowColor = hi.cgColor; f.shadowOpacity = 0.9; f.shadowRadius = 4; f.shadowOffset = .zero
            tr.addSublayer(f)
            g.addSublayer(tr)
            fill = f; track = tr
        }

        guard animated else { soft.opacity = 0; fill?.transform = CATransform3DIdentity; return g }
        // Title pulls into focus as it rises; the artist and line follow.
        let now = CACurrentMediaTime()
        let rise = big ? ctx.base * 0.22 : ctx.base * 0.12
        for l in [soft, sharp] {
            animate(l, "position", from: NSValue(point: CGPoint(x: c.x, y: titleY - rise)), to: NSValue(point: l.position), dur: 1.4, curve: Curve.expoOut)
            animate(l, "transform.scale", from: 1.07, to: 1, dur: 1.6, curve: Curve.expoOut)
        }
        soft.opacity = 0
        keyframes(soft, "opacity", values: [0, 1, 0], times: [0, 0.3, 1], dur: big ? 1.3 : 1.8)
        animate(sharp, "opacity", from: 0, to: 1, dur: big ? 1.1 : 1.6, delay: 0.25, curve: Curve.soft)
        if let al = artistLayer {
            animate(al, "opacity", from: 0, to: 1, dur: 0.9, delay: 0.55, curve: Curve.soft)
            animate(al, "position", from: NSValue(point: CGPoint(x: al.position.x, y: al.position.y - ctx.base * 0.1)), to: NSValue(point: al.position), dur: 1.1, delay: 0.55, curve: Curve.expoOut)
        }
        if let track, let fill {
            animate(track, "opacity", from: 0, to: 1, dur: 0.6, delay: 0.8, curve: Curve.soft)
            let a = CABasicAnimation(keyPath: "transform.scale.x")
            a.fromValue = 0.001; a.toValue = 1
            a.duration = max(0.5, gap)
            a.beginTime = fill.convertTime(now, from: nil)
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 20)
            fill.add(a, forKey: "progress")
        }
        // A very slow breath while it waits, so it never looks frozen.
        let b = CABasicAnimation(keyPath: "transform.scale")
        b.fromValue = 1; b.toValue = 1.018
        b.duration = 4.5
        b.autoreverses = true
        b.repeatCount = .infinity
        b.beginTime = sharp.convertTime(now, from: nil) + 1.6
        b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        b.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 20)
        g.add(b, forKey: "breath")
        return g
    }

    // MARK: Interlude dots

    private func dots(gap: Double, animated: Bool) -> CALayer {
        let g = CALayer(); quiet(g)
        g.frame = ctx.bounds
        let r = max(6, ctx.base * 0.13)
        let step = r * 3.4
        let now = CACurrentMediaTime()
        var dots: [CALayer] = []
        let sample = ctx.lyrics.words.prefix(40)
        let arabic = sample.filter { LyricFonts.isArabic($0.text) }.count * 2 > sample.count
        for k in 0..<3 {
            let d = CALayer(); quiet(d)
            d.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            d.cornerRadius = r
            d.backgroundColor = ctx.lyricColor.cgColor
            d.shadowColor = ctx.highlightColor.cgColor; d.shadowOpacity = 0.8; d.shadowRadius = r * 0.9; d.shadowOffset = .zero
            // Reading order: right to left for Arabic songs.
            let dir: CGFloat = arabic ? -1 : 1
            d.position = CGPoint(x: ctx.center.x + dir * CGFloat(k - 1) * step, y: ctx.center.y)
            d.opacity = 0.45
            g.addSublayer(d)
            dots.append(d)
        }
        guard animated else { return g }
        animate(g, "opacity", from: 0, to: 1, dur: 0.5, curve: Curve.soft)
        // Each dot lights up in turn over the break, so you can feel the next line coming.
        let span = max(1.2, gap)
        for (k, d) in dots.enumerated() {
            let begin = now + span * Double(k) / 3
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.45; a.toValue = 1
            a.duration = span / 3
            a.beginTime = d.convertTime(begin, from: nil)
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            d.add(a, forKey: "fill")
            let s = CAKeyframeAnimation(keyPath: "transform.scale")
            s.values = [0.8, 1.25, 1]
            s.keyTimes = [0, 0.7, 1]
            s.duration = span / 3
            s.beginTime = d.convertTime(begin, from: nil)
            s.fillMode = .both
            s.isRemovedOnCompletion = false
            s.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            d.add(s, forKey: "pop")
        }
        // The whole group breathes, like the music is holding its breath.
        let b = CABasicAnimation(keyPath: "transform.scale")
        b.fromValue = 1; b.toValue = 1.1
        b.duration = 1.4
        b.autoreverses = true
        b.repeatCount = .infinity
        b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        b.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
        g.add(b, forKey: "breath")
        return g
    }
}
