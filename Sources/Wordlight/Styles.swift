import AppKit
import CoreText
import QuartzCore

// MARK: - Sprite line skeleton

/// Shared logic for one-line-at-a-time styles built from baked sprites: lines are laid out
/// and baked ahead of time, swapped with an enter/exit choreography, and words revealed as sung.
class SpriteLineScene: LyricScene {
    final class Item {
        let layer = CALayer()
        var parts: [String: CALayer] = [:]
        var letters: [CALayer] = []
        var letterHomes: [CGPoint] = []
        var box: CGSize = .zero
        var home: CGPoint = .zero
        var index = 0
    }
    final class Line {
        let layer: CALayer
        var items: [Int: Item] = [:]
        var order: [Int] = []
        var sung: Set<Int> = []
        var number = 0
        init(_ l: CALayer) { layer = l }
    }

    let ctx: SceneContext
    var lines: [Int: Line] = [:]
    var current = Int.min
    var lastWord = -1

    var sizeFactor: CGFloat { 0.62 }
    var wrapWidth: CGFloat { min(ctx.bounds.width * 0.8, ctx.base * sizeFactor * 16) }
    var lineY: CGFloat { ctx.center.y }
    /// Looks to bake ahead for upcoming lines.
    var prefetchLooks: [SpriteLook] { [] }

    init(ctx: SceneContext) { self.ctx = ctx }

    // Hooks
    func makeItem(_ i: Int, size: CGFloat) -> Item {
        let it = Item()
        let s = ctx.sprite(ctx.lyrics.words[i].text, size: size, look: SpriteLook(fill: .solid(ctx.lyricColor.rgba), shadow: true))
        it.box = CGSize(width: s.text.width + size * 0.26, height: s.text.height + size * 0.12)
        let l = ctx.spriteLayer(s)
        it.layer.bounds = CGRect(origin: .zero, size: it.box)
        l.position = CGPoint(x: it.box.width / 2, y: it.box.height / 2)
        it.layer.addSublayer(l)
        it.parts["base"] = l
        return it
    }
    func idle(_ l: Line, _ it: Item) {}
    func sing(_ l: Line, _ it: Item, animated: Bool, now: Double) {}
    func enter(_ l: Line, animated: Bool) {
        l.layer.opacity = 1
        if animated { animate(l.layer, "opacity", from: 0, to: 1, dur: 0.35) }
    }
    func exit(_ l: Line, animated: Bool) -> Double {
        if animated { animate(l.layer, "opacity", from: nil, to: 0, dur: 0.3, curve: Curve.soft) } else { l.layer.opacity = 0 }
        return 0.35
    }
    func wordChanged(_ l: Line, from old: Int, to new: Int, animated: Bool) {}
    func didLayout(_ l: Line) {}

    func line(_ n: Int) -> Line? {
        if let l = lines[n] { return l }
        let idx = ctx.words(inLine: n)
        guard !idx.isEmpty else { return nil }
        let l = Line(ctx.groupLayer())
        l.number = n
        l.order = idx
        let size = ctx.base * sizeFactor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var items: [Item] = []
        for i in idx { let it = makeItem(i, size: size); it.index = i; quiet(it.layer); items.append(it); l.items[i] = it }
        let pos = ctx.rows(items.map(\.box), maxWidth: wrapWidth, gap: size * 0.06, rowGap: size * 0.06, rtl: ctx.rtl(n))
        for (k, it) in items.enumerated() {
            it.home = CGPoint(x: ctx.center.x + pos[k].x, y: lineY + pos[k].y)
            it.layer.position = it.home
            l.layer.addSublayer(it.layer)
            idle(l, it)
        }
        didLayout(l)
        l.layer.opacity = 0
        ctx.host.addSublayer(l.layer)
        CATransaction.commit()
        lines[n] = l
        if !prefetchLooks.isEmpty { ctx.prefetch(ctx.words(inLine: n + 2), size: size, looks: prefetchLooks) }
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
            for i in l.order where i < index && !l.sung.contains(i) { l.sung.insert(i); sing(l, l.items[i]!, animated: false, now: now) }
            _ = line(n + 1)
        }
        guard let l = lines[n] else { return }
        if index >= 0, let it = l.items[index], !l.sung.contains(index) {
            l.sung.insert(index)
            sing(l, it, animated: animated, now: now)
        }
        wordChanged(l, from: lastWord, to: index, animated: animated)
        lastWord = index
    }
}

