import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum MotionStyle: String, CaseIterable, Identifiable {
    case auto = "Auto", flow = "Flow", orbit = "Orbit", bloom = "Bloom", aurora = "Aurora"
    var id: String { rawValue }
}

/// How the wallpaper moves for a particular song. Derived from the song itself so every
/// track gets its own, stable look: the same song always moves the same way.
struct SongMood: Equatable {
    var motion: MotionStyle = .flow   // never .auto once resolved
    var speed: Double = 1             // ~0.6 (slow ballad) … 1.8 (fast rap)
    var seed: UInt64 = 0

    static func make(track: Track?, lyrics: Lyrics?, preferred: MotionStyle) -> SongMood {
        guard let track else { return SongMood() }
        // FNV-1a — stable across launches (Swift's hashValue is randomized per process).
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(track.artist.lowercased())|\(track.title.lowercased())".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }

        // Lyric density is a good proxy for tempo/energy: words sung per second.
        var speed = 1.0
        if let w = lyrics?.words, w.count > 10, let first = w.first, let last = w.last, last.end > first.start {
            let wps = Double(w.count) / (last.end - first.start)
            speed = min(1.8, max(0.6, wps / 1.6))
        }

        var motion = preferred
        if motion == .auto {
            let fast: [MotionStyle] = [.orbit, .bloom], slow: [MotionStyle] = [.flow, .aurora]
            let all: [MotionStyle] = [.flow, .orbit, .bloom, .aurora]
            if speed > 1.25 { motion = fast[Int(h % 2)] }
            else if speed < 0.85 { motion = slow[Int(h % 2)] }
            else { motion = all[Int(h % 4)] }
        }
        return SongMood(motion: motion, speed: speed, seed: h)
    }
}

/// Pre-blurred album art, made once per song. Drawing tiny blurred images scaled up to full
/// screen gives Apple Music's soft colour clouds for almost no GPU cost.
struct ArtClouds {
    /// Full square, used as the always-covering base layer.
    var cover: NSImage
    /// Same art with a soft round alpha falloff: a "blob" with no visible edges.
    var blob: NSImage
}

enum ArtBlur {
    private static let ctx = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    static func clouds(from image: NSImage) -> ArtClouds? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let s = 96 / max(ci.extent.width, ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let extent = ci.extent

        let color = CIFilter.colorControls()
        color.inputImage = ci
        color.saturation = 1.6
        color.contrast = 1.12
        color.brightness = -0.03
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = color.outputImage?.clampedToExtent()
        blur.radius = 6
        guard let soft = blur.outputImage?.cropped(to: extent) else { return nil }

        let grad = CIFilter.radialGradient()
        grad.center = CGPoint(x: extent.midX, y: extent.midY)
        grad.radius0 = Float(extent.width * 0.18)
        grad.radius1 = Float(extent.width * 0.5)
        grad.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        grad.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        let mask = CIFilter.blendWithAlphaMask()
        mask.inputImage = soft
        mask.backgroundImage = CIImage.empty()
        mask.maskImage = grad.outputImage?.cropped(to: extent)

        guard let coverCG = ctx.createCGImage(soft, from: extent),
              let blobOut = mask.outputImage?.cropped(to: extent),
              let blobCG = ctx.createCGImage(blobOut, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        return ArtClouds(cover: NSImage(cgImage: coverCG, size: extent.size), blob: NSImage(cgImage: blobCG, size: extent.size))
    }
}

/// The animated background, built from Core Animation layers.
///
/// All motion is expressed as long-running CA animations, which the window server plays on
/// its own — Wordlight's process doesn't wake up per frame. The app only touches the layers
/// when the song changes (new art, new motion) and to fire a short "pulse" on each word or beat.
struct WallpaperView: View {
    @EnvironmentObject var engine: Engine
    var active: Bool
    /// Desktop only: play the click-the-cover zoom/blur transitions.
    var transitions = false
    var body: some View { WallpaperLayers(pulse: engine.pulse, active: active, allowTransitions: transitions) }
}

private struct WallpaperLayers: NSViewRepresentable {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @ObservedObject var pulse: Pulse
    var active: Bool
    var allowTransitions: Bool

    func makeNSView(context: Context) -> WallpaperLayerView { WallpaperLayerView() }

