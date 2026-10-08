import AppKit
import ApplicationServices
import Combine
import DottKit
import Foundation

/// Le scelte che riguardano il Compagno (memoria, registro, giornata, cura). Tutto ruota intorno a un principio:
/// quello che Dott sa di te sta sul tuo Mac, si legge a mano e si cancella con un pulsante.
final class CompanionSettings: ObservableObject {
    static let shared = CompanionSettings()
    private let d = UserDefaults.standard

    /// Scrive il diario della giornata (eventi, file, commit, test). Niente righe di output dei comandi.
    @Published var journal: Bool { didSet { d.set(journal, forKey: "dott.c.journal") } }
    /// Salva l'inizio delle tue richieste nel diario (serve a "Dove eravamo"). Spento: restano solo i conteggi.
    @Published var storePrompts: Bool { didSet { d.set(storePrompts, forKey: "dott.c.storePrompts") } }
    /// Consegna a Claude un promemoria all'inizio di ogni chat nuova.
    @Published var brief: Bool { didSet { d.set(brief, forKey: "dott.c.brief") } }
    /// Il tetto di token del promemoria.
    @Published var briefBudget: Int { didSet { d.set(briefBudget, forKey: "dott.c.briefBudget") } }
    /// Inviti alla pausa e a smettere a notte fonda.
    @Published var care: Bool { didSet { d.set(care, forKey: "dott.c.care") } }
    /// Lettura dei consumi dalle trascrizioni di Claude Code.
    @Published var ledger: Bool { didSet { d.set(ledger, forKey: "dott.c.ledger") } }

    private init() {
        journal = d.object(forKey: "dott.c.journal") as? Bool ?? true
        storePrompts = d.object(forKey: "dott.c.storePrompts") as? Bool ?? true
        brief = d.object(forKey: "dott.c.brief") as? Bool ?? true
        briefBudget = d.object(forKey: "dott.c.briefBudget") as? Int ?? 600
        care = d.object(forKey: "dott.c.care") as? Bool ?? true
        ledger = d.object(forKey: "dott.c.ledger") as? Bool ?? true
    }
}

/// Il promemoria consegnato a una chat, ricordato per mostrarti cosa ha letto Claude.
struct DeliveredBrief: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let project: String
    let text: String
    let tokens: Int
    let at: Date
}

@MainActor
final class Companion: ObservableObject {
    static let shared = Companion()

    let paths = DottPaths.standard
    let format = DayFormat()
    let journal: JournalWriter
    let reader: JournalReader
    let memory: MemoryStore
    private let scanner: LedgerScanner

    @Published private(set) var ledgerRows: [LedgerRow] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var briefs: [DeliveredBrief] = []
    @Published var rates: RateCard

    private var recent: [Date] = []
    private var lastNudges: [String: Date] = [:]
    private var timers: [Timer] = []
    private weak var model: IslandModel?
    private let engine = RhythmEngine()

    private init() {
        journal = JournalWriter(dir: paths.journalDir)
        reader = JournalReader(dir: paths.journalDir)
        memory = MemoryStore(dir: paths.memoryDir)
        scanner = LedgerScanner(projectsDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
                                stateFile: paths.ledgerFile)
        rates = JSONFile.read(RateCard.self, from: paths.ratesFile) ?? RateCard()
    }

    // MARK: Avvio

