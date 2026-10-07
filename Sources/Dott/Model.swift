import AppKit
import Combine
import SwiftUI

// MARK: - Umore della mascotte

enum Mood: String, CaseIterable, Identifiable {
    case sleeping, thinking, reading, writing, running, searching, working, waiting, happy, hurt

    var id: String { rawValue }

    /// Chi vince quando piu' sessioni fanno cose diverse.
    var priority: Int {
        switch self {
        case .waiting: 9
        case .hurt: 8
        case .running: 7
        case .writing: 6
        case .reading: 5
        case .searching: 4
        case .working: 3
        case .thinking: 2
        case .happy: 1
        case .sleeping: 0
        }
    }

    var title: String {
        switch self {
        case .sleeping: "\(AppSettings.shared.name) dorme"
        case .thinking: "Sta pensando"
        case .reading: "Sta leggendo"
        case .writing: "Sta scrivendo"
        case .running: "Sta eseguendo"
        case .searching: "Sta cercando"
        case .working: "Sta lavorando"
        case .waiting: "Ti aspetta"
        case .happy: "Fatto!"
        case .hurt: "Qualcosa è andato storto"
        }
    }

    var symbol: String {
        switch self {
        case .sleeping: "moon.zzz.fill"
        case .thinking: "ellipsis"
        case .reading: "doc.text"
        case .writing: "pencil"
        case .running: "terminal"
        case .searching: "magnifyingglass"
        case .working: "gearshape.2.fill"
        case .waiting: "exclamationmark"
        case .happy: "checkmark"
        case .hurt: "xmark"
        }
    }

    /// Verbo breve per dire cosa sta facendo.
    var verb: String {
        switch self {
        case .reading: "Legge"
        case .writing: "Scrive"
        case .running: "Esegue"
        case .searching: "Cerca"
        case .thinking: "Riflette"
        case .hurt: "Errore"
        default: "Lavora"
        }
    }

    var accent: Color {
        switch self {
        case .waiting: Palette.amber
        case .hurt: Palette.coral
        case .sleeping: Color.white.opacity(0.35)
        default: Palette.lime
        }
    }
}

enum Palette {
    /// Il colore di Dott: e' anche l'accento di tutta l'isola.
    static var lime: Color { AppSettings.shared.color.top }
    static var limeDeep: Color { AppSettings.shared.color.bottom }
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.14)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.36)
    static let ink = Color(red: 0.04, green: 0.06, blue: 0.02)

    /// Colori degli aiutanti: tutti diversi da quello di Dott.
    static func helper(_ index: Int) -> (top: Color, bottom: Color) {
        let list = DottColor.helperOrder.filter { $0 != AppSettings.shared.color }
        let c = list[index % list.count]
        return (c.top, c.bottom)
    }
}

// MARK: - Evento di un hook

struct HookEvent {
    let raw: [String: Any]

    var name: String { raw["hook_event_name"] as? String ?? "" }
    var sessionId: String { raw["session_id"] as? String ?? "default" }
    var cwd: String? { raw["cwd"] as? String }
    var toolName: String { raw["tool_name"] as? String ?? "" }
    var toolInput: [String: Any] { raw["tool_input"] as? [String: Any] ?? [:] }
    /// L'app da cui parte la sessione (per portartela in primo piano).
    var appBundle: String? {
        if let a = raw["dott_app"] as? String, !a.isEmpty { return a }
        switch raw["dott_term"] as? String ?? "" {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }
    var transcriptPath: String? { raw["transcript_path"] as? String }
    var permissionMode: String? { raw["permission_mode"] as? String }
    var lastAssistantMessage: String? { raw["last_assistant_message"] as? String }
    var command: String { toolInput["command"] as? String ?? "" }
    /// L'output di un comando (o il testo dell'errore), se l'hook lo ha mandato.
    var bashOutput: String? {
        if let r = raw["tool_response"] as? [String: Any] {
            return ((r["stdout"] as? String) ?? "") + "\n" + ((r["stderr"] as? String) ?? "")
        }
        if let r = raw["tool_response"] as? String { return r }
        return raw["error"] as? String
    }
    var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Cosa sta facendo il tool, in due parole: umore + oggetto.
    func describeTool() -> (Mood, String) {
        let input = toolInput
        func file() -> String {
            let p = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String) ?? ""
            return p.isEmpty ? "" : URL(fileURLWithPath: p).lastPathComponent
        }
        func clip(_ s: String, _ n: Int = 90) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch toolName {
        case "Read", "NotebookRead", "LS":
            return (.reading, file())
        case "Glob":
            return (.reading, clip(input["pattern"] as? String ?? ""))
        case "Grep":
            return (.searching, clip(input["pattern"] as? String ?? ""))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return (.writing, file())
        case "Bash":
            let d = (input["description"] as? String) ?? (input["command"] as? String) ?? ""
            return (.running, clip(d))
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? ""
            return (.searching, host)
        case "WebSearch":
            return (.searching, clip(input["query"] as? String ?? ""))
        case "Task", "Agent":
            return (.working, clip(input["description"] as? String ?? "Un aiutante al lavoro"))
        case "TodoWrite":
            return (.working, "Aggiorna la lista")
        default:
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                return (.working, parts.last.map(String.init) ?? toolName)
            }
            return (.working, toolName)
        }
    }
}

// MARK: - Gesti di Dott

/// Piccoli gesti che si innestano sulla posa, con entrata e uscita morbide.
enum GestureKind: CaseIterable {
    case nod        // un cenno: ho capito / ok
    case tilt       // testa inclinata: ti ascolto
    case sigh       // un sospiro di sollievo
    case giggle     // una risatina
    case hop        // un saltello
    case spin       // una giravolta
    case wave       // un saluto con l'antennina
    case purr       // fusa
    case stretch    // stiracchiarsi
    case peek       // uno sguardo in giro
    case annoyed    // seccato: lo hai punzecchiato troppo
    case dizzy      // gli gira la testa
    case sneeze     // starnuto: la polvere della scopa
    case whistle    // fischietta mentre aspetta un lavoro lungo
    case chase      // insegue una lucciola

    var duration: Double {
        switch self {
        case .nod: 0.8
        case .tilt: 1.4
        case .sigh: 2.2
        case .giggle: 1.0
        case .hop: 0.65
        case .spin: 1.0
        case .wave: 1.6
        case .purr: 2.4
        case .stretch: 2.0
        case .peek: 2.4
        case .annoyed: 2.0
        case .dizzy: 3.2
        case .sneeze: 2.2
        case .whistle: 3.4
        case .chase: 4.4
        }
    }
}

struct GestureEvent: Equatable {
    let id = UUID()
    let kind: GestureKind
    let at: Date
}

// MARK: - Cosa mi sono perso

struct RecapLine: Equatable {
    let symbol: String
    let text: String
}

struct Recap: Equatable {
    let lines: [RecapLine]
    let until: Date
}

// MARK: - Sessioni e permessi

/// Un sottoagente: ha il suo colore, il suo compito e quello che sta facendo ora.
struct Helper: Identifiable {
    let id: String
    let type: String
    var task: String
    var activity: String
    var mood: Mood
    let colorIndex: Int
    let started = Date()
    var lastSeen = Date()
}

struct PendingTask {
    let type: String
    let text: String
}

