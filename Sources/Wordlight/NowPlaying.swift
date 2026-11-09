import AppKit
import Foundation

enum PlayerApp: String {
    case music = "Apple Music"
    case spotify = "Spotify"

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var player: PlayerApp
}

/// Snapshot returned by one poll of a player.
private struct PlayerSnapshot {
    var track: Track
    var isPlaying: Bool
    var position: Double
    var artworkURL: String?
}

/// Reads the current track and playback position from Music and Spotify via AppleScript,
/// and interpolates the position between polls with a monotonic clock.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var permissionProblem: String?

    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: Timer?
    private var artworkTrackID: String?
    private let queue = DispatchQueue(label: "wordlight.applescript", qos: .userInitiated)
    private var polling = false
    private var pendingPoll = false

    // Scripts are compiled lazily and only for installed players, so we never trigger
    // a "Where is Spotify?" dialog or launch an app that isn't running.
    nonisolated(unsafe) private static var musicScript: NSAppleScript?
    nonisolated(unsafe) private static var spotifyScript: NSAppleScript?

    func start() {
        // 1 poll/s while playing (keeps sync tight); every 3 s while paused or idle.
        // Player notifications still trigger an immediate poll on play/pause/skip.
        var n = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                n += 1
                if self.isPlaying || n % 3 == 0 { self.poll() }
            }
        }
        timer?.tolerance = 0.2
        RunLoop.main.add(timer!, forMode: .common)

        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
        poll()
    }

    /// Current playback position in seconds, interpolated between polls.
    func position() -> Double {
        guard isPlaying else { return anchorPosition }
        return anchorPosition + (CACurrentMediaTime() - anchorTime)
    }

    /// Developer demo: WL_DEMO="Title|Artist|durationSeconds|startAtSeconds" fakes a playing track.
    private lazy var demo: (Track, CFTimeInterval)? = {
        guard let v = ProcessInfo.processInfo.environment["WL_DEMO"] else { return nil }
        let p = v.split(separator: "|").map(String.init)
        guard p.count >= 3 else { return nil }
        let start = p.count > 3 ? Double(p[3]) ?? 0 : 0
        return (Track(id: "demo", title: p[0], artist: p[1], album: "", duration: Double(p[2]) ?? 0, player: .music),
                CACurrentMediaTime() - start)
    }()

    func poll() {
        if let (t, t0) = demo {
            if track != t { track = t; isPlaying = true; anchorTime = t0; anchorPosition = 0 }
            if artwork == nil, let path = ProcessInfo.processInfo.environment["WL_DEMO_ART"] { artwork = NSImage(contentsOfFile: path) }
            return
        }
        if polling { pendingPoll = true; return }
        polling = true
        let musicRunning = PlayerApp.music.isRunning
        let spotifyRunning = PlayerApp.spotify.isRunning
        queue.async { [weak self] in
            let sent = CACurrentMediaTime()
            var snaps: [PlayerSnapshot] = []
            var errors: [String] = []
            if musicRunning {
                switch Self.readMusic() {
                case .success(let s): if let s { snaps.append(s) }
                case .failure(let e): errors.append(e.localizedDescription)
                }
            }
            if spotifyRunning {
                switch Self.readSpotify() {
                case .success(let s): if let s { snaps.append(s) }
                case .failure(let e): errors.append(e.localizedDescription)
                }
            }
            let received = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(snaps, errors: errors, latency: received - sent, receivedAt: received)
                self.polling = false
                if self.pendingPoll { self.pendingPoll = false; self.poll() }
            }
        }
    }

    private func apply(_ snaps: [PlayerSnapshot], errors: [String], latency: Double, receivedAt: CFTimeInterval) {
        if errors.first != permissionProblem, let e = errors.first { NSLog("Wordlight: player error: \(e)") }
        if permissionProblem != errors.first { permissionProblem = errors.first }
        // Prefer a player that is actually playing; keep the current player on ties.
        let chosen = snaps.first(where: { $0.isPlaying && $0.track.player == track?.player })
            ?? snaps.first(where: { $0.isPlaying })
            ?? snaps.first(where: { $0.track.player == track?.player })
            ?? snaps.first

        guard let snap = chosen else {
            // Only publish real changes: every assignment would wake all of Wordlight's views.
            if track != nil { track = nil }
            if isPlaying { isPlaying = false }
            if artwork != nil { artwork = nil }
            artworkTrackID = nil
            return
        }

        // The position was sampled roughly halfway through the AppleScript round trip.
        let sampled = snap.position + (snap.isPlaying ? latency / 2 : 0)
        let trackChanged = snap.track != track
        let predicted = position()
        let drift = abs(predicted - sampled)
        if trackChanged || snap.isPlaying != isPlaying || drift > 0.12 || !snap.isPlaying {
            anchorPosition = sampled
            anchorTime = receivedAt
            // A jump (seek, skip, buffering): check again right away instead of waiting a second.
            if drift > 0.4 && snap.isPlaying && !trackChanged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
            }
        } else {
            // Small drift: nudge gently instead of jumping, so words don't stutter.
            anchorPosition = predicted + (sampled - predicted) * 0.3
            anchorTime = receivedAt
        }

        if trackChanged { track = snap.track; NSLog("Wordlight: now playing \(snap.track.title) — \(snap.track.artist) [\(snap.track.player.rawValue)]") }
        if snap.isPlaying != isPlaying { isPlaying = snap.isPlaying }

        if artworkTrackID != snap.track.id {
            artworkTrackID = snap.track.id
            artwork = nil
            loadArtwork(for: snap)
        }
    }

    private func loadArtwork(for snap: PlayerSnapshot) {
        let id = snap.track.id
        switch snap.track.player {
        case .spotify:
            guard let s = snap.artworkURL, !s.isEmpty, let url = URL(string: s) else { loadCatalogArtwork(for: snap.track); return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let img = NSImage(data: data), self.artworkTrackID == id else { return }
                self.artwork = img
            }
        case .music:
            queue.async {
                let img = Self.readMusicArtwork()
                DispatchQueue.main.async {
                    guard self.artworkTrackID == id else { return }
                    if let img { self.artwork = img } else { self.loadCatalogArtwork(for: snap.track) }
                }
            }
        }
    }

    /// Streaming tracks often report no artwork to AppleScript; look the cover up in Apple's
    /// public iTunes catalogue instead (no account or key needed).
    private func loadCatalogArtwork(for track: Track) {
        let id = track.id
        Task {
            guard let img = await ArtworkLookup.cover(title: track.title, artist: track.artist), self.artworkTrackID == id else { return }
            self.artwork = img
        }
    }

    // MARK: - AppleScript (runs on `queue`)

    private struct ScriptError: LocalizedError {
        var errorDescription: String?
    }

    nonisolated private static func run(_ script: inout NSAppleScript?, source: String) -> Result<NSAppleEventDescriptor, Error> {
        if script == nil {
            script = NSAppleScript(source: source)
            var err: NSDictionary?
            script?.compileAndReturnError(&err)
            if let err { script = nil; return .failure(ScriptError(errorDescription: "\(err[NSAppleScript.errorMessage] ?? err)")) }
        }
        var err: NSDictionary?
        guard let result = script?.executeAndReturnError(&err) else {
            let code = err?[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return .failure(ScriptError(errorDescription: "Lyra isn't allowed to read your music app. Turn it on in System Settings › Privacy & Security › Automation."))
            }
            return .failure(ScriptError(errorDescription: "\(err?[NSAppleScript.errorMessage] ?? "AppleScript error \(code)")"))
        }
        return .success(result)
    }

    nonisolated private static func strings(_ d: NSAppleEventDescriptor) -> [String] {
        guard d.numberOfItems > 0 else { return [d.stringValue ?? ""] }
        return (1...d.numberOfItems).map { d.atIndex($0)?.stringValue ?? "" }
    }

    nonisolated private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    nonisolated private static func readMusic() -> Result<PlayerSnapshot?, Error> {
        let src = """
        tell application id "com.apple.Music"
            set wlState to (player state as string)
            if wlState is "stopped" then return {"stopped"}
            set wlTrack to current track
            return {wlState, name of wlTrack, artist of wlTrack, album of wlTrack, (duration of wlTrack) as string, (player position) as string, persistent ID of wlTrack}
        end tell
        """
        return run(&musicScript, source: src).map { d in
            let v = strings(d)
            guard v.count >= 7 else { return nil }
            let track = Track(id: "music:" + v[6], title: v[1], artist: v[2], album: v[3],
                              duration: number(v[4]), player: .music)
            return PlayerSnapshot(track: track, isPlaying: v[0] == "playing", position: number(v[5]), artworkURL: nil)
        }
    }

    nonisolated private static func readSpotify() -> Result<PlayerSnapshot?, Error> {
        let src = """
        tell application id "com.spotify.client"
            set wlState to (player state as string)
            if wlState is "stopped" then return {"stopped"}
            set wlTrack to current track
            return {wlState, name of wlTrack, artist of wlTrack, album of wlTrack, (duration of wlTrack) as string, (player position) as string, id of wlTrack, artwork url of wlTrack}
        end tell
        """
        return run(&spotifyScript, source: src).map { d in
            let v = strings(d)
            guard v.count >= 8 else { return nil }
            let track = Track(id: v[6], title: v[1], artist: v[2], album: v[3],
                              duration: number(v[4]) / 1000, player: .spotify)
            return PlayerSnapshot(track: track, isPlaying: v[0] == "playing", position: number(v[5]), artworkURL: v[7])
        }
    }

    /// The next few songs in Music's current playlist/album (Spotify doesn't expose its queue).
    func upcomingTracks() async -> [Track] {
        guard track?.player == .music else { return [] }
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: Self.readMusicUpcoming()) }
        }
    }

    nonisolated private static func readMusicUpcoming() -> [Track] {
        let script = NSAppleScript(source: """
        tell application id "com.apple.Music"
            set out to {}
            try
                set pl to current playlist
                set i to index of current track
                set n to count of tracks of pl
                repeat with k from (i + 1) to (i + 3)
                    if k > n then exit repeat
                    set wlT to track k of pl
                    set end of out to {name of wlT, artist of wlT, album of wlT, (duration of wlT) as string, persistent ID of wlT}
                end repeat
            end try
            return out
        end tell
        """)
        var err: NSDictionary?
        guard let d = script?.executeAndReturnError(&err), d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { i in
            guard let item = d.atIndex(i), item.numberOfItems >= 5 else { return nil }
            let v = (1...5).map { item.atIndex($0)?.stringValue ?? "" }
            return Track(id: "music:" + v[4], title: v[0], artist: v[1], album: v[2], duration: number(v[3]), player: .music)
        }
    }

    nonisolated private static func readMusicArtwork() -> NSImage? {
        let script = NSAppleScript(source: """
        tell application id "com.apple.Music"
            try
                return data of artwork 1 of current track
            end try
        end tell
        """)
        var err: NSDictionary?
        guard let d = script?.executeAndReturnError(&err) else { return nil }
        return NSImage(data: d.data)
    }
}

