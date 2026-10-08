import Foundation

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case decision, preference, gotcha, fact

    public var label: String {
        switch self {
        case .decision: "Decisione"
        case .preference: "Preferenza"
        case .gotcha: "Attenzione"
        case .fact: "Fatto"
        }
    }
}

/// Qualcosa che Dott ricorda di un progetto e che Claude deve sapere all'inizio di ogni chat.
public struct MemoryNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: NoteKind
    public var text: String
    public var created: Date
    /// Una nota fissata e' la prima a entrare nel promemoria.
    public var pinned: Bool
    /// Spenta, resta scritta ma non viene consegnata.
    public var enabled: Bool

    public init(id: UUID = UUID(), kind: NoteKind, text: String, created: Date = Date(), pinned: Bool = false, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.text = text
        self.created = created
        self.pinned = pinned
        self.enabled = enabled
    }
}

/// Un appunto catturato al volo: aspetta la prossima chat del progetto e viene consegnato una volta sola.
public struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var created: Date

    public init(id: UUID = UUID(), text: String, created: Date = Date()) {
        self.id = id
        self.text = text
        self.created = created
    }
}

/// Dove eravamo rimasti: lo scrive Dott quando una chat si ferma.
public struct Handoff: Codable, Equatable, Sendable {
    public var savedAt: Date
    public var lastPrompt: String?
    public var lastOutcome: String?
    public var openTodos: [String]
    public var files: [String]
    public var branch: String?

    public init(savedAt: Date, lastPrompt: String? = nil, lastOutcome: String? = nil, openTodos: [String] = [], files: [String] = [], branch: String? = nil) {
        self.savedAt = savedAt
        self.lastPrompt = lastPrompt
        self.lastOutcome = lastOutcome
        self.openTodos = openTodos
        self.files = files
        self.branch = branch
    }

    /// Costruisce il "dove eravamo" dagli eventi di un progetto (gia' filtrati) e da quello che l'app sa in piu'.
    public static func make(from events: [JournalEvent], openTodos: [String], branch: String?, outcome: String?, now: Date) -> Handoff? {
        guard events.contains(where: { $0.kind == .prompt }) else { return nil }
        let sorted = events.sorted { $0.at < $1.at }
        var files: [String] = []
        for e in sorted where e.kind == .edit {
            guard let t = e.text, !t.isEmpty else { continue }
            files.removeAll { $0 == t }
            files.append(t)
        }
        return Handoff(savedAt: now,
                       lastPrompt: sorted.last(where: { $0.kind == .prompt })?.text,
                       lastOutcome: outcome ?? sorted.last(where: { $0.kind == .stop })?.text,
                       openTodos: Array(openTodos.prefix(6)),
                       files: Array(files.suffix(8)),
                       branch: branch)
    }
}

/// Tutto cio' che Dott sa di un progetto.
public struct ProjectMemory: Codable, Equatable, Sendable {
    public var version = 1
    public var key: String
    public var name: String
    public var notes: [MemoryNote] = []
    public var inbox: [InboxItem] = []
    public var handoff: Handoff?
    /// Spento, Dott non consegna niente a Claude per questo progetto.
    public var briefEnabled = true

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// Un file per progetto, in `memory/`. Si apre con qualsiasi editor e si cancella senza conseguenze.
public final class MemoryStore {
    private let dir: URL
    private let lock = NSLock()

    public init(dir: URL) { self.dir = dir }

    private func url(_ key: String) -> URL { dir.appendingPathComponent(DottPaths.fileName(for: key) + ".json") }

    public func load(_ key: String, name: String = "") -> ProjectMemory {
        lock.lock(); defer { lock.unlock() }
        return loadLocked(key, name: name)
    }

    private func loadLocked(_ key: String, name: String) -> ProjectMemory {
        var m = JSONFile.read(ProjectMemory.self, from: url(key)) ?? ProjectMemory(key: key, name: name)
        if !name.isEmpty { m.name = name }
        return m
    }

