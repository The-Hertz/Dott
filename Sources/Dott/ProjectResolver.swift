import Foundation

/// Chi e' un "progetto" per Dott. Nell'app Claude ogni chat gira nella stessa cartella di lavoro: a dire a quale
/// progetto appartiene e' il suo **gruppo** nella barra laterale. Un Dott per gruppo, dunque; le sessioni senza
/// gruppo (terminale, chat sciolte) restano legate alla loro cartella.
///
/// L'app non ha un'API: tiene i gruppi in `claude_desktop_config.json` e scrive un file per ogni chat con il
/// `cliSessionId` (= il `session_id` degli hook). Qui si legge soltanto, e solo i campi che servono.
@MainActor
final class ProjectResolver {
    static let shared = ProjectResolver()

    /// Chiamato quando cambia qualcosa (gruppi, cartelle ricavate).
    var onChange: (() -> Void)?

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    private var groupNames: [String: String] = [:]
    private var assignments: [String: String] = [:]
    private var configStamp = Date.distantPast
    private var chats: [String: Chat] = [:]          // per file locale
    private var byCli: [String: String] = [:]        // cliSessionId → file locale
    private var inferred: [String: String] = [:]     // gruppo → cartella ricavata dalle chat
    private var lastScan = Date.distantPast
    private var inferring = false
    private var timer: Timer?

    private struct Chat {
        var stamp: Date
        var cli: String
        var title: String?
        var cwd: String?
        var activity: Date = .distantPast
        var archived = false
    }

    /// Una chat dell'app Claude, per l'elenco dell'hub.
    struct ChatInfo: Identifiable, Equatable {
        var id: String            // cliSessionId = session_id degli hook
        var title: String
        var activity: Date
        var cwd: String?
    }

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Interrogazioni

    static func key(group id: String) -> String { "g:" + id }
    static func isGroup(_ key: String) -> Bool { key.hasPrefix("g:") }

    /// L'app Claude ha dei gruppi? Se no (o se non si riesce a leggerli) le sessioni restano legate alla cartella.
    var hasGroups: Bool { !groupNames.isEmpty }

