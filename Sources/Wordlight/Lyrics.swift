import Foundation

struct LyricWord: Hashable, Codable {
    var text: String
    var start: Double
    var end: Double
    var line: Int
}

struct Lyrics: Codable {
    var words: [LyricWord]
    var lineCount: Int
    var source: String
    /// true when the provider gave real per-word timings; false when they were estimated from line timings.
    var wordSynced: Bool

    /// Index of the last word whose start time is <= t, or nil before the first word.
    func wordIndex(at t: Double) -> Int? {
        var lo = 0, hi = words.count - 1, best: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= t { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    func words(inLine line: Int) -> ArraySlice<LyricWord> {
        guard let first = words.firstIndex(where: { $0.line == line }) else { return [] }
        let last = words[first...].firstIndex(where: { $0.line != line }) ?? words.count
        return words[first..<last]
    }
}

// MARK: - Parsing

enum LyricsParser {
    /// NetEase "YRC": `[lineStart,lineDur](wordStart,wordDur,0)text(wordStart,wordDur,0)text...` (milliseconds).
    static func parseYRC(_ raw: String) -> [LyricWord] {
        var out: [LyricWord] = []
        let marker = try! NSRegularExpression(pattern: #"\((\d+),(\d+),-?\d+\)"#)
        var lineNo = 0
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let body = String(line[line.index(after: close)...])
            let ns = body as NSString
            let matches = marker.matches(in: body, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            // Tokens: (start, end, text). Text runs until the next marker.
            var tokens: [(Double, Double, String)] = []
            for (i, m) in matches.enumerated() {
                let s = Double(ns.substring(with: m.range(at: 1)))! / 1000
                let d = Double(ns.substring(with: m.range(at: 2)))! / 1000
                let textStart = m.range.location + m.range.length
                let textEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                tokens.append((s, s + d, ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))))
            }
            let lineText = tokens.map(\.2).joined()
            if isCreditLine(lineText) { continue }

            // Merge syllable tokens into whole words: a word ends where the text has whitespace.
            var buffer = "", wStart = 0.0, wEnd = 0.0, hasBuffer = false
            func flush() {
                let t = buffer.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(LyricWord(text: t, start: wStart, end: max(wEnd, wStart + 0.05), line: lineNo)) }
                buffer = ""; hasBuffer = false
            }
            for (s, e, text) in tokens {
                let letters = text.contains { $0.isLetter || $0.isNumber }
                if !hasBuffer && letters { wStart = s; hasBuffer = true }
                buffer += text
                if letters { wEnd = e }
                if text.last?.isWhitespace == true { flush() }
            }
            flush()
            lineNo += 1
        }
        return out
    }

    /// Standard / enhanced LRC. Enhanced word tags `<mm:ss.xx>` are used when present;
    /// otherwise word times are estimated across each line by syllable weight.
    static func parseLRC(_ raw: String) -> (words: [LyricWord], wordSynced: Bool) {
        let tag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
        let wordTag = try! NSRegularExpression(pattern: #"<(\d+):(\d+(?:[.:]\d+)?)>"#)
        var lines: [(Double, String)] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let ns = line as NSString
            let ms = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let lastTag = ms.last else { continue }
            let text = ns.substring(from: lastTag.range.location + lastTag.range.length)
            for m in ms {
                let t = Double(ns.substring(with: m.range(at: 1)))! * 60 + parseSeconds(ns.substring(with: m.range(at: 2)))
                lines.append((t, text))
            }
        }
        lines.sort { $0.0 < $1.0 }

        var out: [LyricWord] = []
        var anyWordTags = false
        var lineNo = 0
        for (i, (start, text)) in lines.enumerated() {
            let nextStart = i + 1 < lines.count ? lines[i + 1].0 : start + 5
            let ns = text as NSString
            let wtags = wordTag.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if !wtags.isEmpty {
                anyWordTags = true
                for (j, m) in wtags.enumerated() {
                    let s = Double(ns.substring(with: m.range(at: 1)))! * 60 + parseSeconds(ns.substring(with: m.range(at: 2)))
                    let from = m.range.location + m.range.length
                    let to = j + 1 < wtags.count ? wtags[j + 1].range.location : ns.length
                    let piece = ns.substring(with: NSRange(location: from, length: to - from))
                    let e = j + 1 < wtags.count
                        ? Double(ns.substring(with: wtags[j + 1].range(at: 1)))! * 60 + parseSeconds(ns.substring(with: wtags[j + 1].range(at: 2)))
                        : nextStart
                    for w in piece.split(separator: " ") where w.contains(where: { $0.isLetter || $0.isNumber }) {
                        out.append(LyricWord(text: String(w), start: s, end: e, line: lineNo))
                    }
                }
                lineNo += 1
                continue
            }

            let tokens = text.split(separator: " ").map(String.init).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            guard !tokens.isEmpty, !isCreditLine(text) else { continue }
            let weights = tokens.map { syllables($0) }
            let total = Double(weights.reduce(0, +))
            // Sung lines rarely fill the whole gap before the next line; assume ~0.28s per syllable, capped by the gap.
            let gap = max(0.3, nextStart - start)
            let span = min(gap * 0.92, max(total * 0.28, min(gap, 1.2)))
            var t = start
            for (k, (w, weight)) in zip(tokens, weights).enumerated() {
                let d = span * Double(weight) / total
                // Singers hold the last word of a line: let it glow until just before the next line.
                let end = k == tokens.count - 1 ? max(t + d, min(start + gap * 0.9, t + d + 1.5)) : t + d
                out.append(LyricWord(text: w, start: t, end: end, line: lineNo))
                t += d
            }
            lineNo += 1
        }
        return (out, anyWordTags)
    }

