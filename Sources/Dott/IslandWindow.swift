import AppKit
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// Di solito la finestra non prende mai la tastiera; la prende solo mentre scrivi una risposta.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    // Il panel deve poter stare sopra la barra dei menu, nel notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Fa funzionare i bottoni anche al primo clic, senza attivare l'app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// L'isola su un singolo schermo: la sua finestra, il controllo del mouse, la tastiera.
@MainActor
final class IslandController {
    let model: IslandModel
    let screenID: UInt32
    let geometry: NotchGeometry
    let panel = IslandPanel()
    private var hoverTimer: Timer?
    private var previousApp: NSRunningApplication?
    private var lastMouse = CGPoint.zero
    private var lastMoved = Date.distantPast
    var onNear: ((UInt32, Bool) -> Void)?

    init(model: IslandModel, screenID: UInt32, geometry: NotchGeometry) {
        self.model = model
        self.screenID = screenID
        self.geometry = geometry

        let ctx = ScreenContext(id: screenID, geometry: geometry)
        let host = FirstMouseHostingView(rootView: IslandView(model: model, screen: ctx))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host
        // Con la finestra sempre alla dimensione massima l'isola si anima dentro
        // uno spazio che non cambia mai: niente stati a meta' tra chiusa e aperta.
        panel.ignoresMouseEvents = true

        // Il passaggio del mouse lo leggiamo noi: SwiftUI non lo vede su un'app che non e' attiva
        // e i monitor globali non sempre scattano. In modalita' .common il controllo non si ferma
        // nemmeno mentre il cursore e' sulla barra dei menu.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer

        place()
        panel.orderFrontRegardless()
    }

