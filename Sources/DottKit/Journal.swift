import Foundation

public enum JournalKind: String, Codable, CaseIterable, Sendable {
    case sessionStart, prompt, edit, commit, test, build, failure, permission, stop, sessionEnd
}

/// Una cosa successa, scritta in una riga. Niente dell'output dei comandi: solo cio' che serve a raccontare la giornata.
public struct JournalEvent: Codable, Equatable, Sendable {
    public var at: Date
    /// La chiave del Dott (il progetto).
    public var project: String
    /// Il nome da mostrare.
    public var name: String
    public var session: String
    public var kind: JournalKind
    /// Il testo breve: l'inizio della richiesta, il file, il messaggio di commit.
    public var text: String?
    /// L'esito, dove ha senso (test, build, permesso consentito).
    public var ok: Bool?
    /// Un numero, dove serve: i secondi che hai impiegato a rispondere a un permesso.
    public var seconds: Double?

    public init(at: Date, project: String, name: String, session: String, kind: JournalKind,
                text: String? = nil, ok: Bool? = nil, seconds: Double? = nil) {
        self.at = at
        self.project = project
        self.name = name
        self.session = session
        self.kind = kind
        self.text = text
        self.ok = ok
        self.seconds = seconds
    }
}

/// Scrive il diario: un file per giorno, una riga per evento. Si puo' aprire con qualsiasi editor.
public final class JournalWriter {
    private let dir: URL
    private let format: DayFormat
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(dir: URL, format: DayFormat = DayFormat()) {
        self.dir = dir
        self.format = format
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        encoder = e
    }

