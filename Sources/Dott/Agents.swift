import Foundation

/// La struttura dei Dott: il Manager di tutti i progetti, un capo progetto per ciascuno (il Dott del gruppo) e, sotto di lui,
/// gli specialisti con un ruolo (Designer, Ricerca, Scrittura, Automazione). Gli specialisti e il Manager sono chat dell'app
/// Claude, aperte da Dott con una frase iniziale che dice che ruolo hanno; Dott le riconosce dal segno `[Dott:ruolo]`.

extension DottRole {
    /// I ruoli che si possono dare a un Dott di progetto (il Manager e gli specialisti hanno il loro posto).
    static var assignable: [DottRole] { [.generic, .coding] }

    /// Gli agenti specializzati: non appartengono a nessun progetto, ci sono e li dirige l'orchestratore.
    static var specialists: [DottRole] { [.design, .research, .writing, .automation] }

    var isAgent: Bool { DottRole.specialists.contains(self) }

    /// Come si chiama chi ha quel ruolo.
    var agentTitle: String {
        switch self {
        case .generic: "Tuttofare"
        case .coding: "Coding"
        case .design: "Designer"
        case .research: "Ricercatore"
        case .writing: "Scrittore"
        case .automation: "Automatore"
        case .manager: "Manager"
        }
    }

    /// Gli strumenti che di solito servono a quel ruolo (un promemoria: li configuri in Claude Code).
    var tools: String? {
        switch self {
        case .design: "Figma (MCP)"
        case .research: "Web e documenti"
        case .automation: "Terminale e script"
        default: nil
        }
    }

    /// Il nome di chi usa Dott (l'utente di macOS): le istruzioni degli agenti parlano a nome suo, senza nomi scritti nel codice.
    static var owner: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "chi mi usa" }

    /// La chiave di un agente globale (e del Manager).
    var agentKey: String { self == .manager ? AgentRegistry.managerKey : "agent:\(rawValue)" }

    /// Le istruzioni con cui nasce la chat di un agente. Il primo rigo e' il segno che Dott riconosce.
    var preamble: String {
        let mark = "[Dott:\(rawValue)]"
        switch self {
        case .design:
            return "\(mark) Sei il Designer di \(DottRole.owner): interfaccia, esperienza d'uso, coerenza visiva, per qualsiasi progetto. Non appartieni a un progetto: il Manager ti dirà cosa fare e su quale progetto lavorare. Se hai Figma tramite MCP, usalo. Rispondi in modo conciso e dì cosa hai cambiato."
        case .research:
            return "\(mark) Sei il Ricercatore di \(DottRole.owner): cerchi, confronti le fonti, riassumi con riferimenti, per qualsiasi progetto. Non appartieni a un progetto: il Manager ti dirà cosa cercare e per quale progetto. Non modificare il codice se non richiesto."
        case .writing:
            return "\(mark) Sei lo Scrittore di \(DottRole.owner): documentazione, testi dell'interfaccia, README, messaggi di commit, per qualsiasi progetto. Non appartieni a un progetto: il Manager ti dirà cosa scrivere e dove. Tono chiaro e diretto."
        case .automation:
            return "\(mark) Sei l'Automatore di \(DottRole.owner): script, build, CI, attività ripetitive, per qualsiasi progetto. Non appartieni a un progetto: il Manager ti dirà cosa automatizzare e dove. Soluzioni semplici e verificabili, e spiega cosa automatizzi."
        default:
            return ""
        }
    }

    /// La frase iniziale del Manager: conosce tutti i progetti e gli agenti, e dirige il lavoro senza farlo lui.
    static func managerPreamble(projects: [(name: String, folder: String?, lead: String)]) -> String {
        let list = projects.map { "- \($0.name) (capo progetto: \($0.lead))" + ($0.folder.map { ", cartella \($0)" } ?? "") }.joined(separator: "\n")
        let agents = specialists.map { "\($0.agentTitle)" }.joined(separator: ", ")
        return """
        [Dott:manager] Sei il Manager (orchestratore) di tutti i miei progetti. Capisci l'obiettivo, lo scomponi e dici a chi va affidato ogni compito: ai capi progetto (uno per progetto) o agli agenti specializzati, che non appartengono a nessun progetto e lavorano dove li mandi (\(agents)). Non fai tu il lavoro.

        Quando vuoi affidare dei compiti, scrivi liberamente la tua risposta e poi, IN FONDO, un blocco con una riga per compito, sempre in questa forma esatta:
        @designer [Progetto]: cosa deve fare
        Destinatari possibili: @designer, @ricercatore, @scrittore, @automatore, oppure @capo per il capo progetto del progetto indicato. Il nome tra parentesi quadre è obbligatorio e deve essere uno dei progetti elencati qui sotto. Usa la chiocciola normale @ (non una variante tipografica) e non mettere le righe in grassetto o in un elenco. Non scrivere altro in quelle righe. Dott mi chiederà conferma, poi li manderà e ti riporterà le risposte con un messaggio che inizia con "[Risposta di …]".

        Progetti:
        \(list)
        """
    }
}

/// Le chat con un ruolo (il Manager e gli agenti specializzati), riconosciute dal segno `[Dott:ruolo]` nella prima richiesta.
struct AgentRef: Codable, Equatable {
    var role: String
    /// Non piu' usato: gli agenti non appartengono a un progetto.
    var lead: String?
}

