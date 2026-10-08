import Foundation

public struct HealthItem: Equatable, Identifiable, Sendable {
    public enum Status: String, Sendable { case ok, warning, problem }

    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    /// Cosa fare per sistemare, in una riga (un comando o un'indicazione).
    public var fix: String?

    public init(id: String, title: String, status: Status, detail: String, fix: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}

/// Controlla che il ponte fra Claude Code e Dott sia a posto. Solo cose che si leggono dal disco: i permessi di macOS li controlla l'app.
public struct HealthChecker {
    /// Gli eventi che `install-hooks.sh` aggancia: se ne manca uno, una parte di Dott e' cieca.
    public static let requiredEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification",
        "PermissionRequest", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
    ]

    private let home: URL
    private let paths: DottPaths
    private let fm = FileManager.default

    public init(home: URL, paths: DottPaths) {
        self.home = home
        self.paths = paths
    }

    public func run() -> [HealthItem] {
        [claudeHooks(), hookScript(), jq(), socket(), claudeData()]
    }

    func claudeHooks() -> HealthItem {
        let url = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url) else {
            return HealthItem(id: "hooks", title: "Hook di Claude Code", status: .problem,
                              detail: "Non trovo ~/.claude/settings.json: Dott non riceve nessun evento.", fix: "scripts/install-hooks.sh")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return HealthItem(id: "hooks", title: "Hook di Claude Code", status: .problem,
                              detail: "~/.claude/settings.json non e' un JSON valido.", fix: "Correggi il file, poi esegui scripts/install-hooks.sh")
        }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let missing = Self.requiredEvents.filter { !Self.hasDottCommand(hooks[$0]) }
        if missing.isEmpty {
            return HealthItem(id: "hooks", title: "Hook di Claude Code", status: .ok, detail: "Tutti i \(Self.requiredEvents.count) eventi sono agganciati.")
        }
        let status: HealthItem.Status = missing.count == Self.requiredEvents.count ? .problem : .warning
        return HealthItem(id: "hooks", title: "Hook di Claude Code", status: status,
                          detail: "Mancano: \(missing.joined(separator: ", ")).", fix: "scripts/install-hooks.sh")
    }

    static func hasDottCommand(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        for g in groups {
            for h in g["hooks"] as? [[String: Any]] ?? [] {
                if let c = h["command"] as? String, c.contains("dott-hook") { return true }
            }
        }
        return false
    }

    func hookScript() -> HealthItem {
        let path = paths.hookScript.path
        guard fm.fileExists(atPath: path) else {
            return HealthItem(id: "script", title: "Ponte dott-hook", status: .problem,
                              detail: "Il ponte non e' installato in \(path).", fix: "scripts/install-hooks.sh")
        }
        guard fm.isExecutableFile(atPath: path) else {
            return HealthItem(id: "script", title: "Ponte dott-hook", status: .problem,
                              detail: "Il ponte c'e' ma non e' eseguibile.", fix: "chmod +x \"\(path)\"")
        }
        return HealthItem(id: "script", title: "Ponte dott-hook", status: .ok, detail: "Installato ed eseguibile.")
    }

    func jq() -> HealthItem {
        let found = ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"].contains { fm.isExecutableFile(atPath: $0) }
        // Il ponte usa /usr/bin/jq (c'e' da macOS 15): altrove ricade su un invio senza pulizia dell'output.
        return found
            ? HealthItem(id: "jq", title: "jq", status: .ok, detail: "Disponibile.")
            : HealthItem(id: "jq", title: "jq", status: .warning, detail: "Senza jq il ponte manda eventi grezzi e piu' pesanti.", fix: "brew install jq")
    }

    func socket() -> HealthItem {
        let path = paths.socket.path
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            return HealthItem(id: "socket", title: "Canale di Dott", status: .warning,
                              detail: "Dott non sta ascoltando (il canale non esiste).", fix: "Apri Dott")
        }
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if perms & 0o077 != 0 {
            return HealthItem(id: "socket", title: "Canale di Dott", status: .problem,
                              detail: "Il canale e' accessibile ad altri utenti (permessi \(String(perms, radix: 8))).", fix: "chmod 600 \"\(path)\"")
        }
        return HealthItem(id: "socket", title: "Canale di Dott", status: .ok, detail: "Attivo e riservato a te.")
    }

    func claudeData() -> HealthItem {
        let dir = home.appendingPathComponent(".claude/projects")
        let count = (try? fm.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        return count > 0
            ? HealthItem(id: "data", title: "Cronologia di Claude Code", status: .ok, detail: "\(count) cartelle di progetto: il Registro ha da dove leggere.")
            : HealthItem(id: "data", title: "Cronologia di Claude Code", status: .warning,
                         detail: "Non trovo ~/.claude/projects: il Registro dei consumi resta vuoto finche' non usi Claude Code.")
    }
}