    public func append(_ event: JournalEvent) {
        guard let line = try? encoder.encode(event) else { return }
        lock.lock(); defer { lock.unlock() }
        let url = dir.appendingPathComponent("\(format.stamp(event.at)).jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = line
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Cancella i giorni piu' vecchi di `days`. Il diario e' tuo: non cresce senza limite.
    public func prune(keepDays days: Int, now: Date = Date()) {
        guard let limit = format.calendar.date(byAdding: .day, value: -days, to: now) else { return }
        let cut = format.stamp(limit)
        lock.lock(); defer { lock.unlock() }
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "jsonl" && url.deletingPathExtension().lastPathComponent < cut {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Cancella tutto (il pulsante "Dimentica tutto" delle impostazioni).
    public func eraseAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir)
    }
}

public struct JournalReader {
    private let dir: URL
    private let format: DayFormat

    public init(dir: URL, format: DayFormat = DayFormat()) {
        self.dir = dir
        self.format = format
    }

    /// Gli eventi di un giorno, in ordine di tempo. Una riga rovinata si salta, il resto si legge.
    public func events(on day: Date) -> [JournalEvent] {
        events(stamp: format.stamp(day))
    }

    public func events(stamp: String) -> [JournalEvent] {
        let url = dir.appendingPathComponent("\(stamp).jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? d.decode(JournalEvent.self, from: Data($0)) }
            .sorted { $0.at < $1.at }
    }

    /// Gli eventi degli ultimi `days` giorni (oggi compreso).
    public func events(lastDays days: Int, endingAt end: Date) -> [JournalEvent] {
        var out: [JournalEvent] = []
        for back in stride(from: days - 1, through: 0, by: -1) {
            if let d = format.calendar.date(byAdding: .day, value: -back, to: end) { out += events(on: d) }
        }
        return out
    }
}

// MARK: - La giornata raccontata

public struct ProjectDigest: Equatable, Sendable {
    public var key: String
    public var name: String
    public var activeSeconds: TimeInterval = 0
    public var prompts = 0
    public var files: [String] = []
    public var commits: [String] = []
    public var testsPassed = 0
    public var testsFailed = 0
    public var buildsFailed = 0
    public var failures = 0
    public var permissionsAsked = 0
    public var permissionsDenied = 0
    public var firstAt: Date
    public var lastAt: Date
    public var lastPrompt: String?
}

public struct DayDigest: Equatable, Sendable {
    public var projects: [ProjectDigest]
    public var activeSeconds: TimeInterval
    /// Quanto ci hai messo, in media, a rispondere ai permessi (nil se non ne sono arrivati).
    public var averagePermissionWait: TimeInterval?
    public var totalPrompts: Int { projects.reduce(0) { $0 + $1.prompts } }
    public var totalFiles: Int { projects.reduce(0) { $0 + $1.files.count } }
    public var totalCommits: Int { projects.reduce(0) { $0 + $1.commits.count } }
    public var isEmpty: Bool { projects.isEmpty }
}

public enum Digester {
    /// Il tempo e' "attivo" finche' fra due eventi passano al massimo `idleGap` secondi: oltre, hai fatto altro.
    public static func digest(_ events: [JournalEvent], idleGap: TimeInterval = 300) -> DayDigest {
        var byProject: [String: [JournalEvent]] = [:]
        for e in events { byProject[e.project, default: []].append(e) }

        var digests: [ProjectDigest] = []
        for (key, list) in byProject {
            let sorted = list.sorted { $0.at < $1.at }
            guard let first = sorted.first, let last = sorted.last else { continue }
            var d = ProjectDigest(key: key, name: sorted.last(where: { !$0.name.isEmpty })?.name ?? key, firstAt: first.at, lastAt: last.at)
            d.activeSeconds = activeTime(sorted.map(\.at), idleGap: idleGap)
            for e in sorted {
                switch e.kind {
                case .prompt:
                    d.prompts += 1
                    if let t = e.text, !t.isEmpty { d.lastPrompt = t }
                case .edit:
                    if let t = e.text, !t.isEmpty, !d.files.contains(t) { d.files.append(t) }
                case .commit:
                    d.commits.append(e.text ?? "commit")
                case .test:
                    if e.ok == true { d.testsPassed += 1 } else if e.ok == false { d.testsFailed += 1 }
                case .build:
                    if e.ok == false { d.buildsFailed += 1 }
                case .failure:
                    d.failures += 1
                case .permission:
                    d.permissionsAsked += 1
                    if e.ok == false { d.permissionsDenied += 1 }
                case .sessionStart, .stop, .sessionEnd:
                    break
                }
            }
            digests.append(d)
        }
        digests.sort { $0.activeSeconds == $1.activeSeconds ? $0.key < $1.key : $0.activeSeconds > $1.activeSeconds }

        // Il tempo totale non e' la somma dei progetti: se lavori su due insieme, il tempo non si raddoppia.
        let total = activeTime(events.map(\.at).sorted(), idleGap: idleGap)
        let waits = events.filter { $0.kind == .permission }.compactMap(\.seconds)
        let wait = waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count)
        return DayDigest(projects: digests, activeSeconds: total, averagePermissionWait: wait)
    }

    /// Somma gli intervalli fra eventi consecutivi, scartando le pause lunghe.
    public static func activeTime(_ times: [Date], idleGap: TimeInterval) -> TimeInterval {
        guard times.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<times.count {
            let gap = times[i].timeIntervalSince(times[i - 1])
            if gap > 0, gap <= idleGap { sum += gap }
        }
        return sum
    }

    /// Il racconto della giornata in poche righe, per il riepilogo e per l'esportazione.
    public static func narrative(_ day: DayDigest) -> [String] {
        guard !day.isEmpty else { return ["Oggi non abbiamo ancora lavorato insieme."] }
        var lines: [String] = []
        lines.append("Hai lavorato circa \(DayFormat.duration(day.activeSeconds)) su \(day.projects.count == 1 ? "1 progetto" : "\(day.projects.count) progetti").")
        for p in day.projects {
            var parts: [String] = []
            if p.prompts > 0 { parts.append(p.prompts == 1 ? "1 richiesta" : "\(p.prompts) richieste") }
            if !p.files.isEmpty { parts.append(p.files.count == 1 ? "1 file modificato" : "\(p.files.count) file modificati") }
            if !p.commits.isEmpty { parts.append(p.commits.count == 1 ? "1 commit" : "\(p.commits.count) commit") }
            if p.testsPassed + p.testsFailed > 0 {
                parts.append(p.testsFailed == 0 ? "test sempre verdi" : "\(p.testsFailed) test falliti su \(p.testsPassed + p.testsFailed) esecuzioni")
            }
            if p.buildsFailed > 0 { parts.append(p.buildsFailed == 1 ? "1 build fallita" : "\(p.buildsFailed) build fallite") }
            let detail = parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
            lines.append("• \(p.name) (\(DayFormat.duration(p.activeSeconds)))\(detail)")
        }
        if let w = day.averagePermissionWait {
            lines.append("Rispondi ai permessi in media in \(w < 60 ? "\(Int(w.rounded())) secondi" : DayFormat.duration(w)).")
        }
        return lines
    }
}