    static func parseSeconds(_ s: String) -> Double {
        // "12.34" or "12:34" (some files use ':' for centiseconds)
        let parts = s.split(whereSeparator: { $0 == "." || $0 == ":" })
        guard let sec = Double(parts.first ?? "0") else { return 0 }
        guard parts.count > 1 else { return sec }
        let frac = String(parts[1])
        return sec + (Double(frac) ?? 0) / pow(10, Double(frac.count))
    }

    static func syllables(_ word: String) -> Int {
        let vowels = Set("aeiouyAEIOUY")
        var count = 0, prevVowel = false
        for c in word {
            let v = vowels.contains(c)
            if v && !prevVowel { count += 1 }
            prevVowel = v
        }
        if LyricFonts.isArabic(word) {
            // Written Arabic leaves out short vowels: roughly one syllable per two letters
            // (harakat and tatweel don't count), e.g. حرام → 2, المظابيط → 4.
            let letters = word.unicodeScalars.filter { (0x0621...0x064A).contains($0.value) || (0x0671...0x06D3).contains($0.value) }.count
            return max(1, Int((Double(letters) * 0.5).rounded()))
        }
        if !word.contains(where: { $0.isASCII }) { return max(1, word.count) } // CJK etc: one per character
        return max(1, count)
    }

    /// Lines like "作词 : ..." / "Composer: ..." that providers prepend.
    static func isCreditLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let head = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let credits = ["作词", "作曲", "编曲", "制作人", "混音", "母带", "词", "曲", "lyrics by", "composed by", "producer", "produced by", "written by", "composer", "lyricist", "arranger"]
        return credits.contains(where: { head.hasPrefix($0) }) || (head.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } && head.count <= 6)
    }
}

// MARK: - Providers

enum LyricsService {
    private static var cache: [String: Lyrics] = [:]
    private static let lock = NSLock()

    static func lyrics(for track: Track) async -> Lyrics? {
        let key = "\(normalize(track.artist))|\(normalize(track.title))|\(Int(track.duration))"
        let hit = lock.withLock { cache[key] }
        if let hit { return hit }

        let result = await fetch(track)
        if let result {
            lock.withLock { cache[key] = result }
            saveToDisk(result, key: key)
        } else if let disk = loadFromDisk(key: key) {
            return disk
        }
        return result
    }