struct Session: Identifiable {
    var id: String
    var project: String
    var mood: Mood = .sleeping
    var detail: String = ""
    /// Titolo al posto di quello dell'umore (saluti): vale finche' dura il `hold`.
    var headline: String?
    var afterDetail: String?
    var turnStart: Date?
    var updated = Date()
    /// Umore temporaneo (festa, ahi): scade e torna a `after`.
    var holdUntil: Date?
    var after: Mood = .sleeping
    /// Sottoagenti al lavoro.
    var agents: [String: Helper] = [:]
    /// Compiti affidati con lo strumento Agent, in attesa che il sottoagente parta.
    var pending: [PendingTask] = []
    var helperSeq = 0
    var bundleId: String?
    var transcript: String?
    var contextTokens = 0
    var contextWindow = 200_000
    var lastContextRead = Date.distantPast
    var failStreak = 0
    var turnOutcome: BuildOutcome?
    var runningCommand: String?
    var runningSince: Date?
    var lastInterruptCheck = Date.distantPast
    var cwd: String?
    var permissionMode: String?
    var todos: [TodoItem] = []
    var snippet: String?
    var compacting = false
    var pr: PRInfo?
    var lastPRCheck = Date.distantPast
    var warnedContext = false
    /// Il turno e' gia' stato dichiarato finito: un secondo segnale di fine non deve rifare la festa.
    var turnFinished = false

    var contextFraction: Double? {
        contextTokens > 0 ? min(1, Double(contextTokens) / Double(contextWindow)) : nil
    }

    mutating func set(_ mood: Mood, _ detail: String, hold: TimeInterval? = nil, then: Mood = .sleeping,
                      headline: String? = nil, thenDetail: String? = nil) {
        self.mood = mood
        self.detail = detail
        self.headline = headline
        self.afterDetail = thenDetail
        self.after = then
        self.holdUntil = hold.map { Date().addingTimeInterval($0) }
    }
}

enum PaletteCount { static let helpers = 5 }

/// Un Dott per progetto: lo stato di tutte le sessioni di quella cartella, riassunto.
struct ProjectDott: Identifiable, Equatable {
    let id: String
    var name: String
    var mood: Mood
    var sessionId: String
    var accessory: Accessory?
    var detail: String
    var contextFraction: Double?
    var turnStart: Date?
    var agents: Int
    var sessions: Int
}

enum PermissionDecision { case allow, always, deny }

final class PermissionItem: Identifiable {
    let id = UUID()
    let sessionId: String
    let project: String
    let tool: String
    let preview: String
    let suggestions: [Any]
    let connection: Connection
    // Per le richieste che non sono un permesso (negato in automatico, cambio di modello, impostazioni…).
    var title: String?
    var subtitle: String?
    var allowLabel: String?
    var denyLabel: String?
    var custom: ((PermissionDecision) -> [String: Any]?)?

    init(sessionId: String, project: String, tool: String, preview: String, suggestions: [Any], connection: Connection) {
        self.sessionId = sessionId
        self.project = project
        self.tool = tool
        self.preview = preview
        self.suggestions = suggestions
        self.connection = connection
    }

    /// Il JSON che Claude Code si aspetta dall'hook PermissionRequest.
    func response(for decision: PermissionDecision) -> [String: Any]? {
        if let custom { return custom(decision) }
        var d: [String: Any]
        switch decision {
        case .allow: d = ["behavior": "allow"]
        case .always:
            d = ["behavior": "allow"]
            if !suggestions.isEmpty { d["updatedPermissions"] = suggestions }
        case .deny: d = ["behavior": "deny", "message": tool == "ExitPlanMode" ? "Piano non approvato dall'utente: rivedilo con lui." : "Negato da Dott"]
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
    }
}

// MARK: - Domande di Claude (AskUserQuestion)

struct AskOption: Hashable {
    let label: String
    let detail: String
}

struct AskSpec {
    let text: String
    let header: String
    let options: [AskOption]
    let multi: Bool

    init?(_ raw: [String: Any]) {
        guard let text = raw["question"] as? String,
              let opts = raw["options"] as? [[String: Any]], !opts.isEmpty else { return nil }
        self.text = text
        self.header = raw["header"] as? String ?? ""
        self.multi = raw["multiSelect"] as? Bool ?? false
        self.options = opts.compactMap {
            guard let l = $0["label"] as? String else { return nil }
            return AskOption(label: l, detail: $0["description"] as? String ?? "")
        }
        if options.isEmpty { return nil }
    }
}

struct QuestionState: Identifiable {
    let id = UUID()
    let sessionId: String
    let project: String
    let specs: [AskSpec]
    let rawQuestions: [Any]
    let connection: Connection
    var index = 0
    var selected: [String] = []
    var answers: [String: Any] = [:]
    var typing = false

    var current: AskSpec { specs[index] }
}

// MARK: - Geometria del notch

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    /// La geometria di uno schermo: la notch vera se c'e', altrimenti una notch finta sotto la barra dei menu.
    @MainActor
    static func forScreen(_ s: NSScreen) -> NotchGeometry {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: s.frame, notchWidth: s.frame.width - l.width - r.width,
                                 notchHeight: s.safeAreaInsets.top, hasNotch: true)
        }
        let bar = s.frame.maxY - s.visibleFrame.maxY      // spessore della barra dei menu (0 se nascosta)
        return NotchGeometry(screenFrame: s.frame, notchWidth: 150, notchHeight: max(30, bar), hasNotch: false)
    }

    static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: s.frame,
                                 notchWidth: s.frame.width - l.width - r.width,
                                 notchHeight: s.safeAreaInsets.top,
                                 hasNotch: true)
        }
        let s = NSScreen.main ?? screens[0]
        // Niente notch: ne disegniamo uno finto sotto la barra dei menu.
        return NotchGeometry(screenFrame: s.frame, notchWidth: 170, notchHeight: 30, hasNotch: false)
    }
}

// MARK: - Il cervello dell'isola

@MainActor
final class IslandModel: ObservableObject {
    static let ear: CGFloat = 42
    static let topRadius: CGFloat = 8
    /// Dimensioni massime dell'isola aperta (con permesso): la finestra sta sempre a questa misura.
    static let maxIslandWidth: CGFloat = 480
    static let maxBodyHeight: CGFloat = 312

    @Published var sessions: [String: Session] = [:]
    @Published var permissions: [PermissionItem] = []
    @Published var questions: [QuestionState] = []
    @Published var geometry: NotchGeometry
    @Published var mood: Mood = .sleeping
    @Published var lead: Session?
    /// Un Dott per progetto, nell'ordine in cui sono comparsi (non saltano da una posizione all'altra).
    @Published var dotts: [ProjectDott] = []
    /// Il progetto che hai scelto di tenere in primo piano (se no, comanda il piu' urgente).
    @Published var pinnedProject: String?
    var projectOrder: [String] = []
    @Published var expanded = false
    @Published var size: CGSize = .zero
    @Published var hovering = false
    /// Sale a ogni cambiamento visibile: la vista lo usa come contesto di animazione unico.
    @Published var version = 0
    var lastSignature = ""

