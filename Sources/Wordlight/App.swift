import AppKit
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

@main
struct WordlightMain {
    static func main() {
        let args = CommandLine.arguments
        // Command-line check, no UI: Wordlight --lyrics "Title" "Artist" [seconds]
        if args.count >= 4, args[1] == "--lyrics" {
            let track = Track(id: "cli", title: args[2], artist: args[3], album: "", duration: args.count > 4 ? Double(args[4]) ?? 0 : 0, player: .music)
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                if let l = await LyricsService.lyrics(for: track) {
                    print("source: \(l.source)  words: \(l.words.count)  lines: \(l.lineCount)")
                    for w in l.words.prefix(Int(args.count > 5 ? args[5] : "25") ?? 25) {
                        print(String(format: "%7.2f–%7.2f  L%-3d %@", w.start, w.end, w.line, w.text))
                    }
                } else { print("no synced lyrics found") }
                sem.signal()
            }
            sem.wait()
            return
        }
        // What Auto would choose: Wordlight --profile "Title" "Artist" seconds
        if args.count >= 5, args[1] == "--profile" {
            let track = Track(id: "cli", title: args[2], artist: args[3], album: "", duration: Double(args[4]) ?? 0, player: .music)
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                async let l = LyricsService.lyrics(for: track)
                async let g = SongInfo.genre(title: track.title, artist: track.artist)
                let (lyr, gen) = await (l, g)
                let p = SongProfile.make(lyrics: lyr, genre: gen, title: track.title, artist: track.artist)
                let c = p.choice
                let em = Engine.pickEmoji(lyr)
                print(String(format: "%-28@ genre=%-14@ %-20@ tempo=%.2f lineWords=%.1f synced=%@ → %@ | %@ | %@/%@ | emoji %@ (%d: %@)",
                             String(track.title.prefix(28)) as NSString, (gen ?? "?") as NSString, p.kind.rawValue as NSString, p.tempo, p.avgLineWords,
                             (p.wordSynced ? "word" : "line") as NSString, c.style.rawValue as NSString, c.motion.rawValue as NSString,
                             c.english.rawValue as NSString, c.arabic.rawValue as NSString, (c.emoji ? "on" : "off") as NSString, em.count,
                             em.sorted { $0.key < $1.key }.prefix(4).map { "\(lyr!.words[$0.key].text)\($0.value)" }.joined(separator: " ") as NSString))
                sem.signal()
            }
            sem.wait()
            return
        }
        // Film strip of real animation frames: WL_DEMO=… Wordlight --film outDir startSeconds styles
        if args.count >= 5, args[1] == "--film" {
            MainActor.assumeIsolated { Film.run(outDir: args[2], start: Double(args[3]) ?? 15, styles: args[4]) }
            return
        }
        // Render overlay frames to PNG without needing screen-recording permission:
        // WL_DEMO="Title|Artist|dur" Wordlight --snapshot outDir t1,t2,...
        if args.count >= 4, args[1] == "--snapshot" {
            MainActor.assumeIsolated { Snapshot.run(outDir: args[2], times: args[3].split(separator: ",").compactMap { Double($0) }) }
            return
        }
        // Picture of the menu panel: Wordlight --menushot out.png [more]
        if args.count >= 3, args[1] == "--menushot" {
            MainActor.assumeIsolated { MenuShot.run(out: args[2], more: args.count > 3) }
            return
        }
        // Frames of the on/off transition over your wallpaper: WL_DEMO=… Wordlight --transition outDir
        if args.count >= 3, args[1] == "--transition" {
            MainActor.assumeIsolated { TransitionFilm.run(outDir: args[2]) }
            return
        }
        WordlightApp.main()
    }
}

