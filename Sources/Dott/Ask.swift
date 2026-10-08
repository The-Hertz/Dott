import AppKit
import ApplicationServices
import Foundation

/// Scrivere a Dott e aprire le chat, senza lavoro parallelo: tutto passa dall'app Claude, che e' dove stanno le chat e la loro storia.
/// "Chiedi a Birba…" apre una chat nuova nella cartella del suo progetto, con la richiesta gia' scritta (la mandi tu).
extension IslandModel {
    /// Il progetto a cui parla il campo: quello in primo piano, altrimenti l'ultimo visto (solo se si sa dove lavorare).
    var commandKey: String? {
        func usable(_ k: String?) -> String? { k.flatMap { folder(for: $0) != nil ? $0 : nil } }
        if let l = lead, let k = usable(Self.projectKey(l)) { return k }
        return usable(lastKey)
    }

    /// La chiave a cui parla un campo: quella data (l'hub sceglie il suo Dott) o il progetto in primo piano.
    func target(_ key: String?) -> String? { key ?? commandKey }

    /// La cartella in cui lavora il Dott: per un gruppo, quella scelta o ricavata; per il Dott libero, l'ultima sessione libera.
    func folder(for key: String) -> String? {
        // Il Manager e gli agenti non hanno un progetto: lavorano da ~/Projects.
        if AgentRegistry.role(forKey: key) != nil { return ProjectResolver.existingDir(NSHomeDirectory() + "/Projects") ?? NSHomeDirectory() }
        return key == DottRoster.freeKey ? ProjectResolver.existingDir(freeCwd) : ProjectResolver.shared.folder(for: key)
    }

    /// Il nome da mostrare per il progetto dei comandi.
    var commandName: String? {
        guard let k = commandKey else { return nil }
        if k == DottRoster.freeKey { return freeCwd.map { ($0 as NSString).lastPathComponent } }
        return ProjectResolver.shared.groupName(k) ?? (k as NSString).lastPathComponent
    }

    /// Il nome proprio del Dott in primo piano (nil se non c'e' nessuna sessione).
    var leadDottName: String? { lead.map { DottRoster.shared.name(for: Self.projectKey($0)) } }

    func dottName(for key: String?) -> String { target(key).map { DottRoster.shared.name(for: $0) } ?? AppSettings.shared.name }

    /// Cambiano i gruppi (o le loro cartelle): le sessioni gia' note si riassegnano, e i Dott nuovi vengono accolti.
    func regroup() {
        let born = DottRoster.shared.ensure(groups: ProjectResolver.shared.groups().map(\.key))
        if let b = born.first {
            let project = ProjectResolver.shared.groupName(b.key) ?? ""
            showRecap([RecapLine(symbol: "sparkles", text: "\(b.name), per \(project)")], title: "Un nuovo Dott!", gesture: .hop)
            Sounds.play(.done)
        }
        for (id, var s) in sessions where !id.hasPrefix("preview") {
            s.reidentify()
            sessions[id] = s
        }
        recompute()
    }

    // MARK: Il campo

    func beginCompose(key: String? = nil) {
        guard target(key) != nil else { return }
        composing = true
        composeIdle = Date()
        recompute()
    }

    func cancelCompose() {
        composing = false
        recompute()
    }

    /// La chat in cui finisce la richiesta: quella che stai usando (la sessione viva del capo progetto), altrimenti la piu' recente.
    /// Per il Manager e per ogni agente e' la loro chat (se c'e'). Una chat la cui cartella non esiste piu' non si puo' continuare:
    /// l'app non fa scrivere.
    func chatTarget(_ key: String?) -> (id: String, title: String)? {
        guard let key = target(key) else { return nil }
        let resolver = ProjectResolver.shared
        let reg = AgentRegistry.shared

        // Il Manager o un agente: la chat piu' recente di quel ruolo (viva prima, poi le altre).
        if let role = AgentRegistry.role(forKey: key) {
            // Una chat appena nata non ha ancora un titolo: conta lo stesso. L'elenco dell'app si rilegge adesso, non fra dieci minuti.
            resolver.refresh()
            let name = role == .manager ? "Chat del Manager" : "Chat del \(role.agentTitle)"
            let ids = reg.sessions(role: role)
            var best: (id: String, title: String, rank: Date)?
            for id in ids {
                let state = resolver.chatState(id)
                if state?.archived == true, sessions[id] == nil { continue }          // archiviata e non viva: non e' piu' la chat in uso
                guard state != nil || sessions[id] != nil else { continue }          // l'app non la conosce (e non e' viva)
                let rank = sessions[id]?.updated ?? state?.activity ?? .distantPast
                if best == nil || rank > best!.rank { best = (id, state?.title ?? name, rank) }
            }
            return best.map { ($0.id, $0.title) }
        }

        func continuable(_ cwd: String?) -> Bool {
            guard let cwd else { return true }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
        }
        // Il capo progetto: le chat senza ruolo.
        let live = sessions.values
            .filter { Self.projectKey($0) == key && resolver.title(for: $0.id) != nil && reg.ref(for: $0.id) == nil }
            .sorted { $0.updated > $1.updated }
        let all = resolver.chats(for: key, limit: 200)
        for s in live {
            if let c = all.first(where: { $0.id == s.id }), continuable(c.cwd) { return (c.id, c.title) }
        }
        if let c = all.first(where: { reg.ref(for: $0.id) == nil && continuable($0.cwd) }) { return (c.id, c.title) }
        return nil
    }