    /// I gruppi noti, per nome.
    func groups() -> [(key: String, name: String)] {
        groupNames.map { (Self.key(group: $0.key), $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func groupName(_ key: String) -> String? {
        Self.isGroup(key) ? groupNames[String(key.dropFirst(2))] : nil
    }

    /// Cartella in cui lavorare per un progetto: per un gruppo, quella scelta da te o ricavata dalle sue chat.
    func folder(for key: String) -> String? {
        guard Self.isGroup(key) else { return Self.existingDir(key) }
        let id = String(key.dropFirst(2))
        let overrides = UserDefaults.standard.dictionary(forKey: "dott.groupFolders") as? [String: String] ?? [:]
        return Self.existingDir(overrides[id]) ?? Self.existingDir(inferred[id])
    }

    /// A quale progetto appartiene una sessione: (chiave, nome da mostrare); nil se non ha un gruppo.
    func resolve(sessionId: String, cwd: String?) -> (key: String, name: String)? {
        if let local = byCli[sessionId], let c = chats[local], let gid = assignments["code:" + local], let n = groupNames[gid] {
            _ = c
            return (Self.key(group: gid), n)
        }
        // Una sessione da terminale nella cartella di un gruppo (non quella "di tutti": Finances ospita le chat dell'app).
        if let cwd, let gid = groupNames.keys.first(where: { Self.existingDir(inferred[$0]) == cwd || Self.existingDir(overrideFolder($0)) == cwd }) {
            return (Self.key(group: gid), groupNames[gid] ?? gid)
        }
        return nil
    }

    /// Le chat (non archiviate) di un Dott, le piu' recenti prima. Per il Dott libero: quelle senza gruppo.
    func chats(for key: String, limit: Int = 8) -> [ChatInfo] {
        let gid = Self.isGroup(key) ? String(key.dropFirst(2)) : nil
        return chats.compactMap { local, c -> ChatInfo? in
            guard !c.archived, let title = c.title, !title.isEmpty else { return nil }
            let assigned = assignments["code:" + local]
            if let gid { guard assigned == gid else { return nil } } else { guard assigned == nil else { return nil } }
            return ChatInfo(id: c.cli, title: title, activity: c.activity, cwd: c.cwd)
        }
        .sorted { $0.activity > $1.activity }
        .prefix(limit).map { $0 }
    }

    func title(for sessionId: String) -> String? {
        byCli[sessionId].flatMap { chats[$0]?.title }
    }

    /// Per le prove: cartella di ogni gruppo.
    func dump() -> String {
        groupNames.sorted { $0.value < $1.value }.map { id, name in
            "\(name)\t\(folder(for: Self.key(group: id)) ?? "-")\t(\(chatCount(group: id)) chat)"
        }.joined(separator: "\n")
    }

    // MARK: Lettura

    private func overrideFolder(_ gid: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "dott.groupFolders") as? [String: String])?[gid]
    }

    private func chatCount(group gid: String) -> Int {
        assignments.filter { $0.value == gid && $0.key.hasPrefix("code:") }.count
    }

    func refresh() {
        loadConfig()
        scanChats()
        inferFolders()
    }

    private func loadConfig() {
        let url = root.appendingPathComponent("claude_desktop_config.json")
        guard let stamp = Self.modified(url), stamp != configStamp,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = (json["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any],
              let scopes = prefs["dframe-group-scopes"] as? [String: Any] else { return }
        configStamp = stamp
        var names: [String: String] = [:]
        var assigned: [String: String] = [:]
        // Una voce per account e organizzazione, ciascuna con { groups, assignments }.
        for (_, scope) in scopes {
            guard let s = scope as? [String: Any] else { continue }
            for g in s["groups"] as? [[String: Any]] ?? [] {
                if let id = g["id"] as? String, let n = g["name"] as? String { names[id] = n }
            }
            for (k, v) in s["assignments"] as? [String: String] ?? [:] { assigned[k] = v }
        }
        if names != groupNames || assigned != assignments {
            groupNames = names
            assignments = assigned
            onChange?()
        }
    }

    /// Un file per chat, grosso (c'e' la configurazione degli MCP): se ne legge solo l'inizio, e solo se e' cambiato.
    private func scanChats() {
        let dir = root.appendingPathComponent("claude-code-sessions", isDirectory: true)
        let fm = FileManager.default
        var seen = Set<String>()
        var changed = false
        for account in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let accountDir = dir.appendingPathComponent(account)
            for org in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
                let orgDir = accountDir.appendingPathComponent(org)
                for name in (try? fm.contentsOfDirectory(atPath: orgDir.path)) ?? [] where name.hasSuffix(".json") {
                    let url = orgDir.appendingPathComponent(name)
                    guard let stamp = Self.modified(url) else { continue }
                    let local = String(name.dropLast(5))
                    seen.insert(local)
                    if let c = chats[local], c.stamp == stamp { continue }
                    guard let head = Self.head(of: url), let cli = Self.field("cliSessionId", in: head) else { continue }
                    chats[local] = Chat(stamp: stamp, cli: cli, title: Self.field("title", in: head), cwd: Self.field("cwd", in: head),
                                        activity: Self.number("lastActivityAt", in: head).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast,
                                        archived: Self.flag("isArchived", in: head))
                    byCli[cli] = local
                    changed = true
                }
            }
        }
        for local in chats.keys where !seen.contains(local) {
            if let c = chats.removeValue(forKey: local), byCli[c.cli] == local { byCli[c.cli] = nil }
            changed = true
        }
        if changed { onChange?() }
    }

    // MARK: Cartelle ricavate dalle chat

    /// Ogni chat gira nella stessa cartella: la cartella vera di un gruppo si ricava dai file che le sue chat hanno toccato.
    private func inferFolders() {
        guard !inferring, Date().timeIntervalSince(lastScan) > 60 else { return }
        lastScan = Date()
        inferring = true
        var jobs: [String: [String]] = [:]       // gruppo → cliSessionId
        var cwds: [String: Set<String>] = [:]    // gruppo → cartelle di lavoro delle sue chat
        for (local, gid) in assignments where local.hasPrefix("code:") {
            guard let c = chats[String(local.dropFirst(5))] else { continue }
            jobs[gid, default: []].append(c.cli)
            if let w = c.cwd { cwds[gid, default: []].insert(w) }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [String: String] = [:]
            for (gid, clis) in jobs {
                var total: [String: Int] = [:]
                for cli in clis { for (k, v) in TouchedFolders.counts(session: cli) { total[k, default: 0] += v } }
                if let best = Self.pick(total, workCwds: cwds[gid] ?? []) { result[gid] = best }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inferring = false
                    if result != self.inferred { self.inferred = result; self.onChange?() }
                }
            }
        }
    }

