import AppKit
import Combine
import SwiftUI

/// Beat/word pulses live in their own object so a pulse only refreshes the wallpaper layer,
/// not every view that watches the engine.
@MainActor
final class Pulse: ObservableObject {
    @Published private(set) var count = 0
    private(set) var strength = 0.0
    func fire(_ s: Double) { strength = s; count &+= 1 }
}

@MainActor
final class LyricClock: ObservableObject {
    @Published var index = -1
    @Published var idle = false
}

/// Ties together the player, lyrics, palette, mood, audio, lock state and display-awake assertion.
@MainActor
final class Engine: ObservableObject {
    let prefs = Prefs()
    let player = NowPlayingMonitor()
    let lock = LockMonitor()
    let audio = AudioReactor()
    private let awake = DisplayAwake()

    enum LyricsState: Equatable { case none, loading, ready, notFound }

    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsState: LyricsState = .none
    /// Index of the word being sung (-1 before the first word).
    private(set) var index: Int = -1
    /// True during long instrumental gaps.
    private(set) var idle = false
    /// Word-by-word state lives here so only the lyric layers refresh on every word,
    /// not every Wordlight window (menu, card, wallpaper, lock screen).
    let clock = LyricClock()
    @Published private(set) var artPalette: Palette?
    @Published private(set) var artCloud: ArtClouds?
    @Published private(set) var mood = SongMood()
    @Published private(set) var desktopVisible = false
    @Published private(set) var lockVisible = false
    /// Ring light around the screen edges (shows over apps while music plays).
    @Published private(set) var ringVisible = false
    @Published private(set) var audioError: String?

    /// Desktop live wallpaper on/off, with the click-to-toggle transitions in between.
    enum WallpaperPhase: Equatable { case live, off, entering, leaving }
    @Published private(set) var phase: WallpaperPhase = .live
    @Published private(set) var phaseID = 0
    /// Set by the window controller: is the main desktop wallpaper actually visible?
    var desktopOnScreen = true { didSet { if desktopOnScreen != oldValue { tickSoon() } } }
    private var audioOffSince: Date?
    private var pausedSince: Date?
    /// The last song shown (kept after playback stops, for the exit animation and the card).
    @Published private(set) var lastTrack: Track?
    @Published private(set) var lastArtwork: NSImage?

    /// The song the desktop card shows: the current one, or the last one while animating out.
    var displayTrack: Track? { player.track ?? (phase == .leaving ? lastTrack : nil) }
    var displayArtwork: NSImage? { player.artwork ?? (phase == .leaving || player.track != nil ? lastArtwork : nil) }

    /// Live wallpaper is wanted when you've turned it on AND music is playing
    /// (or was paused only briefly, so a quick pause doesn't flash your normal wallpaper).
    private var wantLive: Bool {
        guard prefs.enabled, prefs.desktopWallpaper, player.track != nil else { return false }
        if player.isPlaying { return true }
        return Date().timeIntervalSince(pausedSince ?? .distantPast) < 20
    }

    /// Bumped on every sung word (and every bass beat when audio reaction is on);
    /// the wallpaper fires one short Core Animation pulse per bump.
    let pulse = Pulse()

    private var bag = Set<AnyCancellable>()
    private var ticker: Timer?
    private var loadTask: Task<Void, Never>?

    var palette: Palette {
        if prefs.autoColors, let p = artPalette { return p }
        return Palette(lyric: Color(hex: prefs.lyricHex), highlight: Color(hex: prefs.highlightHex), secondary: Color(hex: prefs.secondaryHex))
    }

    /// What Auto knows about the current song (genre, tempo, language, timing quality).
    @Published private(set) var profile = SongProfile()
    /// Emoji to show, by word index: few, strong words only (see `pickEmoji`).
    @Published private(set) var emoji: [Int: String] = [:]
    private var genreCache: [String: String] = [:]

