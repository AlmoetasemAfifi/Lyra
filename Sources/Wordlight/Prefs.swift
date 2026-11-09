import AppKit
import SwiftUI

enum DisplayStyle: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case director = "Director"
    case glow = "Glow"
    case spotlight = "Spotlight"
    case focus = "Focus"
    case depth = "Depth"
    case marker = "Marker"
    case ribbon = "Ribbon"
    case constellation = "Constellation"
    case motion = "Motion"
    case neon = "Neon"
    case poster = "Poster"
    case brush = "Brush"
    case lens = "Lens"
    var id: String { rawValue }
    static var allCases: [DisplayStyle] { [.auto, .glow, .spotlight, .focus, .depth, .marker, .ribbon, .constellation, .motion, .neon, .poster, .brush, .lens] }
    var blurb: String {
        switch self {
        case .auto: return "Each song is analysed and directed: every section (intro, verse, chorus…) gets its own animation."
        case .director: return "Like a lyric-video edit: intro, verses and chorus each get their own treatment, with punch words flashing."
        case .glow: return "Like Apple Music: lines glide by, each word fills with a soft glow and floats up; nearby lines melt into soft focus."
        case .spotlight: return "Cinematic and centred: one big glowing line, the others shrink away into a soft blur."
        case .focus: return "Every word pulls into focus out of a soft blur; finished lines blur away."
        case .depth: return "Lines float in 3D: the next ones wait far away, the sung line is sharp up front, finished lines fly past you."
        case .marker: return "A glowing marker glides behind each word as it's sung, like a highlighter following the singer."
        case .ribbon: return "One endless ribbon of words flowing past a fixed reading point, right to left for Arabic."
        case .constellation: return "Every sung word becomes a star, linked to the one before; repeated words link back and grow."
        case .motion: return "Words streak in with real motion blur and land sharp."
        case .neon: return "Bloom-lit neon tubes that flicker on, with a reflection below."
        case .poster: return "One poster-size glowing word at a time, cut to the beat, with flashes on punch words."
        case .brush: return "Hand-painted words land and stack into a tilted block."
        case .lens: return "A fisheye column of words — the one being sung magnified up front."
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case bold = "Bold", rounded = "Rounded", serif = "Serif", mono = "Mono"
    var id: String { rawValue }
    func font(_ size: CGFloat) -> Font {
        switch self {
        case .bold: return .system(size: size, weight: .black, design: .default)
        case .rounded: return .system(size: size, weight: .heavy, design: .rounded)
        case .serif: return .system(size: size, weight: .bold, design: .serif)
        case .mono: return .system(size: size, weight: .bold, design: .monospaced)
        }
    }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var style: DisplayStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var font: FontChoice { didSet { d.set(font.rawValue, forKey: "font") } }
    @Published var englishFont: EnglishFont { didSet { d.set(englishFont.rawValue, forKey: "englishFont") } }
    @Published var arabicFont: ArabicFont { didSet { d.set(arabicFont.rawValue, forKey: "arabicFont") } }
    @Published var icons: Bool { didSet { d.set(icons, forKey: "icons") } }
    @Published var autoColors: Bool { didSet { d.set(autoColors, forKey: "autoColors") } }
    @Published var lyricHex: String { didSet { d.set(lyricHex, forKey: "lyricHex") } }
    @Published var highlightHex: String { didSet { d.set(highlightHex, forKey: "highlightHex") } }
    @Published var secondaryHex: String { didSet { d.set(secondaryHex, forKey: "secondaryHex") } }
    @Published var textSize: Double { didSet { d.set(textSize, forKey: "textSize") } }
    @Published var verticalPosition: Double { didSet { d.set(verticalPosition, forKey: "verticalPosition") } }
    @Published var syncOffset: Double { didSet { d.set(syncOffset, forKey: "syncOffset") } }
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake") } }
    /// Per-song lyric timing fixes (seconds, + = lyrics show earlier), remembered by track.
    @Published var trackOffsets: [String: Double] { didSet { d.set(trackOffsets, forKey: "trackOffsets") } }
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }

    // Live wallpaper
    @Published var desktopWallpaper: Bool { didSet { d.set(desktopWallpaper, forKey: "desktopWallpaper") } }
    @Published var lockWallpaper: Bool { didSet { d.set(lockWallpaper, forKey: "lockWallpaper") } }
    @Published var desktopLyrics: Bool { didSet { d.set(desktopLyrics, forKey: "desktopLyrics") } }
    @Published var nowPlayingCard: Bool { didSet { d.set(nowPlayingCard, forKey: "nowPlayingCard") } }
    @Published var lockClock: Bool { didSet { d.set(lockClock, forKey: "lockClock") } }
    @Published var motion: MotionStyle { didSet { d.set(motion.rawValue, forKey: "motion") } }
    @Published var intensity: Double { didSet { d.set(intensity, forKey: "intensity") } }
    @Published var dim: Double { didSet { d.set(dim, forKey: "dim") } }
    @Published var audioReactive: Bool { didSet { d.set(audioReactive, forKey: "audioReactive") } }
    @Published var extraSmooth: Bool { didSet { d.set(extraSmooth, forKey: "extraSmooth") } }
    // Ring light: a glow around the screen edges that follows the music
    @Published var ringLight: Bool { didSet { d.set(ringLight, forKey: "ringLight") } }
    @Published var ringStrength: Double { didSet { d.set(ringStrength, forKey: "ringStrength") } }

    init() {
        style = DisplayStyle(rawValue: d.string(forKey: "style") ?? "") ?? .auto
        font = FontChoice(rawValue: d.string(forKey: "font") ?? "") ?? .bold
        englishFont = EnglishFont(rawValue: d.string(forKey: "englishFont") ?? "") ?? .auto
        arabicFont = ArabicFont(rawValue: d.string(forKey: "arabicFont") ?? "") ?? .auto
        icons = d.object(forKey: "icons") as? Bool ?? true
        autoColors = d.object(forKey: "autoColors") as? Bool ?? true
        lyricHex = d.string(forKey: "lyricHex") ?? "#F4E3C8"
        highlightHex = d.string(forKey: "highlightHex") ?? "#F59A23"
        secondaryHex = d.string(forKey: "secondaryHex") ?? "#2A1606"
        textSize = d.object(forKey: "textSize") as? Double ?? 1.0
        verticalPosition = d.object(forKey: "verticalPosition") as? Double ?? 0.5
        syncOffset = d.object(forKey: "syncOffset") as? Double ?? 0.0
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        trackOffsets = d.dictionary(forKey: "trackOffsets") as? [String: Double] ?? [:]
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        desktopWallpaper = d.object(forKey: "desktopWallpaper") as? Bool ?? true
        lockWallpaper = d.object(forKey: "lockWallpaper") as? Bool ?? true
        desktopLyrics = d.object(forKey: "desktopLyrics") as? Bool ?? true
        nowPlayingCard = d.object(forKey: "nowPlayingCard") as? Bool ?? true
        lockClock = d.object(forKey: "lockClock") as? Bool ?? true
        motion = MotionStyle(rawValue: d.string(forKey: "motion") ?? "") ?? .auto
        intensity = d.object(forKey: "intensity") as? Double ?? 1.0
        dim = d.object(forKey: "dim") as? Double ?? 0.22
        audioReactive = d.object(forKey: "audioReactive") as? Bool ?? true
        extraSmooth = d.object(forKey: "extraSmooth") as? Bool ?? false
        ringLight = d.object(forKey: "ringLight") as? Bool ?? true
        ringStrength = d.object(forKey: "ringStrength") as? Double ?? 0.6
    }

    func binding(_ kp: ReferenceWritableKeyPath<Prefs, String>) -> Binding<Color> {
        Binding(get: { Color(hex: self[keyPath: kp]) },
                set: { self[keyPath: kp] = $0.hexString })
    }
}

