import AppKit
import CoreImage
import CoreVideo
import IOSurface
import CoreText
import QuartzCore
import os

// MARK: - Sprites: words pre-rendered to images
//
// Every animated word is drawn ONCE into a bitmap with its whole look baked in — glow/bloom,
// metallic gradient, outline, drop shadow, brush texture — plus optional blurred and
// motion-blurred copies. Animating is then just moving/fading images, which the window server
// does for free: no live shadows, no live blur filters, no text re-rendering per frame.

struct SpriteLook: Hashable {
    enum Fill: Hashable {
        case solid(UInt32)                  // RGBA
        case metal(UInt32)                  // brushed metal around a base colour
        case gradient(UInt32, UInt32)       // top → bottom
    }
    var fill: Fill
    var glow: CGFloat = 0                   // glow radius × font size
    var glowColor: UInt32 = 0xFFFFFFFF
    var bloom = false                       // add a second, wide soft halo (neon / poster)
    var stroke: CGFloat = 0                 // % of font size: < 0 thickens the letters, > 0 outline only
    var shadow = false                      // soft drop shadow for legibility over bright art
    var distress = false                    // hand-painted chips and dry-brush gaps
    var blur: CGFloat = 0                   // gaussian blur radius × font size (depth / focus copies)
    var motion: CGFloat = 0                 // horizontal motion-blur length × font size

    static func solid(_ c: NSColor) -> SpriteLook { SpriteLook(fill: .solid(c.rgba)) }
}

extension NSColor {
    var rgba: UInt32 {
        let c = usingColorSpace(.sRGB) ?? .white
        let r = UInt32(max(0, min(255, c.redComponent * 255))), g = UInt32(max(0, min(255, c.greenComponent * 255)))
        let b = UInt32(max(0, min(255, c.blueComponent * 255))), a = UInt32(max(0, min(255, c.alphaComponent * 255)))
        return r << 24 | g << 16 | b << 8 | a
    }
    convenience init(rgba v: UInt32) {
        self.init(srgbRed: CGFloat(v >> 24 & 255) / 255, green: CGFloat(v >> 16 & 255) / 255,
                  blue: CGFloat(v >> 8 & 255) / 255, alpha: CGFloat(v & 255) / 255)
    }
}

/// A baked word: the image plus where the text sits inside it (images carry padding for glow).
final class Sprite {
    let image: CGImage?
    /// GPU-resident copy for effect sprites: Core Animation shows it directly, with no copy back to
    /// main memory and no upload again (the slow part of baking glowing words).
    let surface: IOSurface?
    let size: CGSize        // points (image size / scale)
    let text: CGSize        // the typographic box of the text, centred in the image
    init(image: CGImage, size: CGSize, text: CGSize) { self.image = image; surface = nil; self.size = size; self.text = text }
    init(surface: IOSurface, size: CGSize, text: CGSize) { image = nil; self.surface = surface; self.size = size; self.text = text }
    var contents: Any? { surface ?? image }
    var pixelWidth: Int { surface?.width ?? image?.width ?? 1 }
    var bytes: Int { surface.map { $0.bytesPerRow * $0.height } ?? image.map { $0.bytesPerRow * $0.height } ?? 0 }
    var ciImage: CIImage? { surface.map { CIImage(ioSurface: $0) } ?? image.map { CIImage(cgImage: $0) } }
}

