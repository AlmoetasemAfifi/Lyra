import AppKit
import SwiftUI

/// Lyric fonts. English and Arabic are chosen separately; a mixed line shows each script
/// in its own font (the Arabic font is attached as a cascade/fallback to the English one).
enum EnglishFont: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case system = "SF Black"
    case rounded = "SF Rounded"
    case serif = "New York"
    case avenir = "Avenir Next Heavy"
    case futura = "Futura Condensed"
    case impact = "Impact"
    case didot = "Didot"
    case bodoni = "Bodoni"
    case rockwell = "Rockwell"
    case gill = "Gill Sans UltraBold"
    case typewriter = "Typewriter"
    case marker = "Marker"
    case chalk = "Chalk"
    case script = "Script"
    var id: String { rawValue }

    func font(_ size: CGFloat) -> NSFont {
        func named(_ n: String) -> NSFont { NSFont(name: n, size: size) ?? .systemFont(ofSize: size, weight: .black) }
        func design(_ d: NSFontDescriptor.SystemDesign, _ w: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: w)
            return base.fontDescriptor.withDesign(d).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        switch self {
        case .auto, .system: return .systemFont(ofSize: size, weight: .black)
        case .rounded: return design(.rounded, .heavy)
        case .serif: return design(.serif, .bold)
        case .avenir: return named("AvenirNext-Heavy")
        case .futura: return named("Futura-CondensedExtraBold")
        case .impact: return named("Impact")
        case .didot: return named("Didot-Bold")
        case .bodoni: return named("BodoniSvtyTwoITCTT-Bold")
        case .rockwell: return named("Rockwell-Bold")
        case .gill: return named("GillSans-UltraBold")
        case .typewriter: return named("AmericanTypewriter-Bold")
        case .marker: return named("MarkerFelt-Wide")
        case .chalk: return named("Chalkduster")
        case .script: return named("SnellRoundhand-Black")
        }
    }
}

enum ArabicFont: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case geeza = "Geeza Pro"
    case muna = "Muna Black"
    case nile = "Al Nile"
    case damascus = "Damascus"
    case bayan = "Al Bayan"
    case kufi = "Diwan Kufi"
    case thuluth = "Diwan Thuluth"
    case naskh = "DecoType Naskh"
    case farisi = "Farisi"
    case mishafi = "Mishafi"
    case baghdad = "Baghdad"
    case beirut = "Beirut"
    case waseem = "Waseem"
    case farah = "Farah (brush)"
    case sana = "Sana (brush)"
    var id: String { rawValue }

    /// Calligraphic faces draw small for their point size; geometric Kufi draws large.
    /// This evens out how big each font *looks*.
    var sizeScale: CGFloat {
        switch self {
        case .thuluth: return 1.4
        case .naskh, .farisi: return 1.3
        case .mishafi, .nile: return 1.12
        case .kufi: return 0.78
        case .muna, .baghdad: return 1.05
        case .farah: return 1.18
        case .sana: return 1.1
        default: return 1
        }
    }

    var postScriptName: String {
        switch self {
        case .auto, .geeza: return "GeezaPro-Bold"
        case .muna: return "MunaBlack"
        case .nile: return "AlNile-Bold"
        case .damascus: return "DamascusBold"
        case .bayan: return "AlBayan-Bold"
        case .kufi: return "DiwanKufi"
        case .thuluth: return "DiwanThuluth"
        case .naskh: return "DecoTypeNaskh"
        case .farisi: return "Farisi"
        case .mishafi: return "DiwanMishafi"
        case .baghdad: return "Baghdad"
        case .beirut: return "Beirut"
        case .waseem: return "Waseem"
        case .farah: return "Farah"
        case .sana: return "Sana"
        }
    }
}

enum LyricFonts {
    private static var cache: [String: NSFont] = [:]

    /// Right-to-left paragraph style, so brackets and punctuation in Arabic words land on the correct side.
    static let rtlStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .rightToLeft
        return p
    }()

    static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) || (0xFB50...0xFDFF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value) }
    }

    /// The right font for one word: the Arabic font for Arabic script, the English font otherwise.
    static func font(for text: String, english: EnglishFont, arabic: ArabicFont, size: CGFloat) -> NSFont {
        if isArabic(text) {
            let key = "ar|\(arabic.rawValue)|\(Int(size * 10))"
            if let f = cache[key] { return f }
            let sz = size * arabic.sizeScale
            let f = NSFont(name: arabic.postScriptName, size: sz) ?? NSFont(name: "GeezaPro-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
            cache[key] = f
            return f
        }
        return font(english: english, arabic: arabic, size: size)
    }

    /// English font with the Arabic font cascaded behind it for Arabic glyphs.
    static func font(english: EnglishFont, arabic: ArabicFont, size: CGFloat) -> NSFont {
        let key = "\(english.rawValue)|\(arabic.rawValue)|\(Int(size * 10))"
        if let f = cache[key] { return f }
        let latin = english.font(size)
        var result = latin
        if let ar = NSFont(name: arabic.postScriptName, size: size) ?? NSFont(name: "GeezaPro-Bold", size: size) {
            let desc = latin.fontDescriptor.addingAttributes([.cascadeList: [ar.fontDescriptor]])
            result = NSFont(descriptor: desc, size: size) ?? latin
        }
        cache[key] = result
        return result
    }
}
