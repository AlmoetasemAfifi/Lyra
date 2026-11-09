import AppKit
import ServiceManagement
import SwiftUI

/// The menu-bar panel. The everyday choices sit up front as big, tappable tiles;
/// everything fiddly lives under "More settings".
struct MenuView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @State private var showMore = UserDefaults.standard.bool(forKey: "menushotMore")

    /// Selections pick up the album's colour, so the panel matches the song.
    private var tint: Color { engine.artPalette?.highlight ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if engine.player.track != nil, engine.lyricsState == .ready { syncRow }
            Group {
                section("Show on") { placesRow }
                section("Lyrics style") { styles }
                section("Beat") { beatPicker }
                section("Text size") { sizeSlider }
                moreSettings
            }
            .disabled(!prefs.enabled)
            .opacity(prefs.enabled ? 1 : 0.4)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .tint(tint)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showMore)
        .animation(.easeOut(duration: 0.2), value: prefs.style)
    }

    // MARK: Now playing

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                if let art = engine.player.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.secondary.opacity(0.25), .secondary.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: tint.opacity(engine.player.artwork == nil ? 0 : 0.45), radius: 10, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                if let t = engine.player.track {
                    Text(t.title).font(.headline).lineLimit(1)
                    Text(t.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    status
                } else {
                    Text("Nothing playing").font(.headline)
                    Text(engine.player.permissionProblem ?? "Play a song in Apple Music or Spotify.")
                        .font(.caption).foregroundStyle(engine.player.permissionProblem == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $prefs.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(prefs.enabled ? "Turn Lyra off" : "Turn Lyra on")
        }
    }

    @ViewBuilder private var status: some View {
        switch engine.lyricsState {
        case .loading:
            Label("Finding lyrics…", systemImage: "ellipsis").font(.caption2).foregroundStyle(.secondary)
        case .notFound:
            HStack(spacing: 6) {
                Label("No synced lyrics", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Button("Retry") { engine.reloadLyrics() }.buttonStyle(.link)
            }.font(.caption2)
        case .ready:
            Label(engine.lyrics?.wordSynced == true ? "Word-synced lyrics" : "Line-synced lyrics", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    // MARK: Per-song sync

    /// Quick fix when a song's lyrics run ahead or behind; remembered for that song.
    private var syncRow: some View {
        let off = engine.songOffset
        return HStack(spacing: 8) {
            Image(systemName: "metronome").foregroundStyle(.secondary).font(.caption)
            Text(off == 0 ? "Lyrics timing" : String(format: off > 0 ? "Lyrics %.1fs earlier" : "Lyrics %.1fs later", abs(off)))
                .font(.caption).foregroundStyle(off == 0 ? .secondary : .primary)
            Spacer()
            Button { engine.nudgeSong(-0.1) } label: { Label("Later", systemImage: "minus") }
                .help("Lyrics are early: show them later")
            Button { engine.nudgeSong(0.1) } label: { Label("Earlier", systemImage: "plus") }
                .help("Lyrics are late: show them earlier")
            if off != 0 {
                Button { engine.resetSongOffset() } label: { Image(systemName: "arrow.uturn.backward") }.help("Reset")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Where it shows

    private var placesRow: some View {
        HStack(spacing: 6) {
            Tile(icon: "menubar.dock.rectangle", title: "Desktop", on: $prefs.desktopWallpaper, tint: tint)
            Tile(icon: "lock.rectangle", title: "Lock", on: $prefs.lockWallpaper, tint: tint)
            Tile(icon: "quote.bubble", title: "Lyrics", on: $prefs.desktopLyrics, tint: tint)
            Tile(icon: "rectangle.dashed", title: "Ring light", on: $prefs.ringLight, tint: tint)
        }
    }

    // MARK: Lyrics style

    private static let manual: [DisplayStyle] = [.glow, .spotlight, .focus, .depth, .marker, .ribbon, .constellation, .motion, .neon, .poster, .brush, .lens]

    private var isAuto: Bool { prefs.style == .auto || prefs.style == .director }

    private var styles: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Auto, the recommended choice, gets the big button.
            Button { prefs.style = .auto } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.title3)
                        .frame(width: 30)
                        .foregroundStyle(isAuto ? tint : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto").font(.body.weight(.semibold))
                        Text(autoLine).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if isAuto { Image(systemName: "checkmark.circle.fill").foregroundStyle(tint) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(chip(selected: isAuto))
                .contentShape(Rectangle())
            }
            .buttonStyle(Press())

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.manual) { s in
                    Button { prefs.style = s } label: {
                        VStack(spacing: 4) {
                            Image(systemName: Self.icon(s)).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(prefs.style == s ? tint : .primary.opacity(0.75))
                                .frame(height: 18)
                            Text(s.rawValue).font(.caption2.weight(prefs.style == s ? .semibold : .regular)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(chip(selected: prefs.style == s))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Press())
                    .help(s.blurb)
                }
            }
            if !isAuto {
                Text(prefs.style.blurb).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private var autoLine: String {
        if engine.player.track != nil, engine.script != nil {
            let kind = engine.autoChoice.reason.components(separatedBy: ",").first ?? ""
            return "Made for this song (\(kind)), with a new look each section"
        }
        return "Picks the best look for each song, section by section"
    }

    private static func icon(_ s: DisplayStyle) -> String {
        switch s {
        case .auto, .director: return "sparkles"
        case .glow: return "sun.max"
        case .spotlight: return "light.overhead.right"
        case .focus: return "camera.aperture"
        case .depth: return "square.stack.3d.down.forward"
        case .marker: return "highlighter"
        case .ribbon: return "text.line.first.and.arrowtriangle.forward"
        case .constellation: return "point.3.connected.trianglepath.dotted"
        case .motion: return "wind"
        case .neon: return "lightbulb.max"
        case .poster: return "textformat.size.larger"
        case .brush: return "paintbrush.pointed"
        case .lens: return "circle.circle"
        }
    }

    // MARK: Beat

    private enum Beat: String, CaseIterable { case off = "Off", soft = "Soft", normal = "Normal", strong = "Strong"
        var amount: Double { switch self { case .off: 0; case .soft: 0.5; case .normal: 1.0; case .strong: 1.6 } }
    }

    private var beat: Binding<Beat> {
        Binding(get: {
            guard prefs.audioReactive else { return .off }
            return [Beat.soft, .normal, .strong].min { abs($0.amount - prefs.intensity) < abs($1.amount - prefs.intensity) } ?? .normal
        }, set: { b in
            if b == .off { prefs.audioReactive = false } else { prefs.audioReactive = true; prefs.intensity = b.amount }
        })
    }

    @ViewBuilder private var beatPicker: some View {
        Picker("Beat", selection: beat) {
            ForEach(Beat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(maxWidth: .infinity)
        if let err = engine.audioError, prefs.audioReactive {
            Text(err).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
            Slider(value: $prefs.textSize, in: 0.5...1.8)
            Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
        }
    }

    // MARK: More

    private var moreSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showMore.toggle() } label: {
                HStack {
                    Text("More settings").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                MoreSettings(tint: tint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(prefs.enabled ? "Lyra is on" : "Lyra is off").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q").controlSize(.small)
        }
        .padding(.top, 2)
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func chip(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? tint.opacity(0.18) : Color.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? tint.opacity(0.7) : .clear, lineWidth: 1.2))
    }
}

/// A big on/off tile, like Control Center.
private struct Tile: View {
    let icon: String
    let title: String
    @Binding var on: Bool
    let tint: Color
    var body: some View {
        Button { on.toggle() } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(on ? Color.white : .primary.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(on ? tint : Color.primary.opacity(0.1)))
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
                Text(on ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .animation(.easeOut(duration: 0.18), value: on)
    }
}

/// A label on the left, a small switch lined up on the right.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// Buttons sink a little when pressed.
private struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The fine-tuning, grouped into small labelled cards.
private struct MoreSettings: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    let tint: Color
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card("Ring light") {
                row("Glow") { Slider(value: $prefs.ringStrength, in: 0...1) }
                Text("A light around the screen edges in the song's colours. It pulses on beats and sweeps round on each new line.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card("App") {
                SwitchRow("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 58, alignment: .leading)
            content()
        }
    }

}