    var autoChoice: SongProfile.Choice { profile.choice }

    /// The lyric style actually used. Auto = the Director (a treatment per section).
    var lyricStyle: DisplayStyle { prefs.style == .auto ? .director : prefs.style }
    /// The director's plan for this song (sections, treatments, punch words).
    @Published private(set) var script: SongScript?

    private func refreshScript() {
        guard let l = lyrics else { script = nil; return }
        script = Analyzer.heuristic(l, profile: profile)
    }
    var englishFont: EnglishFont { prefs.englishFont == .auto ? autoChoice.english : prefs.englishFont }
    var arabicFont: ArabicFont { prefs.arabicFont == .auto ? autoChoice.arabic : prefs.arabicFont }
    /// Emoji on when you've allowed them and (in Auto style) the song suits them.
    var emojiOn: Bool { prefs.icons && (prefs.style != .auto || autoChoice.emoji) }

    private func refreshProfile() {
        guard let t = player.track else { return }
        let p = SongProfile.make(lyrics: lyrics, genre: genreCache[t.id], title: t.title, artist: t.artist)
        if p != profile { profile = p }
        mood = SongMood.make(track: t, lyrics: lyrics, preferred: prefs.motion == .auto ? p.choice.motion : prefs.motion)
        emoji = Self.pickEmoji(lyrics)
        refreshScript()
    }

    /// Sparse emoji: strong words only, at most 6 per song, 25+ words apart, one per line,
    /// and the same emoji at most twice (so a repeated chorus doesn't spam it).
    nonisolated static func pickEmoji(_ lyrics: Lyrics?) -> [Int: String] {
        guard let w = lyrics?.words else { return [:] }
        var out: [Int: String] = [:]
        var used: [String: Int] = [:]
        var lastAt = -100, lastLine = -1
        for (i, word) in w.enumerated() {
            guard out.count < 6, word.line != lastLine, i - lastAt >= 25,
                  let e = WordIcons.icon(for: word.text), used[e, default: 0] < 2 else { continue }
            out[i] = e
            used[e, default: 0] += 1
            lastAt = i
            lastLine = word.line
        }
        return out
    }

    /// Fixed clock used by the snapshot renderer.
    var timeOverride: Double?
    /// Snapshot renderer: pretend the screen is locked.
    var forceLockPreview = false
    /// Snapshot renderer: a still of the Core Animation wallpaper (ImageRenderer can't draw CA layers).
    var snapshotBackground: NSImage?
    /// Words fade in over a few hundred ms, so they're cued a touch early to *look* on time.
    static let displayLead = 0.07
    func time() -> Double {
        timeOverride ?? (player.position() + prefs.syncOffset + songOffset + Self.displayLead)
    }
    /// This song's own timing fix (some lyric files are timed to a slightly different release).
    var songOffset: Double { player.track.map { prefs.trackOffsets[Self.offsetKey($0)] ?? 0 } ?? 0 }
    static func offsetKey(_ t: Track) -> String { (t.title + "|" + t.artist).lowercased() }
    func nudgeSong(_ delta: Double) {
        guard let t = player.track else { return }
        let k = Self.offsetKey(t)
        let v = ((prefs.trackOffsets[k] ?? 0) + delta).clamped(-3, 3)
        prefs.trackOffsets[k] = abs(v) < 0.001 ? nil : (v * 100).rounded() / 100
        tickSoon()
    }
    func resetSongOffset() { guard let t = player.track else { return }; prefs.trackOffsets[Self.offsetKey(t)] = nil; tickSoon() }