enum Sprites {
    private struct Key: Hashable {
        var text: String, font: String, size: Int, scale: Int, look: SpriteLook
    }
    private final class Box: NSObject { let s: Sprite; init(_ s: Sprite) { self.s = s } }
    private final class KeyBox: NSObject {
        let k: Key
        init(_ k: Key) { self.k = k }
        override var hash: Int { k.hashValue }
        override func isEqual(_ o: Any?) -> Bool { (o as? KeyBox)?.k == k }
    }
    private static let cache: NSCache<KeyBox, Box> = {
        let c = NSCache<KeyBox, Box>()
        c.totalCostLimit = 96 * 1024 * 1024        // ~96 MB of bitmaps, oldest evicted first (~3 songs' worth)
        return c
    }()
    /// Shared Core Image context for one-off images (wallpaper covers, ring masks); no intermediate caching.
    static let shared = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private static let ci = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    /// Effects composite in gamma sRGB, like CoreGraphics, so glows and shadows fall off the same way they always have.
    private static let fx = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false,
                                                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                .workingFormat: CIFormat.RGBA8])
    static let debugBakes = ProcessInfo.processInfo.environment["WL_DEBUG_BAKES"] != nil
    static let bakeLog = OSAllocatedUnfairLock(initialState: [String]())
    private static let queue = DispatchQueue(label: "wordlight.sprites", qos: .utility)

    /// Get (or bake) a sprite. Safe from any thread.
    static func get(_ text: String, font: NSFont, look: SpriteLook, scale: CGFloat) -> Sprite {
        let key = Key(text: text, font: font.fontName, size: Int(font.pointSize * 4), scale: Int(scale * 10), look: look)
        if let hit = cache.object(forKey: KeyBox(key)) { return hit.s }
        let s: Sprite
        if look.blur > 0 || look.motion > 0 {
            var sharpLook = look; sharpLook.blur = 0; sharpLook.motion = 0
            s = blurred(get(text, font: font, look: sharpLook, scale: scale), look: look, fontSize: font.pointSize, scale: scale)
        } else {
            s = render(text, font: font, look: look, scale: scale)
        }
        cache.setObject(Box(s), forKey: KeyBox(key), cost: s.bytes)
        if debugBakes { bakeLog.withLock { $0.append("\(Date().timeIntervalSince1970) \(text) \(look.motion > 0 ? "streak" : look.blur > 0 ? "soft" : "sharp") \(Int(font.pointSize))") } }
        return s
    }

    /// Bake ahead of time on a background thread so they're ready before they're needed.
    static func prefetch(_ items: [(String, NSFont, SpriteLook)], scale: CGFloat) {
        queue.async {
            for (t, f, l) in items { _ = get(t, font: f, look: l, scale: scale) }
            // Let Core Image drop its scratch buffers after each batch instead of holding ~180 MB.
            fx.clearCaches(); ci.clearCaches()
        }
    }

    // MARK: Rendering

    private static func render(_ text: String, font: NSFont, look: SpriteLook, scale: CGFloat) -> Sprite {
        let size = font.pointSize
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if LyricFonts.isArabic(text) { attrs[.paragraphStyle] = LyricFonts.rtlStyle }
        let baseColor: NSColor
        switch look.fill {
        case .solid(let c): baseColor = NSColor(rgba: c)
        case .metal(let c): baseColor = NSColor(rgba: c).blended(withFraction: 0.35, of: .black) ?? NSColor(rgba: c)
        case .gradient(let a, _): baseColor = NSColor(rgba: a)
        }
        attrs[.foregroundColor] = baseColor
        if look.stroke != 0 { attrs[.strokeWidth] = look.stroke; attrs[.strokeColor] = baseColor }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        let ink = CTLineGetImageBounds(line, nil)
        let textH = asc + desc
        let pad = size * (0.14 + look.glow * (look.bloom ? 3.2 : 2.2) + abs(look.stroke) * 0.02) + (look.shadow ? size * 0.12 : 0)
        let minX = min(0, ink.minX), maxX = max(width, ink.maxX)
        let wPts = ceil(maxX - minX + pad * 2), hPts = ceil(max(textH, ink.height) + pad * 2)
        let pw = Int(wPts * scale), ph = Int(hPts * scale)
        guard let c = CGContext(data: nil, width: max(1, pw), height: max(1, ph), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return Sprite(image: blank, size: CGSize(width: 1, height: 1), text: .zero) }
        c.scaleBy(x: scale, y: scale)
        c.setShouldAntialias(true)
        c.setAllowsFontSmoothing(true)
        // Baseline so the typographic box is centred vertically.
        let origin = CGPoint(x: pad - minX + (wPts - pad * 2 - (maxX - minX)) / 2, y: (hPts - textH) / 2 + desc)
        func drawText() { c.textPosition = origin; CTLineDraw(line, c) }

        // 3. Fill.
        switch look.fill {
        case .solid:
            drawText()
        case .metal(let base), .gradient(let base, _):
            // Clip to the letter shapes and paint a gradient through them.
            // Mask from the very same layout, drawn white into a grey image, so it lines up exactly.
            var mAttrs = attrs; mAttrs[.foregroundColor] = NSColor.white; mAttrs[.strokeColor] = NSColor.white
            let maskLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: mAttrs))
            guard let mask = shapeMask(maskLine, origin: origin, pw: pw, ph: ph, scale: scale) else { drawText(); break }
            c.saveGState()
            c.clip(to: CGRect(x: 0, y: 0, width: wPts, height: hPts), mask: mask)
            let colors: [CGColor]
            let stops: [CGFloat]
            if case .gradient(let a, let b) = look.fill {
                colors = [NSColor(rgba: a).cgColor, NSColor(rgba: b).cgColor]; stops = [0, 1]
            } else {
                let b = NSColor(rgba: base)
                let light = b.blended(withFraction: 0.72, of: .white) ?? b
                let dark = b.blended(withFraction: 0.45, of: .black) ?? b
                let mid = b.blended(withFraction: 0.15, of: .white) ?? b
                // Bright top, a sharp horizon line, darker belly, warm bounce light at the bottom.
                colors = [light.cgColor, mid.cgColor, dark.cgColor, b.cgColor, light.withAlphaComponent(0.9).cgColor]
                stops = [0, 0.42, 0.52, 0.82, 1]
            }
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: stops)!
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: origin.y + asc), end: CGPoint(x: 0, y: origin.y - desc), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
        }
        guard let textImg = c.makeImage() else { return Sprite(image: blank, size: CGSize(width: 1, height: 1), text: .zero) }
        let spriteSize = CGSize(width: wPts, height: hPts), textBox = CGSize(width: width, height: textH)
        let effects = look.shadow || look.glow > 0 || look.distress
        guard effects else { return Sprite(image: textImg, size: spriteSize, text: textBox) }

        // Effects are composited on the GPU with Core Image in one pass (CoreGraphics shadows and
        // image draws blur and resample on the CPU, which got very slow at poster sizes).
        let textCI = CIImage(cgImage: textImg)
        let extent = textCI.extent
        func tinted(_ color: NSColor) -> CIImage {
            let col = color.usingColorSpace(.sRGB) ?? color
            return textCI.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: col.alphaComponent),
                "inputBiasVector": CIVector(x: col.redComponent, y: col.greenComponent, z: col.blueComponent, w: 0)])
        }
        // Radii/offsets are in pixels, exactly like the CoreGraphics shadows this replaces (CG shadows ignore the CTM).
        func blur(_ img: CIImage, _ radius: CGFloat) -> CIImage {
            let sigma = radius * 0.5
            // Wide blurs are computed on a quarter-size copy and scaled back up: same look, ~16x less work.
            guard sigma > 6 else { return img.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent) }
            let k: CGFloat = 0.25
            let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let b = small.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma * k)).cropped(to: small.extent)
            return b.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)).cropped(to: extent)
        }
        func fade(_ img: CIImage, _ alpha: CGFloat) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
        }
        var out = CIImage.empty().cropped(to: extent)
        // 1. Drop shadow (legibility).
        if look.shadow {
            out = blur(tinted(NSColor.black.withAlphaComponent(0.55)), size * 0.22)
                .transformed(by: CGAffineTransform(translationX: 0, y: -size * 0.04)).cropped(to: extent)
        }
        // 2. Glow: a wide bloom pass, then a tight one (twice, for a hot core).
        if look.glow > 0 {
            let g = tinted(NSColor(rgba: look.glowColor))
            if look.bloom { out = fade(blur(g, size * look.glow * 2.6), 0.85).composited(over: out) }
            let tight = blur(g, size * look.glow)
            out = tight.composited(over: tight.composited(over: out))
        }
        // 3. The paint itself.
        out = textCI.composited(over: out)
        // 4. Brush texture: punch chips and dry-brush gaps out of everything.
        if look.distress, let chips = Textures.chips {
            let seed = CGFloat(abs(text.hashValue % 97)) / 97
            let r = CGRect(x: -seed * 120, y: -seed * 40, width: max(wPts, 512) + 120, height: max(hPts, 256) + 40)
            let chipCI = (chipsOnGPU ?? CIImage(cgImage: chips)).transformed(by: CGAffineTransform(
                a: r.width * scale / CGFloat(chips.width), b: 0, c: 0, d: r.height * scale / CGFloat(chips.height),
                tx: r.minX * scale, ty: r.minY * scale))
            out = out.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: chipCI])
        }
        if let surf = gpuRender(out.cropped(to: extent), extent) { return Sprite(surface: surf, size: spriteSize, text: textBox) }
        guard let img = fx.createCGImage(out.cropped(to: extent), from: extent, format: .BGRA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            return Sprite(image: textImg, size: spriteSize, text: textBox)
        }
        return Sprite(image: img, size: spriteSize, text: textBox)
    }

    private static func shapeMask(_ line: CTLine, origin: CGPoint, pw: Int, ph: Int, scale: CGFloat) -> CGImage? {
        guard let m = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        m.setFillColor(gray: 0, alpha: 1)
        m.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        m.scaleBy(x: scale, y: scale)
        m.textPosition = origin
        CTLineDraw(line, m)
        return m.makeImage()
    }

    /// The brush-chip texture, uploaded to the GPU once (instead of once per word).
    private static let chipsOnGPU: CIImage? = {
        guard !cpuImages, let chips = Textures.chips else { return nil }
        let src = CIImage(cgImage: chips)
        guard let surf = gpuRender(src, src.extent) else { return nil }
        return CIImage(ioSurface: surf)
    }()

    /// Film/snapshot tools render layers on the CPU, which can't read IOSurfaces: they get CGImages.
    private static let cpuImages = ProcessInfo.processInfo.arguments.contains { $0 == "--film" || $0 == "--snapshot" || $0 == "--transition" }

    /// Render straight into a GPU surface that Core Animation can display as-is.
    private static func gpuRender(_ image: CIImage, _ rect: CGRect) -> IOSurface? {
        guard !cpuImages else { return nil }
        let w = Int(rect.width.rounded(.up)), h = Int(rect.height.rounded(.up))
        guard w > 0, h > 0, let surf = IOSurface(properties: [
            .width: w, .height: h, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        let dest = CIRenderDestination(ioSurface: surf)
        dest.isFlipped = true
        dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let moved = image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        do { try fx.startTask(toRender: moved, to: dest).waitUntilCompleted() } catch { return nil }
        return surf
    }

    private static func blurred(_ s: Sprite, look: SpriteLook, fontSize: CGFloat, scale: CGFloat) -> Sprite {
        guard let input = s.ciImage else { return s }
        // Soft/streaked copies don't need full detail: work at half size (or less) and scale up.
        let k: CGFloat = (look.motion > 0 || look.blur * fontSize * scale * 0.5 > 8) ? 0.5 : 1
        let work = k < 1 ? input.transformed(by: CGAffineTransform(scaleX: k, y: k)) : input
        var out = work.clampedToExtent()
        if look.blur > 0 {
            out = out.applyingGaussianBlur(sigma: Double(look.blur * fontSize * scale * 0.5 * k))
        }
        if look.motion > 0, let f = CIFilter(name: "CIMotionBlur") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(look.motion * fontSize * scale * k, forKey: kCIInputRadiusKey)
            f.setValue(0, forKey: kCIInputAngleKey)
            out = f.outputImage ?? out
        }
        // Grow the canvas so the blur isn't clipped.
        let grow = (look.blur * 2 + look.motion * 1.2) * fontSize * scale
        let ext = input.extent.insetBy(dx: -grow, dy: -grow * (look.motion > 0 && look.blur == 0 ? 0.1 : 1))
        // Stays at the reduced size: the layer scales it up on the GPU (contentsScale follows the image).
        let ext2 = CGRect(x: ext.minX * k, y: ext.minY * k, width: ext.width * k, height: ext.height * k).integral
        let premasked = out.cropped(to: ext2)
        // Clamp-to-extent smears edge pixels outward; sprites have transparent padding so that's fine.
        if let surf = gpuRender(premasked, ext2) { return Sprite(surface: surf, size: CGSize(width: ext.width / scale, height: ext.height / scale), text: s.text) }
        guard let img = fx.createCGImage(premasked, from: ext2, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return s }
        return Sprite(image: img, size: CGSize(width: ext.width / scale, height: ext.height / scale), text: s.text)
    }

    private static let blank: CGImage = {
        let c = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return c.makeImage()!
    }()
}

