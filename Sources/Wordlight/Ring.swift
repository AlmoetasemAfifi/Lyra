import AppKit
import Combine
import CoreImage

/// Ring light: a soft glow hugging the screen edges, brightest in the corners, painted in the
/// album's colours. It floats over every app while music plays and follows the song:
///  - the colours slowly circle the screen at the song's own pace,
///  - beats flare the bright inner edge,
///  - each new lyric line sends a comet of light around the ring,
///  - punch words hit with a full flash.
/// Everything is Core Animation, so the window server animates it; the app only fires events.
@MainActor
final class RingLight {
    private let engine: Engine
    private var window: NSWindow?
    private var view: RingLayerView?
    private var bag = Set<AnyCancellable>()
    private var lastLine = -1
    private var lastPulse = 0
    private var hideWork: DispatchWorkItem?

    init(engine: Engine) {
        self.engine = engine
        build()
        engine.$ringVisible.removeDuplicates().sink { [weak self] on in self?.setVisible(on) }.store(in: &bag)
        engine.pulse.$count.sink { [weak self] c in self?.pulse(c) }.store(in: &bag)
        engine.clock.$index.sink { [weak self] i in self?.word(i) }.store(in: &bag)
        // Colours, speed and strength follow the song and the settings.
        engine.objectWillChange.merge(with: engine.prefs.objectWillChange)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in self?.restyle() }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func build() {
        let w = NSWindow(contentRect: screen?.frame ?? .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // Over apps and the menu bar, like a light around the display.
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        let v = RingLayerView(frame: CGRect(origin: .zero, size: w.frame.size))
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        window = w
        view = v
        place()
        restyle()
    }

    private func place() {
        guard let w = window, let s = screen else { return }
        w.setFrame(s.frame, display: false)
        view?.needsRebuild = true
        view?.layoutSubtreeIfNeeded()
    }

    private func setVisible(_ on: Bool) {
        guard let w = window, let v = view else { return }
        NSLog("Wordlight: ring light \(on ? "on" : "off")")
        hideWork?.cancel()
        if on {
            place()
            restyle()
            w.orderFrontRegardless()
            v.fade(in: true)
        } else {
            v.fade(in: false)
            let work = DispatchWorkItem { [weak w, weak v] in w?.orderOut(nil); v?.setRunning(false) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
        }
    }

    private func restyle() {
        let p = engine.palette
        view?.style(highlight: NSColor(p.highlight), lyric: NSColor(p.lyric), secondary: NSColor(p.secondary),
                    speed: engine.mood.speed, strength: engine.prefs.ringStrength)
    }

    private func pulse(_ count: Int) {
        guard count != lastPulse else { return }
        lastPulse = count
        guard engine.ringVisible else { return }
        view?.beat(engine.pulse.strength * (0.5 + engine.prefs.intensity * 0.5))
    }

    private func word(_ i: Int) {
        guard engine.ringVisible, i >= 0, let l = engine.lyrics, i < l.words.count else { return }
        let w = l.words[i]
        if engine.script?.emphasis.contains(i) == true { view?.punch() }
        if w.line != lastLine {
            lastLine = w.line
            // Arabic lines sweep the other way round.
            view?.comet(clockwise: !LyricFonts.isArabic(w.text))
        }
    }
}

final class RingLayerView: NSView {
    private let base = CALayer()          // soft glow, masked to the edge band
    private let colors = CAGradientLayer() // conic colours, slowly circling
    private let comet = CAGradientLayer()  // bright wedge that sweeps once per lyric line
    private let edge = CALayer()          // thin hot inner edge that flares on beats
    private let softMask = CALayer(), edgeMask = CALayer()
    private let corners = CALayer()        // corner pools that flare on beats
    private let cornerMask = CALayer()
    var needsRebuild = true
    private var size = CGSize.zero
    private var speed = 1.0
    private var strength = 0.6
    private var cometSide = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root
        root.opacity = 0
        colors.type = .conic
        colors.startPoint = CGPoint(x: 0.5, y: 0.5)
        colors.endPoint = CGPoint(x: 0.5, y: 0)
        comet.type = .conic
        comet.startPoint = CGPoint(x: 0.5, y: 0.5)
        comet.endPoint = CGPoint(x: 0.5, y: 0)
        comet.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.25).cgColor, NSColor.white.withAlphaComponent(0.95).cgColor, NSColor.clear.cgColor]
        comet.locations = [0, 0.62, 0.88, 0.955, 1]   // long fading tail, bright head
        comet.opacity = 0
        base.addSublayer(colors)
        base.addSublayer(comet)
        base.mask = softMask
        edge.mask = edgeMask
        edge.opacity = 0
        corners.mask = cornerMask
        corners.opacity = 0
        root.addSublayer(base)
        root.addSublayer(corners)
        root.addSublayer(edge)
        for l in [root, base, colors, comet, edge, softMask, edgeMask, corners, cornerMask] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull(), "frame": NSNull(), "opacity": NSNull()]
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard needsRebuild || bounds.size != size, bounds.width > 10 else { return }
        needsRebuild = false
        size = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.frame = bounds
        edge.frame = bounds
        softMask.frame = bounds
        edgeMask.frame = bounds
        softMask.contents = Self.band(size, width: 12, blur: 15, corner: 95)
        edgeMask.contents = Self.band(size, width: 2.5, blur: 2.5, corner: 40)
        corners.frame = bounds
        cornerMask.frame = bounds
        cornerMask.contents = Self.band(size, width: 0, blur: 30, corner: 170)
        // The conic layers are squares big enough to cover the screen while they spin.
        let side = hypot(size.width, size.height)
        for g in [colors, comet] {
            g.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            g.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
        spin()
    }

    /// Alpha image of a band along the screen edges fading inward, with brighter corner pools.
    private static func band(_ size: CGSize, width: CGFloat, blur: CGFloat, corner: CGFloat) -> CGImage? {
        let s: CGFloat = 0.5   // it's all soft light, so half resolution is plenty
        let pw = Int(size.width * s), ph = Int(size.height * s)
        guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: s, y: s)
        let r = CGRect(origin: .zero, size: size)
        c.setFillColor(NSColor.white.cgColor)
        c.fill(r)
        c.setBlendMode(.clear)
        let inner = r.insetBy(dx: width, dy: width)
        c.addPath(CGPath(roundedRect: inner, cornerWidth: 18 + width, cornerHeight: 18 + width, transform: nil))
        c.fillPath()
        c.setBlendMode(.normal)
        // Corner pools: the light gathers where two edges meet.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
            c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: corner, options: [])
        }
        guard let img = c.makeImage() else { return nil }
        let ci = CIImage(cgImage: img)
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * s)).cropped(to: ci.extent)
        return Sprites.shared.createCGImage(out, from: ci.extent)
    }

    func style(highlight: NSColor, lyric: NSColor, secondary: NSColor, speed: Double, strength: Double) {
        let hi = highlight.usingColorSpace(.sRGB) ?? highlight
        // A second accent: the highlight nudged round the colour wheel, so the ring has movement in it.
        let alt = NSColor(hue: (hi.hueComponent + 0.09).truncatingRemainder(dividingBy: 1), saturation: min(1, hi.saturationComponent * 1.1),
                          brightness: max(0.85, hi.brightnessComponent), alpha: 1)
        let deep = (secondary.usingColorSpace(.sRGB) ?? secondary)
        let deepLit = NSColor(hue: deep.hueComponent, saturation: max(0.5, deep.saturationComponent), brightness: 0.75, alpha: 1)
        let cols = [hi, alt, deepLit, alt, hi].map(\.cgColor)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        let fade = CABasicAnimation(keyPath: "colors")
        fade.duration = 1.2
        colors.add(fade, forKey: "fade")
        colors.colors = cols
        edge.backgroundColor = hi.blended(withFraction: 0.3, of: .white)?.cgColor
        corners.backgroundColor = alt.cgColor
        CATransaction.commit()
        if abs(speed - self.speed) > 0.01 { self.speed = speed; spin() }
        if abs(strength - self.strength) > 0.001 {
            self.strength = strength
            if layer?.opacity ?? 0 > 0 { setBaseLevel() }
        }
    }

    private func setBaseLevel() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.opacity = Float(0.25 + strength * 0.6)
        CATransaction.commit()
        // A slow breath, so the light feels alive between beats.
        let b = CABasicAnimation(keyPath: "opacity")
        b.fromValue = 0; b.toValue = -0.18 * Float(0.4 + strength)
        b.isAdditive = true
        b.duration = 2.6 / max(0.5, speed)
        b.autoreverses = true
        b.repeatCount = .infinity
        b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        b.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
        base.add(b, forKey: "breath")
    }

    private func spin() {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -Double.pi * 2
        a.duration = 16 / max(0.4, speed)
        a.repeatCount = .infinity
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 20)   // slow drift: 20 fps is plenty
        colors.add(a, forKey: "spin")
    }

    func setRunning(_ on: Bool) { layer?.speed = on ? 1 : 0 }

    func fade(in on: Bool) {
        guard let root = layer else { return }
        if on { setRunning(true); setBaseLevel() }
        let from = root.presentation()?.opacity ?? root.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.opacity = on ? 1 : 0
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = on ? 1 : 0
        a.duration = on ? 1.1 : 0.8
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(a, forKey: "fade")
        if on { comet(clockwise: true) }
    }

    /// Beat: the hot inner edge flares, and the glow swells a little.
    func beat(_ s: Double) {
        guard s > 0.05 else { return }
        let k = Float(min(1.4, s) * (0.5 + strength * 0.5))
        let f = CAKeyframeAnimation(keyPath: "opacity")
        f.values = [0, 0.85 * k, 0]
        f.keyTimes = [0, 0.1, 1]
        f.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        f.isAdditive = true
        f.duration = 0.55
        f.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        edge.add(f, forKey: "beat\(Int.random(in: 0..<3))")
        let g = CAKeyframeAnimation(keyPath: "opacity")
        g.values = [0, 0.25 * k, 0]
        g.keyTimes = [0, 0.12, 1]
        g.isAdditive = true
        g.duration = 0.6
        base.add(g, forKey: "swell\(Int.random(in: 0..<3))")
        // Strong hits also light the corners.
        if s > 0.5 {
            let c = CAKeyframeAnimation(keyPath: "opacity")
            c.values = [0, 0.7 * k, 0]
            c.keyTimes = [0, 0.12, 1]
            c.isAdditive = true
            c.duration = 0.7
            c.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            corners.add(c, forKey: "corner\(Int.random(in: 0..<3))")
        }
    }

    /// Punch word: everything flashes at once.
    func punch() {
        let f = CAKeyframeAnimation(keyPath: "opacity")
        f.values = [0, 1, 0]
        f.keyTimes = [0, 0.08, 1]
        f.isAdditive = true
        f.duration = 0.7
        edge.add(f, forKey: "punch")
        let g = CAKeyframeAnimation(keyPath: "opacity")
        g.values = [0, 0.3, 0]
        g.keyTimes = [0, 0.1, 1]
        g.isAdditive = true
        g.duration = 0.8
        base.add(g, forKey: "punchGlow")
    }

    /// New lyric line: a comet of light races once around the screen.
    func comet(clockwise: Bool) {
        cometSide.toggle()
        let start = cometSide ? Double.pi : 0   // alternate bottom / top starts
        let dir = clockwise ? -1.0 : 1.0
        let r = CABasicAnimation(keyPath: "transform.rotation.z")
        r.fromValue = start
        r.toValue = start + dir * Double.pi * 2
        r.duration = 1.5
        r.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.25, 1)
        r.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        comet.add(r, forKey: "sweep")
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, Float(0.55 + strength * 0.45), Float(0.4 + strength * 0.3), 0]
        o.keyTimes = [0, 0.12, 0.7, 1]
        o.duration = 1.5
        comet.add(o, forKey: "show")
    }
}