    func updateNSView(_ v: WallpaperLayerView, context: Context) {
        v.apply(clouds: engine.artCloud, palette: engine.palette, mood: engine.mood,
                dim: prefs.dim, glowY: prefs.verticalPosition)
        v.setRunning(active, playing: engine.player.isPlaying)
        v.pulse(id: pulse.count, strength: pulse.strength * prefs.intensity)
        if allowTransitions {
            v.prewarm(engine.displayArtwork)
            v.transition(phase: engine.phase, id: engine.phaseID, art: engine.displayArtwork)
        }
    }
}

final class WallpaperLayerView: NSView {
    private let world = CALayer()        // everything that breathes on a pulse
    /// The whole live picture (colour, clouds, glow, dim, vignette); masked for the reveal.
    private let liveGroup = CALayer()
    private let reveal = CAGradientLayer()
    private let baseHolder = CALayer(), baseContent = CALayer()
    private var holders: [CALayer] = [], contents: [CALayer] = []
    private let glow = CAGradientLayer()
    private let dimLayer = CALayer()
    private let vignette = CAGradientLayer()
    /// Sharp album cover used only during the on/off transitions.
    private let artLayer = CALayer()
    /// Coloured glow under the floating cover (the album's highlight colour).
    private let artGlow = CALayer()
    private let artSoft = CALayer()
    private let artGroup = CALayer()
    private var artCache: (id: ObjectIdentifier, sharp: CGImage?, soft: CGImage?)?
    private var glowImage: CGImage?
    private var glowColor = NSColor.white.cgColor
    private var lastPhaseID = -1
    private var shown = true          // live picture visible (false = your normal wallpaper)
    private var bgColor = NSColor.black.cgColor