    private static func fetch(_ track: Track) async -> Lyrics? {
        // 1. NetEase word-level (YRC) — real per-word timings.
        let netease = await NetEase.lyrics(for: track)
        if let yrc = netease?.yrc {
            let words = LyricsParser.parseYRC(yrc)
            if words.count > 3 {
                return Lyrics(words: words, lineCount: (words.last?.line ?? 0) + 1, source: "NetEase · word-synced", wordSynced: true)
            }
        }
        // 2. LRCLIB (enhanced LRC if present, else line-synced with estimated words).
        if let lrc = await LRCLib.synced(for: track) {
            let p = LyricsParser.parseLRC(lrc)
            if p.words.count > 3 {
                return Lyrics(words: p.words, lineCount: (p.words.last?.line ?? 0) + 1,
                              source: p.wordSynced ? "LRCLIB · word-synced" : "LRCLIB · line-synced", wordSynced: p.wordSynced)
            }
        }
        // 3. NetEase line-synced LRC as a last resort.
        if let lrc = netease?.lrc {
            let p = LyricsParser.parseLRC(lrc)
            if p.words.count > 3 {
                return Lyrics(words: p.words, lineCount: (p.words.last?.line ?? 0) + 1, source: "NetEase · line-synced", wordSynced: false)
            }
        }
        return nil
    }

    // Small disk cache so songs you've played work offline and load instantly.
    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Wordlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return cacheDir.appendingPathComponent(String(safe.prefix(180)) + ".json")
    }
    private static func saveToDisk(_ l: Lyrics, key: String) {
        try? JSONEncoder().encode(l).write(to: file(key))
    }
    private static func loadFromDisk(key: String) -> Lyrics? {
        guard let d = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: d)
    }

    // MARK: matching helpers

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("&", "and")] { t = t.replacingOccurrences(of: a, with: b) }
        // drop "(feat. …)", "[Remastered]", " - Radio Edit"
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+.*(remaster|version|edit|mix|live|mono|stereo).*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        return t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func primaryArtist(_ s: String) -> String {
        let seps = [",", "&", " feat", " ft.", " x ", " and ", ";", "、", "/"]
        var a = s.lowercased()
        for sep in seps { if let r = a.range(of: sep) { a = String(a[..<r.lowerBound]) } }
        return normalize(a)
    }
}

private let userAgent = "Lyra/2.0 (macOS lyrics viewer)"

enum NetEase {
    struct Result { var yrc: String?; var lrc: String? }

    private struct SearchResponse: Decodable {
        struct R: Decodable { var songs: [Song]? }
        struct Song: Decodable {
            var id: Int; var name: String; var duration: Int?
            var artists: [Artist]?
        }
        struct Artist: Decodable { var name: String }
        var result: R?
    }
    private struct LyricResponse: Decodable {
        struct L: Decodable { var lyric: String? }
        var yrc: L?; var lrc: L?
    }

