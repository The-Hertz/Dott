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
        key == DottRoster.freeKey ? ProjectResolver.existingDir(freeCwd) : ProjectResolver.shared.folder(for: key)
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

    /// La chat in cui finisce la richiesta: quella che stai usando (la sessione viva di questo Dott), altrimenti la piu' recente.
    /// Una chat la cui cartella non esiste piu' non si puo' continuare: l'app non fa scrivere.
    func chatTarget(_ key: String?) -> (id: String, title: String)? {
        guard let key = target(key) else { return nil }
        func continuable(_ cwd: String?) -> Bool {
            guard let cwd else { return true }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
        }
        let resolver = ProjectResolver.shared
        let live = sessions.values
            .filter { Self.projectKey($0) == key && resolver.title(for: $0.id) != nil }
            .sorted { $0.updated > $1.updated }
        for s in live {
            if let c = resolver.chats(for: key, limit: 200).first(where: { $0.id == s.id }), continuable(c.cwd) { return (c.id, c.title) }
        }
        if let c = resolver.chats(for: key, limit: 20).first(where: { continuable($0.cwd) }) { return (c.id, c.title) }
        return nil
    }

    /// Scrive nella chat in corso (la apre e incolla la richiesta nel suo campo, senza inviarla); con `newChat`, o se non c'e'
    /// una chat da continuare, ne apre una nuova nella cartella del progetto, con la richiesta gia' scritta.
    func ask(_ text: String, key given: String? = nil, newChat: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let key = target(given) else { return }
        composing = false
        trigger(.nod)
        Self.trace("ask key=\(key) newChat=\(newChat) chat=\(chatTarget(key)?.title ?? "nessuna")")
        if !newChat, let chat = chatTarget(key) {
            continueChat(chat.id, prompt)
        } else {
            var q = [("q", prompt)]
            if let folder = folder(for: key) { q.insert(("folder", folder), at: 0) }
            if let url = Self.claudeURL("code/new", q) { NSWorkspace.shared.open(url) }
        }
        recompute()
    }

    /// Apre la chat e incolla la richiesta nel campo (serve il permesso "Accessibilita'": senza, il testo resta negli appunti).
    private func continueChat(_ cli: String, _ prompt: String) {
        // L'app in cui eri: dopo l'invio ci torni, cosi' l'app Claude resta un lampo e non ti porta via dal lavoro.
        let previous = NSWorkspace.shared.frontmostApplication
        Self.trace("continueChat chat=\(cli) accessibilita=\(AXIsProcessTrusted()) testo=\(prompt.prefix(40))")
        if let url = Self.claudeURL("resume", [("session", cli)]) { NSWorkspace.shared.open(url) }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            showRecap([RecapLine(symbol: "doc.on.clipboard", text: "Incolla con ⌘V nel campo della chat")],
                      title: "Testo copiato", gesture: .nod)
            return
        }
        // Si aspetta che l'app Claude sia in primo piano e la chat caricata; poi si incolla nel campo (gia' attivo).
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if front == "com.anthropic.claudefordesktop" || Date().timeIntervalSince(start) > 3 {
                    t.invalidate()
                    Self.trace("in primo piano=\(front ?? "-") dopo \(String(format: "%.1f", Date().timeIntervalSince(start)))s: incollo")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        // Il campo potrebbe non avere il cursore (per esempio dopo aver scritto nell'isola): un clic lo attiva.
                        Self.clickComposer()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.paste(prompt, returnTo: previous) }
                    }
                }
            }
        }
    }

    /// Incolla `text` (⌘V) nell'app in primo piano e rimette a posto gli appunti di prima.
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
                if let previous, previous.bundleIdentifier != "com.anthropic.claudefordesktop", !previous.isTerminated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        trace("ritorno a \(previous.bundleIdentifier ?? "-")")
                        previous.activate()
                    }
                }
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