/// Il registro delle chat con un ruolo, ricordato fra un avvio e l'altro.
@MainActor
final class AgentRegistry {
    static let shared = AgentRegistry()
    static let managerKey = "manager"
    static let agentPrefix = "agent:"
    private let storeKey = "dott.agentRegistry"
    private(set) var refs: [String: AgentRef]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let m = try? JSONDecoder().decode([String: AgentRef].self, from: data) {
            refs = m.filter { DottRole(rawValue: $0.value.role).map { $0.isAgent || $0 == .manager } ?? false }
        } else {
            refs = [:]
        }
    }

    /// Il ruolo di una chiave di Dott ("manager", "agent:design"), se e' un agente.
    static func role(forKey key: String) -> DottRole? {
        if key == managerKey { return .manager }
        guard key.hasPrefix(agentPrefix) else { return nil }
        return DottRole(rawValue: String(key.dropFirst(agentPrefix.count)))
    }

    /// Il ruolo dichiarato dal segno `[Dott:ruolo]` nei primi caratteri di una richiesta. Non e' per forza all'inizio:
    /// l'app aggiunge un suo avviso in testa al primo messaggio delle chat senza cartella.
    nonisolated static func marker(in prompt: String) -> DottRole? {
        let head = String(prompt.prefix(12_000))
        guard let re = try? NSRegularExpression(pattern: #"\[Dott:([a-z]+)\]"#),
              let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let r = Range(m.range(at: 1), in: head),
              let role = DottRole(rawValue: String(head[r])), role.isAgent || role == .manager else { return nil }
        return role
    }

    func ref(for sessionId: String) -> AgentRef? { refs[sessionId] }

    /// La chiave del Dott a cui appartiene una chat con un ruolo.
    func key(for sessionId: String) -> String? {
        refs[sessionId].flatMap { DottRole(rawValue: $0.role) }?.agentKey
    }

    /// Le chat (session_id) di un ruolo.
    func sessions(role: DottRole) -> [String] {
        refs.filter { $0.value.role == role.rawValue }.map(\.key)
    }

    /// Se la prima richiesta di una chat porta il segno `[Dott:ruolo]`, la chat e' di quel ruolo.
    @discardableResult
    func registerIfMarked(sessionId: String, prompt: String) -> Bool {
        guard refs[sessionId] == nil, let role = Self.marker(in: prompt) else { return false }
        refs[sessionId] = AgentRef(role: role.rawValue, lead: nil)
        if refs.count > 400 { refs = Dictionary(uniqueKeysWithValues: refs.suffix(300).map { ($0.key, $0.value) }) }
        save()
        return true
    }

    // MARK: Recupero

    private var checkedFiles: [String: Date] = [:]
    private var recovering = false

    /// Ritrova le chat con un ruolo gia' esistenti (create prima che Dott le riconoscesse, o dopo un azzeramento del registro):
    /// il primo messaggio utente della trascrizione porta il segno `[Dott:ruolo]`. Si legge solo l'inizio dei file recenti.
    func recover(onChange: @escaping () -> Void) {
        guard !recovering else { return }
        recovering = true
        let known = Set(refs.keys)
        let checked = checkedFiles
        DispatchQueue.global(qos: .utility).async {
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            var found: [(String, DottRole)] = []
            var seen: [String: Date] = [:]
            let cutoff = Date().addingTimeInterval(-14 * 86400)
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
                let d = base.appendingPathComponent(dir)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where name.hasSuffix(".jsonl") {
                    let sid = String(name.dropLast(6))
                    let url = d.appendingPathComponent(name)
                    guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > cutoff else { continue }
                    seen[url.path] = m
                    if known.contains(sid) || checked[url.path] == m { continue }
                    guard let h = try? FileHandle(forReadingFrom: url), let data = try? h.read(upToCount: 96 * 1024) else { continue }
                    try? h.close()
                    let text = String(decoding: data, as: UTF8.self)
                    // solo il primo messaggio utente: la prima riga con "type":"user"
                    guard let line = text.split(separator: "\n").first(where: { $0.contains("\"type\":\"user\"") }),
                          let role = Self.marker(in: String(line)) else { continue }
                    found.append((sid, role))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = AgentRegistry.shared
                    me.checkedFiles.merge(seen) { $1 }
                    me.recovering = false
                    var added = false
                    for (sid, role) in found where me.refs[sid] == nil { me.refs[sid] = AgentRef(role: role.rawValue, lead: nil); added = true }
                    if added { me.save(); onChange() }
                }
            }
        }
    }

    /// Per le prove.
    func clear() { refs = [:]; save() }
    func add(sessionId: String, role: DottRole) { refs[sessionId] = AgentRef(role: role.rawValue, lead: nil); save() }

    fileprivate func save() {
        guard AppSettings.shared.persist, let data = try? JSONEncoder().encode(refs) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}

/// L'ultima risposta (testo) di una chat, letta dalla sua trascrizione.
enum Transcript {
    static func lastAssistantText(sessionId: String) -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            let url = base.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: url.path),
                  let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 600_000 ? size - 600_000 : 0)
            guard let data = try? h.readToEnd() else { continue }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            for line in lines.reversed() {
                guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["type"] as? String == "assistant", let msg = o["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                let t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !t.isEmpty { return t }
            }
        }
        return nil
    }
}

extension IslandModel {
    /// La chat viva piu' recente del capo progetto stesso (senza Manager e agenti).
    func leadOwnSession(_ key: String) -> Session? {
        sessions.values.filter { Self.projectKey($0) == key && AgentRegistry.shared.ref(for: $0.id) == nil }.max { $0.updated < $1.updated }
    }

    /// La chat viva piu' recente di un agente (o del Manager).
    func agentSession(_ role: DottRole) -> Session? {
        AgentRegistry.shared.sessions(role: role).compactMap { sessions[$0] }.max { $0.updated < $1.updated }
    }

    /// La chat viva di chi riceve la richiesta: il capo progetto, un agente o il Manager.
    func targetSession(_ key: String) -> Session? {
        if let role = AgentRegistry.role(forKey: key) { return agentSession(role) }
        return leadOwnSession(key)
    }
}
