import AppKit
import Foundation
import SwiftUI

/// Funzioni di supporto senza stato.
enum Features {
    /// La lista di TodoWrite: [{content, status, activeForm}].
    static func parseTodos(_ input: [String: Any]) -> [TodoItem]? {
        guard let arr = input["todos"] as? [[String: Any]], !arr.isEmpty else { return nil }
        return arr.enumerated().compactMap { i, d in
            guard let text = d["content"] as? String else { return nil }
            let st = TodoItem.Status(rawValue: d["status"] as? String ?? "pending") ?? .pending
            return TodoItem(id: "t\(i):\(text)", text: text, active: d["activeForm"] as? String, status: st)
        }
    }

    /// Titolo e testo per un errore di fine turno, dal suo tipo.
    static func failureText(type: String?, details: String?) -> (String, String) {
        let extra = (details ?? "").replacingOccurrences(of: "\n", with: " ")
        func with(_ base: String) -> String { extra.isEmpty ? base : "\(base) — \(String(extra.prefix(90)))" }
        switch type ?? "" {
        case "rate_limit": return ("Limite raggiunto", with("Hai finito i messaggi disponibili per ora"))
        case "overloaded": return ("Server sovraccarico", with("Riprova tra poco"))
        case "authentication_failed": return ("Accesso scaduto", with("Rifai il login"))
        case "oauth_org_not_allowed": return ("Account non autorizzato", with("L'organizzazione non consente questo accesso"))
        case "account_on_hold": return ("Account sospeso", with("Controlla il tuo account"))
        case "verification_required": return ("Serve una verifica", with("Completa la verifica dell'account"))
        case "billing_error": return ("Problema di fatturazione", with("Controlla il piano o il pagamento"))
        case "model_not_found": return ("Modello non trovato", with("Il modello scelto non è disponibile"))
        case "invalid_request": return ("Richiesta non valida", with("Claude non ha accettato la richiesta"))
        case "max_output_tokens": return ("Risposta troppo lunga", with("Ha raggiunto il limite di scrittura"))
        case "server_error": return ("Errore del server", with("Il servizio ha avuto un problema"))
        case "cloud_credential_error": return ("Credenziali cloud", with("Le credenziali del provider non funzionano"))
        default: return ("Qualcosa è andato storto", with("La richiesta è fallita"))
        }
    }

    static func isSpecialNotification(_ kind: String) -> Bool {
        kind.hasPrefix("quota_auto_resume") || kind == "agent_needs_input" || kind == "agent_completed" || kind == "auth_success"
    }

    /// Cosa mostrare per le notifiche speciali; nil = ignorala.
    static func describeNotification(kind: String, message: String) -> (title: String, detail: String, mood: Mood, hold: TimeInterval)? {
        let time = message.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression).map { String(message[$0]) }
        switch kind {
        case "quota_auto_resume":
            return (time.map { "Riprende alle \($0)" } ?? "Riprende da solo", message, .waiting, 40)
        case "quota_auto_resume_fired":
            return ("Riprende ora", message, .working, 6)
        case "quota_auto_resume_stale", "quota_auto_resume_disabled", "quota_auto_resume_cancelled":
            return ("Non riprenderà da solo", message, .waiting, 40)
        case "agent_needs_input":
            return ("Un agente ha bisogno di te", message, .waiting, 60)
        case "agent_completed":
            return ("Agente in background finito", message, .happy, 5)
        default:
            return nil
        }
    }

    /// La prima frase utile di una risposta, senza segni di markdown.
    static func snippet(from message: String) -> String? {
        var lines: [String] = []
        for raw in message.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("|") { continue }
            while line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("-") || line.hasPrefix("*") { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.count >= 4 { lines.append(line) }
            if lines.count >= 4 { break }
        }
        // Meglio una frase vera di un titolo: la prima abbastanza lunga, altrimenti la prima.
        guard let pick = lines.first(where: { $0.count >= 25 }) ?? lines.first else { return nil }
        return pick.count > 150 ? String(pick.prefix(150)) + "…" : pick
    }
}

