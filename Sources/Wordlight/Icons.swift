import Foundation

/// A small, curated set of strong lyric words that earn an emoji. Generic words (baby, girl,
/// yeah, say, time, …) are deliberately left out; `Engine.pickEmoji` also limits them to at
/// most one per line, spaced well apart.
enum WordIcons {
    static func icon(for word: String) -> String? {
        if word.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return arabic(word) }
        var w = word.lowercased().filter { $0.isLetter || $0 == "'" }
        if w.hasSuffix("in'") { w = String(w.dropLast(1)) + "g" }
        w = w.replacingOccurrences(of: "'", with: "")
        if let e = english[w] { return e }
        for suffix in ["s", "es", "ing", "ed"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            let stem = String(w.dropLast(suffix.count))
            if let e = english[stem] ?? english[stem + "e"] { return e }
        }
        return nil
    }

    private static let englishGroups: [(String, [String])] = [
        ("❤️", ["love", "heart"]),
        ("💔", ["heartbreak", "heartbroken"]),
        ("🔥", ["fire", "flame", "flames", "burn"]),
        ("💸", ["money", "cash", "racks"]),
        ("💎", ["diamond", "diamonds"]),
        ("👑", ["king", "queen", "crown"]),
        ("🌙", ["moon", "midnight"]),
        ("☀️", ["sun", "sunshine"]),
        ("⭐️", ["star", "stars"]),
        ("🌊", ["ocean", "waves"]),
        ("🌹", ["rose", "roses"]),
        ("💋", ["kiss", "kisses"]),
        ("💧", ["tears", "crying"]),
        ("🌧️", ["rain", "storm"]),
        ("❄️", ["ice", "snow", "frozen"]),
        ("🚗", ["car", "drive", "driving"]),
        ("✈️", ["fly", "plane"]),
        ("🍾", ["champagne"]),
        ("💃", ["dance", "dancing"]),
        ("🎵", ["music", "song", "melody"]),
        ("🌍", ["world"]),
        ("👻", ["ghost"]),
        ("🦋", ["butterflies", "butterfly"]),
        ("🌈", ["rainbow"]),
        ("⚡️", ["lightning", "electric"]),
        ("🖤", ["darkness"]),
        ("💍", ["ring", "wedding"]),
        ("🚀", ["rocket"]),
    ]
    private static let english: [String: String] = {
        var m: [String: String] = [:]
        for (e, ws) in englishGroups { for w in ws { m[w] = e } }
        return m
    }()

    // MARK: Arabic

    private static let arabicGroups: [(String, [String])] = [
        ("❤️", ["حب", "قلب", "غرام", "عشق", "هوي"]),
        ("💔", ["جرح", "مجروح", "مكسور", "فراق"]),
        ("🔥", ["نار", "ولعه", "ولع"]),
        ("💸", ["فلوس", "مال"]),
        ("💎", ["الماس", "دهب"]),
        ("👑", ["ملك", "ملكه", "تاج"]),
        ("🌙", ["قمر"]),
        ("☀️", ["شمس"]),
        ("⭐️", ["نجم", "نجوم", "نجمه"]),
        ("🌊", ["بحر", "موج"]),
        ("🌹", ["ورد", "ورده"]),
        ("💋", ["بوسه"]),
        ("💧", ["دموع", "دمعه", "بكا"]),
        ("🌧️", ["مطر", "شتا"]),
        ("🚗", ["عربيه"]),
        ("✈️", ["طياره"]),
        ("💃", ["رقص", "ارقص"]),
        ("🎵", ["مزيكا", "غنا", "اغنيه"]),
        ("🌍", ["دنيا"]),
        ("⛓️", ["سجن", "مسجون"]),
        ("📱", ["موبايل", "تليفون"]),
        ("🦁", ["اسد"]),
    ]
    private static let arabicMap: [String: String] = {
        var m: [String: String] = [:]
        for (e, ws) in arabicGroups { for w in ws { m[normalize(w)] = e } }
        return m
    }()

    /// Arabic spelling normalisation: drop diacritics/tatweel, unify alef, ta marbuta, ya.
    private static func normalize(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue          // harakat, tatweel
            case 0x0622, 0x0623, 0x0625: out.unicodeScalars.append("\u{0627}")  // آ أ إ → ا
            case 0x0629: out.unicodeScalars.append("\u{0647}")      // ة → ه
            case 0x0649: out.unicodeScalars.append("\u{064A}")      // ى → ي
            default:
                if CharacterSet.letters.contains(u) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    private static func arabic(_ word: String) -> String? {
        let w = normalize(word)
        if let e = arabicMap[w] { return e }
        // Strip common prefixes (و ب ف ل ال) and possessive suffixes (ي ك ه ها نا هم).
        let prefixes = ["وال", "بال", "فال", "لل", "ال", "و", "ب", "ف", "ل"]
        let suffixes = ["كم", "هم", "ها", "نا", "ك", "ي", "ه"]
        var stems = [w]
        for p in prefixes where w.hasPrefix(p) && w.count > p.count + 1 { stems.append(String(w.dropFirst(p.count))) }
        for s in stems { for x in suffixes where s.hasSuffix(x) && s.count > x.count + 1 { stems.append(String(s.dropLast(x.count))) } }
        for s in stems { if let e = arabicMap[s] { return e } }
        return nil
    }
}