    static func lyrics(for track: Track) async -> Result? {
        var form = URLComponents()
        form.queryItems = [.init(name: "s", value: "\(track.title) \(track.artist)"), .init(name: "type", value: "1"), .init(name: "limit", value: "15")]
        guard let data = await get(URL(string: "https://music.163.com/api/search/get")!,
                                   body: form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")) else { return nil }
        if ProcessInfo.processInfo.environment["WL_DEBUG"] != nil {
            do { _ = try JSONDecoder().decode(SearchResponse.self, from: data) } catch { print("decode:", error) }
        }
        guard let resp = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let songs = resp.result?.songs, !songs.isEmpty else { return nil }

        let wantTitle = LyricsService.normalize(track.title)
        let wantArtist = LyricsService.primaryArtist(track.artist)
        let variantWords = ["instrumental", "karaoke", "live", "remix", "acoustic", "cover", "sped up", "slowed", "伴奏", "demo", "version", "edit"]
        let wantRaw = track.title.lowercased()
        func score(_ s: SearchResponse.Song) -> Int {
            var sc = 0
            let title = LyricsService.normalize(s.name)
            if title == wantTitle { sc += 50 } else if title.contains(wantTitle) || wantTitle.contains(title) { sc += 20 } else { return -1 }
            // "(Instrumental)" / "(Live)" etc. normalize away, so penalize variants the player isn't playing.
            let raw = s.name.lowercased()
            for v in variantWords where raw.contains(v) && !wantRaw.contains(v) { sc -= 45 }
            let artists = (s.artists ?? []).map { LyricsService.normalize($0.name) }
            let artistOK = artists.contains(where: { $0 == wantArtist || $0.contains(wantArtist) || wantArtist.contains($0) })
            if artistOK { sc += 40 } else {
                // Artist spelled differently (e.g. "حمو الطيخا" vs "Hamo El Tikha"): trust an exact
                // title with a near-identical length instead.
                guard title == wantTitle, let d = s.duration, track.duration > 0, abs(Double(d) / 1000 - track.duration) < 2 else { return -1 }
            }
            if let d = s.duration, track.duration > 0 {
                let diff = abs(Double(d) / 1000 - track.duration)
                if diff > 6 { return -1 }
                sc += Int(max(0, 20 - diff * 5))
            }
            return sc
        }
        let ranked = songs.map { ($0, score($0)) }.filter { $0.1 >= 0 }.sorted { $0.1 > $1.1 }.prefix(4)
        if ProcessInfo.processInfo.environment["WL_DEBUG"] != nil {
            print("want", wantTitle, wantArtist, track.duration)
            for so in songs.prefix(6) { print("  cand", so.name, LyricsService.normalize(so.name), (so.artists ?? []).map { LyricsService.normalize($0.name) }, so.duration ?? -1, score(so)) }
        }
        guard !ranked.isEmpty else { return nil }

        // Several uploads of the same song exist; only some carry word timings. Try the best few.
        var fallbackLRC: String?
        for (song, _) in ranked {
            let url = URL(string: "https://music.163.com/api/song/lyric?id=\(song.id)&lv=1&yv=1&tv=-1")!
            guard let ld = await get(url), let lr = try? JSONDecoder().decode(LyricResponse.self, from: ld) else { continue }
            let lrc = lr.lrc?.lyric.flatMap { $0.contains("[") ? $0 : nil }
            if fallbackLRC == nil { fallbackLRC = lrc }
            if let yrc = lr.yrc?.lyric, !yrc.isEmpty { return Result(yrc: yrc, lrc: lrc) }
        }
        return Result(yrc: nil, lrc: fallbackLRC)
    }

    /// Cookie-less, cache-less session: NetEase changes search behaviour once it has set cookies.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static func get(_ url: URL, body: String? = nil) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        if let body {
            req.httpMethod = "POST"
            req.httpBody = body.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let res = try? await session.data(for: req)
        if ProcessInfo.processInfo.environment["WL_DEBUG"] != nil {
            print("GET", url.absoluteString.prefix(120), (res?.1 as? HTTPURLResponse)?.statusCode ?? -1, res.map { String(data: $0.0.prefix(160), encoding: .utf8) ?? "" } ?? "")
        }
        guard let (d, r) = res, (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
}

enum LRCLib {
    private struct Entry: Decodable {
        var trackName: String?; var artistName: String?; var duration: Double?
        var syncedLyrics: String?
    }

    static func synced(for track: Track) async -> String? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist),
                        .init(name: "album_name", value: track.album), .init(name: "duration", value: String(Int(track.duration.rounded())))]
        if let d = await get(c.url!), let e = try? JSONDecoder().decode(Entry.self, from: d), let s = e.syncedLyrics, !s.isEmpty {
            return s
        }
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [.init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist)]
        guard let d = await get(s.url!), let list = try? JSONDecoder().decode([Entry].self, from: d) else { return nil }
        let candidates = list.filter { ($0.syncedLyrics?.isEmpty == false) && abs(($0.duration ?? track.duration) - track.duration) < 5 }
        if let hit = candidates.min(by: { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) })?.syncedLyrics {
            return hit
        }
        // Artist names are often spelled differently across services (Arabic vs Latin script,
        // "&" vs "feat."): search by title alone and accept an exact title with the same length.
        var q = URLComponents(string: "https://lrclib.net/api/search")!
        q.queryItems = [.init(name: "track_name", value: track.title)]
        guard track.duration > 0, let d2 = await get(q.url!), let list2 = try? JSONDecoder().decode([Entry].self, from: d2) else { return nil }
        let want = LyricsService.normalize(track.title)
        return list2.filter {
            $0.syncedLyrics?.isEmpty == false && LyricsService.normalize($0.trackName ?? "") == want
                && abs(($0.duration ?? 0) - track.duration) < 2.5
        }.min(by: { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) })?.syncedLyrics
    }

    private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
}