struct WordlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(delegate.engine).environmentObject(delegate.engine.prefs)
        } label: {
            Image(nsImage: MenuIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    private var windows: WallpaperController?
    private var ring: RingLight?

    @objc func toggleEnabled() { engine.prefs.enabled.toggle() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Renamed from Wordlight: point "Open at login" at this copy (once).
        if !UserDefaults.standard.bool(forKey: "loginItemMovedToLyra") {
            UserDefaults.standard.set(true, forKey: "loginItemMovedToLyra")
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
                try? SMAppService.mainApp.register()
            }
        }
        engine.start()
        windows = WallpaperController(engine: engine)
        ring = RingLight(engine: engine)
        // Right-click on the menu-bar logo: a small menu (the SwiftUI menu-bar extra has no right-click of its own).
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] e in
            guard let self, let w = e.window, String(describing: type(of: w)).contains("StatusBar"), let view = w.contentView else { return e }
            let m = NSMenu()
            let toggle = m.addItem(withTitle: self.engine.prefs.enabled ? "Turn Lyra Off" : "Turn Lyra On", action: #selector(self.toggleEnabled), keyEquivalent: "")
            toggle.target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Lyra", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
            return nil
        }
        // Developer (for demo videos): WL_TOGGLE_ONCE=seconds flips the live wallpaper once;
        // WL_STYLE_CYCLE="Glow:4,Neon:5" switches lyric style after each given number of seconds.
        if let v = ProcessInfo.processInfo.environment["WL_TOGGLE_ONCE"], let at = Double(v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.engine.toggleLive() }
        }
        if let v = ProcessInfo.processInfo.environment["WL_STYLE_CYCLE"] {
            var t = 0.0
            for part in v.split(separator: ",") {
                let kv = part.split(separator: ":")
                guard kv.count == 2, let style = DisplayStyle(rawValue: String(kv[0])), let d = Double(kv[1]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.engine.prefs.style = style }
                t += d
            }
        }
        // Developer: WL_TOGGLE_EVERY=seconds flips the live wallpaper on a timer (to film the transition).
        if let v = ProcessInfo.processInfo.environment["WL_TOGGLE_EVERY"], let every = Double(v) {
            Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.toggleLive() }
            }
        }
        if Sprites.debugBakes {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                let lines = Sprites.bakeLog.withLock { l -> [String] in let c = l; l.removeAll(); return c }
                NSLog("bakes last 5s: \(lines.count) — \(Set(lines.map { $0.split(separator: " ").dropFirst().joined(separator: " ") }).count) unique")
            }
        }
    }
}