    func start(model: IslandModel) {
        self.model = model
        ledgerRows = scanner.rows
        DispatchQueue.global(qos: .utility).async { [journal] in journal.prune(keepDays: 180) }
        refreshLedger()
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLedger() }
        })
    }

    // MARK: Registro

    func refreshLedger() {
        guard CompanionSettings.shared.ledger, !scanning else { return }
        scanning = true
        let scanner = self.scanner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            scanner.scan()
            let rows = scanner.rows
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ledgerRows = rows
                    self.scanning = false
                    self.lastScan = Date()
                }
            }
        }
    }

    func saveRates(_ card: RateCard) {
        rates = card
        try? JSONFile.write(card, to: paths.ratesFile)
    }

    /// A quale progetto va il consumo di una riga: il Dott del gruppo, il Manager, un agente o la cartella.
    func project(of row: LedgerRow) -> String {
        if let k = AgentRegistry.shared.key(for: row.sessionId) {
            return AgentRegistry.role(forKey: k).map { $0 == .manager ? "Manager" : $0.agentTitle } ?? k
        }
        if let r = ProjectResolver.shared.resolve(sessionId: row.sessionId, cwd: row.cwd) { return r.name }
        return row.cwd.isEmpty ? "Senza cartella" : (row.cwd as NSString).lastPathComponent
    }

    /// Il lavoro del Manager e degli agenti: serve a capire se orchestrare conviene.
    func isOrchestrated(_ row: LedgerRow) -> Bool { AgentRegistry.shared.ref(for: row.sessionId) != nil }

    // MARK: Diario

    private func identity(of e: HookEvent) -> (key: String, name: String)? {
        guard let s = model?.sessions[e.sessionId] else { return nil }
        return (IslandModel.projectKey(s), s.project)
    }

    /// Dopo che un evento e' stato gestito: se vale la pena ricordarlo, finisce nel diario.
    func record(_ e: HookEvent) {
        let now = Date()
        recent.append(now)
        if recent.count > 400 { recent.removeFirst(recent.count - 300) }

        guard CompanionSettings.shared.journal, let who = identity(of: e) else { return }
        func add(_ kind: JournalKind, text: String? = nil, ok: Bool? = nil) {
            journal.append(JournalEvent(at: now, project: who.key, name: who.name, session: e.sessionId, kind: kind, text: text, ok: ok))
        }

        switch e.name {
        case "SessionStart":
            add(.sessionStart)
        case "UserPromptSubmit":
            var p = (e.raw["prompt"] as? String ?? "")
                .replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if AgentRegistry.marker(in: p) != nil, let r = p.range(of: "\n\n", options: .backwards) { p = String(p[r.upperBound...]) }
            add(.prompt, text: CompanionSettings.shared.storePrompts ? String(p.replacingOccurrences(of: "\n", with: " ").prefix(160)) : nil)
        case "PostToolUse":
            if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(e.toolName) {
                let path = (e.toolInput["file_path"] as? String) ?? (e.toolInput["notebook_path"] as? String) ?? ""
                if !path.isEmpty { add(.edit, text: (path as NSString).lastPathComponent) }
            } else if e.toolName == "Bash" {
                recordBash(e, add: add)
            }
        case "PostToolUseFailure":
            add(.failure, text: e.toolName)
        case "Stop":
            let snippet = e.lastAssistantMessage.flatMap(Features.snippet(from:))
            add(.stop, text: snippet)
            saveHandoff(e, who: who, outcome: snippet)
        case "SessionEnd":
            add(.sessionEnd)
        default:
            break
        }
    }

    private func recordBash(_ e: HookEvent, add: (JournalKind, String?, Bool?) -> Void) {
        let cmd = e.command
        if cmd.range(of: #"\bgit\s+commit\b"#, options: .regularExpression) != nil {
            var msg = "commit"
            if let r = cmd.range(of: #"-m\s+["']([^"']+)["']"#, options: .regularExpression) {
                msg = String(cmd[r]).replacingOccurrences(of: #"^-m\s+["']|["']$"#, with: "", options: .regularExpression)
            }
            add(.commit, String(msg.prefix(120)), true)
        }
        if let o = BuildParser.parse(command: cmd, output: e.bashOutput ?? "") {
            add(o.kind == .tests ? .test : .build, o.short, o.ok)
        }
    }

    /// Quanto ci hai messo a rispondere a una richiesta di permesso.
    func recordPermission(_ item: PermissionItem, decision: PermissionDecision) {
        guard CompanionSettings.shared.journal, let s = model?.sessions[item.sessionId] else { return }
        journal.append(JournalEvent(at: Date(), project: IslandModel.projectKey(s), name: s.project, session: item.sessionId,
                                    kind: .permission, text: item.tool, ok: decision != .deny,
                                    seconds: Date().timeIntervalSince(item.created)))
    }

    // MARK: Dove eravamo

    private func saveHandoff(_ e: HookEvent, who: (key: String, name: String), outcome: String?) {
        guard !who.key.hasPrefix("agent:"), who.key != AgentRegistry.managerKey else { return }
        let now = Date()
        let events = reader.events(lastDays: 2, endingAt: now).filter { $0.project == who.key }
        // Si riparte dall'ultima sessione: gli eventi dopo l'ultimo avvio di una chat.
        let since = events.last(where: { $0.kind == .sessionStart })?.at ?? .distantPast
        let todos = model?.sessions[e.sessionId]?.todos.filter { $0.status != .completed }.map(\.text) ?? []
        let branch = model?.sessions[e.sessionId]?.pr?.branch
        guard let h = Handoff.make(from: events.filter { $0.at >= since }, openTodos: todos, branch: branch, outcome: outcome, now: now) else { return }
        memory.update(who.key, name: who.name) { $0.handoff = h }
    }

    // MARK: Promemoria

    /// La risposta all'hook SessionStart: il promemoria da consegnare a Claude, o nil se non c'e' niente da dire.
    /// Solo a chat nuove o dopo una compattazione: una chat ripresa ce l'ha gia' nel suo contesto.
    func briefReply(for e: HookEvent) -> [String: Any]? {
        let st = CompanionSettings.shared
        guard st.brief, let who = identity(of: e),
              !who.key.hasPrefix("agent:"), who.key != AgentRegistry.managerKey else { return nil }
        let source = e.raw["source"] as? String ?? "startup"
        guard ["startup", "clear", "compact"].contains(source) else { return nil }

        let m = memory.load(who.key, name: who.name)
        let options = BriefOptions(tokenBudget: st.briefBudget, ownerName: DottRole.owner)
        guard let brief = BriefBuilder.build(m, now: Date(), options: options, format: format) else { return nil }

        // Gli appunti lasciati si consegnano una volta sola.
        if !brief.deliveredInbox.isEmpty {
            let gone = Set(brief.deliveredInbox)
            memory.update(who.key) { $0.inbox.removeAll { gone.contains($0.id) } }
        }
        briefs.insert(DeliveredBrief(sessionId: e.sessionId, project: who.name, text: brief.text, tokens: brief.estimatedTokens, at: Date()), at: 0)
        if briefs.count > 20 { briefs.removeLast(briefs.count - 20) }
        return ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": brief.text]]
    }

    // MARK: Cura

    private func tick() {
        guard CompanionSettings.shared.care, let model else { return }
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) > 6 * 3600 }
        guard let nudge = engine.evaluate(now: now, activity: recent, lastNudges: lastNudges) else { return }
        // Mai mentre Dott aspetta una tua decisione: non e' il momento.
        guard model.permissions.isEmpty, model.elicitations.isEmpty else { return }
        lastNudges[nudge.key] = now
        model.showRecap([RecapLine(symbol: nudge.key == "lateNight" ? "moon.stars.fill" : "figure.walk", text: nudge.message)],
                        title: nudge.title, gesture: .stretch)
    }

    // MARK: Cattura rapida

    /// Una riga dal campo di cattura: diventa una nota o un appunto per la prossima chat del progetto. Risponde con cosa e' successo.
    @discardableResult
    func capture(_ raw: String, model: IslandModel) -> String {
        guard let intent = CaptureParser.parse(raw) else { return "Non ho capito: scrivi una riga, anche con @progetto e /decisione" }
        var key: String?
        var name = ""
        if let p = intent.project {
            guard let found = model.project(named: p) else { return "Non conosco il progetto «\(p)»" }
            key = found.key
            name = found.name
        } else if let k = model.commandKey {
            key = k
            name = ProjectResolver.shared.groupName(k) ?? (k as NSString).lastPathComponent
        }
        guard let key else { return "Dimmi per quale progetto: @nome" }
        switch intent.action {
        case .inbox:
            memory.update(key, name: name) { $0.inbox.append(InboxItem(text: intent.text)) }
            objectWillChange.send()
            return "Lo consegno a Claude alla prossima chat di \(name)"
        case .note(let kind):
            memory.update(key, name: name) { $0.notes.append(MemoryNote(kind: kind, text: intent.text, pinned: kind == .gotcha)) }
            objectWillChange.send()
            return "Ricordato per \(name): \(kind.label.lowercased())"
        }
    }

    // MARK: Salute

    func healthItems() -> [HealthItem] {
        var items = HealthChecker(home: FileManager.default.homeDirectoryForCurrentUser, paths: paths).run()
        let trusted = AXIsProcessTrusted()
        items.append(HealthItem(id: "ax", title: "Accessibilita'", status: trusted ? .ok : .warning,
                                detail: trusted ? "Concessa: Dott puo' scrivere nelle chat al posto tuo."
                                                : "Senza, \"Chiedi a…\" e il Manager copiano il testo negli appunti invece di incollarlo.",
                                fix: trusted ? nil : "Impostazioni di Sistema → Privacy e sicurezza → Accessibilita'"))
        let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        items.append(HealthItem(id: "app", title: "App Claude", status: claude ? .ok : .warning,
                                detail: claude ? "Trovata." : "Non la trovo: il Manager e \"Chiedi a…\" usano le sue chat."))
        return items
    }

    // MARK: Dimentica

    func forgetEverything() {
        journal.eraseAll()
        memory.eraseAll()
        briefs = []
        objectWillChange.send()
    }
}
