import Foundation
import Security

/// The "director's plan" for one song: which section each line belongs to, how each
/// section should be animated, and which words deserve a punch (flash / bigger / colour).
struct SongScript: Codable, Equatable {
    struct Section: Codable, Equatable {
        var firstLine: Int
        var lastLine: Int
        var kind: String          // intro, verse, chorus, bridge, outro
        var treatment: String     // flash, brush, sweep, scroll, spotlight, bold, karaoke, kinetic, neon, gold, typewriter, lens, wall
        var energy: Double        // 0…2
    }
    var sections: [Section] = []
    var emphasis: [Int] = []      // word indices
    var mood: String?
    var source = "auto"           // "auto" (on-device rules) or "ai"

    var id: String { "\(source)|\(sections.count)|\(sections.map(\.treatment).joined(separator: ","))|\(emphasis.count)" }

    func section(forLine line: Int) -> Int {
        sections.firstIndex { line >= $0.firstLine && line <= $0.lastLine } ?? max(0, sections.count - 1)
    }
    var summary: String {
        var seen: [String] = []
        for s in sections { let t = "\(s.kind) \(s.treatment.capitalized)"; if seen.last != t { seen.append(t) } }
        return seen.prefix(5).joined(separator: " · ")
    }
}

enum Analyzer {
    static let treatments = ["poster", "brush", "motion", "glow", "spotlight", "focus", "depth", "marker", "ribbon", "constellation", "neon", "lens"]

    // MARK: On-device analysis

    /// Sections from structure: repeated lines are the chorus; long gaps and chorus/verse
    /// changes start a new section. Treatments come from the section kind + song profile.
    static func heuristic(_ lyrics: Lyrics, profile: SongProfile) -> SongScript {
        var lineText: [Int: String] = [:], lineStart: [Int: Double] = [:], lineEnd: [Int: Double] = [:], lineWords: [Int: [Int]] = [:]
        for (i, w) in lyrics.words.enumerated() {
            lineText[w.line, default: ""] += (lineText[w.line] == nil ? "" : " ") + w.text
            lineStart[w.line] = min(lineStart[w.line] ?? .infinity, w.start)
            lineEnd[w.line] = max(lineEnd[w.line] ?? 0, w.end)
            lineWords[w.line, default: []].append(i)
        }
        let lines = lineText.keys.sorted()
        guard !lines.isEmpty else { return SongScript() }
        let norm: (String) -> String = { LyricsService.normalize($0) }
        var counts: [String: Int] = [:]
        for l in lines { counts[norm(lineText[l]!), default: 0] += 1 }
        let isChorus: (Int) -> Bool = { l in (counts[norm(lineText[l]!)] ?? 0) >= 2 && (lineWords[l]?.count ?? 0) >= 2 }

        // Group lines into sections.
        var groups: [[Int]] = [[lines[0]]]
        for k in 1..<lines.count {
            let prev = lines[k - 1], l = lines[k]
            let gap = (lineStart[l] ?? 0) - (lineEnd[prev] ?? 0)
            let flip = isChorus(l) != isChorus(prev)
            if gap > 2.8 || flip || groups[groups.count - 1].count >= 8 { groups.append([l]) } else { groups[groups.count - 1].append(l) }
        }

        let gritty = [.rap, .mahraganat, .dance].contains(profile.kind) || profile.tempo > 1.3
        let slow = [.ballad, .tarab, .rnb].contains(profile.kind) || profile.tempo < 0.85
        var chorusSeen = 0
        var out = SongScript()
        for (gi, g) in groups.enumerated() {
            let words = g.flatMap { lineWords[$0] ?? [] }
            let span = max(0.5, (lineEnd[g.last!] ?? 0) - (lineStart[g.first!] ?? 0))
            let energy = min(2, Double(words.count) / span / 1.6)
            var kind: String
            if g.allSatisfy(isChorus) { kind = "chorus"; chorusSeen += 1 }
            else if gi == 0 && g.count <= 4 { kind = "intro" }
            else if gi == groups.count - 1 && g.count <= 4 { kind = "outro" }
            else if chorusSeen >= 2 { kind = "bridge" }
            else { kind = "verse" }
            out.sections.append(.init(firstLine: g.first!, lastLine: g.last!, kind: kind,
                                      treatment: treatment(kind: kind, gritty: gritty, slow: slow, energy: energy, profile: profile, index: gi),
                                      energy: energy))
        }
        out.emphasis = emphasisWords(lyrics, lines: lineWords)
        return out
    }

    /// Treatment per section. Gritty songs (rap / mahraganat / dance) get the lyric-video looks;
    /// slow songs the cinematic ones; everything else the smooth Apple-style reading looks.
    private static func treatment(kind: String, gritty: Bool, slow: Bool, energy: Double, profile: SongProfile, index: Int) -> String {
        let synced = profile.wordSynced
        if gritty {
            switch kind {
            case "intro": return "poster"
            case "chorus": return energy > 1.1 ? "poster" : "ribbon"
            case "bridge": return "motion"
            case "outro": return "motion"
            default: return [synced ? "ribbon" : "brush", "brush", "motion"][index % 3]
            }
        }
        if slow {
            switch kind {
            case "intro", "outro": return "focus"
            case "chorus": return "constellation"
            case "bridge": return "lens"
            default: return synced ? "spotlight" : "focus"
            }
        }
        switch kind {
        case "intro": return "focus"
        case "chorus": return energy > 1.1 ? "marker" : "spotlight"
        case "bridge": return "lens"
        case "outro": return "focus"
        default: return synced ? "glow" : "depth"
        }
    }

    /// Punch words: long held notes, words in another script than their line (SUPREME inside
    /// an Arabic line), and a line's last word when it's held. At most one per line.
    private static func emphasisWords(_ lyrics: Lyrics, lines: [Int: [Int]]) -> [Int] {
        var out: [Int] = []
        for (_, idx) in lines.sorted(by: { $0.key < $1.key }) {
            let arabicLine = idx.filter { LyricFonts.isArabic(lyrics.words[$0].text) }.count * 2 > idx.count
            var best: (Int, Double)?
            for i in idx {
                let w = lyrics.words[i]
                // Ad-libs in brackets, like "(damn)" or "(حي)", are background voices, never the punch.
                if w.text.contains("(") || w.text.contains(")") { continue }
                var score = (w.end - w.start) - 0.6
                if arabicLine != LyricFonts.isArabic(w.text) && w.text.count >= 3 { score += 1.2 }
                if i == idx.last { score += 0.15 }
                if score > 0.3, score > (best?.1 ?? 0) { best = (i, score) }
            }
            if let b = best { out.append(b.0) }
        }
        return out
    }

}