extension SceneContext {
    var shadowLook: SpriteLook { SpriteLook(fill: .solid(lyricColor.rgba), shadow: true) }
    func punch(_ i: Int, _ script: SongScript?) -> Bool { emphasized(i, script) }
}

// MARK: - Focus — every word pulls into focus out of a soft blur; lines blur away

final class FocusScene: SpriteLineScene {
    override var sizeFactor: CGFloat { 0.64 }
    private var sharpLook: SpriteLook { ctx.shadowLook }
    private var softLook: SpriteLook { SpriteLook(fill: .solid(ctx.lyricColor.rgba), blur: 0.11) }
    override var prefetchLooks: [SpriteLook] { [sharpLook, softLook] }

    override func makeItem(_ i: Int, size: CGFloat) -> Item {
        let it = Item()
        let t = ctx.lyrics.words[i].text + (ctx.emoji[i].map { " " + $0 } ?? "")
        let sharp = ctx.sprite(t, size: size, look: sharpLook), soft = ctx.sprite(t, size: size, look: softLook)
        it.box = CGSize(width: sharp.text.width + size * 0.26, height: sharp.text.height + size * 0.1)
        it.layer.bounds = CGRect(origin: .zero, size: it.box)
        let mid = CGPoint(x: it.box.width / 2, y: it.box.height / 2)
        for (k, s) in [("soft", soft), ("sharp", sharp)] {
            let l = ctx.spriteLayer(s); l.position = mid; it.layer.addSublayer(l); it.parts[k] = l
        }
        return it
    }
    override func idle(_ l: Line, _ it: Item) { it.layer.opacity = 0; it.parts["sharp"]?.opacity = 0; it.parts["soft"]?.opacity = 1 }

    override func sing(_ l: Line, _ it: Item, animated: Bool, now: Double) {
        let sharp = it.parts["sharp"]!, soft = it.parts["soft"]!
        guard animated else { it.layer.opacity = 1; sharp.opacity = 1; soft.opacity = 0; return }
        let d = min(0.9, max(0.5, ctx.duration(it.index) * 1.4))
        animate(it.layer, "opacity", from: 0, to: 1, dur: 0.22, curve: Curve.soft)
        animate(soft, "opacity", from: 1, to: 0, dur: d, curve: Curve.expoOut)
        animate(sharp, "opacity", from: 0, to: 1, dur: d * 0.8, curve: Curve.expoOut)
        animate(it.layer, "transform.scale", from: 1.32, to: 1, dur: d * 1.1, curve: Curve.expoOut)
        animate(it.layer, "position", from: NSValue(point: CGPoint(x: it.home.x, y: it.home.y - ctx.base * 0.1)), to: NSValue(point: it.home), dur: d * 1.1, curve: Curve.expoOut)
    }

    override func exit(_ l: Line, animated: Bool) -> Double {
        guard animated else { l.layer.opacity = 0; return 0 }
        for it in l.items.values {
            animate(it.parts["sharp"]!, "opacity", from: nil, to: 0, dur: 0.4, curve: Curve.soft)
            animate(it.parts["soft"]!, "opacity", from: nil, to: 1, dur: 0.3, curve: Curve.soft)
        }
        let p = l.layer.position
        animate(l.layer, "position", from: NSValue(point: p), to: NSValue(point: CGPoint(x: p.x, y: p.y + ctx.base * 0.55)), dur: 0.55, curve: Curve.inOut)
        animate(l.layer, "transform.scale", from: 1, to: 1.06, dur: 0.55, curve: Curve.inOut)
        animate(l.layer, "opacity", from: 1, to: 0, dur: 0.5, curve: Curve.soft)
        return 0.6
    }
}

// MARK: - Motion — words streak in with real motion blur and land sharp; the row glides

final class MotionScene: LyricScene {
    private let ctx: SceneContext
    private let script: SongScript?
    private let gritty: Bool
    private let row = CALayer()
    private var words: [(index: Int, layer: CALayer)] = []
    private var cursor: CGFloat = 0
    private var last = -1
    private var line = Int.min

    init(ctx: SceneContext, script: SongScript?, gritty: Bool) {
        self.ctx = ctx
        self.script = script
        self.gritty = gritty
        if gritty { ctx.host.addSublayer(ctx.backdrop(darkness: 0.72)) }
        quiet(row)
        row.frame = ctx.bounds
        ctx.host.addSublayer(row)
    }

