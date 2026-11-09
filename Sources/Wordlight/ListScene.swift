import AppKit
import QuartzCore

// MARK: - Scroll / Spotlight / Bold / Karaoke
//
// The "premium" lyric look, modelled on how Apple Music's full-screen lyrics behave
// (as documented by the open-source AMLL recreation):
//  • several lines on screen; the current one bright, the others dimmed AND blurred by distance
//  • each sung word fills through a soft-edged gradient that sweeps across in time with the voice
//  • every sung word floats up slightly; long held words swell and glow
//  • lines glide on soft springs, each line below starting a beat later (a rippling stagger)
//  • three breathing dots during instrumental breaks

final class ListScene: LyricScene {
    enum Align { case leading, center }
    enum Fill { case word, line }

    struct Config {
        var align: Align = .leading
        var size: CGFloat = 0.5            // × base
        var inactiveScale: CGFloat = 0.96
        var blurStep: CGFloat = 1.0        // 0 = no depth blur
        var pastOpacity: Float = 0.35
        var futureOpacity: Float = 0.4
        var fill: Fill = .word
        var before = 3, after = 5          // lines shown above / below
        var focus: CGFloat = 0.42          // fraction of height from top where the current line sits
        var gap: CGFloat = 0.5             // line gap × font size
        var float = true
        var emphasize = true
        var hideOthers = false             // Karaoke: only the current + next line
        var nextScale: CGFloat = 0.55      // Karaoke next-line preview size
    }

    static let scroll = Config()
    static let spotlight = Config(align: .center, size: 0.6, inactiveScale: 0.78, blurStep: 1.8, pastOpacity: 0.22,
                                  futureOpacity: 0.28, before: 1, after: 2, focus: 0.5, gap: 0.45)

    private final class Word {
        let layer = CALayer()          // positioned in line coordinates
        var dim = CALayer()
        let bright = CALayer()         // holds the bright sprite, revealed by `mask`
        var glow = CALayer()           // pre-baked glow copy for held notes (inside the mask)
        var soft = CALayer()           // pre-blurred copy shown when the line is out of focus
        let mask = CAGradientLayer()
        var size: CGSize = .zero
        var home: CGPoint = .zero
        var index = 0
        var rtl = false
        var filled = false
    }
    private final class Line {
        let layer = CALayer()
        let sharp = CALayer()          // the crisp words
        let blurred = CALayer()        // their pre-blurred copies (depth of field, no live filter)
        var words: [Word] = []
        var size: CGSize = .zero
        var number = 0
        var rtl = false
    }

    private let ctx: SceneContext
    private let cfg: Config
    private var lines: [Int: Line] = [:]
    private var current = Int.min
    private var lastWord = -1
    private let dots = CALayer()
    private var dotLayers: [CALayer] = []
    private var fontSize: CGFloat { ctx.base * cfg.size }
    private var maxWidth: CGFloat { min(ctx.bounds.width * (cfg.align == .center ? 0.8 : 0.72), fontSize * 15) }
    private var blockLeft: CGFloat { ctx.center.x - maxWidth / 2 }

    init(ctx: SceneContext, config: Config) {
        self.ctx = ctx
        self.cfg = config
        buildDots()
    }

    // MARK: Building