    func close() {
        hoverTimer?.invalidate()
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// La finestra: larga e alta quanto l'isola piu' grande, agganciata al bordo alto.
    private func place() {
        let size = CGSize(width: IslandModel.maxIslandWidth, height: geometry.notchHeight + IslandModel.maxBodyHeight)
        let f = geometry.screenFrame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private var expandedHere: Bool { model.isExpanded(on: screenID) }

    private func logicalRect() -> CGRect {
        let f = geometry.screenFrame
        let s = model.computeSize(geometry, expanded: expandedHere)
        return CGRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func updateHover() {
        let r = logicalRect()
        // A isola chiusa il bersaglio e' basso 32 punti: lo allarghiamo (soprattutto verso il basso,
        // da dove arriva il cursore) per non costringere a centrarlo. Da aperta il margine e' minimo,
        // cosi' si richiude appena ti allontani. Il bordo alto dello schermo conta come dentro.
        let m = NSEvent.mouseLocation
        let open = expandedHere
        let side: CGFloat = open ? 4 : 10
        let below: CGFloat = open ? 4 : 18
        let inside = m.x >= r.minX - side && m.x <= r.maxX + side && m.y >= r.minY - below && m.y <= r.maxY + 2
        model.setHover(inside, screen: screenID)

        // Vicino (entro ~400 punti) e mosso di recente: si alza la cadenza dei fotogrammi.
        if hypot(m.x - lastMouse.x, m.y - lastMouse.y) > 0.5 { lastMoved = Date() }
        lastMouse = m
        let center = CGPoint(x: r.midX, y: r.maxY)
        onNear?(screenID, hypot(m.x - center.x, m.y - center.y) < 400 && Date().timeIntervalSince(lastMoved) < 1.2)

        // La finestra riceve il mouse solo sopra l'isola: altrove i clic passano all'app sotto.
        let accepts = inside && open
        if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
    }

    /// Mentre scrivi una risposta libera la finestra prende la tastiera, senza attivare l'app.
    func acquireKeyboard() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        panel.allowKey = true
        panel.makeKey()
    }

    /// Finito, torni dove stavi.
    func releaseKeyboard() {
        panel.allowKey = false
        panel.resignKey()
        previousApp?.activate()
        previousApp = nil
    }

    var screenFrame: CGRect { geometry.screenFrame }
}

/// Decide su quali schermi sta l'isola e ne tiene una per ciascuno.
@MainActor
final class ScreenManager {
    private let model: IslandModel
    private var controllers: [UInt32: IslandController] = [:]
    private var nearMap: [UInt32: Bool] = [:]
    private var keyboardOwner: IslandController?
    private var cancellables = Set<AnyCancellable>()
    private var followTimer: Timer?
    private var debugSignal: DispatchSourceSignal?
    /// Solo per le prove: disegna l'isola con una notch finta anche sullo schermo del Mac.
    private var fakeExternal = false

    static func displayID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    init(model: IslandModel) {
        self.model = model

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshGeometry(); self?.reconcile() }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("dott.fakeExternal"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fakeExternal.toggle(); self?.reconcile(force: true) }
        }
        AppSettings.shared.$displayMode
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
            .store(in: &cancellables)

        // "Segui il cursore": si controlla ogni mezzo secondo su che schermo sei.
        followTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if AppSettings.shared.displayMode == .follow { self?.reconcile() } }
        }
        RunLoop.main.add(followTimer!, forMode: .common)

        // Un solo schermo prende la tastiera, quello dove sei.
        model.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                guard let self else { return }
                if wants {
                    let m = NSEvent.mouseLocation
                    let c = self.controllers.values.first { $0.screenFrame.contains(m) } ?? self.controllers.values.first
                    self.keyboardOwner = c
                    c?.acquireKeyboard()
                } else {
                    self.keyboardOwner?.releaseKeyboard()
                    self.keyboardOwner = nil
                }
            }
            .store(in: &cancellables)

        reconcile()

        // `kill -USR1 <pid di Dott>` salva la vista reale delle finestre in /tmp/dott-live.png (e -2, -3…):
        // serve a controllare l'aspetto dal vivo, visto che lo schermo non si puo' fotografare.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.dumpViews() }
        src.resume()
        debugSignal = src
    }

    private func dumpViews() {
        let ordered = controllers.values.sorted { $0.screenID < $1.screenID }
        for (i, c) in ordered.enumerated() {
            guard let v = c.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let name = i == 0 ? "/tmp/dott-live.png" : "/tmp/dott-live-\(i + 1).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
        }
        // Se c'e' la finestra delle impostazioni, salviamo anche quella.
        if let w = NSApp.windows.first(where: { $0.title == "Impostazioni di Dott" }), let cv = w.contentView,
           let r2 = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: r2)
            try? r2.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dott-settings.png"))
        }
    }

    /// Gli schermi su cui mostrare l'isola, secondo la scelta nelle impostazioni.
    func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard let first = screens.first else { return [] }
        let primary = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? first
        switch AppSettings.shared.displayMode {
        case .primary:
            return [primary]
        case .external:
            // Un solo schermo alla volta: il monitor se c'e' (il primo, se sono piu' d'uno), altrimenti il Mac.
            // Quando il monitor si scollega o si collega, macOS avvisa e l'isola si sposta da sola.
            let ext = screens.filter { CGDisplayIsBuiltin(Self.displayID($0)) == 0 }
            return [ext.first ?? primary]
        case .all:
            return screens
        case .follow:
            let m = NSEvent.mouseLocation
            return [screens.first { $0.frame.contains(m) } ?? primary]
        }
    }

    func reconcile(force: Bool = false) {
        var wanted: [UInt32: (NSScreen, NotchGeometry)] = [:]
        for s in targetScreens() {
            var g = NotchGeometry.forScreen(s)
            if fakeExternal { g = NotchGeometry(screenFrame: s.frame, notchWidth: 150, notchHeight: 30, hasNotch: false) }
            wanted[Self.displayID(s)] = (s, g)
        }
        for (id, c) in controllers where wanted[id] == nil || wanted[id]?.1 != c.geometry || force {
            c.close()
            controllers[id] = nil
            nearMap[id] = nil
            if keyboardOwner === c { keyboardOwner = nil }
        }
        for (id, pair) in wanted where controllers[id] == nil {
            let c = IslandController(model: model, screenID: id, geometry: pair.1)
            c.onNear = { [weak self] sid, near in
                guard let self else { return }
                self.nearMap[sid] = near
                self.model.setCursorNear(self.nearMap.values.contains(true))
            }
            controllers[id] = c
        }
    }
}