    /// Scrive nella chat in corso (la apre e incolla la richiesta nel suo campo); con `newChat`, o se non c'e' una chat da
    /// continuare, ne apre una nuova: nella cartella del progetto per un capo progetto, in ~/Projects per il Manager e gli
    /// agenti (la cui chat nasce con le loro istruzioni).
    func ask(_ text: String, key given: String? = nil, newChat: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let key = target(given) else { return }
        composing = false
        trigger(.nod)
        // Il Manager e ogni agente hanno una chat sola: "nuova chat" non esiste per loro.
        let single = AgentRegistry.role(forKey: key) != nil
        let chat = (newChat && !single) ? nil : chatTarget(key)
        Self.trace("ask key=\(key) newChat=\(newChat) chat=\(chat?.title ?? "nessuna")")
        if let chat {
            continueChat(chat.id, prompt)
        } else if single, let t = pendingNewChat[key], Date().timeIntervalSince(t) < 600 {
            // La chat e' stata aperta da poco ma il primo messaggio non e' ancora partito: non se ne apre un'altra.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            if let url = URL(string: "claude://") { NSWorkspace.shared.open(url) }
            showRecap([RecapLine(symbol: "paperplane", text: "Invia il primo messaggio nella chat aperta, poi incolla questo con ⌘V")],
                      title: "Chat già aperta", gesture: .nod)
        } else {
            if single { pendingNewChat[key] = Date() }
            let p = newChatPayload(prompt, key: key)
            var q = [("q", p.body)]
            if let folder = p.folder { q.insert(("folder", folder), at: 0) }
            if let url = Self.claudeURL("code/new", q) { NSWorkspace.shared.open(url) }
        }
        recompute()
    }

    /// Cosa si scrive in una chat nuova: la cartella e il testo (con le istruzioni del ruolo, per il Manager e gli agenti).
    func newChatPayload(_ prompt: String, key: String) -> (folder: String?, body: String) {
        var body = prompt
        if let role = AgentRegistry.role(forKey: key) {
            body = (role == .manager ? managerIntro() : role.preamble) + "\n\n" + prompt
        }
        return (folder(for: key), body)
    }

    /// La frase iniziale del Manager, con l'elenco dei progetti.
    private func managerIntro() -> String {
        let projects = ProjectResolver.shared.groups().map { g in
            (name: g.name, folder: folder(for: g.key).map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") },
             lead: DottRoster.shared.name(for: g.key))
        }
        return DottRole.managerPreamble(projects: projects)
    }

    /// Apre la chat e incolla la richiesta nel campo (serve il permesso "Accessibilita'": senza, il testo resta negli appunti).
    private func continueChat(_ cli: String, _ prompt: String) {
        Self.trace("continueChat chat=\(cli) accessibilita=\(AXIsProcessTrusted()) testo=\(prompt.prefix(40))")
        guard AXIsProcessTrusted() else {
            if let url = Self.claudeURL("resume", [("session", cli)]) { NSWorkspace.shared.open(url) }
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            showRecap([RecapLine(symbol: "doc.on.clipboard", text: "Incolla con ⌘V nel campo della chat")],
                      title: "Testo copiato", gesture: .nod)
            return
        }
        Self.driveChat(cli) { previous in Self.paste(prompt, returnTo: previous) }
    }