    private func line(_ n: Int) -> Line? {
        if let l = lines[n] { return l }
        let idx = ctx.words(inLine: n)
        guard !idx.isEmpty else { return nil }
        let l = Line()
        l.number = n
        l.rtl = ctx.rtl(n)
        quiet(l.layer)
        let size = fontSize
        let dimAlpha: CGFloat = cfg.fill == .line ? 1 : 0.42
        let dimLook = SpriteLook(fill: .solid(ctx.lyricColor.withAlphaComponent(dimAlpha).rgba), shadow: true)
        let brightLook = SpriteLook(fill: .solid(ctx.lyricColor.rgba), shadow: true)
        let glowLook = SpriteLook(fill: .solid(ctx.lyricColor.rgba), glow: 0.24, glowColor: NSColor.white.withAlphaComponent(0.95).rgba)
        let softLook = SpriteLook(fill: .solid(ctx.lyricColor.rgba), blur: 0.06)
        var words: [Word] = []
        for i in idx {
            let text = ctx.lyrics.words[i].text + (ctx.emoji[i].map { " " + $0 } ?? "")
            let dimS = ctx.sprite(text, size: size, look: dimLook)
            let brightS = ctx.sprite(text, size: size, look: brightLook)
            let glowS = cfg.emphasize ? ctx.sprite(text, size: size, look: glowLook) : brightS
            let w = Word()
            w.index = i
            w.size = CGSize(width: dimS.text.width + size * 0.24, height: dimS.text.height + size * 0.12)
            w.rtl = LyricFonts.isArabic(text)
            quiet(w.layer); quiet(w.bright); quiet(w.mask)
            // The holder is as big as the largest copy (the glow has the most padding).
            let box = CGSize(width: max(glowS.size.width, brightS.size.width), height: max(glowS.size.height, brightS.size.height))
            let frame = CGRect(origin: .zero, size: box)
            let mid = CGPoint(x: box.width / 2, y: box.height / 2)
            w.layer.bounds = frame
            w.dim = ctx.spriteLayer(dimS); w.dim.position = mid
            w.bright.frame = frame
            let b = ctx.spriteLayer(brightS); b.position = mid
            w.bright.addSublayer(b)
            w.glow = ctx.spriteLayer(glowS); w.glow.position = mid; w.glow.opacity = 0
            w.bright.addSublayer(w.glow)
            if cfg.fill == .word { setupMask(w) }
            w.layer.addSublayer(w.dim)
            w.layer.addSublayer(w.bright)
            if cfg.blurStep > 0 { w.soft = ctx.spriteLayer(ctx.sprite(text, size: size, look: softLook)) }
            words.append(w)
        }
        // Bake the line after next in the background so it's ready before it's needed.
        ctx.prefetch(ctx.words(inLine: n + 2), size: size, looks: [dimLook, brightLook, softLook] + (cfg.emphasize ? [glowLook] : []))
        // Wrap into rows, aligned to the block edge (right edge for RTL lines).
        let gap = size * 0.24
        var rows: [[Word]] = [[]]
        var rw: CGFloat = 0
        for w in words {
            let add = (rows[rows.count - 1].isEmpty ? 0 : gap) + w.size.width
            if rw + add > maxWidth, !rows[rows.count - 1].isEmpty { rows.append([]); rw = 0 }
            rw += (rows[rows.count - 1].isEmpty ? 0 : gap) + w.size.width
            rows[rows.count - 1].append(w)
        }
        let rowH = (words.map(\.size.height).max() ?? size) * 0.92
        let height = rowH * CGFloat(rows.count)
        l.size = CGSize(width: maxWidth, height: height)
        l.layer.bounds = CGRect(origin: .zero, size: l.size)
        for (r, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + $1.size.width } + gap * CGFloat(max(0, row.count - 1))
            var x: CGFloat
            switch cfg.align {
            case .center: x = (maxWidth - total) / 2
            case .leading: x = l.rtl ? maxWidth - total : 0
            }
            let y = height - rowH * (CGFloat(r) + 0.5)
            for w in (l.rtl ? row.reversed() : row) {
                w.home = CGPoint(x: x + w.size.width / 2, y: y)
                w.layer.position = w.home
                l.sharp.addSublayer(w.layer)
                if cfg.blurStep > 0 { w.soft.position = w.home; l.blurred.addSublayer(w.soft) }
                x += w.size.width + gap
            }
        }
        l.words = words
        // Lines scale from their aligned edge, like Apple Music.
        switch cfg.align {
        case .center: l.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        case .leading: l.layer.anchorPoint = CGPoint(x: l.rtl ? 1 : 0, y: 0.5)
        }
        for g in [l.sharp, l.blurred] { quiet(g); g.frame = l.layer.bounds; l.layer.addSublayer(g) }
        l.blurred.opacity = 0
        l.layer.opacity = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ctx.host.addSublayer(l.layer)
        CATransaction.commit()
        lines[n] = l
        return l
    }

    /// Soft-edged reveal: a horizontal gradient (opaque → feather → clear) slides across the word.
    private func setupMask(_ w: Word) {
        let W = w.bright.bounds.width, F = max(w.size.height * 0.9, 12)
        let total = 2 * W + F
        w.mask.bounds = CGRect(x: 0, y: 0, width: total, height: w.bright.bounds.height * 2)
        w.mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        w.mask.startPoint = CGPoint(x: 0, y: 0.5)
        w.mask.endPoint = CGPoint(x: 1, y: 0.5)
        let a = W / total, b = (W + F) / total
        if w.rtl {
            w.mask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
            w.mask.locations = [0, NSNumber(value: Double(a)), NSNumber(value: Double(b)), 1]
        } else {
            w.mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            w.mask.locations = [0, NSNumber(value: Double(a)), NSNumber(value: Double(b)), 1]
        }
        w.mask.position = CGPoint(x: hiddenX(w), y: w.bright.bounds.height / 2)
        w.bright.mask = w.mask
    }
    private func hiddenX(_ w: Word) -> CGFloat { w.rtl ? w.bright.bounds.width : -(w.bright.bounds.width + max(w.size.height * 0.9, 12)) }
    private func shownX(_ w: Word) -> CGFloat { w.rtl ? -(w.bright.bounds.width + max(w.size.height * 0.9, 12)) : 0 }

    private func buildDots() {
        quiet(dots)
        let r = max(4, ctx.base * 0.07)
        for k in 0..<3 {
            let d = CALayer(); quiet(d)
            d.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            d.cornerRadius = r
            d.backgroundColor = ctx.lyricColor.cgColor
            d.position = CGPoint(x: CGFloat(k) * r * 3.2, y: 0)
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.6; breathe.toValue = 1.15; breathe.duration = 0.9
            breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timeOffset = Double(k) * 0.3
            breathe.timingFunction = Curve.soft
            d.add(breathe, forKey: "breathe")
            dots.addSublayer(d)
            dotLayers.append(d)
        }
        dots.opacity = 0
        ctx.host.addSublayer(dots)
    }

    func setIdle(_ idle: Bool) {
        guard let cur = lines[current] else { return }
        let r = max(4, ctx.base * 0.07)
        let x: CGFloat = cfg.align == .center ? ctx.center.x - r * 3.2 : (cur.rtl ? blockLeft + maxWidth - r * 7.4 : blockLeft + r)
        dots.position = CGPoint(x: x, y: cur.layer.position.y - cur.size.height / 2 - fontSize * cfg.gap - r)
        animate(dots, "opacity", from: nil, to: Float(idle ? 0.9 : 0), dur: 0.5, curve: Curve.soft)
    }

    // MARK: Showing

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard !ctx.lyrics.words.isEmpty else { return }
        let n = index >= 0 ? ctx.line(of: index) : ctx.lyrics.words[0].line
        if n != current {
            let first = current == Int.min
            current = n
            layoutLines(animated: animated && !first, now: now, index: index)
        }
        guard let l = lines[n] else { return }
        // Fill the sung word (and catch up any skipped earlier ones).
        for w in l.words where w.index <= index && !w.filled {
            sing(w, in: l, animated: animated && w.index == index)
        }
        lastWord = index
    }

    private func sing(_ w: Word, in l: Line, animated: Bool) {
        w.filled = true
        let dur = ctx.duration(w.index)
        if cfg.fill == .word {
            if animated {
                animate(w.mask, "position.x", from: hiddenX(w), to: shownX(w), dur: max(0.12, dur), curve: Curve.linear)
            } else { w.mask.position.x = shownX(w) }
        }
        guard animated else {
            if cfg.float { w.layer.position = CGPoint(x: w.home.x, y: w.home.y + fontSize * 0.05) }
            return
        }
        if cfg.float {
            animate(w.layer, "position", from: NSValue(point: w.home),
                    to: NSValue(point: CGPoint(x: w.home.x, y: w.home.y + fontSize * 0.05)), dur: max(1, dur), curve: Curve.expoOut)
        }
        // Long held words swell and glow, then settle (Apple-style "emphasize").
        if cfg.emphasize, dur >= 0.9, ctx.lyrics.words[w.index].text.count <= 14 {
            let isLast = w.index == l.words.last?.index
            var amount = CGFloat(dur / 2); amount = amount > 1 ? sqrt(amount) : pow(amount, 3)
            amount = min(1.2, amount * 0.6 * (isLast ? 1.6 : 1))
            let glow = Float(min(0.8, (dur / 3 > 1 ? sqrt(dur / 3) : pow(dur / 3, 3)) * 0.5 * (isLast ? 1.5 : 1)))
            let steps = 16
            var scales: [CGFloat] = [], glows: [Float] = []
            for k in 0...steps {
                let x = Double(k) / Double(steps)
                let e = x < 0.5 ? sin(x * .pi) : sin(x * .pi) * 0.9 // rise, then ease back
                scales.append(1 + CGFloat(e) * 0.1 * amount)
                glows.append(Float(e) * max(0.35, glow))
            }
            let times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            keyframes(w.layer, "transform.scale", values: scales, times: times, dur: dur * (isLast ? 1.2 : 1), name: "emph")
            keyframes(w.glow, "opacity", values: glows.map { min(1, $0 * 1.4) }, times: times, dur: dur * (isLast ? 1.2 : 1), name: "glow")
        }
    }

    /// Position every visible line around the current one, with depth blur, dimming and a
    /// rippling stagger: lines further down start moving a little later.
    private func layoutLines(animated: Bool, now: Double, index: Int) {
        let lo = current - cfg.before, hi = current + cfg.after
        // How far the list moves this step: the new current line travels to the focus line.
        let focusYNow = ctx.bounds.height * (1 - cfg.focus)
        let scrollBy = lines[current].map { focusYNow - $0.layer.position.y } ?? 0
        // Lines leaving the window move exactly with the list while they fade out,
        // so nothing freezes in place or gets overtaken by the lines behind it.
        for (n, l) in lines where n < lo || n > hi {
            let p = l.layer.presentation()?.position ?? l.layer.position
            let shift = scrollBy != 0 ? scrollBy : (l.size.height + fontSize * cfg.gap) * (n < lo ? 1 : -1)
            if animated {
                spring(l.layer, "position", from: NSValue(point: p), to: NSValue(point: CGPoint(x: p.x, y: p.y + shift)), damping: 19, stiffness: 90)
                animate(l.layer, "opacity", from: nil, to: 0, dur: 0.35, curve: Curve.soft)
            } else { l.layer.opacity = 0 }
            lines[n] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { l.layer.removeFromSuperlayer() }
        }
        var visible: [Line] = []
        for n in lo...hi { if let l = line(n) { visible.append(l) } }
        guard let cur = lines[current] else { return }

        // Past lines are fully sung; future ones are reset.
        for l in visible where l.number != current {
            for w in l.words {
                let done = l.number < current
                if done != w.filled || l.number > current {
                    w.filled = done
                    w.mask.removeAllAnimations()
                    if cfg.fill == .word { w.mask.position.x = done ? shownX(w) : hiddenX(w) }
                    if !done { w.layer.removeAnimation(forKey: "position"); w.layer.position = w.home }
                }
            }
        }

        // Vertical placement (CA y is up): current line centred on the focus line.
        let focusY = ctx.bounds.height * (1 - cfg.focus)
        let gap = fontSize * cfg.gap
        var y: [Int: CGFloat] = [current: focusY]
        var scale: [Int: CGFloat] = [:]
        for l in visible { scale[l.number] = l.number == current ? 1 : (cfg.hideOthers ? cfg.nextScale : cfg.inactiveScale) }
        var cursor = focusY - cur.size.height / 2
        for l in visible where l.number > current {
            let h = l.size.height * scale[l.number]!
            y[l.number] = cursor - gap - h / 2
            cursor -= gap + h
        }
        cursor = focusY + cur.size.height / 2
        for l in visible.reversed() where l.number < current {
            let h = l.size.height * scale[l.number]!
            y[l.number] = cursor + gap + h / 2
            cursor += gap + h
        }

        var delay = 0.0, step = 0.05
        for l in visible {
            let d = l.number - current
            let x: CGFloat = {
                switch cfg.align {
                case .center: return ctx.center.x
                case .leading: return l.rtl ? blockLeft + maxWidth : blockLeft
                }
            }()
            let pos = CGPoint(x: x, y: y[l.number] ?? focusY)
            var opacity: Float = d == 0 ? 1 : (d < 0 ? cfg.pastOpacity : cfg.futureOpacity)
            if d != 0 { opacity *= Float(max(0.35, 1 - 0.14 * Double(abs(d) - 1))) }
            if cfg.hideOthers && d < 0 { opacity = 0 }
            let s = scale[l.number]!
            let wasHidden = l.layer.opacity == 0 && l.layer.presentation()?.opacity ?? 0 == 0
            if animated {
                if wasHidden {
                    // New lines rise in from below (or appear in place on first layout).
                    l.layer.position = CGPoint(x: pos.x, y: pos.y - fontSize * 1.2)
                    l.layer.setValue(s, forKeyPath: "transform.scale")
                }
                spring(l.layer, "position", from: nil, to: NSValue(point: pos), damping: 19, stiffness: 90, delay: delay)
                spring(l.layer, "transform.scale", from: nil, to: s, damping: 21, stiffness: 110, delay: delay)
                animate(l.layer, "opacity", from: nil, to: opacity, dur: 0.45, delay: delay, curve: Curve.soft)
                if cfg.blurStep > 0 {
                    // Depth of field: crossfade crisp ↔ pre-blurred copies (cheap, no live blur).
                    animate(l.sharp, "opacity", from: nil, to: Float(d == 0 ? 1 : 0), dur: 0.5, delay: delay, curve: Curve.soft)
                    animate(l.blurred, "opacity", from: nil, to: Float(d == 0 ? 0 : 1), dur: 0.5, delay: delay, curve: Curve.soft)
                }
            } else {
                l.layer.position = pos
                l.layer.setValue(s, forKeyPath: "transform.scale")
                l.layer.opacity = opacity
                if cfg.blurStep > 0 { l.sharp.opacity = d == 0 ? 1 : 0; l.blurred.opacity = d == 0 ? 0 : 1 }
            }
            if d > 0 { delay += step; step /= 1.05 }
        }
        // Bold (whole-line) style: the new line lights up at once with a little pop.
        if cfg.fill == .line {
            for w in cur.words { w.filled = true }
            if animated { spring(cur.layer, "transform.scale", from: 0.96, to: 1, damping: 30, stiffness: 260, name: "pop") }
        }
    }
}