extension Textures {
    /// Opaque chips/streaks on transparent, punched out of painted letters (destination-out).
    static let chips: CGImage? = {
        let w = 640, h = 320
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var s: UInt64 = 23
        func r() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(UInt32.max >> 1) }
        c.setFillColor(NSColor.black.cgColor)
        for _ in 0..<340 {
            let d = 0.6 + pow(r(), 3) * 6
            c.fillEllipse(in: CGRect(x: r() * CGFloat(w), y: r() * CGFloat(h), width: d, height: d * (0.4 + r())))
        }
        for _ in 0..<16 { c.fill(CGRect(x: r() * CGFloat(w), y: r() * CGFloat(h), width: 12 + r() * 80, height: 0.5 + r() * 1.3)) }
        return c.makeImage()
    }()
}

// MARK: - Using sprites in scenes

extension SceneContext {
    func sprite(_ text: String, size: CGFloat, look: SpriteLook, scale s: CGFloat? = nil) -> Sprite {
        Sprites.get(text, font: font(text, size), look: look, scale: s ?? scale)
    }

    /// A layer showing a sprite, centred on its text.
    func spriteLayer(_ s: Sprite) -> CALayer {
        let l = CALayer()
        quiet(l)
        l.contents = s.contents
        l.contentsScale = s.size.width > 0 ? CGFloat(s.pixelWidth) / s.size.width : scale
        l.contentsGravity = .resize
        l.bounds = CGRect(origin: .zero, size: s.size)
        return l
    }

    /// Start baking these words' sprites in the background (call a line or two ahead).
    /// Bake exact (text, size, look) sprites in the background.
    func prefetch(exact items: [(String, CGFloat, SpriteLook)], scale s: CGFloat? = nil) {
        Sprites.prefetch(items.map { ($0.0, font($0.0, $0.1), $0.2) }, scale: s ?? scale)
    }

    func prefetch(_ indices: [Int], size: CGFloat, looks: [SpriteLook]) {
        var items: [(String, NSFont, SpriteLook)] = []
        for i in indices where i >= 0 && i < lyrics.words.count {
            let t = lyrics.words[i].text
            let f = font(t, size)
            for l in looks { items.append((t, f, l)) }
        }
        Sprites.prefetch(items, scale: scale)
    }
}
