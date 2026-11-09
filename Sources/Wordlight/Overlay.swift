import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

/// Private SkyLight (window server) calls that put a window into a space shown above the lock screen.
/// They're undocumented and may change between macOS releases, so everything is looked up dynamically
/// and fails soft: if a symbol is missing, the overlay still works while the Mac is unlocked.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static var space: UInt64 = 0

    /// Lock-screen space level. Override with `defaults write com.almotasem.wordlight skylightLevel -int N`.
    static var level: Int32 {
        let v = UserDefaults.standard.integer(forKey: "skylightLevel")
        return v == 0 ? 400 : Int32(v)
    }

    @discardableResult
    static func moveToLockScreenSpace(_ window: NSWindow) -> Bool {
        guard let mainConn = sym("SLSMainConnectionID", as: MainConnectionID.self),
              let create = sym("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = sym("SLSShowSpaces", as: ShowSpaces.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsAndRemoveFromSpaces.self)
        else { NSLog("Wordlight: SkyLight symbols unavailable"); return false }

        let cid = mainConn()
        if space == 0 {
            space = create(cid, 1, nil)
            _ = setLevel(cid, space, level)
            _ = show(cid, [NSNumber(value: space)] as CFArray)
        }
        let r = add(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        NSLog("Wordlight: lock-screen space \(space) level \(level) add=\(r)")
        return space != 0
    }
}

/// Tracks whether the screen is locked.
@MainActor
final class LockMonitor: ObservableObject {
    @Published private(set) var isLocked = false

    init() {
        isLocked = Self.queryLocked()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isLocked = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isLocked = false }
        }
    }

    static func queryLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? ((dict["CGSSessionScreenIsLocked"] as? Int) == 1)
    }
}

/// Holds a "don't let the display sleep" assertion while lyrics are on screen.
final class DisplayAwake {
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    func set(_ on: Bool) {
        if on == held { return }
        if on {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Lyra is showing lyrics" as CFString, &id) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(id)
            held = false
        }
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Per-window visibility, so hidden/covered windows stop animating.
@MainActor
final class WindowState: ObservableObject {
    @Published var onScreen = true
}

/// Owns the desktop wallpaper windows (one per display, behind all apps and desktop icons)
/// and the lock-screen window (in a SkyLight space above the lock screen).
@MainActor
final class WallpaperController {
    private let engine: Engine
    private var desktop: [(OverlayWindow, WindowState)] = []
    private var lockWindow: OverlayWindow?
    private var cardPanel: CardPanel?
    private var observers: [NSObjectProtocol] = []
    private var lockSub: AnyCancellable?

    init(engine: Engine) {
        self.engine = engine
        rebuildDesktop()
        buildLock()
        buildCard()
        // The lock-screen window only exists while the Mac is locked. Left up all the time, its
        // full-screen (invisible) window sits above the desktop and stops macOS's "click wallpaper
        // to reveal desktop" from working.
        lockSub = engine.lock.$isLocked.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] locked in
            self?.setLockWindow(visible: locked)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildDesktop(); self?.repositionLock(); self?.positionCard() }
        })
        // Spaces switches can drop desktop-level windows; re-assert them.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.desktop.forEach { $0.0.orderFrontRegardless() } }
        })
    }

    private static func isBuiltIn(_ s: NSScreen) -> Bool {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
    }

    private var primaryScreen: NSScreen? {
        NSScreen.screens.first(where: Self.isBuiltIn) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func makeWindow(_ frame: CGRect, level: NSWindow.Level) -> OverlayWindow {
        let w = OverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        return w
    }

    private func rebuildDesktop() {
        desktop.forEach { $0.0.orderOut(nil) }
        desktop.removeAll()
        // Desktop level: above the system wallpaper, below desktop icons and every app window.
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        let primary = primaryScreen
        for screen in NSScreen.screens {
            let w = makeWindow(screen.frame, level: level)
            let state = WindowState()
            let root = DesktopRoot(isPrimary: screen == primary)
                .environmentObject(engine).environmentObject(engine.prefs).environmentObject(state)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            host.autoresizingMask = [.width, .height]
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            let isPrimary = screen == primary
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak w, weak state, weak engine] _ in
                Task { @MainActor in
                    let visible = w?.occlusionState.contains(.visible) ?? true
                    state?.onScreen = visible
                    if isPrimary { engine?.desktopOnScreen = visible }
                }
            }
            desktop.append((w, state))
        }
    }

    private func buildLock() {
        guard let screen = primaryScreen else { return }
        let w = makeWindow(screen.frame, level: .screenSaver)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.canBecomeVisibleWithoutLogin = true
        let host = NSHostingView(rootView: LockRoot().environmentObject(engine).environmentObject(engine.prefs))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        SkyLight.moveToLockScreenSpace(w)
        lockWindow = w
    }

    /// The song card lives in its own small window just above the desktop icons (still below
    /// every app window), so it can be clicked even though the wallpaper itself is click-through.
    private func buildCard() {
        let p = CardPanel(contentRect: CGRect(origin: .zero, size: CardLayout.size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = FirstClickHostingView(rootView: AnyView(CardWindowRoot().environmentObject(engine).environmentObject(engine.prefs)))
        cardPanel = p
        positionCard()
        p.orderFrontRegardless()
    }

    private func positionCard() {
        guard let p = cardPanel, let screen = primaryScreen else { return }
        p.setFrame(CGRect(x: screen.frame.minX + CardLayout.origin.x, y: screen.frame.minY + CardLayout.origin.y,
                          width: CardLayout.size.width, height: CardLayout.size.height), display: true)
    }

    private func repositionLock() {
        guard let w = lockWindow, let screen = primaryScreen else { return }
        w.setFrame(screen.frame, display: true)
        if engine.lock.isLocked { w.orderFrontRegardless() }
    }

    private func setLockWindow(visible: Bool) {
        guard let w = lockWindow else { return }
        if visible {
            if let screen = primaryScreen { w.setFrame(screen.frame, display: true) }
            w.orderFrontRegardless()
            SkyLight.moveToLockScreenSpace(w)
        } else {
            w.orderOut(nil)
        }
    }
}

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets a click on the card work immediately, without first activating Wordlight.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