    func start() {
        // Re-publish nested objects so SwiftUI views that observe Engine refresh too.
        for p in [prefs.objectWillChange, player.objectWillChange, lock.objectWillChange] as [ObservableObjectPublisher] {
            p.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        }
        player.$track.removeDuplicates().sink { [weak self] t in self?.trackChanged(t) }.store(in: &bag)
        player.$artwork.sink { [weak self] img in
            // Keep the last cover's colours when playback stops, so the exit animation uses them.
            guard let self, let img else { return }
            self.lastArtwork = img
            self.artPalette = ArtworkPalette.extract(from: img)
            self.artCloud = ArtBlur.clouds(from: img)
        }.store(in: &bag)
        player.$track.sink { [weak self] t in if let t { self?.lastTrack = t } }.store(in: &bag)
        prefs.$motion.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshProfile() }
        }.store(in: &bag)
        prefs.$audioReactive.sink { [weak self] on in self?.setAudio(on) }.store(in: &bag)
        phase = .off
        audio.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.audioError = msg; self?.prefs.audioReactive = false }
        }
        audio.onBeat = { [weak self] strength in
            DispatchQueue.main.async { self?.firePulse(strength) }
        }
        player.$isPlaying.sink { [weak self] playing in
            guard let self else { return }
            if playing { self.pausedSince = nil } else if self.pausedSince == nil { self.pausedSince = Date() }
            NSLog("Wordlight: playback \(playing ? "playing" : "paused")")
            if playing, self.prefs.audioReactive { self.audio.refreshTargets() }
            self.tickSoon()
        }.store(in: &bag)

        // React immediately to lock/unlock and settings changes.
        lock.$isLocked.sink { [weak self] _ in self?.tickSoon() }.store(in: &bag)
        prefs.objectWillChange.sink { [weak self] in self?.tickSoon() }.store(in: &bag)

        player.start()
        tick()
    }

    private func firePulse(_ strength: Double) {
        guard player.isPlaying, (desktopVisible && desktopOnScreen) || lockVisible || ringVisible else { return }
        pulse.fire(strength)
    }

    /// Wake up exactly when the next word starts (at most every 1/4 s otherwise) instead of
    /// polling 60× a second. A song is ~2–4 words/s, so this is a handful of wakeups per second.
    private func scheduleTick() {
        ticker?.invalidate()
        var delay = 0.25
        if player.isPlaying, desktopVisible || lockVisible || ringVisible, let l = lyrics, index + 1 < l.words.count {
            let untilNext = l.words[index + 1].start - time()
            delay = min(0.25, max(0.004, untilNext + 0.002))
        }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = delay > 0.2 ? 0.05 : 0.002
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tickSoon() {
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    private func setAudio(_ on: Bool) {
        if on { audioError = nil } else { audio.stop() }
        tickSoon()
    }

    /// Only listen to audio while someone can actually see the pulses (saves battery/CPU).
    private func updateAudioListening() {
        let wanted = prefs.audioReactive && player.isPlaying && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ((desktopVisible && desktopOnScreen && !lock.isLocked) || lockVisible || ringVisible)
        if wanted {
            audioOffSince = nil
            if !audio.running { audio.start() }
        } else if audio.running {
            // Small grace period so briefly covering the desktop doesn't restart the tap.
            if audioOffSince == nil { audioOffSince = Date() }
            if let t = audioOffSince, Date().timeIntervalSince(t) > 4 { audio.stop(); audioOffSince = nil }
        }
    }

    /// Click on the song cover: live wallpaper ⇄ your normal wallpaper.
    func toggleLive() {
        prefs.desktopWallpaper = !(phase == .live || phase == .entering)
        tickSoon()
    }

    /// Starts the zoom-in (entering) or enhance-out (leaving) animation when `wantLive` changes.
    private func updatePhase() {
        let want = wantLive
        let showing = phase == .live || phase == .entering
        guard want != showing else { return }
        phase = want ? .entering : .leaving
        NSLog("Wordlight: live wallpaper \(want ? "ON (zoom in)" : "OFF (enhance out)") — playing=\(player.isPlaying) track=\(player.track != nil)")
        phaseID &+= 1
        let id = phaseID
        DispatchQueue.main.asyncAfter(deadline: .now() + (want ? 1.8 : 1.85)) { [weak self] in
            guard let self, self.phaseID == id else { return }
            self.phase = want ? .live : .off
        }
    }

    private func trackChanged(_ t: Track?) {
        loadTask?.cancel()
        lyrics = nil
        index = -1
        clock.index = -1
        // Music stopped: keep the last song's mood so the exit animation doesn't jump.
        guard let t else { lyricsState = .none; return }
        lyricsState = .loading
        refreshProfile()
        loadTask = Task { [weak self] in
            // Lyrics (often already prefetched/cached) and genre in parallel.
            async let lyr = LyricsService.lyrics(for: t)
            async let gen = SongInfo.genre(title: t.title, artist: t.artist)
            let (l, g) = await (lyr, gen)
            guard !Task.isCancelled, let self, self.player.track == t else { return }
            if let g { self.genreCache[t.id] = g }
            self.lyrics = l
            self.lyricsState = l == nil ? .notFound : .ready
            self.refreshProfile()
            let c = self.autoChoice
            NSLog("Wordlight: lyrics \(l?.source ?? "not found") for \(t.title) [genre \(g ?? "?")] → \(self.profile.kind.rawValue): style \(self.lyricStyle.rawValue), motion \(self.mood.motion.rawValue), fonts \(self.englishFont.rawValue)/\(self.arabicFont.rawValue), emoji \(self.emojiOn ? self.emoji.count : 0) (auto: \(c.reason))")
            self.prefetchQueue()
        }
    }

    /// Get the next songs in the current Music playlist ready (lyrics + genre + cover) so
    /// switching songs is instant and smooth.
    private func prefetchQueue() {
        Task { [weak self] in
            guard let self else { return }
            let upcoming = await self.player.upcomingTracks()
            guard !upcoming.isEmpty else { return }
            NSLog("Wordlight: prefetching \(upcoming.count) upcoming song(s)")
            await Task.detached(priority: .utility) {
                for t in upcoming {
                    _ = await LyricsService.lyrics(for: t)
                    _ = await SongInfo.genre(title: t.title, artist: t.artist)
                    _ = await SongInfo.cover(title: t.title, artist: t.artist)
                }
            }.value
        }
    }

    func reloadLyrics() { trackChanged(player.track) }

    func tick() {
        let t = time()

        var newIndex = -1
        var newIdle = false
        if let l = lyrics, !l.words.isEmpty {
            newIndex = l.wordIndex(at: t) ?? -1
            if newIndex >= 0 {
                let w = l.words[newIndex]
                let nextStart = newIndex + 1 < l.words.count ? l.words[newIndex + 1].start : .infinity
                newIdle = t > w.end + 3.5 && nextStart - t > 2.5
            } else {
                newIdle = l.words[0].start - t > 2.5
            }
        }
        if newIndex != index {
            index = newIndex
            clock.index = newIndex
            // Each sung word is a soft hit; beats from audio (when on) are stronger.
            if newIndex >= 0 && !newIdle { firePulse(prefs.audioReactive && audio.running ? 0.35 : 0.6) }
        }
        if newIdle != idle { idle = newIdle; clock.idle = newIdle }

        let hasTrack = prefs.enabled && player.track != nil
        if timeOverride == nil { updatePhase() } else { phase = prefs.desktopWallpaper ? .live : .off }
        let dv = phase != .off
        let lv = hasTrack && prefs.lockWallpaper && (lock.isLocked || forceLockPreview)
        if dv != desktopVisible { desktopVisible = dv }
        if lv != lockVisible { lockVisible = lv }
        let rv = hasTrack && prefs.ringLight && player.isPlaying && !lock.isLocked && timeOverride == nil
        if rv != ringVisible { ringVisible = rv }
        awake.set(lv && player.isPlaying && prefs.keepAwake)
        if timeOverride == nil { updateAudioListening(); scheduleTick() }
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, self)) }
}
