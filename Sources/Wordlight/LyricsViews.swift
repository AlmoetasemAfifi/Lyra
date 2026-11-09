import SwiftUI

/// Desktop: live wallpaper + lyrics + now-playing card. Sits behind all windows.
struct DesktopRoot: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var window: WindowState
    let isPrimary: Bool

    var body: some View {
        // Covered by apps, locked, or switched off: draw nothing and animate nothing.
        let live = engine.desktopVisible && window.onScreen && !engine.lock.isLocked
        GeometryReader { geo in
            ZStack {
                Background(active: live, transitions: isPrimary)
                if live && isPrimary && prefs.desktopLyrics {
                    LyricsLayer(size: geo.size, scale: 0.85)
                        .opacity(engine.phase == .live ? 1 : 0)
                        .animation(.easeInOut(duration: engine.phase == .live ? 0.7 : 0.3), value: engine.phase)
                }
            }
            .opacity(engine.desktopVisible ? 1 : 0)
            // The cover transition handles its own fade on the main screen.
            .animation(isPrimary && engine.phase != .live ? nil : .easeInOut(duration: 0.9), value: engine.desktopVisible)
        }
        .ignoresSafeArea()
    }
}

/// Lock screen: the same live wallpaper, a clock, and the lyrics.
struct LockRoot: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Background(active: engine.lockVisible)
                if engine.lockVisible {
                    if prefs.lockClock {
                        LockClock().position(x: geo.size.width / 2, y: geo.size.height * 0.17)
                    }
                    LyricsLayer(size: geo.size, scale: 1)
                }
            }
            .opacity(engine.lockVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: engine.lockVisible)
        }
        .ignoresSafeArea()
    }
}

/// The live wallpaper, or a pre-rendered still when making snapshots.
struct Background: View {
    @EnvironmentObject var engine: Engine
    var active: Bool
    var transitions = false
    var body: some View {
        if let still = engine.snapshotBackground {
            Image(nsImage: still).resizable()
        } else {
            WallpaperView(active: active, transitions: transitions)
        }
    }
}

struct LyricsLayer: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        let base = size.height * 0.105 * prefs.textSize * scale
        if engine.lyrics == nil, engine.lyricsState == .notFound, let t = engine.player.track {
            // No lyrics anywhere: show the song itself; the wallpaper still booms on the beat.
            VStack(spacing: base * 0.12) {
                Text(t.title).font(Font(LyricFonts.font(for: t.title, english: engine.englishFont, arabic: engine.arabicFont, size: base * 0.75))).foregroundStyle(engine.palette.lyric)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5)
                Text(t.artist).font(Font(LyricFonts.font(for: t.artist, english: engine.englishFont, arabic: engine.arabicFont, size: base * 0.32))).foregroundStyle(engine.palette.highlight)
                    .lineLimit(1)
            }
            .frame(maxWidth: size.width * 0.8)
            .shadow(color: .black.opacity(0.35), radius: base * 0.12)
            .position(x: size.width / 2, y: size.height * prefs.verticalPosition)
            .transition(.opacity)
        }
        if let lyrics = engine.lyrics, engine.snapshotBackground == nil {
            CALyricsView(lyrics: lyrics, base: base)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// True when the first strong letter of the line is from a right-to-left script.
func isRTL(_ words: ArraySlice<LyricWord>) -> Bool {
    for w in words {
        for u in w.text.unicodeScalars where u.properties.isAlphabetic {
            let v = u.value
            return (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
        }
    }
    return false
}

