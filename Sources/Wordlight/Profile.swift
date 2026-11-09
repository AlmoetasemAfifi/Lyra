import Foundation

/// What kind of song this is, worked out from its genre (Apple's catalogue), tempo
/// (words sung per second), line length, language and how precise its lyric timing is.
/// "Auto" uses it to choose the lyric style, background motion, fonts and emoji, by rules,
/// not at random, so the same song always gets the same, fitting look.
struct SongProfile: Equatable {
    enum Kind: String {
        case rap = "rap / hip-hop"
        case dance = "dance / electronic"
        case pop = "pop"
        case rock = "rock"
        case rnb = "R&B / soul"
        case ballad = "slow / acoustic"
        case mahraganat = "mahraganat / shaabi"
        case arabicPop = "Arabic pop"
        case tarab = "tarab / classic Arabic"
        case other = "song"
    }

    var kind: Kind = .other
    var tempo: Double = 1          // words per second ÷ 1.6 (≈ 0.6 slow … 1.8 fast)
    var avgLineWords: Double = 6
    var arabic = false
    var wordSynced = false
    var genre: String?

    static func make(lyrics: Lyrics?, genre: String?, title: String, artist: String) -> SongProfile {
        var p = SongProfile()
        p.genre = genre
        if let w = lyrics?.words, w.count > 10, let first = w.first, let last = w.last, last.end > first.start {
            p.tempo = min(1.8, max(0.6, Double(w.count) / (last.end - first.start) / 1.6))
            p.avgLineWords = Double(w.count) / Double(max(1, lyrics?.lineCount ?? 1))
            let arabicWords = w.prefix(80).filter { $0.text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }.count
            p.arabic = arabicWords * 2 > min(80, w.count)
        } else {
            p.arabic = (title + artist).unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        }
        p.wordSynced = lyrics?.wordSynced ?? false

        let g = (genre ?? "").lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { g.contains($0) } }
        if has("hip-hop", "hip hop", "rap", "trap", "drill") { p.kind = .rap }
        else if has("electronic", "dance", "house", "techno", "edm") { p.kind = .dance }
        else if has("rock", "metal", "punk", "alternative", "grunge") { p.kind = .rock }
        else if has("r&b", "soul", "funk") { p.kind = .rnb }
        else if has("singer/songwriter", "folk", "acoustic", "classical", "jazz", "soundtrack", "ambient") { p.kind = .ballad }
        else if has("arab", "egypt", "khaleeji", "shaabi", "mahragan", "world", "maghreb") || (p.arabic && !has("pop")) {
            p.kind = p.tempo > 1.15 ? .mahraganat : (p.tempo < 0.8 ? .tarab : .arabicPop)
        }
        else if has("pop", "k-pop", "latin") { p.kind = p.arabic ? .arabicPop : .pop }
        else if p.arabic { p.kind = p.tempo > 1.15 ? .mahraganat : (p.tempo < 0.8 ? .tarab : .arabicPop) }
        else { p.kind = p.tempo > 1.35 ? .rap : (p.tempo < 0.8 ? .ballad : .pop) }
        return p
    }

    /// The look Auto chooses, and a short reason shown in the menu.
    struct Choice: Equatable {
        var style: DisplayStyle
        var motion: MotionStyle
        var english: EnglishFont
        var arabic: ArabicFont
        var emoji: Bool
        var reason: String
    }

    var choice: Choice {
        let punchy = wordSynced && avgLineWords <= 9
        let fast = tempo > 1.3, slow = tempo < 0.85
        var c: Choice
        switch kind {
        case .rap: c = Choice(style: punchy ? .ribbon : .motion, motion: .orbit, english: .impact, arabic: .muna, emoji: true, reason: "")
        case .mahraganat: c = Choice(style: punchy ? .ribbon : .brush, motion: .bloom, english: .futura, arabic: .muna, emoji: true, reason: "")
        case .dance: c = Choice(style: punchy ? .marker : .neon, motion: .orbit, english: .futura, arabic: .damascus, emoji: false, reason: "")
        case .pop:
            c = Choice(style: slow ? .focus : (fast ? .marker : .glow), motion: slow ? .aurora : .flow,
                       english: slow ? .serif : .avenir, arabic: .geeza, emoji: !slow, reason: "")
        case .arabicPop:
            c = Choice(style: slow ? .spotlight : (wordSynced ? .glow : .depth), motion: slow ? .aurora : .flow,
                       english: .avenir, arabic: slow ? .naskh : .nile, emoji: !slow, reason: "")
        case .rock: c = Choice(style: .motion, motion: slow ? .aurora : .orbit, english: .rockwell, arabic: .bayan, emoji: false, reason: "")
        case .rnb: c = Choice(style: punchy ? .focus : .constellation, motion: .aurora, english: .didot, arabic: .naskh, emoji: false, reason: "")
        case .ballad: c = Choice(style: avgLineWords > 9 ? .constellation : .spotlight, motion: .aurora, english: .serif, arabic: .naskh, emoji: false, reason: "")
        case .tarab: c = Choice(style: .depth, motion: .aurora, english: .bodoni, arabic: .thuluth, emoji: false, reason: "")
        case .other: c = Choice(style: wordSynced ? .glow : .depth, motion: .flow, english: .system, arabic: .geeza, emoji: true, reason: "")
        }
        let pace = fast ? "fast" : (slow ? "slow" : "mid-tempo")
        c.reason = "\(pace) \(kind.rawValue)\(wordSynced ? "" : ", line-timed lyrics")"
        return c
    }
}
