import AppKit
import Combine
import SwiftUI

/// Dott fuori dall'isola: una finestra piccola che galleggia sul desktop, ti segue con gli occhi
/// e torna al notch da sola quando c'e' qualcosa che richiede te.
final class CompanionState: ObservableObject {
    @Published var center = CGPoint.zero
    @Published var hovering = false
}

private final class CompanionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopCompanion {
    static let shared = DesktopCompanion()
    private let side: CGFloat = 130
    private var panel: NSPanel?
    private var state = CompanionState()
    private weak var model: IslandModel?
    private var followTimer: Timer?
    private var watchTimer: Timer?
    private var dragOffset = CGPoint.zero

    var isOut: Bool { panel != nil }

    /// Esce dall'isola, nel punto in cui e' il cursore, e lo segue finche' tieni premuto il pulsante.
    func detach(model: IslandModel) {
        guard panel == nil else { return }
        self.model = model
        state = CompanionState()
        let p = CompanionPanel()
        let host = NSHostingView(rootView: CompanionView(model: model, state: state, controller: self))
        host.sizingOptions = []
        p.contentView = host
        let m = NSEvent.mouseLocation
        p.setFrame(NSRect(x: m.x - side / 2, y: m.y - side / 2, width: side, height: side), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        panel = p
        model.detached = true
        state.center = CGPoint(x: p.frame.midX, y: p.frame.midY)
        model.trigger(.hop)

        followTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { t.invalidate(); return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    let m = NSEvent.mouseLocation
                    p.setFrameOrigin(NSPoint(x: m.x - self.side / 2, y: m.y - self.side / 2))
                    self.state.center = CGPoint(x: p.frame.midX, y: p.frame.midY)
                } else {
                    t.invalidate()
                }
            }
        }
        RunLoop.main.add(followTimer!, forMode: .common)

        // Se serve la tua attenzione, o ci passi sopra, ci pensa questo controllo.
        watchTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        RunLoop.main.add(watchTimer!, forMode: .common)
    }

    private func watch() {
        guard let model, let p = panel else { return }
        let hover = p.frame.insetBy(dx: 10, dy: 10).contains(NSEvent.mouseLocation)
        if hover != state.hovering { state.hovering = hover }
        let alert = !model.permissions.isEmpty || !model.questions.isEmpty || !model.elicitations.isEmpty || model.mood == .waiting
        if alert { dock() }
    }

    /// Un trascinamento iniziato sulla finestra: la sposta seguendo il cursore.
    func dragBegan() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        dragOffset = CGPoint(x: p.frame.origin.x - m.x, y: p.frame.origin.y - m.y)
    }

    func dragMoved() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: m.x + dragOffset.x, y: m.y + dragOffset.y))
        state.center = CGPoint(x: p.frame.midX, y: p.frame.midY)
    }

    /// Torna nel notch: vola fino al suo posto e si rimpicciolisce.
    func dock(animated: Bool = true) {
        guard let p = panel, let model else { return }
        followTimer?.invalidate(); watchTimer?.invalidate()
        let g = model.geometry
        let cx = g.screenFrame.midX - model.size.width / 2 + IslandModel.topRadius + IslandModel.ear / 2 + 2
        let cy = g.screenFrame.maxY - g.notchHeight / 2
        let target = NSRect(x: cx - 12, y: cy - 12, width: 24, height: 24)
        let finish = { [weak self] in
            p.orderOut(nil)
            self?.panel = nil
            model.detached = false
            model.trigger(.hop)
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 0.2
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        } else {
            finish()
        }
    }
}

private struct CompanionView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var state: CompanionState
    let controller: DesktopCompanion
    @State private var dragging = false

    var body: some View {
        MascotView(mood: model.mood, size: 120, effects: true,
                   gazeFrom: state.center, attentive: state.hovering, following: true,
                   gesture: model.gesture, night: model.night,
                   accessory: model.accessory, outfit: model.outfit,
                   music: model.musicPlaying && AppSettings.shared.danceToMusic)
            .frame(width: 130, height: 130)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { controller.dock() }
            .onTapGesture { model.poke() }
            .onLongPressGesture(minimumDuration: 0.55) { model.trigger(.purr) }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { _ in
                    if !dragging { dragging = true; controller.dragBegan() }
                    controller.dragMoved()
                }
                .onEnded { _ in dragging = false })
            .contextMenu { Button("Riporta nel notch") { controller.dock() } }
    }
}
