import AppKit
import ServiceManagement
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let socketPath = NSHomeDirectory() + "/Library/Application Support/Dott/dott.sock"

    private let model = IslandModel()
    private var screens: ScreenManager?
    private let server = EventServer(path: AppDelegate.socketPath)
    private var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    private var diagnosticsItem: NSMenuItem?
    private let music = MusicWatcher()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Una sola istanza: due Dott si contenderebbero il socket.
        let me = NSRunningApplication.current
        if let id = me.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }

        screens = ScreenManager(model: model)

        server.onMessage = { [weak self] conn, payload in
            MainActor.assumeIsolated { self?.model.receive(payload, from: conn) }
        }
        do {
            try server.start()
        } catch {
            NSLog("Dott: impossibile aprire il socket: \(error.localizedDescription)")
        }

        buildMenu()

        // Musica: se sta suonando, Dott balla.
        music.onChange = { [weak self] playing in
            MainActor.assumeIsolated { if self?.model.musicPlaying != playing { self?.model.musicPlaying = playing } }
        }
        music.start()

        // Scorciatoie globali: si accendono e si spengono dalle impostazioni.
        HotKeys.shared.apply(enabled: AppSettings.shared.globalShortcuts, model: model)
        AppSettings.shared.$globalShortcuts
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                MainActor.assumeIsolated { HotKeys.shared.apply(enabled: on, model: self.model) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: Notification.Name("dott.openSettings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: menu nella barra

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "smallcircle.filled.circle", accessibilityDescription: "Dott")
        statusItem = item

        let menu = NSMenu()
        let title = NSMenuItem(title: "Dott", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let preview = NSMenuItem(title: "Prova gli stati", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mood in Mood.allCases {
            let mi = NSMenuItem(title: mood.title, action: #selector(previewMood(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mood.rawValue
            sub.addItem(mi)
        }
        preview.submenu = sub
        menu.addItem(preview)

        let dock = NSMenuItem(title: "Riporta Dott nel notch", action: #selector(dockCompanion), keyEquivalent: "")
        dock.target = self
        menu.addItem(dock)

        let diag = NSMenuItem(title: "Diagnostica", action: nil, keyEquivalent: "")
        diag.submenu = NSMenu()
        diag.submenu?.delegate = self
        diagnosticsItem = diag
        menu.addItem(diag)

        let gestures = NSMenuItem(title: "Prova i gesti", action: nil, keyEquivalent: "")
        let gsub = NSMenu()
        let names: [GestureKind: String] = [.nod: "Cenno", .tilt: "Testa inclinata", .sigh: "Sospiro", .giggle: "Risatina",
                                            .hop: "Saltello", .spin: "Giravolta", .wave: "Saluto", .purr: "Fusa",
                                            .stretch: "Stiracchiata", .peek: "Sguardo in giro",
                                            .sneeze: "Starnuto", .whistle: "Fischietto", .chase: "Lucciola"]
        for k in GestureKind.allCases {
            let mi = NSMenuItem(title: names[k] ?? "\(k)", action: #selector(previewGesture(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = "\(k)"
            gsub.addItem(mi)
        }
        gestures.submenu = gsub
        menu.addItem(gestures)

        let q = NSMenuItem(title: "Prova una domanda", action: #selector(previewQuestion), keyEquivalent: "")
        q.target = self
        menu.addItem(q)
        let helpers = NSMenuItem(title: "Prova gli aiutanti", action: #selector(previewAgents), keyEquivalent: "")
        helpers.target = self
        menu.addItem(helpers)

        let broom = NSMenuItem(title: "Prova la scopa (compattazione)", action: #selector(previewCompact), keyEquivalent: "")
        broom.target = self
        menu.addItem(broom)

        let settingsItem = NSMenuItem(title: "Impostazioni…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let sounds = NSMenuItem(title: "Suoni", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        sounds.target = self
        sounds.state = Sounds.enabled ? .on : .off
        menu.addItem(sounds)

        let login = NSMenuItem(title: "Apri al login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Esci da Dott", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func previewMood(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mood = Mood(rawValue: raw) else { return }
        model.preview(mood)
    }

    @objc private func dockCompanion() { DesktopCompanion.shared.dock() }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Impostazioni di Dott"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func previewGesture(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let kind = GestureKind.allCases.first(where: { "\($0)" == name }) else { return }
        model.trigger(kind)
    }

    @objc private func previewQuestion() { model.previewQuestion() }
    @objc private func previewAgents() { model.previewAgents() }
    @objc private func previewCompact() { model.previewCompact() }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        Sounds.enabled.toggle()
        sender.state = Sounds.enabled ? .on : .off
        if Sounds.enabled { Sounds.play(.sent) }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Dott: login item: \(error.localizedDescription)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

extension AppDelegate {
    /// Il sottomenu "Diagnostica" si riempie quando lo apri: quanti eventi di ogni tipo sono arrivati.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === diagnosticsItem?.submenu else { return }
        menu.removeAllItems()
        let counts = model.eventCounts.sorted { $0.key < $1.key }
        if counts.isEmpty {
            let none = NSMenuItem(title: "Nessun evento ricevuto", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (name, n) in counts {
            let mi = NSMenuItem(title: "\(name): \(n)", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Dalla accensione di Dott", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
    }
}
