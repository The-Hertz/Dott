import Foundation

/// Una cosa successa a un Dott: serve alle "Ultime attivita'" dell'hub. Si ricava dagli eventi di Claude Code.
struct ActivityItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String          // il Dott (progetto)
    var at: Date
    var symbol: String
    var tone: String         // ok, info, warn, bad
    var title: String
    var detail: String
    /// Per "Ha modificato N file": i nomi, cosi' le modifiche ravvicinate si raggruppano.
    var files: [String]?

    private static let storeKey = "dott.activity"

    static func load() -> [ActivityItem] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let m = try? JSONDecoder().decode([ActivityItem].self, from: data) else { return [] }
        return m
    }

    static func save(_ items: [ActivityItem]) {
        guard AppSettings.shared.persist, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}

extension IslandModel {
    /// Le attivita' di un Dott, le piu' recenti prima.
    func activity(for key: String, limit: Int) -> [ActivityItem] {
        Array(activity.filter { $0.key == key }.prefix(limit))
    }

    func log(_ key: String, _ symbol: String, _ tone: String, _ title: String, _ detail: String = "") {
        activity.insert(ActivityItem(key: key, at: Date(), symbol: symbol, tone: tone, title: title, detail: detail), at: 0)
        trimActivity()
    }

    private func trimActivity() {
        if activity.count > 150 { activity = Array(activity.prefix(150)) }
        ActivityItem.save(activity)
    }

    /// Dopo che un evento e' stato gestito: se vale la pena ricordarlo, finisce nel registro del suo Dott.
    func recordActivity(_ e: HookEvent) {
        guard let s = sessions[e.sessionId] else { return }
        let key = Self.projectKey(s)
        switch e.name {
        case "UserPromptSubmit":
            if var p = e.raw["prompt"] as? String, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Le istruzioni iniziali di un agente (primo paragrafo, con il segno [Dott:ruolo]) non sono la richiesta.
                // Gli avvisi che l'app aggiunge in testa (<system-reminder>) non sono la richiesta.
                p = p.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if AgentRegistry.marker(in: p) != nil, let r = p.range(of: "[Dott:") {
                    p = p[r.lowerBound...].range(of: "\n\n").map { String(p[$0.upperBound...]) } ?? ""
                }
                log(key, "text.bubble.fill", "info", p.isEmpty ? "Chat avviata" : "Nuova richiesta", String(p.prefix(110)))
            }
        case "PostToolUse" where ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(e.toolName):
            let path = (e.toolInput["file_path"] as? String) ?? (e.toolInput["notebook_path"] as? String) ?? ""
            guard !path.isEmpty else { return }
            let name = (path as NSString).lastPathComponent
            // Le modifiche ravvicinate allo stesso progetto sono una sola voce: "Ha modificato 3 file".
            if let i = activity.firstIndex(where: { $0.key == key }), activity[i].files != nil,
               Date().timeIntervalSince(activity[i].at) < 150 {
                var files = activity[i].files ?? []
                if !files.contains(name) { files.append(name) }
                activity[i].files = files
                activity[i].at = Date()
                activity[i].title = files.count == 1 ? "Ha modificato 1 file" : "Ha modificato \(files.count) file"
                activity[i].detail = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? "…" : "")
                trimActivity()
            } else {
                var item = ActivityItem(key: key, at: Date(), symbol: "pencil", tone: "info", title: "Ha modificato 1 file", detail: name)
                item.files = [name]
                activity.insert(item, at: 0)
                trimActivity()
            }
        case "Stop":
            // Stop vero e Stop dedotto dalla trascrizione sono lo stesso fatto.
            if let last = activity.first(where: { $0.key == key }), last.title == "Ha finito",
               Date().timeIntervalSince(last.at) < 20 { return }
            log(key, "checkmark.circle.fill", "ok", "Ha finito", s.detail)
        case "StopFailure":
            log(key, "exclamationmark.triangle.fill", "bad", "Qualcosa non ha funzionato", s.detail)
        case "SubagentStart":
            let type = e.raw["agent_type"] as? String ?? "un aiutante"
            log(key, "person.2.fill", "info", "Ha chiamato un aiutante", type)
        default:
            break
        }
    }

    func recordPermission(_ e: HookEvent) {
        guard let s = sessions[e.sessionId] else { return }
        let what = e.toolName == "Bash" ? e.command : e.toolName
        log(Self.projectKey(s), "hand.raised.fill", "warn", "Chiede la tua autorizzazione", String(what.prefix(90)))
    }
}