struct Palette: Equatable {
    var lyric: Color
    var highlight: Color
    var secondary: Color
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

enum ArtworkPalette {
    /// Picks the most prominent vivid colour from album art and derives three lyric colours from it.
    static func extract(from image: NSImage) -> Palette? {
        let side = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let bins = 18
        var weight = [Double](repeating: 0, count: bins)
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var avg = (0.0, 0.0, 0.0)
        for i in 0..<(side * side) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            avg.0 += r; avg.1 += g; avg.2 += b
            let ns = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let (h, s, v) = (ns.hueComponent, ns.saturationComponent, ns.brightnessComponent)
            guard s > 0.28, v > 0.3 else { continue }
            let bin = min(bins - 1, Int(h * Double(bins)))
            let w = s * v * v
            weight[bin] += w
            sum[bin].0 += r * w; sum[bin].1 += g * w; sum[bin].2 += b * w
        }
        let n = Double(side * side)
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 4 else {
            // Greyscale artwork: neutral palette.
            let l = min(1, (avg.0 + avg.1 + avg.2) / (3 * n) + 0.5)
            return Palette(lyric: Color(white: 0.95), highlight: Color(white: max(0.75, l)), secondary: Color(white: 0.1))
        }
        let w = weight[best]
        var accent = NSColor(srgbRed: sum[best].0 / w, green: sum[best].1 / w, blue: sum[best].2 / w, alpha: 1)
        // Make the accent bright enough to glow on a dark lock screen.
        accent = NSColor(hue: accent.hueComponent, saturation: min(1, max(0.55, accent.saturationComponent)),
                         brightness: max(0.88, accent.brightnessComponent), alpha: 1)
        let lyric = accent.blended(withFraction: 0.72, of: NSColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1)) ?? .white
        let secondary = NSColor(hue: accent.hueComponent, saturation: 0.85, brightness: 0.16, alpha: 1)
        return Palette(lyric: Color(nsColor: lyric), highlight: Color(nsColor: accent), secondary: Color(nsColor: secondary))
    }
}