    private var motionKey = ""
    private var cloudsID: ObjectIdentifier?
    private var paletteKey = ""
    private var lastPulse = 0
    private var running = true
    private var playing = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.clear.cgColor
        layer = root
        // Depth for the cover's 3D lift during the on/off transitions.
        var persp = CATransform3DIdentity; persp.m34 = -1 / 1600
        // The cover tilts in its own 3D space, so it never dips behind the wallpaper plane.
        artGroup.sublayerTransform = persp
        liveGroup.backgroundColor = NSColor.black.cgColor
        root.addSublayer(liveGroup)
        liveGroup.addSublayer(world)
        // Soft-edged disc used as a mask: the live picture blooms out from (or folds back into) the cover.
        reveal.type = .radial
        reveal.startPoint = CGPoint(x: 0.5, y: 0.5)
        reveal.endPoint = CGPoint(x: 1, y: 1)
        reveal.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        reveal.locations = [0, 0.62, 1]
        // The clouds are pure blur, so let the window server render them at 1/4 resolution and
        // scale up: ~16× fewer pixels to fill each frame, visually identical.
        world.shouldRasterize = true
        world.rasterizationScale = 0.25 * (NSScreen.main?.backingScaleFactor ?? 2) / 2
        world.minificationFilter = .linear
        world.magnificationFilter = .linear
        world.addSublayer(baseHolder)
        baseHolder.addSublayer(baseContent)
        for _ in 0..<4 {
            let h = CALayer(), c = CALayer()
            h.addSublayer(c)
            world.addSublayer(h)
            holders.append(h); contents.append(c)
        }
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.opacity = 0
        liveGroup.addSublayer(glow)
        liveGroup.addSublayer(dimLayer)
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)
        vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.55).cgColor]
        vignette.locations = [0.45, 1]
        liveGroup.addSublayer(vignette)
        layerUsesCoreImageFilters = true
        artLayer.masksToBounds = true
        artLayer.contentsGravity = .resizeAspectFill
        artLayer.opacity = 0
        // Pre-blurred copies instead of live filters/shadows: the window server only crossfades images.
        artSoft.contentsGravity = .resize
        artSoft.opacity = 0
        artGlow.contentsGravity = .resize
        artGlow.opacity = 0
        artGlow.zPosition = -1
        artSoft.zPosition = 1
        artGroup.addSublayer(artGlow)
        artGroup.addSublayer(artLayer)
        artGroup.addSublayer(artSoft)
        root.addSublayer(artGroup)
        for l in [artLayer, artGlow, artSoft, artGroup, liveGroup, reveal, world, baseHolder, baseContent, glow, dimLayer, vignette] + holders + contents {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "frame": NSNull()]
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        motionKey = "" // size changed: rebuild animations for the new geometry
        rebuildIfNeeded()
    }

    private var mood = SongMood()
    private var dim = 0.2
    private var glowY = 0.5

    func apply(clouds: ArtClouds?, palette: Palette, mood: SongMood, dim: Double, glowY: Double) {
        self.mood = mood
        self.dim = dim
        self.glowY = glowY

        // New artwork: crossfade the layer contents.
        let id = clouds.map { ObjectIdentifier($0.cover) }
        if id != cloudsID {
            cloudsID = id
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.4)
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = 1.4
            let cover = clouds?.cover.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let blob = clouds?.blob.cgImage(forProposedRect: nil, context: nil, hints: nil)
            baseContent.add(fade, forKey: "fade")
            baseContent.contents = cover
            for c in contents { c.add(fade, forKey: "fade"); c.contents = blob }
            CATransaction.commit()
        }

        let pk = "\(palette.highlight.hexString)\(palette.secondary.hexString)\(dim)"
        if pk != paletteKey {
            paletteKey = pk
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.2)
            bgColor = NSColor(palette.secondary).cgColor
            liveGroup.backgroundColor = bgColor
            glowColor = NSColor(palette.highlight).cgColor
            glowImage = Self.glowBlob(NSColor(palette.highlight))
            artGlow.contents = glowImage
            glow.colors = [NSColor(palette.highlight).withAlphaComponent(0.42).cgColor, NSColor(palette.highlight).withAlphaComponent(0).cgColor]
            dimLayer.backgroundColor = NSColor.black.withAlphaComponent(dim).cgColor
            CATransaction.commit()
        }
        rebuildIfNeeded()
    }

    /// running=false (hidden/covered/locked) freezes everything; paused playback slows to a drift.
    func setRunning(_ running: Bool, playing: Bool) {
        let speed: Float = running ? (playing ? 1 : 0.15) : 0
        guard speed != world.speed else { return }
        let now = CACurrentMediaTime()
        world.timeOffset = world.convertTime(now, from: nil)
        world.beginTime = now
        world.speed = speed
        self.running = running
        self.playing = playing
    }

    // MARK: - Click-the-cover transitions

    /// Where the cover sits in the desktop card (view coordinates, origin bottom-left).
    static var cardArtRect: CGRect {
        CGRect(x: CardLayout.origin.x + CardLayout.artInset, y: CardLayout.origin.y + (CardLayout.size.height - CardLayout.art) / 2,
               width: CardLayout.art, height: CardLayout.art)
    }

    func transition(phase: Engine.WallpaperPhase, id: Int, art: NSImage?) {
        guard id != lastPhaseID else { return }
        let first = lastPhaseID == -1
        lastPhaseID = id
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        func settle(_ live: Bool) {
            shown = live
            liveGroup.mask = nil
            liveGroup.removeAnimation(forKey: "opacity")
            liveGroup.opacity = live ? 1 : 0
            if !live, artLayer.contents != nil, (artLayer.presentation()?.opacity ?? 0) > 0.01 {
                // Landed: the card's cover is now showing on top, so dissolve the flying copy underneath it.
                let p = artLayer.presentation()
                artLayer.removeAllAnimations()
                if let p { artLayer.bounds = p.bounds; artLayer.position = p.position; artLayer.cornerRadius = p.cornerRadius }
                artLayer.opacity = 0
                let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0; a.duration = 0.3; a.beginTime = CACurrentMediaTime() + 0.08
                a.fillMode = .backwards
                artLayer.add(a, forKey: "handoff")
            } else {
                artLayer.removeAllAnimations()
                artLayer.opacity = 0
                artLayer.contents = nil
            }
            artGlow.removeAllAnimations()
            artGlow.opacity = 0
            artSoft.removeAllAnimations()
            artSoft.opacity = 0
            artSoft.contents = nil
        }
        if first { settle(phase != .off); return }

        let full = fullRect
        let card = Self.cardArtRect
        // The "hero" moment: the sharp cover floats big in the middle of the screen.
        let heroSide = min(bounds.width, bounds.height) * 0.52
        let hero = CGRect(x: bounds.midX - heroSide / 2, y: bounds.midY - heroSide / 2, width: heroSide, height: heroSide)
        let heroR = heroSide * 0.055
        let now = CACurrentMediaTime()
        func size(_ r: CGRect, _ k: CGFloat = 1) -> NSValue { NSValue(rect: CGRect(x: 0, y: 0, width: r.width * k, height: r.height * k)) }
        func mid(_ r: CGRect) -> NSValue { NSValue(point: CGPoint(x: r.midX, y: r.midY)) }
        let out = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)      // fast launch, long glide
        let inOut = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        let easeIn = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.75, 0.2)
        let soft = CAMediaTimingFunction(name: .easeInEaseOut)
        let lin = CAMediaTimingFunction(name: .linear)

        let images = coverImages(art)
        for l in [artLayer, artSoft, artGlow] { l.removeAllAnimations(); l.opacity = 0; l.transform = CATransform3DIdentity }
        artLayer.contents = images.sharp
        artSoft.contents = images.soft
        artGlow.contents = glowImage
        /// The blurred copy and the glow follow the cover exactly; only their visibility differs.
        /// The glow is a soft blob 1.6× the cover's size.
        func both(_ key: String, _ v: [Any], _ t: [NSNumber], _ f: [CAMediaTimingFunction], _ d: Double) {
            keys(artLayer, key, v, t, f, d, now)
            if key == "bounds" {
                keys(artSoft, key, v.map { (($0 as? NSValue)?.rectValue).map { NSValue(rect: CGRect(x: 0, y: 0, width: $0.width * 1.5, height: $0.height * 1.5)) } ?? $0 }, t, f, d, now)
            } else if key != "cornerRadius" { keys(artSoft, key, v, t, f, d, now) }
            if key == "bounds" {
                let big = v.map { (($0 as? NSValue)?.rectValue).map { NSValue(rect: CGRect(x: 0, y: 0, width: $0.width * 1.6, height: $0.height * 1.6)) } ?? $0 }
                keys(artGlow, key, big, t, f, d, now)
            } else if key != "cornerRadius" {
                keys(artGlow, key, v, t, f, d, now)
            }
        }
        // The reveal disc must cover the farthest corner when fully open.
        let reach = hypot(bounds.width, bounds.height) / 2 / 0.62 * 2
        reveal.frame = CGRect(x: bounds.midX - reach / 2, y: bounds.midY - reach / 2, width: reach, height: reach)
        reveal.removeAllAnimations()

        switch phase {
        case .entering:
            shown = true
            let d = 1.75
            // Cover: a little press, launch out of the card with a 3D lift, overshoot into the hero
            // size, hang there a moment, then grow past the screen while it melts into the blur.
            artLayer.frame = full; artLayer.cornerRadius = 0
            artSoft.frame = full
            artGlow.frame = full
            let t: [NSNumber] = [0, 0.05, 0.4, 0.5, 0.58, 1]
            both("bounds", [size(card), size(card, 0.9), size(hero, 1.03), size(hero), size(hero), size(full)], t,
                 [soft, out, soft, lin, easeIn], d)
            both("position", [mid(card), mid(card), mid(hero), mid(hero), mid(hero), mid(full)], t,
                 [soft, out, soft, lin, easeIn], d)
            both("cornerRadius", [7, 6.5, heroR, heroR, heroR, 0], t, [soft, out, soft, lin, easeIn], d)
            both("transform.rotation.x", [0, 0, 0.32, 0, 0], [0, 0.05, 0.2, 0.46, 1], [lin, out, soft, lin], d)
            both("transform.rotation.y", [0, 0, -0.2, 0, 0], [0, 0.05, 0.22, 0.48, 1], [lin, out, soft, lin], d)
            // Melt: the sharp cover crossfades into its blurred twin, which then dissolves into the clouds.
            keys(artLayer, "opacity", [1, 1, 0], [0, 0.6, 0.78], [lin, soft], d, now)
            keys(artSoft, "opacity", [0, 0, 1, 0], [0, 0.58, 0.72, 0.95], [lin, soft, soft], d, now)
            keys(artGlow, "opacity", [0, 0, 1, 1, 0], [0, 0.05, 0.32, 0.56, 0.66], [lin, soft, lin, soft], d, now)
            // Live picture blooms outward from behind the floating cover.
            liveGroup.opacity = 1
            liveGroup.mask = reveal
            reveal.transform = CATransform3DIdentity
            keys(reveal, "transform.scale", [0.04, 0.04, 1], [0, 0.3, 0.86], [lin, CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)], d, now)
            keys(liveGroup, "opacity", [0, 0, 1, 1], [0, 0.28, 0.42, 1], [lin, soft, lin], d, now)
            // Landing: one soft "boom" of light as the cover dissolves into the clouds.
            boom(at: now + d * 0.74)

        case .leaving:
            shown = false
            let d = 1.8
            // Cover: fades in as a blur that sharpens ("enhance") while shrinking to the hero size,
            // hangs, then flies home to the card with a tilt and a tiny landing bounce.
            artLayer.frame = card; artLayer.cornerRadius = 7
            artSoft.frame = card
            artGlow.frame = card
            let t: [NSNumber] = [0, 0.36, 0.6, 0.86, 0.94, 1]
            both("bounds", [size(full), size(hero), size(hero), size(card), size(card), size(card)], t,
                 [out, lin, inOut, soft, lin], d)
            both("position", [mid(full), mid(hero), mid(hero), mid(card), mid(card), mid(card)], t,
                 [out, lin, inOut, soft, lin], d)
            both("cornerRadius", [0, heroR, heroR, 7, 7, 7], t, [out, lin, inOut, soft, lin], d)
            both("transform.rotation.x", [0, 0, 0.3, 0, 0], [0, 0.6, 0.74, 0.86, 1], [lin, soft, soft, lin], d)
            both("transform.rotation.y", [0, 0, 0.18, 0, 0], [0, 0.6, 0.74, 0.86, 1], [lin, soft, soft, lin], d)
            // "Enhance": the blurred twin appears, then the sharp cover resolves out of it.
            keys(artSoft, "opacity", [0, 1, 1, 0], [0, 0.14, 0.24, 0.42], [soft, lin, soft], d, now)
            // Stays fully visible all the way into the card; the card's own cover takes over on landing.
            keys(artLayer, "opacity", [0, 0, 1, 1], [0, 0.16, 0.4, 1], [lin, soft, lin], d, now)
            keys(artGlow, "opacity", [0, 0, 1, 1, 0], [0, 0.28, 0.44, 0.78, 0.9], [lin, soft, lin, soft], d, now)
            // Live picture folds back into the cover, uncovering your own wallpaper around it.
            liveGroup.opacity = 0
            liveGroup.mask = reveal
            reveal.transform = CATransform3DMakeScale(0.04, 0.04, 1)
            keys(reveal, "transform.scale", [1, 1, 0.04], [0, 0.24, 0.6], [lin, CAMediaTimingFunction(controlPoints: 0.5, 0, 0.3, 1)], d, now)
            keys(liveGroup, "opacity", [1, 1, 0], [0, 0.6, 0.63], [lin, lin], d, now)

        case .live, .off:
            settle(phase == .live)
        }
    }

    func prewarm(_ art: NSImage?) { _ = coverImages(art) }

    /// Sharp and heavily blurred versions of the cover, made once per artwork.
    private func coverImages(_ art: NSImage?) -> (sharp: CGImage?, soft: CGImage?) {
        guard let art else { return (nil, nil) }
        let id = ObjectIdentifier(art)
        if let c = artCache, c.id == id { return (c.sharp, c.soft) }
        let sharp = art.cgImage(forProposedRect: nil, context: nil, hints: nil)
        var soft: CGImage?
        if let sharp {
            // Blur a small copy (it's going to be a soft wash anyway), then let the GPU scale it up.
            let ci = CIImage(cgImage: sharp)
            let k = 96 / max(ci.extent.width, 1)
            let small = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
            // Not clamped, so the edges feather out to nothing: no hard border while it grows.
            let inner = small.clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: small.extent)
            // Padded by 25% on every side (the layer is drawn 1.5x the cover's size to match).
            let pad = small.extent.width * 0.25
            let feathered = inner.applyingGaussianBlur(sigma: 8)
            soft = Sprites.shared.createCGImage(feathered, from: small.extent.insetBy(dx: -pad, dy: -pad))
        }
        artCache = (id, sharp, soft)
        return (sharp, soft)
    }

    /// A soft glow blob in the song's colour, drawn once per palette.
    private static func glowBlob(_ color: NSColor) -> CGImage? {
        let n = 128
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let inset = CGFloat(n) * 0.19
        c.setFillColor(color.withAlphaComponent(0.85).cgColor)
        c.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset - 6, width: CGFloat(n) - inset * 2, height: CGFloat(n) - inset * 2),
                         cornerWidth: 10, cornerHeight: 10, transform: nil))
        c.fillPath()
        guard let img = c.makeImage() else { return nil }
        let ci = CIImage(cgImage: img)
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: 11).cropped(to: ci.extent)
        return Sprites.shared.createCGImage(out, from: ci.extent)
    }

    /// Keyframes on one property; holds the first value before it starts and the model value after.
    private func keys(_ l: CALayer, _ key: String, _ values: [Any], _ times: [NSNumber], _ timing: [CAMediaTimingFunction],
                      _ dur: Double, _ begin: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        a.keyTimes = times
        a.timingFunctions = timing
        a.duration = dur
        a.beginTime = l.convertTime(begin, from: nil)
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(a, forKey: key)
    }

    /// A soft flash of the highlight colour with a gentle outward kick.
    private func boom(at t: CFTimeInterval) {
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.75, 0]
        flash.keyTimes = [0, 0.18, 1]
        flash.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        flash.isAdditive = true
        flash.duration = 1.1
        flash.beginTime = glow.convertTime(t, from: nil)
        glow.add(flash, forKey: "landing")
        let kick = CAKeyframeAnimation(keyPath: "transform.scale")
        kick.values = [0.07, 0.02, 0]
        kick.keyTimes = [0, 0.35, 1]
        kick.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        kick.isAdditive = true
        kick.duration = 1.2
        kick.beginTime = world.convertTime(t, from: nil)
        world.add(kick, forKey: "landing")
    }

    private var fullRect: CGRect {
        // Aspect-fill square covering the screen, like the cover filling the desktop.
        let side = max(bounds.width, bounds.height)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private func add(_ l: CALayer, _ key: String, from: Any, to: Any, begin: CFTimeInterval, dur: Double,
                     timing: CAMediaTimingFunction, holdFrom: Bool = false, key name: String? = nil) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.beginTime = l.convertTime(begin, from: nil)
        a.duration = dur
        a.timingFunction = timing
        // Before it starts, hold the "from" value (so a delayed step doesn't flash the final state).
        a.fillMode = holdFrom || begin > CACurrentMediaTime() + 0.01 ? .backwards : .removed
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(a, forKey: name ?? key)
    }

    /// One "boom": the whole picture kicks outward and the highlight glow flashes, with a fast
    /// attack and a smooth release. Beats from the music hit harder than word onsets.
    func pulse(id: Int, strength: Double) {
        guard id != lastPulse else { return }
        lastPulse = id
        guard running, playing, shown, strength > 0.01 else { return }
        let s = min(1.6, strength)
        let kick = CAKeyframeAnimation(keyPath: "transform.scale")
        kick.values = [0, 0.055 * s, 0.018 * s, 0]
        kick.keyTimes = [0, 0.09, 0.4, 1]
        kick.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1),
                                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        kick.isAdditive = true
        kick.duration = 0.85
        world.add(kick, forKey: "kick\(id % 4)")

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, min(1, 0.95 * s), 0]
        flash.keyTimes = [0, 0.08, 1]
        flash.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        flash.isAdditive = true
        flash.duration = 0.8
        glow.add(flash, forKey: "flash\(id % 4)")

        // Bigger hits also lift the dim a touch, so the colours "light up" on the boom.
        if s > 0.7 {
            let lift = CAKeyframeAnimation(keyPath: "opacity")
            lift.values = [0, -0.35 * (s - 0.5), 0]
            lift.keyTimes = [0, 0.1, 1]
            lift.isAdditive = true
            lift.duration = 0.6
            dimLayer.add(lift, forKey: "lift\(id % 4)")
        }
    }

    /// Snapshot support: render the layer tree with every animation evaluated at time t.
    func still(at t: Double) -> NSImage? {
        guard let root = layer else { return nil }
        let size = bounds.size
        func freeze(_ l: CALayer) {
            for key in l.animationKeys() ?? [] {
                guard let a = l.animation(forKey: key)?.copy() as? CAAnimation else { continue }
                a.speed = 0
                a.timeOffset = t + a.timeOffset
                a.beginTime = 0
                l.add(a, forKey: key)
            }
            l.sublayers?.forEach(freeze)
            if let m = l.mask { freeze(m) }
        }
        freeze(root)
        // render(in:) only draws model values, so bake the presentation values in.
        func bake(_ l: CALayer) {
            if let p = l.presentation() {
                l.position = p.position; l.transform = p.transform; l.opacity = p.opacity
                l.bounds = p.bounds; l.cornerRadius = p.cornerRadius
            }
            l.sublayers?.forEach(bake)
            if let m = l.mask { bake(m) }
        }
        CATransaction.flush()
        if ProcessInfo.processInfo.environment["WL_DEBUG_STILL"] != nil {
            NSLog("still t=\(t) live pres=\(String(describing: liveGroup.presentation()?.opacity)) model=\(liveGroup.opacity) anims=\(liveGroup.animationKeys() ?? []) mask=\(liveGroup.mask != nil) art=\(artLayer.contents != nil) artPres=\(String(describing: artLayer.presentation()?.bounds))")
        }
        bake(root)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        root.render(in: ctx)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Motion

    private func rebuildIfNeeded() {
        let size = bounds.size
        guard size.width > 10 else { return }
        let key = "\(mood.motion.rawValue)|\(mood.speed)|\(mood.seed)|\(Int(size.width))x\(Int(size.height))|\(glowY)|\(UserDefaults.standard.bool(forKey: "extraSmooth"))"
        guard key != motionKey else { return }
        let sameSize = motionKey.hasSuffix("") && motionKey.contains("|\(Int(size.width))x\(Int(size.height))|")
        let crossfade = !motionKey.isEmpty && sameSize && shown
        motionKey = key
        // New song / new motion: freeze a soft snapshot of the current clouds on top and fade it
        // out while the new motion starts underneath, so the change is seamless (no jump).
        if crossfade { crossfadeFromCurrent() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = size.width, h = size.height
        let mid = CGPoint(x: w / 2, y: h / 2)
        let sp = mood.speed
        let seedPhase = Double(mood.seed % 1000) / 1000 * .pi * 2

        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.position = mid
        liveGroup.frame = bounds
        artGroup.frame = bounds
        world.frame = bounds
        dimLayer.frame = bounds
        vignette.frame = bounds.insetBy(dx: -w * 0.1, dy: -h * 0.1)
        let g = max(w, h) * 0.9
        // CA's y axis points up; SwiftUI's glowY is from the top.
        glow.frame = CGRect(x: mid.x - g / 2, y: h * (1 - glowY) - g / 2, width: g, height: g)

        // Base: full cover, slowly turning, big enough to never show its edges.
        let diag = sqrt(w * w + h * h) * 1.25
        baseHolder.removeAllAnimations()
        baseHolder.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
        baseHolder.position = mid
        baseContent.frame = baseHolder.bounds
        baseHolder.add(spin(from: seedPhase, turns: 1, duration: 520 / sp), forKey: "spin")
        baseHolder.add(loop(points: (0..<24).map { k -> CGPoint in
            let a = Double(k) / 24 * .pi * 2
            return CGPoint(x: mid.x + CGFloat(sin(a + seedPhase)) * w * 0.04, y: mid.y + CGFloat(cos(a + seedPhase)) * h * 0.04)
        }, duration: 70 / sp), forKey: "drift")

        let d = max(w, h) * 1.15
        for i in 0..<4 {
            let holder = holders[i], content = contents[i]
            holder.removeAllAnimations(); content.removeAllAnimations()
            holder.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            content.frame = holder.bounds
            content.opacity = 0.9
            let fi = Double(i)
            let ph = seedPhase + fi * 1.9
            let flipX: CGFloat = (i == 1 || i == 3) ? -1 : 1
            let flipY: CGFloat = i >= 2 ? -1 : 1

            switch mood.motion {
            case .flow, .auto:
                let pts = (0..<48).map { k -> CGPoint in
                    let a = Double(k) / 48 * .pi * 2
                    return CGPoint(x: mid.x + CGFloat(sin(a + ph)) * w * 0.3, y: mid.y + CGFloat(sin(2 * a + ph * 1.3)) * h * 0.28)
                }
                holder.position = pts[0]
                holder.add(loop(points: pts, duration: (80 + fi * 17) / sp), forKey: "path")
                holder.add(spin(from: ph, turns: i % 2 == 0 ? 1 : -1, duration: (210 + fi * 30) / sp), forKey: "spin")
                content.transform = CATransform3DMakeScale(0.8 * flipX, 0.8 * flipY, 1)
                content.add(breathe(from: 0.8, to: 0.94, flipX: flipX, flipY: flipY, duration: (9 + fi * 2) / sp, phase: ph), forKey: "breathe")
            case .orbit:
                let r = CGSize(width: w * 0.27, height: h * 0.27)
                let pts = (0..<48).map { k -> CGPoint in
                    let a = Double(k) / 48 * .pi * 2 + fi * .pi / 2 + seedPhase
                    return CGPoint(x: mid.x + CGFloat(cos(a)) * r.width, y: mid.y + CGFloat(sin(a)) * r.height)
                }
                holder.position = pts[0]
                holder.add(loop(points: pts, duration: 40 / sp), forKey: "path")
                holder.add(spin(from: ph, turns: 1, duration: 57 / sp), forKey: "spin")
                content.transform = CATransform3DMakeScale(0.7 * flipX, 0.7 * flipY, 1)
            case .bloom:
                let q = CGPoint(x: i % 2 == 0 ? -0.24 : 0.24, y: i < 2 ? -0.22 : 0.22)
                let c0 = CGPoint(x: mid.x + q.x * w, y: mid.y + q.y * h)
                let pts = (0..<24).map { k -> CGPoint in
                    let a = Double(k) / 24 * .pi * 2
                    return CGPoint(x: c0.x + CGFloat(sin(a + ph)) * w * 0.05, y: c0.y + CGFloat(cos(a + ph)) * h * 0.05)
                }
                holder.position = pts[0]
                holder.add(loop(points: pts, duration: 70 / sp), forKey: "path")
                holder.add(spin(from: ph, turns: 1, duration: 200 / sp), forKey: "spin")
                content.transform = CATransform3DMakeScale(0.62 * flipX, 0.62 * flipY, 1)
                content.add(breathe(from: 0.5, to: 0.85, flipX: flipX, flipY: flipY, duration: 4.5 / sp, phase: ph), forKey: "breathe")
            case .aurora:
                let y0 = h * CGFloat(0.12 + 0.25 * fi)
                let pts = (0..<36).map { k -> CGPoint in
                    let a = Double(k) / 36 * .pi * 2
                    return CGPoint(x: mid.x + CGFloat(sin(a + ph)) * w * 0.36, y: y0 + CGFloat(sin(3 * a + ph)) * h * 0.05)
                }
                holder.position = pts[0]
                holder.add(loop(points: pts, duration: (120 + fi * 23) / sp), forKey: "path")
                let sway = CABasicAnimation(keyPath: "transform.rotation.z")
                sway.fromValue = -0.3; sway.toValue = 0.3
                sway.duration = (16 + fi * 3) / sp
                sway.autoreverses = true; sway.repeatCount = .infinity
                sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sway.timeOffset = ph
                sway.preferredFrameRateRange = Self.driftRate
                holder.add(sway, forKey: "sway")
                content.transform = CATransform3DMakeScale(1.6 * flipX, 0.42 * flipY, 1)
            }
        }
        CATransaction.commit()
    }

    /// The clouds move slowly, so 24 fps looks identical to 60 fps and halves the
    /// compositing work (less GPU, less fan, longer battery). Beats/transitions still run at 60.
    static var driftRate: CAFrameRateRange {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12) }
        return UserDefaults.standard.bool(forKey: "extraSmooth")
            ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            : CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    }

    private func crossfadeFromCurrent() {
        guard let pres = world.presentation(), bounds.width > 10 else { return }
        let q: CGFloat = 1 / 6                         // the clouds are blur: a tiny snapshot is enough
        let w = Int(bounds.width * q), h = Int(bounds.height * q)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(bgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: q, y: q)
        pres.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let ghost = CALayer()
        ghost.contents = img
        ghost.frame = bounds
        ghost.contentsGravity = .resize
        ghost.minificationFilter = .linear
        ghost.magnificationFilter = .linear
        ghost.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveGroup.insertSublayer(ghost, above: world)
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 1.8
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        ghost.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { ghost.removeFromSuperlayer() }
    }

    private func loop(points: [CGPoint], duration: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "position")
        a.values = (points + [points[0]]).map { NSValue(point: $0) }
        a.calculationMode = .cubic
        a.duration = duration
        a.repeatCount = .infinity
        a.preferredFrameRateRange = Self.driftRate
        return a
    }

    private func spin(from: Double, turns: Double, duration: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = from
        a.toValue = from + turns * .pi * 2
        a.duration = duration
        a.repeatCount = .infinity
        a.preferredFrameRateRange = Self.driftRate
        return a
    }

    private func breathe(from: CGFloat, to: CGFloat, flipX: CGFloat, flipY: CGFloat, duration: Double, phase: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = CATransform3DMakeScale(from * flipX, from * flipY, 1)
        a.toValue = CATransform3DMakeScale(to * flipX, to * flipY, 1)
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.timeOffset = phase.truncatingRemainder(dividingBy: duration)
        a.preferredFrameRateRange = Self.driftRate
        return a
    }
}

