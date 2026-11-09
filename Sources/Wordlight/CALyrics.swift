import AppKit
import SwiftUI

/// Lyrics, drawn by one of the Core Animation scenes in `Scenes.swift`.
struct CALyricsView: View {
    @EnvironmentObject var engine: Engine
    let lyrics: Lyrics
    let base: CGFloat
    var body: some View { CALyricsLayers(lyrics: lyrics, base: base, clock: engine.clock) }
}

private struct CALyricsLayers: NSViewRepresentable {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    let lyrics: Lyrics
    let base: CGFloat
    @ObservedObject var clock: LyricClock

    func makeNSView(context: Context) -> LyricStage { LyricStage() }

    func updateNSView(_ v: LyricStage, context: Context) {
        v.update(lyrics: lyrics, index: clock.index, style: engine.lyricStyle, palette: engine.palette,
                 fonts: FontPair(english: engine.englishFont, arabic: engine.arabicFont),
                 emoji: engine.emojiOn ? engine.emoji : [:], base: base,
                 centerFromTop: prefs.verticalPosition, idle: clock.idle,
                 trackID: engine.player.track?.id ?? "", now: engine.time(), playing: engine.player.isPlaying,
                 script: engine.script, profile: engine.profile,
                 title: engine.displayTrack?.title ?? "", artist: engine.displayTrack?.artist ?? "")
    }
}

struct FontPair: Equatable {
    var english: EnglishFont = .system
    var arabic: ArabicFont = .geeza
    func font(_ size: CGFloat) -> NSFont { LyricFonts.font(english: english, arabic: arabic, size: size) }
    func font(for text: String, _ size: CGFloat) -> NSFont { LyricFonts.font(for: text, english: english, arabic: arabic, size: size) }
    var key: String { english.rawValue + "/" + arabic.rawValue }
}

/// Hosts the active scene. Rebuilds it when the song, style, fonts, colours or size change.
final class LyricStage: NSView {
    private let host = CALayer()
    private var scene: LyricScene?
    private var key = ""
    private var lastIndex = Int.min
    private var lastIdle = false
    private var overlay: StageOverlay?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layerUsesCoreImageFilters = true   // Focus uses a real blur
        host.actions = ["sublayers": NSNull(), "opacity": NSNull(), "sublayerTransform": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(host)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(lyrics: Lyrics, index: Int, style: DisplayStyle, palette: Palette, fonts: FontPair,
                emoji: [Int: String], base: CGFloat, centerFromTop: Double, idle: Bool, trackID: String,
                now: Double = 0, playing: Bool = true, script: SongScript? = nil, profile: SongProfile = SongProfile(),
                title: String = "", artist: String = "") {
        host.frame = bounds
        let k = "\(trackID)|\(script?.id ?? "-")|\(style.rawValue)|\(fonts.key)|\(emoji.count)|\(Int(base))|\(palette.lyric.hexString)\(palette.highlight.hexString)|\(Int(bounds.width))x\(Int(bounds.height))|\(centerFromTop)"
        if k != key, bounds.width > 10 {
            key = k
            host.sublayers?.forEach { $0.removeFromSuperlayer() }
            host.sublayerTransform = CATransform3DIdentity
            host.mask = nil
            let center = CGPoint(x: bounds.midX, y: bounds.height * (1 - CGFloat(centerFromTop)))
            let ctx = SceneContext(host: host, bounds: bounds, center: center, base: base, palette: palette, fonts: fonts,
                                   emoji: emoji, lyrics: lyrics, scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
            scene = Self.make(style, ctx, script: script, profile: profile)
            overlay?.layer.removeFromSuperlayer()
            let o = StageOverlay(ctx: SceneContext(host: host, bounds: bounds, center: center, base: base, palette: palette, fonts: fonts,
                                                   emoji: [:], lyrics: lyrics, scale: ctx.scale))
            layer?.addSublayer(o.layer)
            overlay = o
            lastIndex = Int.min
            lastIdle = false
            host.opacity = 1
            if !idle { animate(host, "opacity", from: 0, to: 1, dur: 0.6, curve: Curve.expoOut, name: "songFade") }
        }
        // Nobody singing: title card (intro/outro) or breathing dots (instrumental break) over a dimmed scene.
        let words = lyrics.words
        let mode: StageOverlay.Mode
        var gap = 0.0
        if !idle || words.isEmpty { mode = .none }
        else if index < 0 { mode = .intro; gap = words[0].start - 2.5 - now }
        else if index >= words.count - 1 { mode = .outro }
        else { mode = .interlude; gap = words[index + 1].start - 2.5 - now }
        if let overlay, mode != overlay.mode {
            let animated = lastIndex != Int.min || mode == .intro
            overlay.set(mode, title: title, artist: artist, gap: gap, animated: animated)
            let target: Float = mode == .none ? 1 : (mode == .interlude ? 0.1 : 0)
            if lastIndex == Int.min && mode != .none {
                host.removeAnimation(forKey: "songFade")   // straight into the card, no flash of lyrics
            } else {
                animate(host, "opacity", from: nil, to: target, dur: mode == .none ? 0.7 : 0.6, curve: Curve.soft, name: "idleFade")
            }
            host.opacity = target
        }
        lastIdle = idle
        guard let scene, index != lastIndex else { return }
        CATransaction.begin()
        scene.show(index: index, now: now, playing: playing, animated: lastIndex != Int.min)
        CATransaction.commit()
        lastIndex = index
    }

    static func make(_ style: DisplayStyle, _ ctx: SceneContext, script: SongScript?, profile: SongProfile) -> LyricScene {
        let gritty = [.rap, .mahraganat, .dance].contains(profile.kind)
        switch style {
        case .director, .auto:
            if let script { return DirectorScene(ctx: ctx, script: script, profile: profile) }
            return ListScene(ctx: ctx, config: ListScene.scroll)
        case .glow: return ListScene(ctx: ctx, config: ListScene.scroll)
        case .spotlight: return ListScene(ctx: ctx, config: ListScene.spotlight)
        case .focus: return FocusScene(ctx: ctx)
        case .depth: return DepthScene(ctx: ctx)
        case .marker: return MarkerScene(ctx: ctx)
        case .ribbon: return RibbonScene(ctx: ctx, script: script)
        case .constellation: return ConstellationScene(ctx: ctx, script: script)
        case .motion: return MotionScene(ctx: ctx, script: script, gritty: gritty)
        case .neon: return NeonTubeScene(ctx: ctx)
        case .poster: return FlashScene(ctx: ctx, script: script)
        case .brush: return BrushStackScene(ctx: ctx, script: script)
        case .lens: return LensScene(ctx: ctx)
        }
    }
}