@MainActor
enum Snapshot {
    static func run(outDir: String, times: [Double]) {
        _ = NSApplication.shared
        let engine = Engine()
        engine.start()
        let deadline = Date().addingTimeInterval(20)
        while engine.lyrics == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard engine.lyrics != nil else { print("no lyrics"); return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5)) // let the artwork palette settle
        engine.forceLockPreview = true
        let styles = (ProcessInfo.processInfo.environment["WL_STYLES"] ?? "Stack").split(separator: ",").compactMap { DisplayStyle(rawValue: String($0)) }
        let motions = (ProcessInfo.processInfo.environment["WL_MOTIONS"] ?? "Flow,Orbit,Bloom,Aurora").split(separator: ",").compactMap { MotionStyle(rawValue: String($0)) }
        for style in styles {
            engine.prefs.style = style
            for motion in motions {
                engine.prefs.motion = motion
                for t in times {
                    engine.timeOverride = t
                    engine.tick()
                    // Render the CA wallpaper with its animations frozen at time t.
                    let wv = WallpaperLayerView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
                    wv.apply(clouds: engine.artCloud, palette: engine.palette, mood: engine.mood, dim: engine.prefs.dim, glowY: engine.prefs.verticalPosition)
                    wv.layout()
                    engine.snapshotBackground = wv.still(at: t)
                    if let bg = engine.snapshotBackground, ProcessInfo.processInfo.environment["WL_CA_LYRICS"] != nil {
                        // Real Core Animation lyrics layers composited over the wallpaper still.
                        let lv = LyricStage(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
                        let base = 900 * 0.105 * engine.prefs.textSize * 0.85
                        lv.update(lyrics: engine.lyrics!, index: engine.index, style: engine.lyricStyle, palette: engine.palette,
                                  fonts: FontPair(english: engine.englishFont, arabic: engine.arabicFont),
                                  emoji: engine.emojiOn ? engine.emoji : [:], base: base,
                                  centerFromTop: engine.prefs.verticalPosition, idle: false, trackID: "snap", now: t, playing: false)
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 900, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
                        if let cg = bg.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1440, height: 900)) }
                        lv.layer!.render(in: ctx)
                        let url = URL(fileURLWithPath: outDir).appendingPathComponent("ca-\(style == .auto ? "Auto-" + engine.lyricStyle.rawValue : style.rawValue)-\(motion.rawValue)-\(t).png")
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                        print("wrote", url.lastPathComponent)
                    }
                    let state = WindowState()
                    let views: [(String, AnyView)] = [
                        ("desktop", AnyView(DesktopRoot(isPrimary: true).environmentObject(state))),
                        ("lock", AnyView(LockRoot())),
                    ]
                    for (name, v) in views {
                        let view = v.environmentObject(engine).environmentObject(engine.prefs).frame(width: 1440, height: 900)
                        let r = ImageRenderer(content: view)
                        r.scale = 1
                        guard let cg = r.cgImage else { continue }
                        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name)-\(style.rawValue)-\(motion.rawValue)-\(t).png")
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
                        print("wrote", url.lastPathComponent)
                    }
                }
            }
        }
    }
}

