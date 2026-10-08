import AppKit
import Foundation

/// Un lavoro affidato a Claude Code da Dott: lancia il binario ufficiale (`claude -p`) nella cartella del
/// progetto. Il lavoro vero lo fa lui; gli hook gia' collegati raccontano a Dott cosa succede.
/// Dott non legge ne' salva mai le credenziali: il login lo trova `claude` da solo.
struct AgentRun: Equatable {
    enum State: Equatable { case starting, working, done, failed, stopped }
    var id = UUID()
    var project: String
    /// Il progetto (gruppo dell'app Claude o cartella) a cui appartiene il lavoro.
    var key: String
    var cwd: String
    var prompt: String
    var state: State = .starting
    var sessionId: String?
    /// Riga di riepilogo (fine lavoro) o motivo dell'errore.
    var summary: String?
    /// Testo originale dell'errore, per la diagnostica.
    var raw: String?
    var started = Date()
    var ended: Date?
    /// Aperta nell'app Claude: da li' in poi un nuovo comando di Dott ne fa una copia.
    var inDesktop = false
    /// Riprende una sessione esistente (se non esiste piu', Dott riparte da zero).
    var resumed = false
    /// Compattazione del contesto (e non un lavoro): `/compact` sulla conversazione del progetto.
    var isCompact = false
    var tokensBefore: Int?
    var tokensAfter: Int?
    /// La battuta con cui Dott prende in carico il lavoro.
    var ack = ["Ok, ci penso io.", "Vediamo cosa combina…", "Subito.", "Ci sono.", "Partiamo."].randomElement()!
    var isActive: Bool { state == .starting || state == .working }
}

/// La conversazione fissa di un progetto: ogni comando di Dott la prosegue, finche' non scegli "Nuova".
struct AgentSessionInfo: Codable, Equatable {
    var sid: String
    /// Aperta nell'app Claude: il prossimo comando ne fa una copia, per non pestarsi i piedi.
    var inDesktop = false
    var at = Date()

    private static let key = "dott.agentSessions"