    private func look(_ punch: Bool) -> SpriteLook {
        var l = SpriteLook(fill: .solid((punch ? ctx.highlightColor : ctx.lyricColor).rgba), shadow: true)
        if gritty { l.stroke = -5; l.distress = true }
        return l
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        guard index >= 0, index != last else { return }
        last = index
        let w = ctx.lyrics.words[index]
        // A new lyric line clears the row (old words streak off).
        if w.line != line {
            line = w.line
            for item in words {
                let p = item.layer.position, l = item.layer
                animated ? animate(l, "opacity", from: nil, to: 0, dur: 0.25, curve: Curve.soft) : (l.opacity = 0)
                if animated { animate(l, "position", from: NSValue(point: p), to: NSValue(point: CGPoint(x: p.x, y: p.y + ctx.base * 0.5)), dur: 0.3, curve: Curve.expoIn) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { l.removeFromSuperlayer() }
            }
            words.removeAll()
            cursor = 0
        }
        // Bake the next words (sharp + streak) in the background, exactly as drawn.
        if animated {
            var ahead: [(String, CGFloat, SpriteLook)] = []
            for j in index + 1 ..< min(ctx.lyrics.words.count, index + 7) {
                let p = ctx.emphasized(j, script), sz = ctx.base * (p ? 1.65 : 1.4)
                let t = ctx.lyrics.words[j].text + (ctx.emoji[j].map { " " + $0 } ?? "")
                var m = look(p); m.motion = 0.9
                ahead += [(t, sz, look(p)), (t, sz, m)]
            }
            ctx.prefetch(exact: ahead)
        }
        let rtl = LyricFonts.isArabic(w.text)
        let punch = ctx.emphasized(index, script)
        let size = ctx.base * (punch ? 1.65 : 1.4)
        let text = w.text + (ctx.emoji[index].map { " " + $0 } ?? "")
        let sharpS = ctx.sprite(text, size: size, look: look(punch))
        var mLook = look(punch); mLook.motion = 0.9
        let streakS = ctx.sprite(text, size: size, look: mLook)
        let width = sharpS.text.width
        let gap = size * 0.28
        let x = cursor + (words.isEmpty ? 0 : gap) + width / 2
        cursor = x + width / 2
        let dir: CGFloat = rtl ? -1 : 1
        let home = CGPoint(x: ctx.center.x + dir * x, y: ctx.center.y)
        let holder = CALayer(); quiet(holder)
        holder.bounds = CGRect(origin: .zero, size: streakS.size)
        holder.position = home
        let sharp = ctx.spriteLayer(sharpS), streak = ctx.spriteLayer(streakS)
        let mid = CGPoint(x: streakS.size.width / 2, y: streakS.size.height / 2)
        sharp.position = mid; streak.position = mid
        holder.addSublayer(streak); holder.addSublayer(sharp)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        row.addSublayer(holder)
        CATransaction.commit()
        words.append((index, holder))
        // The row glides so the newest word lands at the centre.
        let target = CGPoint(x: ctx.bounds.midX - dir * x, y: ctx.bounds.midY)
        animated ? spring(row, "position", from: nil, to: NSValue(point: target), damping: 22, stiffness: 150) : (row.position = target)
        for (k, item) in words.enumerated() where k < words.count - 1 {
            let age = words.count - 1 - k
            let o = Float(max(0.12, 0.7 - Double(age) * 0.16))
            animated ? animate(item.layer, "opacity", from: nil, to: o, dur: 0.3, curve: Curve.soft) : (item.layer.opacity = o)
        }
        guard animated else { streak.opacity = 0; return }
        // Fly in fast as a motion-blurred streak, resolving to sharp as it lands.
        let from = CGPoint(x: home.x + dir * ctx.base * 2.4, y: home.y)
        animate(holder, "position", from: NSValue(point: from), to: NSValue(point: home), dur: 0.34, curve: Curve.expoOut)
        keyframes(streak, "opacity", values: [0.95, 0.7, 0], times: [0, 0.45, 1], dur: 0.34)
        keyframes(sharp, "opacity", values: [0, 0.35, 1], times: [0, 0.5, 1], dur: 0.34)
        if punch { ctx.flash(gritty ? .white : ctx.highlightColor, strength: 0.35, dur: 0.2) }
    }
}

// MARK: - Neon — bloom-lit tubes that flicker on, with a reflection on the floor

final class NeonTubeScene: SpriteLineScene {
    override var sizeFactor: CGFloat { 0.66 }
    private var tube: NSColor { ctx.highlightColor }
    private var offLook: SpriteLook { SpriteLook(fill: .solid(tube.withAlphaComponent(0.38).rgba), stroke: 2.6) }
    private var onLook: SpriteLook {
        SpriteLook(fill: .solid((tube.blended(withFraction: 0.6, of: .white) ?? .white).rgba), glow: 0.16, glowColor: tube.rgba, bloom: true)
    }
    private var reflLook: SpriteLook { var l = onLook; l.blur = 0.05; return l }
    override var prefetchLooks: [SpriteLook] { [offLook, onLook, reflLook] }