/// Funzioni che si appoggiano al modello: eventi che aspettano una decisione, comandi di prova, diagnostica.
extension IslandModel {
    /// Comandi di prova sul socket locale (servono ai collaudi: non fanno nulla che non si possa fare dall'isola).
    func debugCommand(_ cmd: String, _ payload: [String: Any]) {
        switch cmd {
        case "settings":
            NotificationCenter.default.post(name: Notification.Name("dott.openSettings"), object: nil)
        case "allow", "deny":
            if let item = permissions.first { resolve(item, cmd == "allow" ? .allow : .deny) }
        case "elic_accept":
            if let el = elicitations.first {
                submitElicitation(el.id, text: payload["text"] as? [String: String] ?? [:], flags: payload["flags"] as? [String: Bool] ?? [:])
            }
        case "elic_decline":
            if let el = elicitations.first { declineElicitation(el.id) }
        case "music":
            musicPlaying = payload["on"] as? Bool ?? true
        case "poke":
            poke()
        case "select":
            if let k = payload["project"] as? String { selectProject(k) }
        case "detach":
            DesktopCompanion.shared.detach(model: self)
        case "dock":
            DesktopCompanion.shared.dock()
        case "fakeexternal":
            NotificationCenter.default.post(name: Notification.Name("dott.fakeExternal"), object: nil)
        case "pin":
            togglePinned()
        case "hotkeys":
            try? "registrate: \(HotKeys.shared.registeredCount)\n".write(toFile: "/tmp/dott-hotkeys.txt", atomically: true, encoding: .utf8)
        case "repo":
            // Prova: cosa vede la lettura di ramo e PR per la sessione in primo piano.
            let id = lead?.id ?? ""
            let cwd = lead?.cwd ?? ""
            let info = RepoProbe.probe(cwd: cwd)
            try? "id=\(id) cwd=\(cwd) info=\(String(describing: info)) lastCheck=\(String(describing: lead?.lastPRCheck)) pr=\(String(describing: lead?.pr))\n"
                .write(toFile: "/tmp/dott-repo.txt", atomically: true, encoding: .utf8)
        default:
            break
        }
    }