    static func load() -> [String: AgentSessionInfo] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: AgentSessionInfo].self, from: data) else { return [:] }
        return m
    }

    static func save(_ m: [String: AgentSessionInfo]) {
        guard AppSettings.shared.persist, let data = try? JSONEncoder().encode(m) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class AgentRunner {
    static let shared = AgentRunner()

    /// Chiamato a ogni cambio di stato di un lavoro.
    var onChange: ((AgentRun) -> Void)?
    private(set) var runs: [UUID: AgentRun] = [:]
    private var processes: [UUID: Process] = [:]

    /// Il binario ufficiale di Claude Code: installazione da terminale, oppure quella dell'app Claude.
    static func findClaude() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        let nvm = "\(home)/.nvm/versions/node"
        for v in ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed() {
            candidates.append("\(nvm)/\(v)/bin/claude")
        }
        // L'app Claude tiene Claude Code in ".../claude-code/<versione>/<hash>/claude.app/Contents/MacOS/claude".
        let base = "\(home)/Library/Application Support/Claude/claude-code"
        let versions = ((try? fm.contentsOfDirectory(atPath: base)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            for h in (try? fm.contentsOfDirectory(atPath: "\(base)/\(v)")) ?? [] {
                candidates.append("\(base)/\(v)/\(h)/claude.app/Contents/MacOS/claude")
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Ambiente pulito: una chiave API o un token nell'ambiente farebbero pagare a consumo invece di usare l'abbonamento.
    static func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k == "ANTHROPIC_API_KEY" || k == "ANTHROPIC_AUTH_TOKEN" || k == "CLAUDE_CODE_OAUTH_TOKEN"
            || k.hasPrefix("CLAUDE_CODE_USE_") || k == "CLAUDE_CONFIG_DIR" {
            env[k] = nil
        }
        let home = NSHomeDirectory()
        env["HOME"] = home
        env["PATH"] = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        return env
    }

    @discardableResult
    func start(key: String, cwd: String, prompt: String, resume: String? = nil, fork: Bool = false, compact: Bool = false) -> UUID? {
        let project = (cwd as NSString).lastPathComponent
        var run = AgentRun(project: ProjectResolver.shared.groupName(key) ?? project, key: key, cwd: cwd, prompt: prompt)
        run.sessionId = resume
        run.resumed = resume != nil
        if compact {
            run.isCompact = true
            run.ack = "Faccio un po’ di pulizia…"
        }
        runs[run.id] = run
        guard let exe = Self.findClaude() else {
            fail(run.id, "Non trovo Claude Code su questo Mac")
            return run.id
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            fail(run.id, "La cartella \(cwd) non c’è più")
            return run.id
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        // "default": ogni azione che richiede il permesso passa dall'hook, cioe' dal notch (da `-p` partirebbe in automatico).
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", "default"]
        if let resume { args += ["--resume", resume] }
        // Se la sessione e' stata aperta nell'app Claude, una copia: due processi sulla stessa conversazione si pesterebbero.
        if resume != nil, fork { args.append("--fork-session") }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = Self.cleanEnvironment()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let id = run.id
        let lines = LineBuffer { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(line, id) } }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { lines.feed(d) }
        }
        let errText = LockedText()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errText.append(d) }
        }
        p.terminationHandler = { [weak self] proc in
            lines.flush()
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            let stderr = errText.value
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(id, status: status, signaled: reason == .uncaughtSignal, stderr: stderr) }
            }
        }
        do {
            try p.run()
            processes[id] = p
        } catch {
            fail(id, "Non riesco ad avviare Claude Code")
        }
        return id
    }

    /// Ferma il turno in corso: SIGINT lo chiude in modo pulito e la sessione resta ripresa-bile.
    func stop(_ id: UUID) {
        guard var run = runs[id], let p = processes[id], p.isRunning else { return }
        run.state = .stopped
        run.ended = Date()
        runs[id] = run
        kill(p.processIdentifier, SIGINT)
        onChange?(run)
    }

    /// Apre la sessione nell'app Claude (Code), con la sua storia: `claude --desktop --resume <id>`, documentato da Anthropic.
    /// Il processo che ci ha lavorato deve essere finito. Se non riesce, ripiega sul terminale.
    static func openInDesktop(cwd: String, sessionId: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let exe = findClaude() else { completion(false); return }
        let p = Process()
        // `--desktop` pretende un terminale vero: `script` gliene da' uno (invisibile) senza aprire Terminal.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", exe, "--desktop", "--resume", sessionId]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = cleanEnvironment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
        }
        do { try p.run() } catch { Task { @MainActor in completion(false) } }
    }

    /// Porta nel terminale la sessione vera di Claude Code (ripresa, se c'e'): un file `.command` aperto da Terminal.
    static func openInTerminal(cwd: String, sessionId: String?) {
        guard let exe = findClaude() else { return }
        func q(_ t: String) -> String { "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var cmd = "exec \(q(exe))"
        if let sessionId { cmd += " --resume \(q(sessionId))" }
        let script = "#!/bin/zsh\ncd \(q(cwd)) && \(cmd)\n"
        let dir = NSHomeDirectory() + "/Library/Application Support/Dott"
        let path = dir + "/apri-claude.command"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: Lettura dello stream

    private func consume(_ line: String, _ id: UUID) {
        guard var run = runs[id], let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if let sid = obj["session_id"] as? String, run.sessionId == nil || type == "system" { run.sessionId = sid }
        switch type {
        case "system" where obj["subtype"] as? String == "init":
            if run.state == .starting { run.state = .working }
        case "system" where obj["subtype"] as? String == "compact_boundary":
            let meta = obj["compact_metadata"] as? [String: Any]
            run.tokensBefore = meta?["pre_tokens"] as? Int
            run.tokensAfter = meta?["post_tokens"] as? Int
        case "result":
            let text = (obj["result"] as? String) ?? ""
            if run.state == .stopped {
                break
            } else if obj["is_error"] as? Bool == true {
                run.state = .failed
                run.raw = text
                run.summary = Self.friendly(text)
            } else {
                run.state = .done
                if run.isCompact {
                    if let a = run.tokensBefore, let b = run.tokensAfter {
                        run.summary = "Compattata: da \(Self.tokens(a)) a \(Self.tokens(b)) token"
                    } else {
                        run.summary = "Non c’era niente da compattare"
                    }
                } else {
                    run.summary = Features.snippet(from: text) ?? "Fatto"
                }
            }
        default:
            break
        }
        if !run.isActive, run.ended == nil { run.ended = Date() }
        runs[id] = run
        onChange?(run)
    }

    private func finished(_ id: UUID, status: Int32, signaled: Bool, stderr: String) {
        processes[id] = nil
        guard var run = runs[id] else { return }
        if run.state == .starting || run.state == .working {
            run.state = signaled ? .stopped : .failed
            run.raw = stderr
            run.summary = Self.friendly(stderr.isEmpty ? "Claude Code si è fermato (codice \(status))" : stderr)
            run.ended = Date()
            runs[id] = run
            onChange?(run)
        }
    }

    private func fail(_ id: UUID, _ why: String) {
        guard var run = runs[id] else { return }
        run.state = .failed
        run.summary = why
        run.ended = Date()
        runs[id] = run
        onChange?(run)
    }

    private static func tokens(_ n: Int) -> String {
        n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))k" : "\(n)"
    }

    /// Un errore di accesso va detto in chiaro: Dott non gestisce le credenziali, quindi serve entrare con `claude`.
    private static func friendly(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.localizedCaseInsensitiveContains("authenticate") || t.localizedCaseInsensitiveContains("not logged in")
            || t.localizedCaseInsensitiveContains("/login") {
            return "Claude Code non è collegato al tuo account: apri una sessione e accedi"
        }
        return t.count > 200 ? String(t.prefix(200)) + "…" : t
    }
}

/// Spezza i dati in arrivo in righe complete.
private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let emit: (String) -> Void
    init(_ emit: @escaping (String) -> Void) { self.emit = emit }

    func feed(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { out.append(s) }
        }
        lock.unlock()
        out.forEach(emit)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if let s = String(data: rest, encoding: .utf8), !s.isEmpty { emit(s) }
    }
}

private final class LockedText: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if text.count < 20_000 { text += String(decoding: d, as: UTF8.self) }
    }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