    /// Interrompe il lavoro di un Dott: apre la chat su cui sta lavorando e preme Esc nel suo campo.
    func interrupt(_ key: String?) {
        guard let key = target(key) else { return }
        let working = targetSession(key).flatMap { ProjectResolver.shared.title(for: $0.id) != nil ? $0 : nil }
        guard let cli = working?.id ?? chatTarget(key)?.id else { return }
        Self.trace("interrupt key=\(key) chat=\(cli) accessibilita=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        trigger(.nod)
        Self.driveChat(cli) { previous in Self.pressEscape(returnTo: previous) }
    }

    /// Porta in primo piano la chat nell'app Claude, attiva il suo campo con un clic ed esegue `action`.
    /// L'app in cui eri viene ricordata, cosi' dopo ci si puo' tornare.
    private static func driveChat(_ cli: String, _ action: @escaping (NSRunningApplication?) -> Void) {
        let previous = NSWorkspace.shared.frontmostApplication
        if let url = claudeURL("resume", [("session", cli)]) { NSWorkspace.shared.open(url) }
        // Si aspetta che l'app Claude sia in primo piano e la chat caricata; poi un clic attiva il campo.
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if front == "com.anthropic.claudefordesktop" || Date().timeIntervalSince(start) > 3 {
                    t.invalidate()
                    trace("in primo piano=\(front ?? "-") dopo \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        clickComposer()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { action(previous) }
                    }
                }
            }
        }
    }

    /// Esc nel campo della chat: ferma il lavoro in corso. Poi si torna all'app di prima.
    private static func pressEscape(returnTo previous: NSRunningApplication?) {
        trace("esc: ⌘ a \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)   // 53 = Esc
        }
        returnToPrevious(previous, after: 0.6)
    }

    private static func returnToPrevious(_ previous: NSRunningApplication?, after delay: TimeInterval) {
        guard let previous, previous.bundleIdentifier != "com.anthropic.claudefordesktop", !previous.isTerminated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            trace("ritorno a \(previous.bundleIdentifier ?? "-")")
            previous.activate()
        }
    }

    /// Un clic nel campo di scrittura dell'app Claude: in basso, al centro della finestra. Il cursore torna dov'era.
    private static func clickComposer() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let frames: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Claude", (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"], width > 400, height > 300 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard let f = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { trace("clic: nessuna finestra di Claude"); return }
        let point = CGPoint(x: f.midX, y: f.maxY - 55)
        let old = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        trace("clic nel campo a (\(Int(point.x)), \(Int(point.y))) finestra \(f)")
        if let old { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { CGWarpMouseCursorPosition(old) } }
    }

    /// Un registro per capire cosa succede (/tmp/dott-ask.log).
    private static func trace(_ line: String) {
        let l = "\(Date()) \(line)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/dott-ask.log") { h.seekToEndOfFile(); h.write(Data(l.utf8)); try? h.close() }
        else { try? l.write(toFile: "/tmp/dott-ask.log", atomically: true, encoding: .utf8) }
    }

    private static func paste(_ text: String, returnTo previous: NSRunningApplication?) {
        trace("paste: ⌘V a \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // 9 = V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        // Invio automatico: solo se l'app Claude e' ancora in primo piano (altrimenti il tasto andrebbe a un'altra app).
        if AppSettings.shared.autoSendAsk {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                trace("invio automatico: in primo piano=\(front ?? "-")")
                guard front == "com.anthropic.claudefordesktop" else { return }
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)   // 36 = Invio
                    e?.post(tap: .cghidEventTap)
                }
                // Inviata: si torna all'app di prima (se non era gia' Claude).
                returnToPrevious(previous, after: 0.6)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pb.clearContents()
            if let old { pb.setString(old, forType: .string) }
        }
    }

    /// Apre una chat che l'app Claude gia' conosce.
    func openChat(_ cli: String, in key: String) {
        if let url = Self.claudeURL("resume", [("session", cli)]) { NSWorkspace.shared.open(url) }
    }

    /// Un indirizzo `claude://…` con i valori codificati per bene (anche & e +).
    static func claudeURL(_ path: String, _ items: [(String, String)]) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = items.compactMap { k, v in
            v.addingPercentEncoding(withAllowedCharacters: allowed).map { "\(k)=\($0)" }
        }.joined(separator: "&")
        return URL(string: "claude://\(path)?\(query)")
    }
}