/// Small "now playing" card for the desktop.
struct NowPlayingCard: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        if let t = engine.displayTrack {
            let flying = engine.phase == .entering || engine.phase == .leaving
            HStack(spacing: 10) {
                Group {
                    if let art = engine.displayArtwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12))
                    }
                }
                .frame(width: CardLayout.art, height: CardLayout.art).clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                // While the wallpaper changes, the cover itself is out flying; it reappears the moment it lands.
                .opacity(flying ? 0 : 1)
                .animation(flying ? .easeOut(duration: 0.08) : nil, value: flying)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(t.artist).font(.system(size: 11, weight: .medium)).opacity(0.7).lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4)
            }
            .padding(.horizontal, CardLayout.artInset)
            .frame(height: CardLayout.size.height)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: CardLayout.size.width, alignment: .leading)
        }
    }
}

/// Lock-screen clock (date + large time), drawn over the live background.
struct LockClock: View {
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 0) {
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 104, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.25), radius: 12)
        }
    }
}

enum CardLayout {
    static let size = CGSize(width: 300, height: 60)
    static let origin = CGPoint(x: 28, y: 150)     // from the screen's bottom-left
    static let art: CGFloat = 40
    static let artInset: CGFloat = 10
}

/// The clickable card shown in its own small window above the desktop icons.
struct CardWindowRoot: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .leading) {
            if prefs.enabled && prefs.nowPlayingCard && engine.displayTrack != nil {
                NowPlayingCard()
                    .scaleEffect(hover ? 1.04 : 1, anchor: .leading)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
                    .onHover { hover = $0 }
                    .onTapGesture { engine.toggleLive() }
                    .help(engine.phase == .off || engine.phase == .leaving
                          ? "Click to turn the live wallpaper back on"
                          : "Click to show your normal wallpaper")
                    .transition(.opacity)
            }
        }
        .frame(width: CardLayout.size.width, height: CardLayout.size.height, alignment: .leading)
    }
}