    override func makeItem(_ i: Int, size: CGFloat) -> Item {
        let it = Item()
        let t = ctx.lyrics.words[i].text
        let off = ctx.sprite(t, size: size, look: offLook), on = ctx.sprite(t, size: size, look: onLook)
        it.box = CGSize(width: off.text.width + size * 0.32, height: off.text.height + size * 0.2)
        it.layer.bounds = CGRect(origin: .zero, size: it.box)
        let mid = CGPoint(x: it.box.width / 2, y: it.box.height / 2)
        let offL = ctx.spriteLayer(off); offL.position = mid
        let onL = ctx.spriteLayer(on); onL.position = mid; onL.opacity = 0
        // Floor reflection: a faint, softened, upside-down copy below the word.
        let refl = ctx.spriteLayer(ctx.sprite(t, size: size, look: reflLook))
        refl.position = CGPoint(x: mid.x, y: mid.y - off.text.height * 1.08)
        refl.transform = CATransform3DMakeScale(1, -0.8, 1)
        refl.opacity = 0
        for (k, l) in [("off", offL), ("on", onL), ("refl", refl)] { it.layer.addSublayer(l); it.parts[k] = l }
        return it
    }

    private var walls: [Int: CALayer] = [:]

    /// Only the bottom row gets a floor reflection (others would collide with the row below).
    /// Behind the tubes, a soft wall glow that builds up as more of the line lights.
    override func didLayout(_ l: Line) {
        let wall = CAGradientLayer(); quiet(wall)
        wall.type = .radial
        wall.startPoint = CGPoint(x: 0.5, y: 0.5); wall.endPoint = CGPoint(x: 1, y: 1)
        wall.colors = [tube.withAlphaComponent(0.32).cgColor, tube.withAlphaComponent(0).cgColor]
        let xs = l.items.values.map(\.home.x), ys = l.items.values.map(\.home.y)
        let w = ((xs.max() ?? 0) - (xs.min() ?? 0)) + ctx.base * 4, h = ((ys.max() ?? 0) - (ys.min() ?? 0)) + ctx.base * 2.6
        wall.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        wall.position = CGPoint(x: ((xs.max() ?? 0) + (xs.min() ?? 0)) / 2, y: ((ys.max() ?? 0) + (ys.min() ?? 0)) / 2)
        wall.opacity = 0
        l.layer.insertSublayer(wall, at: 0)
        walls[l.number] = wall
        let bottom = l.items.values.map(\.home.y).min() ?? 0
        for it in l.items.values where it.home.y > bottom + 1 { it.parts["refl"]?.removeFromSuperlayer(); it.parts["refl"] = CALayer() }
    }

    override func sing(_ l: Line, _ it: Item, animated: Bool, now: Double) {
        let on = it.parts["on"]!, refl = it.parts["refl"]!
        if let wall = walls[l.number] {
            let lit = Float(l.sung.count) / Float(max(1, l.order.count))
            let to = 0.35 + 0.65 * lit
            animated ? animate(wall, "opacity", from: nil, to: to, dur: 0.5, curve: Curve.soft) : (wall.opacity = to)
        }
        guard animated else { on.opacity = 1; refl.opacity = 0.16; return }
        let flicker: [Float] = [0, 1, 0.12, 0.92, 0.3, 1]
        let times: [NSNumber] = [0, 0.12, 0.24, 0.4, 0.55, 1]
        keyframes(on, "opacity", values: flicker, times: times, dur: 0.44)
        keyframes(refl, "opacity", values: flicker.map { $0 * 0.16 }, times: times, dur: 0.44)
    }

