import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Musica

/// Sa se Music o Spotify stanno suonando, senza lanciarli. La prima volta macOS chiede il permesso.
@MainActor
final class MusicWatcher {
    private var timer: Timer?
    private var denied = Set<String>()
    var onChange: ((Bool) -> Void)?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func poll() {
        guard AppSettings.shared.danceToMusic else { onChange?(false); return }
        var playing = false
        for (bundle, name) in [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")] {
            // Se l'app non e' aperta non la tocchiamo: un comando la avvierebbe.
            guard !denied.contains(bundle), !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { continue }
            var err: NSDictionary?
            let r = NSAppleScript(source: "tell application \"\(name)\" to return (player state as string)")?.executeAndReturnError(&err)
            if err != nil { denied.insert(bundle); continue }   // permesso negato: non insistiamo
            if (r?.stringValue ?? "").lowercased().contains("play") { playing = true }
        }
        onChange?(playing)
    }
}

// MARK: - Ramo git, pull request e CI

enum RepoProbe {
    private static func run(_ exe: String, _ args: [String], cwd: String, timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"; env["GH_NO_UPDATE_NOTIFIER"] = "1"; env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", NSHomeDirectory() + "/.local/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func probe(cwd: String) -> PRInfo? {
        guard FileManager.default.fileExists(atPath: cwd),
              let branch = run("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty, branch != "HEAD" else { return nil }
        var info = PRInfo(number: nil, title: nil, ci: .none, branch: branch)
        guard let gh, let out = run(gh, ["pr", "view", "--json", "number,title,statusCheckRollup"], cwd: cwd, timeout: 12),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return info }
        info.number = obj["number"] as? Int
        info.title = obj["title"] as? String
        let checks = obj["statusCheckRollup"] as? [[String: Any]] ?? []
        var failing = false, pending = false
        for c in checks {
            let conclusion = (c["conclusion"] as? String ?? "").uppercased()
            let status = (c["status"] as? String ?? "").uppercased()
            let state = (c["state"] as? String ?? "").uppercased()
            if ["FAILURE", "TIMED_OUT", "ERROR", "CANCELLED", "ACTION_REQUIRED"].contains(conclusion) || ["FAILURE", "ERROR"].contains(state) { failing = true }
            else if (!status.isEmpty && status != "COMPLETED") || state == "PENDING" { pending = true }
        }
        info.ci = checks.isEmpty ? .none : (failing ? .failing : (pending ? .pending : .passing))
        return info
    }
}

extension IslandModel {
    /// Rilegge ramo, PR e CI del progetto (al massimo ogni due minuti, in background).
    func refreshRepo(_ id: String) {
        guard AppSettings.shared.showGitHub, var s = sessions[id], let cwd = s.cwd, !id.hasPrefix("preview"),
              Date().timeIntervalSince(s.lastPRCheck) > 120 else { return }
        s.lastPRCheck = Date()
        sessions[id] = s
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = RepoProbe.probe(cwd: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, var t = self.sessions[id] else { return }
                    t.pr = info
                    self.sessions[id] = t
                    self.recompute()
                }
            }
        }
    }
}

// MARK: - Scorciatoie globali

/// ⌃⌥Y consenti, ⌃⌥N nega, ⌃⌥Spazio tiene l'isola aperta, ⌃⌥M silenzia i suoni. Non servono permessi.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false
    var registeredCount: Int { actions.count }

    func apply(enabled: Bool, model: IslandModel) {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs = []
        actions = [:]
        guard enabled else { return }
        installHandlerOnce()
        let mods = UInt32(controlKey | optionKey)
        register(UInt32(kVK_ANSI_Y), mods, 1) { [weak model] in
            guard let m = model, let item = m.permissions.first else { return }
            m.resolve(item, .allow)
        }
        register(UInt32(kVK_ANSI_N), mods, 2) { [weak model] in
            guard let m = model, let item = m.permissions.first else { return }
            m.resolve(item, .deny)
        }
        register(UInt32(kVK_Space), mods, 3) { [weak model] in model?.togglePinned() }
        register(UInt32(kVK_ANSI_M), mods, 4) { Sounds.enabled.toggle() }
    }

    private func register(_ key: UInt32, _ mods: UInt32, _ id: UInt32, _ action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x444F5454), id: id)
        if RegisterEventHotKey(key, mods, hid, GetApplicationEventTarget(), 0, &ref) == noErr {
            refs.append(ref)
            actions[id] = action
        }
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hid = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.actions[hid.id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension IslandModel {
    func togglePinned() {
        pinned.toggle()
        recompute()
    }
}