    /// La cartella piu' toccata, ma non quella di lavoro comune a tutte le chat (a meno che non ci sia altro di sostanzioso).
    nonisolated private static func pick(_ counts: [String: Int], workCwds: Set<String>) -> String? {
        // Le cartelle spostate contano come la stessa: si confronta il percorso dove stanno adesso.
        func canon(_ p: String) -> String { existingDir(p) ?? p }
        let work = Set(workCwds.map(canon))
        var merged: [String: Int] = [:]
        for (k, v) in counts { merged[canon(k), default: 0] += v }
        let others = merged.filter { !work.contains($0.key) && $0.value >= 10 }
        if let best = others.max(by: { $0.value < $1.value }) { return best.key }
        return merged.filter { work.contains($0.key) }.max(by: { $0.value < $1.value })?.key ?? work.first
    }

    // MARK: Utilita'

    /// Una cartella che esiste, anche se nel frattempo l'hai spostata: si cerca per nome nelle cartelle dei progetti.
    nonisolated static func existingDir(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
        let name = (p as NSString).lastPathComponent
        let home = NSHomeDirectory()
        for root in ["Projects", "Developer", "Documents", "Desktop", "Code", "dev", ""] {
            let c = root.isEmpty ? "\(home)/\(name)" : "\(home)/\(root)/\(name)"
            if fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue { return c }
        }
        return nil
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func head(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 6 * 1024) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Un campo numerico di primo livello (le date dell'app sono in millisecondi).
    private static func number(_ key: String, in text: String) -> Double? {
        guard let r = text.range(of: "\"\(key)\":") else { return nil }
        let digits = text[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    private static func flag(_ key: String, in text: String) -> Bool {
        text.range(of: "\"\(key)\":true") != nil
    }

    /// Il valore di un campo stringa di primo livello, letto a mano perche' il file e' tagliato.
    private static func field(_ key: String, in text: String) -> String? {
        guard let r = text.range(of: "\"\(key)\":\"") else { return nil }
        var out = ""
        var escaped = false
        for ch in text[r.upperBound...] {
            if escaped { out.append(ch == "n" ? " " : ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { return out }
            out.append(ch)
        }
        return nil
    }
}

/// Le cartelle di primo livello (sotto la home) toccate da una sessione, contate dalla sua trascrizione.
/// La scansione e' pesante (le trascrizioni sono centinaia di MB): si fa in background e il risultato si salva per file.
enum TouchedFolders {
    private struct Entry: Codable { var size: Int; var stamp: Double; var counts: [String: Int] }
    nonisolated(unsafe) private static var cache: [String: Entry]?
    private static let lock = NSLock()

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dott/folders-cache-v3.json")
    }

    static func counts(session cli: String) -> [String: Int] {
        guard let url = transcript(cli) else { return [:] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        lock.lock()
        if cache == nil {
            cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        }
        if let e = cache?[cli], e.size == size, e.stamp == stamp { lock.unlock(); return e.counts }
        lock.unlock()

        let found = scan(url)
        lock.lock()
        cache?[cli] = Entry(size: size, stamp: stamp, counts: found)
        if let data = try? JSONEncoder().encode(cache) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        lock.unlock()
        return found
    }

    private static func transcript(_ cli: String) -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for d in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            let u = base.appendingPathComponent(d).appendingPathComponent("\(cli).jsonl")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private static func scan(_ url: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var counts: [String: Int] = [:]
        for key in ["\"file_path\":\"\(home)/", "\"path\":\"\(home)/", "\"cwd\":\"\(home)/"] {
            let needle = Data(key.utf8)
            var from = data.startIndex
            while let r = data.range(of: needle, in: from..<data.endIndex) {
                let end = min(r.upperBound + 300, data.endIndex)
                if let q = data[r.upperBound..<end].firstIndex(of: 0x22),
                   let rest = String(data: data[r.upperBound..<q], encoding: .utf8),
                   let folder = topFolder(rest, home: home, isFolder: key.hasPrefix("\"cwd\"")) {
                    counts[folder, default: 0] += 1
                }
                from = r.upperBound
            }
        }
        return counts
    }

    /// "Desktop/Dott/Sources/x.swift" → "<home>/Desktop/Dott"; "life/VitaKit/y" → "<home>/life".
    private static func topFolder(_ rel: String, home: String, isFolder: Bool) -> String? {
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first, !first.hasPrefix("."), first != "Library", first != "Downloads" else { return nil }
        let containers: Set<String> = ["Desktop", "Documents", "Developer", "Projects", "Sites"]
        if containers.contains(first) {
            guard parts.count >= (isFolder ? 2 : 3) else { return nil }   // un file va cercato dentro la cartella del progetto
            return "\(home)/\(first)/\(parts[1])"
        }
        guard parts.count >= (isFolder ? 1 : 2) else { return nil }
        return "\(home)/\(first)"
    }
}