/// Apple's public iTunes catalogue: a song's genre and cover (no account or key needed).
/// Results are cached, so prefetching the next songs makes switching instant.
enum SongInfo {
    private struct Response: Decodable {
        struct R: Decodable { var trackName: String?; var artistName: String?; var artworkUrl100: String?; var primaryGenreName: String? }
        var results: [R]
    }
    private struct Info { var genre: String?; var art: URL? }
    private static var cache: [String: Info] = [:]
    private static var images: [String: NSImage] = [:]
    private static let lock = NSLock()

    private static func key(_ title: String, _ artist: String) -> String {
        LyricsService.normalize(title) + "|" + LyricsService.primaryArtist(artist)
    }

    private static func info(title: String, artist: String) async -> Info {
        let k = key(title, artist)
        if let hit = lock.withLock({ cache[k] }) { return hit }
        var found = Info()
        for term in ["\(artist) \(title)", title] {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "song"), .init(name: "limit", value: "10")]
            guard let (d, _) = try? await URLSession.shared.data(from: c.url!),
                  let r = try? JSONDecoder().decode(Response.self, from: d) else { continue }
            let want = LyricsService.normalize(title)
            let best = r.results.first { LyricsService.normalize($0.trackName ?? "") == want } ?? (term == title ? nil : r.results.first)
            if let b = best {
                found = Info(genre: b.primaryGenreName,
                             art: b.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) })
                break
            }
        }
        lock.withLock { cache[k] = found }
        return found
    }

    static func genre(title: String, artist: String) async -> String? {
        await info(title: title, artist: artist).genre
    }

    static func cover(title: String, artist: String) async -> NSImage? {
        let k = key(title, artist)
        if let img = lock.withLock({ images[k] }) { return img }
        guard let url = await info(title: title, artist: artist).art,
              let (d, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: d) else { return nil }
        lock.withLock {
            if images.count > 12 { images.removeAll() }
            images[k] = img
        }
        return img
    }
}

enum ArtworkLookup {
    static func cover(title: String, artist: String) async -> NSImage? { await SongInfo.cover(title: title, artist: artist) }
}
