import Foundation

/// Il consumo di una sessione, in un giorno, con un modello. Le righe sono piccole: si raggruppano come serve al momento di leggerle.
public struct LedgerRow: Codable, Equatable, Sendable {
    public var day: String
    public var sessionId: String
    public var cwd: String
    public var model: String
    public var sidechain: Bool
    public var totals: UsageTotals

    var id: String { "\(day)|\(sessionId)|\(cwd)|\(model)|\(sidechain)" }
}

struct LedgerFileState: Codable, Equatable {
    var size: UInt64
    var offset: UInt64
}

struct LedgerState: Codable {
    var version = 1
    var files: [String: LedgerFileState] = [:]
    /// Gli hash dei messaggi gia' contati: una chat ripresa copia i messaggi vecchi nel nuovo file, e non vanno contati due volte.
    var seen: Set<UInt64> = []
    var rows: [String: LedgerRow] = [:]
}

public struct LedgerScanReport: Equatable, Sendable {
    public var filesRead = 0
    public var messagesAdded = 0
    public var duplicatesSkipped = 0
}

/// Il registro dei consumi: legge le trascrizioni di Claude Code (~/.claude/projects) una volta sola, riprendendo da dove era arrivato.
public final class LedgerScanner {
    private let projectsDir: URL
    private let stateFile: URL
    private let format: DayFormat
    private let keepDays: Int
    private var state: LedgerState
    private let lock = NSLock()

    public init(projectsDir: URL, stateFile: URL, format: DayFormat = DayFormat(), keepDays: Int = 400) {
        self.projectsDir = projectsDir
        self.stateFile = stateFile
        self.format = format
        self.keepDays = keepDays
        self.state = JSONFile.read(LedgerState.self, from: stateFile) ?? LedgerState()
    }

    public var rows: [LedgerRow] {
        lock.lock(); defer { lock.unlock() }
        return Array(state.rows.values)
    }

    /// Aggiorna il registro con quello che e' stato scritto dall'ultima volta. Da chiamare lontano dal thread principale.
    @discardableResult
    public func scan(now: Date = Date()) -> LedgerScanReport {
        lock.lock(); defer { lock.unlock() }
        var report = LedgerScanReport()
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        let dates = DateParser()
        var changed = false

        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "jsonl" {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
                var fileState = state.files[url.path] ?? LedgerFileState(size: 0, offset: 0)
                // Il file si e' accorciato (riscritto da zero): si rilegge tutto, i duplicati li ferma `seen`.
                if size < fileState.offset { fileState.offset = 0 }
                guard size > fileState.offset else { state.files[url.path] = LedgerFileState(size: size, offset: fileState.offset); continue }

                report.filesRead += 1
                let consumed = read(url, from: fileState.offset, until: size, dates: dates, report: &report)
                state.files[url.path] = LedgerFileState(size: size, offset: fileState.offset + consumed)
                changed = true
            }
        }

        if changed {
            prune(now: now)
            try? JSONFile.write(state, to: stateFile)
        }
        return report
    }

    /// Legge a blocchi, fermandosi all'ultimo a-capo completo (l'ultima riga potrebbe essere ancora in scrittura).
    private func read(_ url: URL, from start: UInt64, until end: UInt64, dates: DateParser, report: inout LedgerScanReport) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        var consumed: UInt64 = 0
        var carry = Data()
        let chunkSize = 4 * 1024 * 1024
        var position = start
        while position < end {
            try? h.seek(toOffset: position)
            let want = Int(min(UInt64(chunkSize), end - position))
            guard let chunk = try? h.read(upToCount: want), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            var buffer = carry
            buffer.append(chunk)
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else { carry = buffer; continue }
            let complete = buffer[buffer.startIndex...lastNewline]
            carry = Data(buffer[buffer.index(after: lastNewline)...])
            consumed += UInt64(complete.count)
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                ingest(Data(line), dates: dates, report: &report)
            }
        }
        return consumed
    }

    private func ingest(_ line: Data, dates: DateParser, report: inout LedgerScanReport) {
        guard let e = TranscriptParser.parse(line: line, dates: dates) else { return }
        if let key = e.dedupeKey {
            let h = Hashing.fnv1a(key)
            if state.seen.contains(h) { report.duplicatesSkipped += 1; return }
            state.seen.insert(h)
        }
        let row = LedgerRow(day: format.stamp(e.timestamp), sessionId: e.sessionId, cwd: e.cwd ?? "", model: e.model,
                            sidechain: e.sidechain, totals: e.totals)
        if var existing = state.rows[row.id] {
            existing.totals.add(row.totals)
            state.rows[row.id] = existing
        } else {
            state.rows[row.id] = row
        }
        report.messagesAdded += 1
    }

    /// Tiene solo gli ultimi giorni, per non crescere senza fine.
    private func prune(now: Date) {
        guard let limit = format.calendar.date(byAdding: .day, value: -keepDays, to: now) else { return }
        let cut = format.stamp(limit)
        state.rows = state.rows.filter { $0.value.day >= cut }
    }
}

// MARK: - Domande al registro

public struct LedgerGroup: Equatable, Sendable {
    public var key: String
    public var totals: UsageTotals
    /// Per modello, cosi' si puo' stimare il costo.
    public var byModel: [String: UsageTotals]
}

public enum LedgerQuery {
    /// Raggruppa le righe di un intervallo di giorni ("2026-10-01"..."2026-10-08") secondo una chiave. Il piu' pesante per primo.
    public static func group(_ rows: [LedgerRow], days: ClosedRange<String>? = nil, by key: (LedgerRow) -> String) -> [LedgerGroup] {
        var map: [String: LedgerGroup] = [:]
        for r in rows {
            if let days, !days.contains(r.day) { continue }
            let k = key(r)
            var g = map[k] ?? LedgerGroup(key: k, totals: UsageTotals(), byModel: [:])
            g.totals.add(r.totals)
            g.byModel[r.model, default: UsageTotals()].add(r.totals)
            map[k] = g
        }
        return map.values.sorted { $0.totals.fresh == $1.totals.fresh ? $0.key < $1.key : $0.totals.fresh > $1.totals.fresh }
    }

    /// Una voce per giorno, anche per quelli senza consumo: i grafici non devono avere buchi.
    public static func perDay(_ rows: [LedgerRow], last days: Int, endingAt end: Date, format: DayFormat) -> [LedgerGroup] {
        var stamps: [String] = []
        for back in stride(from: days - 1, through: 0, by: -1) {
            if let d = format.calendar.date(byAdding: .day, value: -back, to: end) { stamps.append(format.stamp(d)) }
        }
        let wanted = Set(stamps)
        let grouped = Dictionary(uniqueKeysWithValues: group(rows, by: { $0.day }).map { ($0.key, $0) })
        return stamps.compactMap { s in
            guard wanted.contains(s) else { return nil }
            return grouped[s] ?? LedgerGroup(key: s, totals: UsageTotals(), byModel: [:])
        }
    }

    /// Quanto pesa il lavoro "orchestrato" (Manager e agenti) sul totale: la domanda con cui si capisce se il Manager conviene.
    public static func orchestrationShare(_ rows: [LedgerRow], isOrchestrated: (LedgerRow) -> Bool, days: ClosedRange<String>? = nil) -> (orchestrated: UsageTotals, other: UsageTotals) {
        var a = UsageTotals(), b = UsageTotals()
        for r in rows {
            if let days, !days.contains(r.day) { continue }
            if isOrchestrated(r) { a.add(r.totals) } else { b.add(r.totals) }
        }
        return (a, b)
    }
}