/// Plays a style live in an off-screen window and saves frames of the actual animation
/// (Core Animation's presentation tree), so motion can be checked without screen recording.
@MainActor
enum Film {
    static func run(outDir: String, start: Double, styles: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let engine = Engine()
        engine.start()
        let deadline = Date().addingTimeInterval(20)
        while (engine.lyrics == nil || engine.artPalette == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let lyrics = engine.lyrics else { print("no lyrics"); return }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5)) // genre + plan
        if let sc = engine.script {
            print("profile:", engine.profile.kind.rawValue, "tempo", String(format: "%.2f", engine.profile.tempo), "| plan:", sc.source)
            for sec in sc.sections {
                let t = lyrics.words.first { $0.line == sec.firstLine }?.start ?? 0
                let text = lyrics.words.filter { $0.line == sec.firstLine }.map(\.text).joined(separator: " ")
                print(String(format: "  %6.1fs  lines %3d–%3d  %-7@ → %-9@ %@", t, sec.firstLine, sec.lastLine, sec.kind as NSString, sec.treatment as NSString, String(text.prefix(40)) as NSString))
            }
            print("  punch words:", sc.emphasis.prefix(12).map { lyrics.words[$0].text }.joined(separator: ", "))
        }
        if ProcessInfo.processInfo.environment["WL_PLAN_ONLY"] != nil { return }
        let size = CGSize(width: 960, height: 600)
        let win = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        win.backgroundColor = NSColor(engine.palette.secondary).blended(withFraction: 0.6, of: .black) ?? .black
        for name in styles.split(separator: ",") {
            guard let style = DisplayStyle(rawValue: String(name)) else { continue }
            let stage = LyricStage(frame: CGRect(origin: .zero, size: size))
            win.contentView = stage
            win.orderFrontRegardless()
            let base = size.height * 0.105
            var frames: [CGImage] = []
            let t0 = Date()
            let dt = 0.12
            var lastIndex = -2
            var lastIdleF = false
            for _ in 0..<36 {
                let songT = start + Date().timeIntervalSince(t0)
                let idx = lyrics.wordIndex(at: songT) ?? -1
                // Same idle rule as the engine (intro, breaks, outro).
                let ws = lyrics.words
                let idle: Bool = idx >= 0
                    ? songT > ws[idx].end + 3.5 && (idx + 1 < ws.count ? ws[idx + 1].start : .infinity) - songT > 2.5
                    : (ws.first.map { $0.start - songT > 2.5 } ?? false)
                if idx != lastIndex || idle != lastIdleF {
                    stage.update(lyrics: lyrics, index: idx, style: style, palette: engine.palette,
                                 fonts: FontPair(english: engine.englishFont, arabic: engine.arabicFont),
                                 emoji: engine.emojiOn ? engine.emoji : [:], base: base, centerFromTop: 0.5, idle: idle,
                                 trackID: "film-\(style.rawValue)", now: songT, playing: true,
                                 script: engine.script, profile: engine.profile,
                                 title: engine.player.track?.title ?? "", artist: engine.player.track?.artist ?? "")
                    lastIndex = idx
                    lastIdleF = idle
                }
                RunLoop.main.run(until: Date().addingTimeInterval(dt))
                CATransaction.flush()
                guard let pres = stage.layer?.presentation() else { continue }
                let ctx = CGContext(data: nil, width: Int(size.width / 2), height: Int(size.height / 2), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(win.backgroundColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                ctx.scaleBy(x: 0.5, y: 0.5)
                pres.render(in: ctx)
                if let img = ctx.makeImage() { frames.append(img) }
            }
            // Contact sheet: 6 × 6 frames, 0.12 s apart.
            let cols = 6, fw = size.width / 2, fh = size.height / 2
            let rows = Int(ceil(Double(frames.count) / Double(cols)))
            let sheet = CGContext(data: nil, width: Int(fw) * cols, height: Int(fh) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (k, f) in frames.enumerated() {
                sheet.draw(f, in: CGRect(x: CGFloat(k % cols) * fw, y: CGFloat(rows - 1 - k / cols) * fh, width: fw, height: fh))
            }
            if let img = sheet.makeImage() {
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("film-\(style.rawValue).jpg")
                try? NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.write(to: url)
                print("wrote", url.lastPathComponent, frames.count, "frames")
            }
        }
    }
}

@MainActor
enum MenuShot {
    static func run(out: String, more: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let engine = Engine()
        engine.start()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        if more { UserDefaults.standard.set(true, forKey: "menushotMore") }
        let host = NSHostingView(rootView: MenuView().environmentObject(engine).environmentObject(engine.prefs))
        let size = host.fittingSize
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let fx = NSVisualEffectView(frame: CGRect(origin: .zero, size: size)); fx.material = .popover; fx.state = .active
        host.frame = fx.bounds; fx.addSubview(host)
        w.contentView = fx; w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let rep = fx.bitmapImageRepForCachingDisplay(in: fx.bounds) else { return }
        fx.cacheDisplay(in: fx.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print("wrote", out, size)
    }
}

@MainActor
enum TransitionFilm {
    static func run(outDir: String) {
        _ = NSApplication.shared
        let engine = Engine()
        engine.start()
        let deadline = Date().addingTimeInterval(20)
        while engine.artCloud == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let w = 1440, h = 900
        let wallURL = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let wall = wallURL.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if ProcessInfo.processInfo.environment["WL_LIVE"] != nil { live(engine: engine, outDir: outDir, wall: wall); return }
        for (name, phase) in [("on", Engine.WallpaperPhase.entering), ("off", .leaving)] {
            let times = stride(from: 0.0, through: 1.8, by: 0.15).map { $0 }
            let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w / 3 * 4, pixelsHigh: h / 3 * ((times.count + 3) / 4), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let sc = NSGraphicsContext(bitmapImageRep: sheet)!.cgContext
            for (i, t) in times.enumerated() {
                let v = WallpaperLayerView(frame: CGRect(x: 0, y: 0, width: w, height: h))
                let win = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = v
                win.orderFrontRegardless()
                v.apply(clouds: engine.artCloud, palette: engine.palette, mood: engine.mood, dim: engine.prefs.dim, glowY: engine.prefs.verticalPosition)
                v.layout()
                v.transition(phase: phase == .entering ? .off : .live, id: 0, art: nil)
                v.transition(phase: phase, id: 1, art: engine.player.artwork)
                CATransaction.flush()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                defer { win.orderOut(nil) }
                guard let img = v.still(at: t)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let cell = CGRect(x: (i % 4) * w / 3, y: sheet.pixelsHigh - (i / 4 + 1) * h / 3, width: w / 3, height: h / 3)
                if let wall { sc.draw(wall, in: cell) } else { sc.setFillColor(gray: 0.5, alpha: 1); sc.fill(cell) }
                sc.draw(img, in: cell)
            }
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("transition-\(name).jpg")
            try? sheet.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: url)
            print("wrote", url.path)
        }
    }

    /// Real-time capture of the window (masks, blur and 3D included) while the transition plays.
    static func live(engine: Engine, outDir: String, wall: CGImage?) {
        let w = 1440, h = 900
        let v = WallpaperLayerView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear
        // Wallpaper level, behind every app window; click-through.
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        win.ignoresMouseEvents = true
        win.contentView = v
        win.orderFrontRegardless()
        v.apply(clouds: engine.artCloud, palette: engine.palette, mood: engine.mood, dim: engine.prefs.dim, glowY: engine.prefs.verticalPosition)
        v.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        for (name, phase, start) in [("on", Engine.WallpaperPhase.entering, Engine.WallpaperPhase.off), ("off", .leaving, .live)] {
            v.transition(phase: start, id: name == "on" ? 0 : 10, art: nil)
            if name == "off" { v.transition(phase: .live, id: 11, art: nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            var frames: [CGImage] = []
            var done = false
            Task { @MainActor in
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let scw = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) }) else { print("no SC window"); done = true; return }
                let filter = SCContentFilter(desktopIndependentWindow: scw)
                let cfg = SCStreamConfiguration(); cfg.width = w / 3; cfg.height = h / 3; cfg.showsCursor = false
                v.transition(phase: phase, id: name == "on" ? 1 : 12, art: engine.player.artwork)
                let t0 = Date()
                for k in 0..<13 {
                    while Date().timeIntervalSince(t0) < Double(k) * 0.15 { try? await Task.sleep(nanoseconds: 5_000_000) }
                    do { frames.append(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)) } catch { if k == 0 { print("capture error:", error) } }
                }
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let cw = w / 3, ch = h / 3
            let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw * 4, pixelsHigh: ch * 4, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let sc = NSGraphicsContext(bitmapImageRep: sheet)!.cgContext
            for (i, f) in frames.enumerated() {
                let cell = CGRect(x: (i % 4) * cw, y: sheet.pixelsHigh - (i / 4 + 1) * ch, width: cw, height: ch)
                if let wall { sc.draw(wall, in: cell) }
                sc.draw(f, in: cell)
            }
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("live-\(name).jpg")
            try? sheet.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: url)
            print("wrote", url.path, frames.count, "frames")
        }
    }
}

/// Menu-bar icon: the logo's ring with three lyric lines, as a template so it follows the menu bar's colour.
enum MenuIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.6, dy: 1.6))
            ring.lineWidth = 1.7
            NSColor.black.setStroke(); ring.stroke()
            func line(_ y: CGFloat, _ w: CGFloat, _ a: CGFloat) {
                NSColor.black.withAlphaComponent(a).setFill()
                NSBezierPath(roundedRect: NSRect(x: c.x - 3.6, y: c.y + y - 0.8, width: w, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            }
            line(2.6, 5, 0.55); line(0, 7.4, 1); line(-2.6, 4, 0.55)
            return true
        }
        img.isTemplate = true
        return img
    }()
}