    // Gesti e legame con te
    @Published var gesture: GestureEvent?
    /// 0 di giorno, 1 a notte fonda.
    @Published var night = IslandModel.nightLevel(Date())
    var lastEventAt = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "dott.lastEvent"))
    var lastPersist = Date.distantPast
    var lastWhistle = Date.distantPast
    var projectSeen: [String: Double] = UserDefaults.standard.dictionary(forKey: "dott.projects") as? [String: Double] ?? [:]
    var workStreakStart: Date?
    var lastStopAt: Date?
    var lastNudge: Date?
    var hoverSince: Date?
    var lastPoke: GestureKind?

    // Diagnostica: quanti eventi di ogni tipo sono arrivati da quando Dott e' acceso.
    var eventCounts: [String: Int] = [:]

    @Published var pinned = false
    @Published var baseExpanded = false
    var hoverScreen: UInt32?
    var pokeTimes: [Date] = []
    @Published var musicPlaying = false
    @Published var detached = false
    @Published var elicitations: [ElicState] = []

    // Cosa mi sono perso
    @Published var recap: Recap?
    /// L'accessorio di questo momento (occhiali, matita, cuffie, casco) e i vestiti di stagione.
    @Published var accessory: Accessory?
    @Published var outfit: Set<Outfit> = AppSettings.shared.outfit(on: Date())
    var wasAway = false
    var awayFinished: [(project: String, took: String?)] = []
    var awayFailures: [String] = []
    var awayErrors = 0
    var awayFiles = Set<String>()
    /// True mentre scrivi una risposta libera: la finestra deve poter ricevere la tastiera.
    @Published var wantsKeyboard = false
    /// Il cursore si sta muovendo vicino alla mascotte.
    @Published var cursorNear = false

    /// Solo per le istantanee di prova.
    var forceExpanded: Bool?
    var peekUntil = Date.distantPast
    var hoverWork: DispatchWorkItem?
    var timer: Timer?

    init() {
        geometry = NotchGeometry.current()
        recompute()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var bodyWidth: CGFloat { size.width - 2 * Self.topRadius }

    /// Aiutanti al lavoro in tutte le sessioni, non solo in quella in primo piano.
    var totalAgents: Int { sessions.values.reduce(0) { $0 + $1.agents.count } }

    static func projectKey(_ s: Session) -> String { s.cwd ?? s.project }

    var leadKey: String? { lead.map(Self.projectKey) }

    /// I Dott degli altri progetti (quello in primo piano ha lo spazio grande).
    var otherDotts: [ProjectDott] { dotts.filter { $0.id != leadKey } }

    /// Gli aiutanti del progetto in primo piano, nell'ordine in cui sono partiti.
    var leadHelpers: [Helper] {
        guard let k = leadKey else { return [] }
        return sessions.values.filter { Self.projectKey($0) == k }.flatMap { $0.agents.values }.sorted { $0.started < $1.started }
    }

    /// Larghezza di ciascun orecchio a isola chiusa: cresce quando ci sono piu' Dott.
    var earWidth: CGFloat { Self.ear + 14 * CGFloat(max(0, min(dotts.count, 3) - 1)) }

    /// Tocchi un altro progetto: passa in primo piano (e saluta con un cenno).
    func selectProject(_ key: String) {
        pinnedProject = key
        recompute()
        trigger(.nod)
    }

    static func accessory(group: [Session], lead l: Session, mood: Mood, now: Date) -> Accessory? {
        guard AppSettings.shared.accessories else { return nil }
        if mood != .waiting, group.contains(where: { $0.compacting && now.timeIntervalSince($0.updated) < 300 }) { return .broom }
        switch mood {
        case .writing: return .pencil
        case .reading, .searching: return .glasses
        case .running:
            if Risk.isRisky(l.runningCommand ?? "") { return .helmet }
            if let since = l.runningSince, now.timeIntervalSince(since) > 12 { return .headphones }
            return nil
        default: return nil
        }
    }

    /// Gli aiutanti di tutte le sessioni, nell'ordine in cui sono partiti.
    var helpers: [Helper] { sessions.values.flatMap { $0.agents.values }.sorted { $0.started < $1.started } }

    func refreshGeometry() {
        let g = NotchGeometry.current()
        if g != geometry { geometry = g; recompute() }
    }

    // MARK: Hover

    func setHover(_ inside: Bool, screen: UInt32? = nil) {
        if inside {
            hoverWork?.cancel()
            hoverWork = nil
            if !hovering || hoverScreen != screen {
                let wasHovering = hovering
                hovering = true
                hoverScreen = screen
                if !wasHovering {
                    hoverSince = Date()
                    if mood != .sleeping { trigger(.tilt) }   // ti nota
                }
                recompute()
            }
        } else if hovering, hoverScreen == screen, hoverWork == nil {
            // Chiusura ritardata; i controlli successivi non devono riprogrammarla.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.hoverWork = nil
                    self?.hovering = false
                    self?.hoverScreen = nil
                    self?.hoverSince = nil
                    self?.recompute()
                }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func setCursorNear(_ near: Bool) {
        if near != cursorNear { cursorNear = near }
    }

    // MARK: Cosa mi sono perso

    /// Secondi dall'ultimo input (mouse o tastiera), senza chiedere permessi.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var isAway: Bool { Self.idleSeconds() > 180 }

    /// Quando torni dopo almeno tre minuti, riassume cosa e' successo mentre non c'eri.
    func checkReturn() {
        let idle = Self.idleSeconds()
        if idle > 180 {
            wasAway = true
        } else if wasAway && idle < 3 {
            wasAway = false
            presentRecap()
        }
    }

    func presentRecap() {
        var lines: [RecapLine] = []
        if awayFinished.count == 1, let f = awayFinished.first {
            lines.append(RecapLine(symbol: "checkmark.circle", text: "\(f.project): finito" + (f.took.map { " in \($0)" } ?? "")))
        } else if awayFinished.count > 1 {
            lines.append(RecapLine(symbol: "checkmark.circle", text: "\(awayFinished.count) lavori finiti"))
        }
        if !awayFiles.isEmpty {
            lines.append(RecapLine(symbol: "doc.on.doc", text: "\(awayFiles.count) \(awayFiles.count == 1 ? "file modificato" : "file modificati")"))
        }
        for f in Array(Set(awayFailures)).sorted().prefix(2) {
            lines.append(RecapLine(symbol: "xmark.octagon", text: f))
        }
        if awayErrors > 0 {
            lines.append(RecapLine(symbol: "exclamationmark.triangle", text: "\(awayErrors) \(awayErrors == 1 ? "errore" : "errori")"))
        }
        let waits = permissions.count + questions.count
        if waits > 0 {
            lines.append(RecapLine(symbol: "hourglass", text: "In attesa di te: \(waits) \(waits == 1 ? "richiesta" : "richieste")"))
        }
        awayFinished = []; awayFailures = []; awayErrors = 0; awayFiles = []
        guard !lines.isEmpty else { return }
        showRecap(Array(lines.prefix(5)))
    }

    func showRecap(_ lines: [RecapLine]) {
        recap = Recap(lines: lines, until: Date().addingTimeInterval(5 + 1.2 * Double(lines.count)))
        trigger(.tilt)
        recompute()
    }

    /// Solo per le prove.
    func debugRecap(_ lines: [RecapLine]) { showRecap(lines) }

    // MARK: Gesti

    /// Avvia un gesto, senza interrompere bruscamente quello in corso.
    func trigger(_ kind: GestureKind) {
        if let g = gesture, Date().timeIntervalSince(g.at) < min(0.5, g.kind.duration) { return }
        gesture = GestureEvent(kind: kind, at: Date())
    }

    /// Un tocco sulla mascotte: una risatina, un saltello o un saluto (mai due volte lo stesso di fila).
    func poke(double: Bool = false) {
        // Troppi tocchi ravvicinati: prima si secca, poi gli gira la testa.
        let now = Date()
        pokeTimes = pokeTimes.filter { now.timeIntervalSince($0) < 8 } + [now]
        if pokeTimes.count >= 8 { pokeTimes = []; gesture = GestureEvent(kind: .dizzy, at: now); return }
        if pokeTimes.count >= 4 { trigger(.annoyed); return }
        if double { trigger(.spin); return }
        let all: [GestureKind] = [.giggle, .hop, .wave]
        let options = all.filter { $0 != lastPoke }
        let k: GestureKind = options.randomElement() ?? GestureKind.giggle
        lastPoke = k
        trigger(k)
    }

    static func nightLevel(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        if h >= 23 { return min(1, h - 23) }
        if h < 5 { return 1 }
        if h < 6 { return 1 - (h - 5) }
        return 0
    }

    private static func greetingTitle(_ date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case 5..<12: return "Buongiorno!"
        case 12..<18: return "Buon pomeriggio!"
        case 18..<24: return "Buonasera!"
        default: return "Ancora in piedi?"
        }
    }

    func peek(_ seconds: TimeInterval) {
        peekUntil = Date().addingTimeInterval(seconds)
    }

    // MARK: Eventi

    func receive(_ payload: [String: Any], from conn: Connection) {
        let e = HookEvent(raw: payload)
        if !e.name.isEmpty { eventCounts[e.name, default: 0] += 1 }

        // Comandi di prova (socket locale): {"dott_gesture":"giggle"}, {"dott_cmd":"settings"}.
        if let name = payload["dott_gesture"] as? String,
           let kind = GestureKind.allCases.first(where: { "\($0)" == name }) {
            trigger(kind)
            conn.close()
            return
        }
        if let cmd = payload["dott_cmd"] as? String {
            debugCommand(cmd, payload)
            conn.close()
            return
        }
        if payload["dott_kind"] as? String == "ask" {
            handleAsk(e, conn)
        } else if e.name == "PermissionRequest" {
            handlePermission(e, conn)
        } else if handleHeld(e, conn) {
            // Evento che aspetta una decisione tua: gestito (negato dall'auto-mode, modulo MCP, cambio di modello…).
        } else {
            handle(e)
        }
    }

    func handle(_ e: HookEvent) {
        if e.name == "SessionEnd" {
            sessions[e.sessionId] = nil
            recompute()
            return
        }
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, project: e.project ?? "Claude")
        if let p = e.project { s.project = p }

        // Legame con te: dopo una lunga assenza, o tornando su un progetto dopo giorni, Dott ti saluta.
        let now0 = Date()
        let gap = now0.timeIntervalSince(lastEventAt)
        lastEventAt = now0
        var greeting: (title: String, detail: String)?
        var greetKind: GestureKind = .wave
        if e.name == "SessionStart" || e.name == "UserPromptSubmit" {
            let seen = projectSeen[s.project].map { Date(timeIntervalSince1970: $0) }
            let awayDays = seen.map { now0.timeIntervalSince($0) > 24 * 3600 } ?? true
            let awayCount = seen.map { Int(now0.timeIntervalSince($0) / 86400) } ?? 0
            let back = awayCount >= 7 ? "\(s.project): non ci lavoravi da \(awayCount) giorni" : "Rieccoti su \(s.project)"
            if gap > 5 * 3600 {
                greeting = (Self.greetingTitle(now0), awayDays && seen != nil ? back : "Si ricomincia: \(s.project)")
            } else if awayDays && seen != nil {
                greeting = ("Rieccoti!", awayCount >= 7 ? back : "Di nuovo su \(s.project)")
            }
            // Una ricorrenza (una settimana insieme, cinque giorni di fila…) vale piu' di un saluto qualunque.
            if let m = DayLog.shared.touch(now0, name: AppSettings.shared.name) {
                greeting = m
                greetKind = .spin
            }
            projectSeen[s.project] = now0.timeIntervalSince1970
        }
        if now0.timeIntervalSince(lastPersist) > 60 {
            lastPersist = now0
            UserDefaults.standard.set(now0.timeIntervalSince1970, forKey: "dott.lastEvent")
            UserDefaults.standard.set(projectSeen, forKey: "dott.projects")
        }

        if let a = e.appBundle { s.bundleId = a }
        if let t = e.transcriptPath { s.transcript = t }
        if let c = e.cwd { s.cwd = c }
        if let m = e.permissionMode { s.permissionMode = m }
        s.updated = Date()

        // Gli eventi di un sottoagente aggiornano il suo compagnetto, non l'umore di Dott.
        if let aid = e.raw["agent_id"] as? String, var h = s.agents[aid],
           ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(e.name) {
            switch e.name {
            case "PreToolUse":
                let (m, d) = e.describeTool()
                h.mood = m
                h.activity = d.isEmpty ? m.verb : "\(m.verb) \(d)"
            case "PostToolUse":
                h.mood = .thinking
                h.activity = "Riflette"
            default:
                h.mood = .hurt
                h.activity = "Un tool ha fallito"
            }
            h.lastSeen = Date()
            s.agents[aid] = h
            sessions[e.sessionId] = s
            recompute()
            return
        }

        // Nuovo lavoro: si riapre il turno. Eventi in ritardo dopo la fine: non devono rovinare il "Fatto!".
        switch e.name {
        case "UserPromptSubmit", "PreToolUse", "SubagentStart", "SessionStart":
            s.turnFinished = false
        case "PostToolUse", "PostToolUseFailure", "SubagentStop":
            if s.turnFinished { return }
        default:
            break
        }

        switch e.name {
        case "SessionStart":
            if let g = greeting {
                s.set(.working, g.detail, hold: 3.0, headline: g.title)
                peek(3.5)
                trigger(greetKind)
            } else {
                s.set(.happy, "Pronto a lavorare", hold: 1.6)
            }
            refreshContext(e.sessionId, in: &s, force: true)
        case "UserPromptSubmit":
            let prompt = (e.raw["prompt"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            s.turnStart = Date()
            s.agents = [:]
            s.pending = []
            s.turnOutcome = nil
            s.snippet = nil
            if s.todos.allSatisfy({ $0.status == .completed }) { s.todos = [] }
            refreshContext(e.sessionId, in: &s, force: false)
            let promptDetail = prompt.isEmpty ? "Ci sta pensando" : String(prompt.prefix(120))
            s.set(.thinking, promptDetail)
            // Una serie di lavoro continua si interrompe dopo 20 minuti di silenzio.
            if lastStopAt.map({ now0.timeIntervalSince($0) > 20 * 60 }) ?? true { workStreakStart = now0 }
            if let g = greeting {
                s.set(.working, g.detail, hold: 2.8, then: .thinking, headline: g.title, thenDetail: promptDetail)
                peek(3.2)
                trigger(greetKind)
            } else {
                trigger(.tilt)   // ti ascolta
            }
        case "PreToolUse" where e.toolName == "AskUserQuestion":
            // La domanda vera arriva dall'hook dedicato; qui ci limitiamo a segnalarla.
            s.set(.waiting, "Ha una domanda per te", hold: 90)
            peek(6)
            Sounds.play(.attention)
        case "PreToolUse":
            let (mood, detail) = e.describeTool()
            if s.turnStart == nil { s.turnStart = Date() }
            if e.toolName == "Bash" {
                s.runningCommand = e.command
                s.runningSince = Date()
            } else {
                s.runningCommand = nil
                s.runningSince = nil
            }
            if e.toolName == "TodoWrite", let list = Features.parseTodos(e.toolInput) {
                s.todos = list
                if let cur = list.first(where: { $0.status == .inProgress }) {
                    s.set(.working, cur.active ?? cur.text)
                    sessions[e.sessionId] = s
                    recompute()
                    return
                }
            }
            if e.toolName == "Agent" || e.toolName == "Task" {
                // Il compito che sta per essere affidato: lo abbiniamo al sottoagente quando parte.
                let type = e.toolInput["subagent_type"] as? String ?? "general-purpose"
                s.pending.append(PendingTask(type: type, text: detail))
            }
            s.set(mood, detail)
        case "PostToolUse" where e.toolName == "Bash" && BuildParser.parse(command: e.command, output: e.bashOutput ?? "") != nil:
            // Un test o una build: l'isola dice com'e' andata, non il comando.
            let r = BuildParser.parse(command: e.command, output: e.bashOutput ?? "")!
            s.turnOutcome = r
            s.failStreak = 0
            if !r.ok, isAway { awayFailures.append("\(r.text) in \(s.project)") }
            if r.ok {
                s.set(.thinking, r.text)
                trigger(.nod)
            } else {
                s.set(.hurt, r.text, hold: 3.5, then: .thinking)
            }
            refreshContext(e.sessionId, in: &s, force: false)
        case "PostToolUse":
            if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(e.toolName), isAway,
               let f = (e.toolInput["file_path"] as? String) ?? (e.toolInput["notebook_path"] as? String) {
                awayFiles.insert(f)
            }
            if s.failStreak >= 2 {
                // Dopo qualche errore va di nuovo: un sospiro di sollievo.
                s.set(.thinking, "Rimessa in piedi")
                trigger(.sigh)
            } else {
                s.set(.thinking, "Riflette sul risultato")
            }
            s.failStreak = 0
            refreshContext(e.sessionId, in: &s, force: false)
        case "PostToolUseFailure" where e.toolName == "Bash" && BuildParser.parse(command: e.command, output: e.bashOutput ?? "") != nil:
            // Un test o una build che falliscono sono normali: non contano come "tre errori di fila".
            let r = BuildParser.parse(command: e.command, output: e.bashOutput ?? "")!
            s.turnOutcome = r
            if isAway { awayFailures.append("\(r.text) in \(s.project)") }
            s.set(.hurt, r.text, hold: 3.5, then: .thinking)
        case "PostToolUseFailure":
            let (_, detail) = e.describeTool()
            s.failStreak += 1
            if s.failStreak >= 3 {
                // Tre errori di fila: Dott si spaventa e te lo dice.
                s.set(.hurt, "Ancora un errore, sono \(s.failStreak) di fila", hold: 6, then: .thinking)
                peek(4)
                Sounds.play(.error)
            } else {
                s.set(.hurt, detail.isEmpty ? e.toolName : detail, hold: 2.5, then: .thinking)
            }
        case "Notification" where Features.isSpecialNotification(e.raw["notification_type"] as? String ?? ""):
            let kind = e.raw["notification_type"] as? String ?? ""
            let message = e.raw["message"] as? String ?? ""
            guard let n = Features.describeNotification(kind: kind, message: message) else { return }
            s.set(n.mood, n.detail, hold: n.hold, then: n.mood == .happy ? .sleeping : .waiting, headline: n.title)
            peek(5)
            if n.mood == .waiting { Sounds.play(.attention) }
        case "Notification":
            let message = e.raw["message"] as? String ?? "Ha bisogno di te"
            let kind = e.raw["notification_type"] as? String ?? ""
            let hold: TimeInterval = kind == "idle_prompt" ? 12 : (kind == "permission_prompt" ? 90 : 30)
            s.set(.waiting, message, hold: hold)
            peek(5)
            Sounds.play(.attention)
        case "Stop":
            // Stop vero e Stop ricavato dalla trascrizione dicono la stessa cosa: vale il primo.
            if s.turnFinished { return }
            s.turnFinished = true
            let seconds = s.turnStart.map { Date().timeIntervalSince($0) }
            let took = seconds.map(Self.format)
            s.turnStart = nil
            s.agents = [:]
            s.pending = []
            s.failStreak = 0
            refreshContext(e.sessionId, in: &s, force: true)
            if let seconds, seconds >= 10 { Sounds.play(.done) }
            var detail = took.map { "Finito in \($0)" } ?? "Finito"
            if let o = s.turnOutcome { detail += " · \(o.short)" }
            if let seconds, seconds >= 300 { detail += " — è stata lunga!" }
            // Dopo due ore di lavoro continuo, un invito gentile a staccare (al massimo ogni due ore).
            if let start = workStreakStart, now0.timeIntervalSince(start) >= 2 * 3600,
               lastNudge.map({ now0.timeIntervalSince($0) > 2 * 3600 }) ?? true {
                let hours = Int(now0.timeIntervalSince(start) / 3600)
                detail += " · Lavori da \(hours) ore: una pausa?"
                lastNudge = now0
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    MainActor.assumeIsolated { self?.trigger(.stretch) }
                }
            }
            lastStopAt = now0
            s.lastPRCheck = .distantPast
            if isAway { awayFinished.append((s.project, took)) }
            s.snippet = e.lastAssistantMessage.flatMap(Features.snippet(from:))
            s.set(.happy, detail, hold: s.snippet == nil ? 6 : 9)
            peek(s.snippet == nil ? 5 : 8)
        case "StopFailure":
            let (failTitle, msg) = Features.failureText(type: e.raw["error"] as? String, details: e.raw["error_details"] as? String)
            s.turnStart = nil
            s.agents = [:]
            s.set(.hurt, msg, hold: 8, headline: failTitle)
            peek(5)
            Sounds.play(.error)
        case "PreCompact":
            s.compacting = true
            let auto = (e.raw["trigger"] as? String) == "auto"
            s.set(.working, auto ? "Il contesto è pieno: lo comprime" : "Comprime la memoria", headline: "Fa spazio")
            trigger(.stretch)
            peek(4)
        case "PostCompact":
            s.compacting = false
            s.warnedContext = false
            s.set(.thinking, "Memoria compressa")
            trigger(.sneeze)   // la polvere della scopa
            refreshContext(e.sessionId, in: &s, force: true)
            refreshContextSoon(e.sessionId, after: 2.5)
        case "TaskCreated":
            if let id = e.raw["task_id"] as? String, let t = e.raw["task_subject"] as? String, !s.todos.contains(where: { $0.id == id }) {
                s.todos.append(TodoItem(id: id, text: t, active: nil, status: .pending))
            }
        case "TaskCompleted":
            if let id = e.raw["task_id"] as? String {
                if let i = s.todos.firstIndex(where: { $0.id == id }) { s.todos[i].status = .completed }
                else if let t = e.raw["task_subject"] as? String { s.todos.append(TodoItem(id: id, text: t, active: nil, status: .completed)) }
            }
        case "SubagentStart":
            let id = e.raw["agent_id"] as? String ?? UUID().uuidString
            let type = e.raw["agent_type"] as? String ?? "agente"
            var task = type
            if let i = s.pending.firstIndex(where: { $0.type == type }) ?? (s.pending.isEmpty ? nil : 0) {
                let t = s.pending.remove(at: i).text
                if !t.isEmpty { task = t }
            }
            s.agents[id] = Helper(id: id, type: type, task: task, activity: "Parte", mood: .working,
                                  colorIndex: s.helperSeq % PaletteCount.helpers)
            s.helperSeq += 1
            s.set(.working, Self.helpers(s.agents.count))
            peek(4)
        case "SubagentStop":
            if let id = e.raw["agent_id"] as? String, s.agents[id] != nil {
                s.agents[id] = nil
            } else if let oldest = s.agents.values.min(by: { $0.started < $1.started })?.id {
                s.agents[oldest] = nil
            }
            if s.agents.isEmpty {
                // Gli aiutanti hanno consegnato: Claude ora rielabora quello che gli hanno riportato.
                s.set(.thinking, "Rielabora il lavoro degli aiutanti")
            } else {
                // Ne restano altri al lavoro: Dott sta ancora delegando, non pensando.
                s.set(.working, Self.helpers(s.agents.count))
            }
        default:
            return
        }
        sessions[e.sessionId] = s
        recompute()
    }

    // MARK: Permessi

    func handlePermission(_ e: HookEvent, _ conn: Connection) {
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, project: e.project ?? "Claude")
        if let p = e.project { s.project = p }
        s.updated = Date()

        // Le domande arrivano dall'hook dedicato; se passano di qui le segnaliamo e basta.
        if e.toolName == "AskUserQuestion" {
            s.set(.waiting, "Ha una domanda per te", hold: 90)
            sessions[e.sessionId] = s
            peek(6)
            conn.close()
            recompute()
            return
        }

        conn.held = true
        let input = e.toolInput
        var preview: String
        switch e.toolName {
        case "Bash": preview = input["command"] as? String ?? ""
        case "Edit", "MultiEdit", "Write", "NotebookEdit": preview = (input["file_path"] as? String) ?? ""
        case "ExitPlanMode": preview = input["plan"] as? String ?? ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { preview = text } else { preview = "" }
        }
        let limit = e.toolName == "ExitPlanMode" ? 8000 : 400
        if preview.count > limit { preview = String(preview.prefix(limit)) + "…" }

        let item = PermissionItem(sessionId: e.sessionId, project: s.project, tool: e.toolName,
                                  preview: preview, suggestions: e.raw["permission_suggestions"] as? [Any] ?? [],
                                  connection: conn)
        // Se Claude Code chiude l'hook (risposta data nel terminale), l'isola si ritira.
        conn.onClose = { [weak self, weak item] in
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.permissions.removeAll { $0.id == item.id }
                self.clearWaiting(item.sessionId)
                self.recompute()
            }
        }
        s.set(.waiting, e.toolName == "ExitPlanMode" ? "Il piano è pronto da approvare" : e.toolName, hold: nil)
        sessions[e.sessionId] = s
        permissions.append(item)
        Sounds.play(.attention)
        recompute()
    }

    /// Una richiesta e' stata ritirata (risposta data altrove): la sessione non aspetta piu' nessuno.
    func clearWaiting(_ sessionId: String) {
        guard var s = sessions[sessionId], s.mood == .waiting, s.holdUntil == nil,
              !permissions.contains(where: { $0.sessionId == sessionId }),
              !questions.contains(where: { $0.sessionId == sessionId }) else { return }
        s.set(.thinking, "Sta proseguendo")
        sessions[sessionId] = s
    }

    func resolve(_ item: PermissionItem, _ decision: PermissionDecision) {
        if let r = item.response(for: decision) { item.connection.reply(r) } else { item.connection.close() }
        Sounds.play(.sent)
        trigger(decision == .deny ? .tilt : .nod)
        permissions.removeAll { $0.id == item.id }
        if var s = sessions[item.sessionId] {
            s.set(decision == .deny ? .thinking : .working, decision == .deny ? "Permesso negato" : item.tool)
            sessions[item.sessionId] = s
        }
        recompute()
    }

    // MARK: Domande

    func handleAsk(_ e: HookEvent, _ conn: Connection) {
        let raw = e.toolInput["questions"] as? [Any] ?? []
        let specs = raw.compactMap { ($0 as? [String: Any]).flatMap(AskSpec.init) }
        // Domanda che non capiamo: nessuna risposta, Claude la chiede nel terminale.
        guard !specs.isEmpty, specs.count == raw.count else { conn.close(); return }

        conn.held = true
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, project: e.project ?? "Claude")
        if let p = e.project { s.project = p }
        s.updated = Date()
        s.set(.waiting, "Ha una domanda per te", hold: nil)
        sessions[e.sessionId] = s

        let q = QuestionState(sessionId: e.sessionId, project: s.project, specs: specs, rawQuestions: raw, connection: conn)
        let id = q.id
        // Se la domanda viene chiusa altrove (hai risposto nel terminale), l'isola si ritira.
        conn.onClose = { [weak self] in
            MainActor.assumeIsolated {
                self?.questions.removeAll { $0.id == id }
                self?.clearWaiting(e.sessionId)
                self?.recompute()
            }
        }
        questions.append(q)
        peek(6)
        Sounds.play(.attention)
        recompute()
    }

    /// Un clic su un'opzione: risposta singola, oppure (a scelta multipla) spunta o toglie.
    func pick(_ id: UUID, _ label: String) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        var q = questions[i]
        let spec = q.current
        if spec.multi {
            if let at = q.selected.firstIndex(of: label) { q.selected.remove(at: at) } else { q.selected.append(label) }
            questions[i] = q
            recompute()
        } else {
            q.answers[spec.text] = label
            advance(q, at: i)
        }
    }

    /// "Avanti" / "Invia" nelle domande a scelta multipla.
    func confirmMulti(_ id: UUID) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        var q = questions[i]
        guard !q.selected.isEmpty else { return }
        let order = q.current.options.map(\.label)
        q.answers[q.current.text] = q.selected.sorted { (order.firstIndex(of: $0) ?? Int.max) < (order.firstIndex(of: $1) ?? Int.max) }
        advance(q, at: i)
    }

    func advance(_ state: QuestionState, at i: Int) {
        var q = state
        Sounds.play(.sent)
        trigger(.nod)
        if q.index + 1 < q.specs.count {
            q.index += 1
            q.selected = []
            questions[i] = q
        } else {
            let out: [String: Any] = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": ["questions": q.rawQuestions, "answers": q.answers],
            ]]
            q.connection.reply(out)
            questions.remove(at: i)
            if var s = sessions[q.sessionId] {
                s.set(.working, "Risposta data")
                sessions[q.sessionId] = s
            }
        }
        recompute()
    }

    /// "Rispondi nel terminale": chiudiamo senza output e Claude Code chiede come sempre.
    func askInTerminal(_ id: UUID) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        let q = questions.remove(at: i)
        q.connection.close()
        if var s = sessions[q.sessionId] {
            s.set(.waiting, "Rispondi nel terminale", hold: 90)
            sessions[q.sessionId] = s
        }
        recompute()
    }

    // MARK: Testo libero

    func beginFreeText(_ id: UUID) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[i].typing = true
        recompute()
    }

    func cancelFreeText(_ id: UUID) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[i].typing = false
        recompute()
    }

    func submitFreeText(_ id: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = questions.firstIndex(where: { $0.id == id }) else { return }
        var q = questions[i]
        q.typing = false
        if q.current.multi {
            q.selected.append(t)
            questions[i] = q
            confirmMulti(id)
        } else {
            q.answers[q.current.text] = t
            advance(q, at: i)
        }
    }

    // MARK: Tornare alla sessione

    /// Porta in primo piano l'app da cui parte la sessione (quella indicata, o la piu' urgente).
    func focus(_ sessionId: String? = nil) {
        let s = sessionId.flatMap { sessions[$0] } ?? lead
        guard let bundle = s?.bundleId,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Contesto

    /// Legge in background quanto contesto ha usato la sessione (al massimo ogni 15 secondi).
    func refreshContext(_ id: String, in s: inout Session, force: Bool) {
        guard let path = s.transcript else { return }
        let now = Date()
        guard force || now.timeIntervalSince(s.lastContextRead) > 15 else { return }
        s.lastContextRead = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let r = ContextMeter.read(path: path) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var t = self.sessions[id] else { return }
                    t.contextTokens = r.tokens
                    t.contextWindow = r.window
                    if let f = t.contextFraction {
                        if f >= 0.9, !t.warnedContext { t.warnedContext = true; self.peek(5); self.trigger(.tilt) }
                        if f < 0.6 { t.warnedContext = false }
                    }
                    self.sessions[id] = t
                    self.recompute()
                }
            }
        }
    }

    // MARK: Anteprima dal menu

    func previewQuestion() {
        let raw: [[String: Any]] = [[
            "question": "Che stile preferisci per la nuova schermata?", "header": "Stile", "multiSelect": false,
            "options": [["label": "Minimale", "description": "Poche scritte, molto spazio"],
                        ["label": "Denso", "description": "Più informazioni in una vista"],
                        ["label": "Come l'altra app", "description": "Stesso aspetto della Home"]],
        ]]
        let specs = raw.compactMap(AskSpec.init)
        let conn = Connection(fd: -1) { _, _ in }
        conn.held = true
        let q = QuestionState(sessionId: "preview-q", project: "Anteprima", specs: specs, rawQuestions: raw, connection: conn)
        let id = q.id
        conn.onClose = { [weak self] in
            MainActor.assumeIsolated { self?.questions.removeAll { $0.id == id }; self?.recompute() }
        }
        var s = Session(id: "preview-q", project: "Anteprima")
        s.set(.waiting, "Ha una domanda per te", hold: 60)
        sessions["preview-q"] = s
        questions.append(q)
        Sounds.play(.attention)
        recompute()
    }

    func previewAgents() {
        var s = Session(id: "preview", project: "Anteprima")
        let samples: [(String, String, String, Mood)] = [
            ("Explore", "Cerca dove si calcola il budget", "Legge BudgetView.swift", .reading),
            ("general-purpose", "Controlla che i test passino", "Esegue swift test", .running),
            ("Plan", "Disegna la migrazione 013", "Scrive 013_goals.sql", .writing),
        ]
        for (i, x) in samples.enumerated() {
            s.agents["p\(i)"] = Helper(id: "p\(i)", type: x.0, task: x.1, activity: x.2, mood: x.3, colorIndex: i)
        }
        s.set(.working, Self.helpers(samples.count), hold: 10)
        s.turnStart = Date()
        sessions["preview"] = s
        peek(10)
        recompute()
    }

    /// Prova la scopa: una compattazione finta di una decina di secondi.
    func previewCompact() {
        let dummy = Connection(fd: -1) { _, _ in }
        receive(["hook_event_name": "PreCompact", "session_id": "preview", "cwd": "/Users/x/Anteprima", "trigger": "manual"], from: dummy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            self?.receive(["hook_event_name": "PostCompact", "session_id": "preview", "cwd": "/Users/x/Anteprima"], from: dummy)
        }
    }

    static func helpers(_ n: Int) -> String {
        n == 1 ? "Un aiutante è al lavoro" : "\(n) aiutanti al lavoro"
    }

    func preview(_ mood: Mood) {
        var s = Session(id: "preview", project: "Anteprima")
        s.set(mood, mood == .waiting ? "Ha bisogno di te" : "Anteprima dell'umore", hold: 6)
        if mood != .sleeping { s.turnStart = Date() }
        sessions["preview"] = s
        peek(6)
        recompute()
    }

    // MARK: Ricalcolo

    func tick() {
        checkTranscripts()
        checkReturn()
        if let r = recap, Date() >= r.until, !hovering { recap = nil }
        if expanded, let l = lead { refreshRepo(l.id) }

        let o = AppSettings.shared.outfit(on: Date())
        if o != outfit { outfit = o }

        let n = Self.nightLevel(Date())
        if abs(n - night) > 0.02 { night = n }

        // Se resti a lungo sopra di lei, ogni tanto si guarda in giro, inclina la testa o insegue una lucciola.
        let idleGesture = gesture.map { Date().timeIntervalSince($0.at) > 9 } ?? true
        if let since = hoverSince, Date().timeIntervalSince(since) > 6, idleGesture {
            let all: [GestureKind] = mood == .sleeping ? [.chase] : [.peek, .tilt, .wave, .chase]
            trigger(all.randomElement() ?? .peek)
        }
        // Un lavoro che va per le lunghe: fischietta, senza darti fastidio (mai con te sopra, mai di seguito).
        else if !hovering, idleGesture, let l = lead, let start = l.turnStart,
                [.thinking, .working, .reading, .writing, .searching].contains(l.mood),
                Date().timeIntervalSince(start) > 80, Date().timeIntervalSince(lastWhistle) > 150,
                Int.random(in: 0..<6) == 0 {
            lastWhistle = Date()
            trigger(.whistle)
        }
        recompute()
    }

    /// Una sessione "al lavoro" ma muta da qualche secondo: potrebbe essere finita o essere stata
    /// interrotta senza che Claude Code ce lo dica (niente `Stop`). Lo verifichiamo nella trascrizione.
    func checkTranscripts() {
        let now = Date()
        let active: Set<Mood> = [.thinking, .working, .reading, .writing, .running, .searching]
        for (id, var s) in sessions where active.contains(s.mood) && s.holdUntil == nil {
            guard let path = s.transcript, now.timeIntervalSince(s.updated) > 4,
                  now.timeIntervalSince(s.lastInterruptCheck) > 3 else { continue }
            s.lastInterruptCheck = now
            sessions[id] = s
            let stamp = s.updated
            let cwd = s.project
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let state = TranscriptState.read(path: path)
                guard state != .working else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let t = self.sessions[id], t.updated == stamp else { return }
                        switch state {
                        case .finished:
                            // Come se fosse arrivato `Stop`: festa, tempo impiegato, suono.
                            self.handle(HookEvent(raw: ["hook_event_name": "Stop", "session_id": id, "cwd": "/\(cwd)"]))
                        case .interrupted:
                            var u = t
                            u.agents = [:]
                            u.pending = []
                            u.turnStart = nil
                            u.set(.sleeping, "Interrotto")
                            self.sessions[id] = u
                            self.recompute()
                        case .working:
                            break
                        }
                    }
                }
            }
        }
    }

    func refresh() { recompute() }

    func recompute() {
        let now = Date()

        for (k, var s) in sessions {
            if let h = s.holdUntil, h <= now {
                s.mood = s.after
                if let d = s.afterDetail { s.detail = d }
                s.headline = nil
                s.afterDetail = nil
                s.holdUntil = nil
                if s.id.hasPrefix("preview") { sessions[k] = nil; continue }
                sessions[k] = s
            }
            if now.timeIntervalSince(s.updated) > 6 * 3600 { sessions[k] = nil }
            // Un aiutante che non da' segni di vita da tre minuti non c'e' piu' (partenza senza fine, interruzione).
            if s.agents.values.contains(where: { now.timeIntervalSince($0.lastSeen) > 180 }), var t = sessions[k] {
                t.agents = t.agents.filter { now.timeIntervalSince($0.value.lastSeen) <= 180 }
                sessions[k] = t
            }
        }

        // Un Dott per progetto.
        var groups: [String: [Session]] = [:]
        for sess in sessions.values { groups[Self.projectKey(sess), default: []].append(sess) }
        for k in groups.keys.sorted() where !projectOrder.contains(k) { projectOrder.append(k) }
        projectOrder.removeAll { groups[$0] == nil }
        let waiting = Set(permissions.map(\.sessionId) + questions.map(\.sessionId) + elicitations.map(\.sessionId))
        var newDotts: [ProjectDott] = []
        for k in projectOrder {
            guard let g = groups[k], let l = g.max(by: { ($0.mood.priority, $0.updated) < ($1.mood.priority, $1.updated) }) else { continue }
            let m: Mood = g.contains(where: { waiting.contains($0.id) }) ? .waiting : l.mood
            newDotts.append(ProjectDott(id: k, name: l.project, mood: m, sessionId: l.id,
                                        accessory: Self.accessory(group: g, lead: l, mood: m, now: now),
                                        detail: l.detail, contextFraction: l.contextFraction, turnStart: l.turnStart,
                                        agents: g.reduce(0) { $0 + $1.agents.count }, sessions: g.count))
        }
        if newDotts != dotts { dotts = newDotts }

        let ranked = sessions.values.sorted { ($0.mood.priority, $0.updated) > ($1.mood.priority, $1.updated) }
        var newMood = ranked.first?.mood ?? .sleeping
        var newLead = ranked.first
        if let p = permissions.first {
            newMood = .waiting
            newLead = sessions[p.sessionId] ?? newLead
        } else if let q = questions.first {
            newMood = .waiting
            newLead = sessions[q.sessionId] ?? newLead
        } else if let el = elicitations.first {
            newMood = .waiting
            newLead = sessions[el.sessionId] ?? newLead
        }
        // Hai scelto un progetto: resta in primo piano, salvo che qualcosa ti chieda un'azione.
        if let pk = pinnedProject {
            if permissions.isEmpty, questions.isEmpty, elicitations.isEmpty {
                if let d = newDotts.first(where: { $0.id == pk }), let ps = sessions[d.sessionId] {
                    newLead = ps
                    newMood = d.mood
                } else {
                    pinnedProject = nil
                }
            }
        }
        if newMood != mood { mood = newMood }
        if newLead?.id != lead?.id || newLead?.detail != lead?.detail || newLead?.mood != lead?.mood
            || newLead?.project != lead?.project || newLead?.turnStart != lead?.turnStart
            || newLead?.agents.count != lead?.agents.count
            || newLead?.contextTokens != lead?.contextTokens
            || newLead?.headline != lead?.headline
            || newLead?.todos != lead?.todos
            || newLead?.pr != lead?.pr
            || newLead?.snippet != lead?.snippet
            || newLead?.permissionMode != lead?.permissionMode
            || newLead?.agents.values.map(\.activity) != lead?.agents.values.map(\.activity) {
            lead = newLead
        }

        // Accessorio: dipende da cosa sta facendo (e da quanto: le cuffie servono per un lavoro lungo).
        var acc = newLead.flatMap { l in newDotts.first(where: { $0.id == Self.projectKey(l) })?.accessory }
        if AppSettings.shared.accessories, let p = permissions.first, p.tool == "Bash", Risk.isRisky(p.preview) { acc = .helmet }
        if acc != accessory { accessory = acc }

        let kb = questions.contains { $0.typing } || (elicitations.first?.needsKeyboard ?? false)
        if kb != wantsKeyboard { wantsKeyboard = kb }

        // Aperta "di base" (avvisi, permessi…) su tutti gli schermi; il passaggio del mouse apre solo lo schermo toccato.
        let base = forceExpanded ?? (!permissions.isEmpty || !questions.isEmpty || !elicitations.isEmpty || pinned || recap != nil || now < peekUntil)
        if base != baseExpanded { baseExpanded = base }
        let isExpanded = forceExpanded ?? (base || hovering)
        if isExpanded != expanded { expanded = isExpanded }

        let newSize = computeSize(geometry, expanded: isExpanded)
        if newSize != size { size = newSize }

        // Firma di tutto cio' che si vede: se cambia, la vista anima il passaggio.
        var sig = "\(mood)|\(isExpanded)|\(hovering)|\(newSize.width)x\(newSize.height)|\(lead?.id ?? "")|\(lead?.mood.rawValue ?? "")|\(lead?.detail ?? "")|\(lead?.headline ?? "")|\(lead?.project ?? "")"
        sig += "|\(Int((lead?.contextFraction ?? 0) * 100))"
        if let l = lead { sig += "|g\(l.pr?.branch ?? "")\(l.pr?.number ?? 0)\(String(describing: l.pr?.ci))" }
        if let l = lead { sig += "|t\(l.todos.map { "\($0.status.rawValue.prefix(1))\($0.text.prefix(8))" }.joined())|s\(l.snippet ?? "")|m\(l.permissionMode ?? "")" }
        for h in helpers { sig += "|h\(h.id):\(h.mood.rawValue):\(h.activity)" }
        for d in dotts { sig += "|o\(d.id):\(d.mood.rawValue):\(d.detail):\(Int((d.contextFraction ?? 0) * 100)):\(d.accessory.map { "\($0)" } ?? "")" }
        for p in permissions { sig += "|p\(p.id)" }
        for el in elicitations { sig += "|e\(el.id)" }
        if let r = recap { sig += "|r\(r.lines.count):\(r.lines.first?.text ?? "")" }
        for q in questions { sig += "|q\(q.id):\(q.index):\(q.selected.joined(separator: ",")):\(q.typing)" }
        if sig != lastSignature { lastSignature = sig; version += 1 }
    }

    /// Le dimensioni dell'isola su uno schermo con la geometria `g` (la notch cambia da schermo a schermo).
    func computeSize(_ g: NotchGeometry, expanded isExpanded: Bool) -> CGSize {
        let compactBody = g.notchWidth + 2 * earWidth
        var body = compactBody
        var height = g.notchHeight
        if isExpanded {
            if let p = permissions.first {
                body = max(compactBody, 440)
                height = g.notchHeight + (p.tool == "ExitPlanMode" ? 300 : (196 + (AppSettings.shared.globalShortcuts ? 14 : 0)))
            } else if let q = questions.first {
                body = max(compactBody, 440)
                height = g.notchHeight + 122 + 46 * CGFloat(q.current.options.count)
            } else if let el = elicitations.first {
                body = max(compactBody, 440)
                height = g.notchHeight + el.height
            } else if let r = recap {
                body = max(compactBody, 380)
                height = g.notchHeight + 56 + 26 * CGFloat(r.lines.count) + 12
            } else {
                body = max(compactBody, 380)
                height = g.notchHeight + 84
                let n = leadHelpers.count
                if n > 0 { height += 10 + 38 * CGFloat(min(n, 4)) + (n > 4 ? 18 : 0) }
                if let l = lead {
                    if !l.todos.isEmpty {
                        let open = l.todos.filter { $0.status != .completed }.count
                        height += 14 + 26 + 22 * CGFloat(min(3, open)) + 10
                    }
                    if mood == .happy, l.snippet != nil { height += 34 }
                    if l.pr != nil, AppSettings.shared.showGitHub { height += 30 }
                }
                let others = otherDotts.filter { !$0.sessionId.hasPrefix("preview") }.count
                if others > 0 { height += 30 + 40 * CGFloat(min(others, 4)) + (others > 4 ? 16 : 0) }
            }
        }
        return CGSize(width: body + 2 * Self.topRadius, height: height)
    }

    /// Sullo schermo `id` l'isola e' aperta? (da sola, o perche' ci stai passando sopra)
    func isExpanded(on id: UInt32?) -> Bool {
        if let f = forceExpanded { return f }
        return baseExpanded || (hovering && (hoverScreen == nil || id == nil || hoverScreen == id))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