    /// Rilegge il contesto un po' dopo (dopo la compattazione la trascrizione si aggiorna con calma).
    func refreshContextSoon(_ id: String, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var s = self.sessions[id] else { return }
                self.refreshContext(id, in: &s, force: true)
                self.sessions[id] = s
            }
        }
    }

    /// Eventi per cui Claude Code aspetta una tua decisione. Ritorna true se li ha presi in carico.
    func handleHeld(_ e: HookEvent, _ conn: Connection) -> Bool {
        let st = AppSettings.shared
        switch e.name {
        case "PermissionDenied":
            // L'auto-mode ha rifiutato un'azione: puoi chiedere a Claude di riprovare.
            let reason = e.raw["reason"] as? String ?? ""
            let what = e.toolName == "Bash" ? e.command : (e.toolName)
            return addNotice(e, conn, title: "Negato in automatico", subtitle: "Claude Code ha rifiutato \(e.toolName)",
                             preview: [reason, what].filter { !$0.isEmpty }.joined(separator: "\n"),
                             allow: "Riprova", deny: "Lascia") { d in
                d == .deny ? nil : ["hookSpecificOutput": ["hookEventName": "PermissionDenied", "retry": true]]
            }
        case "ConfigChange":
            guard st.watchConfig else { return false }
            let source = e.raw["source"] as? String ?? "impostazioni"
            return addNotice(e, conn, title: "Impostazioni modificate", subtitle: "Cambiate durante la sessione (\(source))",
                             preview: e.raw["file_path"] as? String ?? source, allow: "Consenti", deny: "Blocca") { d in
                d == .deny ? ["decision": "block", "reason": "Modifica alle impostazioni bloccata dall'utente."] : nil
            }
        case "PreModelSwitch":
            guard st.confirmModelSwitch else { return false }
            let from = e.raw["from_model"] as? String ?? "?", to = e.raw["to_model"] as? String ?? "?"
            return addNotice(e, conn, title: "Cambio di modello", subtitle: "Può costare di più: conferma",
                             preview: "\(from)  →  \(to)", allow: "Cambia", deny: "Annulla") { d in
                ["hookSpecificOutput": ["hookEventName": "PreModelSwitch",
                                        "permissionDecision": d == .deny ? "deny" : "allow",
                                        "permissionDecisionReason": d == .deny ? "Annullato dall'utente tramite Dott" : "Confermato dall'utente tramite Dott"]]
            }
        case "Elicitation":
            return addElicitation(e, conn)
        default:
            return false
        }
    }

    /// Una card "conferma o rifiuta" per un evento che non e' un permesso vero e proprio.
    private func addNotice(_ e: HookEvent, _ conn: Connection, title: String, subtitle: String, preview: String,
                           allow: String, deny: String, response: @escaping (PermissionDecision) -> [String: Any]?) -> Bool {
        conn.held = true
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, project: e.project ?? "Claude")
        if let p = e.project { s.project = p }
        s.updated = Date()
        let item = PermissionItem(sessionId: e.sessionId, project: s.project, tool: e.name,
                                  preview: String(preview.prefix(400)), suggestions: [], connection: conn)
        item.title = title; item.subtitle = subtitle; item.allowLabel = allow; item.denyLabel = deny; item.custom = response
        let itemID = item.id
        conn.onClose = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permissions.removeAll { $0.id == itemID }
                self.clearWaiting(e.sessionId)
                self.recompute()
            }
        }
        s.set(.waiting, title, hold: nil)
        sessions[e.sessionId] = s
        permissions.append(item)
        Sounds.play(.attention)
        recompute()
        return true
    }

    // MARK: Moduli dei server MCP

    private func addElicitation(_ e: HookEvent, _ conn: Connection) -> Bool {
        let mode = e.raw["mode"] as? String ?? "form"
        let fields = ElicState.parseFields(e.raw["requested_schema"] as? [String: Any])
        conn.held = true
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, project: e.project ?? "Claude")
        if let p = e.project { s.project = p }
        s.updated = Date()
        let st = ElicState(sessionId: e.sessionId, project: s.project, server: e.raw["mcp_server_name"] as? String ?? "Un server",
                           message: e.raw["message"] as? String ?? "Serve il tuo input", mode: mode,
                           url: e.raw["url"] as? String, fields: fields, connection: conn)
        let sid = st.id
        conn.onClose = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elicitations.removeAll { $0.id == sid }
                self.clearWaiting(e.sessionId)
                self.recompute()
            }
        }
        s.set(.waiting, "\(st.server) ha bisogno di te", hold: nil)
        sessions[e.sessionId] = s
        elicitations.append(st)
        Sounds.play(.attention)
        peek(5)
        recompute()
        return true
    }

    /// Valori inseriti nel modulo -> contenuto per il server.
    func submitElicitation(_ id: UUID, text: [String: String], flags: [String: Bool]) {
        guard let i = elicitations.firstIndex(where: { $0.id == id }) else { return }
        let st = elicitations[i]
        var content: [String: Any] = [:]
        for f in st.fields {
            switch f.kind {
            case .bool: content[f.id] = flags[f.id] ?? f.initialFlag
            case .integer: if let v = Int(text[f.id] ?? f.initialText) { content[f.id] = v }
            case .number: if let v = Double(text[f.id] ?? f.initialText) { content[f.id] = v }
            case .text, .choice:
                let v = text[f.id] ?? f.initialText
                if !v.isEmpty || f.required { content[f.id] = v }
            }
        }
        finishElicitation(i, ["hookSpecificOutput": ["hookEventName": "Elicitation", "action": "accept", "content": content]])
    }

    func declineElicitation(_ id: UUID) {
        guard let i = elicitations.firstIndex(where: { $0.id == id }) else { return }
        finishElicitation(i, ["hookSpecificOutput": ["hookEventName": "Elicitation", "action": "decline"]])
    }

    /// URL: lo apre e conferma.
    func openElicitationURL(_ id: UUID) {
        guard let i = elicitations.firstIndex(where: { $0.id == id }) else { return }
        if let u = elicitations[i].url.flatMap(URL.init(string:)), ["http", "https"].contains(u.scheme ?? "") {
            NSWorkspace.shared.open(u)
        }
        finishElicitation(i, ["hookSpecificOutput": ["hookEventName": "Elicitation", "action": "accept"]])
    }

    func elicitationInTerminal(_ id: UUID) {
        guard let i = elicitations.firstIndex(where: { $0.id == id }) else { return }
        finishElicitation(i, nil)
    }

    private func finishElicitation(_ i: Int, _ reply: [String: Any]?) {
        let st = elicitations.remove(at: i)
        if let reply { st.connection.reply(reply) } else { st.connection.close() }
        Sounds.play(.sent)
        trigger(.nod)
        clearWaiting(st.sessionId)
        recompute()
    }
}