    override func exit(_ l: Line, animated: Bool) -> Double {
        if let wall = walls[l.number] { animated ? animate(wall, "opacity", from: nil, to: 0, dur: 0.3, curve: Curve.soft) : (wall.opacity = 0) }
        walls[l.number] = nil
        guard animated else { l.layer.opacity = 0; return 0 }
        for i in l.order where l.sung.contains(i) {
            guard let it = l.items[i] else { continue }
            let d = Double(i % 5) * 0.03
            keyframes(it.parts["on"]!, "opacity", values: [1, 0.25, 0.8, 0], times: [0, 0.3, 0.5, 1], dur: 0.34, delay: d)
            if let r = it.parts["refl"], r.superlayer != nil { keyframes(r, "opacity", values: [0.16, 0.04, 0.12, 0], times: [0, 0.3, 0.5, 1], dur: 0.34, delay: d) }
        }
        animate(l.layer, "opacity", from: 1, to: 0, dur: 0.3, delay: 0.15, curve: Curve.soft)
        return 0.5
    }
}

// MARK: - Lens — a fisheye column of words; the sung one magnified and glowing up front

final class LensScene: LyricScene {
    private let ctx: SceneContext
    private var items: [Int: (layer: CALayer, hot: CALayer)] = [:]
    private var lastIndex = Int.min
    private let reach = 4
    private var radius: CGFloat { ctx.base * 3.1 }

    init(ctx: SceneContext) { self.ctx = ctx }

    private func pose(_ r: CGFloat) -> (CGPoint, CGFloat, Float, CGFloat) {
        let a = max(-1.5, min(1.5, r * 0.4)), c = cos(a)
        let p = CGPoint(x: ctx.center.x - (1 - c) * ctx.base * 0.35, y: ctx.center.y - sin(a) * radius)
        return (p, 0.22 + 0.78 * pow(c, 3), Float(0.05 + 0.95 * pow(c, 3)), c)
    }

    func show(index: Int, now: Double, playing: Bool, animated: Bool) {
        let focus = max(0, index)
        guard focus != lastIndex else { return }
        let from = lastIndex == Int.min ? focus : lastIndex
        let lo = max(0, focus - reach), hi = min(ctx.lyrics.words.count - 1, focus + reach)
        let size = ctx.base * 0.95
        let baseLook = ctx.shadowLook
        let hotLook = SpriteLook(fill: .solid((ctx.highlightColor.blended(withFraction: 0.35, of: .white) ?? ctx.highlightColor).rgba), glow: 0.2, glowColor: ctx.highlightColor.rgba)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in lo...hi where items[i] == nil {
            let t = ctx.lyrics.words[i].text + (ctx.emoji[i].map { " " + $0 } ?? "")
            let bS = ctx.sprite(t, size: size, look: baseLook), hS = ctx.sprite(t, size: size, look: hotLook)
            let holder = CALayer(); quiet(holder)
            holder.bounds = CGRect(origin: .zero, size: hS.size)
            let mid = CGPoint(x: hS.size.width / 2, y: hS.size.height / 2)
            let b = ctx.spriteLayer(bS), h = ctx.spriteLayer(hS)
            b.position = mid; h.position = mid; h.opacity = 0
            holder.addSublayer(b); holder.addSublayer(h)
            let (p, s, o, c) = pose(CGFloat(i - from))
            holder.position = p; holder.setValue(s, forKeyPath: "transform.scale"); holder.opacity = animated ? 0 : o; holder.zPosition = c
            ctx.host.addSublayer(holder)
            items[i] = (holder, h)
        }
        CATransaction.commit()
        ctx.prefetch(Array(stride(from: hi + 1, through: min(ctx.lyrics.words.count - 1, hi + 4), by: 1)), size: size, looks: [baseLook, hotLook])
        let steps = 10, times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        for (i, item) in items {
            let l = item.layer
            let r0 = CGFloat(i - from), r1 = CGFloat(i - focus)
            let (p1, s1, o1, c1) = pose(r1)
            l.zPosition = c1
            if animated && from != focus {
                var ps: [NSValue] = [], ss: [CGFloat] = [], os: [Float] = []
                for k in 0...steps {
                    let e = 1 - pow(1 - CGFloat(k) / CGFloat(steps), 3)
                    let (p, sc, o, _) = pose(r0 + (r1 - r0) * e)
                    ps.append(NSValue(point: p)); ss.append(sc); os.append(l.opacity == 0 && k == 0 ? 0 : o)
                }
                keyframes(l, "position", values: ps, times: times, dur: 0.5)
                keyframes(l, "transform.scale", values: ss, times: times, dur: 0.5)
                keyframes(l, "opacity", values: os, times: times, dur: 0.5)
            } else { l.position = p1; l.setValue(s1, forKeyPath: "transform.scale"); l.opacity = o1 }
            let hot: Float = i == focus ? 1 : 0
            if item.hot.opacity != hot { animated ? animate(item.hot, "opacity", from: nil, to: hot, dur: 0.3) : (item.hot.opacity = hot) }
        }
        for (i, item) in items where i < lo || i > hi {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { item.layer.removeFromSuperlayer() }
            items[i] = nil
        }
        lastIndex = focus
    }
}