    /// Cambia la memoria di un progetto e la salva, tutto sotto lo stesso lucchetto.
    @discardableResult
    public func update(_ key: String, name: String = "", _ change: (inout ProjectMemory) -> Void) -> ProjectMemory {
        lock.lock(); defer { lock.unlock() }
        var m = loadLocked(key, name: name)
        change(&m)
        try? JSONFile.write(m, to: url(key))
        return m
    }

    /// Tutti i progetti che hanno qualcosa da ricordare.
    public func all() -> [ProjectMemory] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { JSONFile.read(ProjectMemory.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func eraseAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Il promemoria

/// Una stima prudente dei token di un testo (l'italiano ne usa piu' dell'inglese): serve a tenere il promemoria sotto un tetto.
public enum TokenEstimate {
    public static func of(_ text: String) -> Int {
        Int((Double(text.unicodeScalars.count) / 3.2).rounded(.up))
    }
}

public struct BriefOptions: Sendable {
    /// Il tetto massimo di token del promemoria.
    public var tokenBudget = 600
    /// Un "dove eravamo" piu' vecchio di cosi' non si consegna: sarebbe rumore.
    public var handoffMaxAgeDays = 30
    public var ownerName: String

    public init(tokenBudget: Int = 600, handoffMaxAgeDays: Int = 30, ownerName: String = "") {
        self.tokenBudget = tokenBudget
        self.handoffMaxAgeDays = handoffMaxAgeDays
        self.ownerName = ownerName
    }
}

public struct Brief: Equatable, Sendable {
    public var text: String
    public var estimatedTokens: Int
    public var includedNotes: [UUID]
    public var deliveredInbox: [UUID]
    /// Note che non sono entrate per il tetto: l'app lo dice, cosi' sai cosa Claude non ha visto.
    public var droppedNotes: Int
}

public enum BriefBuilder {
    private struct Line {
        enum Section: Int { case notes, handoff, inbox }
        var section: Section
        var priority: Int
        var text: String
        var noteId: UUID?
        var inboxId: UUID?
    }

    /// Il promemoria per l'inizio di una chat, o nil se non c'e' niente di utile da dire (meglio il silenzio che il rumore).
    public static func build(_ m: ProjectMemory, now: Date, options: BriefOptions = BriefOptions(), format: DayFormat = DayFormat()) -> Brief? {
        guard m.briefEnabled else { return nil }

        var lines: [Line] = []
        let notes = m.notes.filter { $0.enabled && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (i, n) in notes.sorted(by: { $0.created > $1.created }).enumerated() {
            lines.append(Line(section: .notes, priority: n.pinned ? 0 : 30 + i, text: "- (\(n.kind.label.lowercased())) \(oneLine(n.text, 280))", noteId: n.id))
        }

        if let h = m.handoff, let age = format.calendar.dateComponents([.day], from: h.savedAt, to: now).day, age <= options.handoffMaxAgeDays {
            var parts: [(Int, String)] = []
            if let p = h.lastPrompt, !p.isEmpty { parts.append((10, "- Ultima richiesta: «\(oneLine(p, 200))»")) }
            if let o = h.lastOutcome, !o.isEmpty { parts.append((11, "- Come era finita: \(oneLine(o, 200))")) }
            if !h.openTodos.isEmpty { parts.append((12, "- Ancora aperto: " + h.openTodos.map { oneLine($0, 80) }.joined(separator: "; "))) }
            if !h.files.isEmpty { parts.append((20, "- File toccati: " + h.files.joined(separator: ", "))) }
            if let b = h.branch, !b.isEmpty { parts.append((21, "- Ramo: \(b)")) }
            for (prio, t) in parts { lines.append(Line(section: .handoff, priority: prio, text: t)) }
        }

        for (i, item) in m.inbox.sorted(by: { $0.created < $1.created }).enumerated() {
            lines.append(Line(section: .inbox, priority: 5 + i, text: "- \(oneLine(item.text, 280))", inboxId: item.id))
        }
        guard !lines.isEmpty else { return nil }

        let owner = options.ownerName.isEmpty ? "chi usa Dott" : options.ownerName
        let header = "[Promemoria di Dott per «\(m.name)» — scritto da \(owner), non e' una richiesta]"
        let footer = "Usalo solo se serve al compito; se qualcosa qui e' superato, dillo."
        var used = TokenEstimate.of(header) + TokenEstimate.of(footer)
        // I titoli delle sezioni costano poco ma si contano lo stesso.
        let titles: [Line.Section: String] = [.notes: "Da ricordare:", .handoff: "Dove eravamo (\(m.handoff.map { format.ago($0.savedAt, now: now) } ?? "")):", .inbox: "Appunti lasciati mentre non c'eri:"]

        var chosen: [Line] = []
        var dropped = 0
        for l in lines.sorted(by: { $0.priority == $1.priority ? $0.text < $1.text : $0.priority < $1.priority }) {
            var cost = TokenEstimate.of(l.text) + 1
            if !chosen.contains(where: { $0.section == l.section }) { cost += TokenEstimate.of(titles[l.section] ?? "") + 1 }
            if used + cost <= options.tokenBudget {
                chosen.append(l)
                used += cost
            } else if l.noteId != nil {
                dropped += 1
            }
        }
        guard !chosen.isEmpty else { return nil }

        var out = [header]
        for section in [Line.Section.notes, .handoff, .inbox] {
            let inSection = chosen.filter { $0.section == section }.sorted { $0.priority < $1.priority }
            guard !inSection.isEmpty, let title = titles[section] else { continue }
            out.append(title)
            out += inSection.map(\.text)
        }
        out.append(footer)
        let text = out.joined(separator: "\n")
        return Brief(text: text, estimatedTokens: TokenEstimate.of(text),
                     includedNotes: chosen.compactMap(\.noteId), deliveredInbox: chosen.compactMap(\.inboxId), droppedNotes: dropped)
    }

    private static func oneLine(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

// MARK: - Cattura rapida

/// Cosa vuoi fare con una riga scritta nel campo di cattura rapida.
public struct CaptureIntent: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Un appunto per la prossima chat del progetto.
        case inbox
        /// Una nota che resta.
        case note(NoteKind)
    }
    /// Il nome del progetto scritto dopo la chiocciola, se c'e'.
    public var project: String?
    public var action: Action
    public var text: String
}

public enum CaptureParser {
    private static let commands: [String: NoteKind] = [
        "ricorda": .fact, "fatto": .fact, "decisione": .decision, "decido": .decision,
        "preferenza": .preference, "preferisco": .preference, "attenzione": .gotcha, "trappola": .gotcha,
    ]

    /// "@Workout /decisione usiamo SwiftData" → progetto Workout, nota di tipo decisione.
    /// Senza comando e' un appunto per la prossima chat. Il progetto puo' avere spazi se scritto fra virgolette: @"Il mio progetto".
    public static func parse(_ raw: String) -> CaptureIntent? {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        var project: String?
        var action = CaptureIntent.Action.inbox

        // Il comando e il progetto possono stare in qualunque ordine, ma solo all'inizio.
        for _ in 0..<2 {
            if rest.hasPrefix("@") {
                rest.removeFirst()
                if rest.hasPrefix("\"") {
                    rest.removeFirst()
                    guard let close = rest.firstIndex(of: "\"") else { return nil }
                    project = String(rest[rest.startIndex..<close])
                    rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? rest.endIndex
                    project = String(rest[rest.startIndex..<end])
                    rest = String(rest[end...]).trimmingCharacters(in: .whitespaces)
                }
            } else if rest.hasPrefix("/") {
                rest.removeFirst()
                let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? rest.endIndex
                let word = String(rest[rest.startIndex..<end]).lowercased()
                guard let kind = commands[word] else { return nil }
                action = .note(kind)
                rest = String(rest[end...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !rest.isEmpty else { return nil }
        if let p = project, p.isEmpty { return nil }
        return CaptureIntent(project: project, action: action, text: rest)
    }
}
