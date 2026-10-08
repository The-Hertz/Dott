import AppKit
import Foundation
import SwiftUI

/// L'inoltro dei compiti: il Manager chiude la risposta con un blocco di righe
///   @designer [Workout]: ridisegna la scheda
/// Dott le legge, te le mostra nel notch e, se approvi, le manda nelle chat giuste (incollando, come "Chiedi a…").
/// Quando un agente finisce, Dott riporta la sua risposta al Manager.

struct DispatchTask: Identifiable, Equatable {
    let id = UUID()
    var destKey: String           // "agent:design", "manager" non serve, oppure la chiave del capo progetto
    var destTitle: String         // "Designer", "Capo di Workout"
    var projectName: String?
    var projectFolder: String?
    var text: String
    var selected = true
}

struct DispatchBatch: Identifiable, Equatable {
    let id = UUID()
    var tasks: [DispatchTask]
    let created = Date()
}

/// Un compito gia' mandato, in attesa di risposta. Si ricorda anche dopo un riavvio di Dott.
struct AwaitedTask: Codable {
    var title: String
    var projects: [String]
    var sent = Date()

    private static let key = "dott.awaiting"

    static func load() -> [String: AwaitedTask] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: AwaitedTask].self, from: data) else { return [:] }
        return m.filter { Date().timeIntervalSince($0.value.sent) < 3600 }
    }

    static func save(_ m: [String: AwaitedTask]) {
        guard AppSettings.shared.persist, let data = try? JSONEncoder().encode(m) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension IslandModel {
    // MARK: Lettura del blocco

    /// Le righe `@destinatario [Progetto]: compito` di un messaggio.
    static func parseTasks(_ message: String) -> [(dest: String, project: String, text: String)] {
        // Il Manager puo' scrivere la chiocciola, le parentesi o i due punti "a larghezza piena" (＠ ［ ］ ：), o mettere il rigo
        // in un elenco, in grassetto o fra apici: si normalizza prima di leggere.
        let message = message
            .replacingOccurrences(of: "＠", with: "@").replacingOccurrences(of: "﹫", with: "@")
            .replacingOccurrences(of: "［", with: "[").replacingOccurrences(of: "］", with: "]")
            .replacingOccurrences(of: "：", with: ":")
        guard let re = try? NSRegularExpression(pattern: #"^[\s>*_`"'\-•]*@([A-Za-zÀ-ú]+)\s*\[([^\]]+)\]\s*[*_`]*:[*_`]*\s*(.+)$"#, options: [.anchorsMatchLines]) else { return [] }
        let ns = message as NSString
        return re.matches(in: message, range: NSRange(location: 0, length: ns.length)).map { m in
            (ns.substring(with: m.range(at: 1)).lowercased(), ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces),
             ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces))
        }
    }

    private static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Il progetto (gruppo) a cui si riferisce un nome: uguale al nome del gruppo o al nome del suo capo.
    func project(named name: String) -> (key: String, name: String)? {
        let n = Self.norm(name)
        let groups = ProjectResolver.shared.groups()
        if let g = groups.first(where: { Self.norm($0.name) == n }) { return (g.key, g.name) }
        if let g = groups.first(where: { Self.norm(DottRoster.shared.name(for: $0.key)) == n }) { return (g.key, g.name) }
        // Il nome della cartella del progetto ("Forma" per il gruppo Workout).
        if let g = groups.first(where: { g in folder(for: g.key).map { Self.norm(($0 as NSString).lastPathComponent) == n } ?? false }) { return (g.key, g.name) }
        if let g = groups.first(where: { Self.norm($0.name).hasPrefix(n) || n.hasPrefix(Self.norm($0.name)) }) { return (g.key, g.name) }
        return nil
    }

    private func destination(_ word: String) -> DottRole? {
        switch word {
        case "designer", "design": return .design
        case "ricercatore", "ricerca", "research": return .research
        case "scrittore", "scrittura", "writer": return .writing
        case "automatore", "automazione", "automation": return .automation
        default: return nil
        }
    }

    // MARK: Dagli eventi

    /// Dopo un evento: un messaggio del Manager con dei compiti diventa una richiesta di approvazione; la risposta di un agente
    /// o di un capo progetto che aspettavamo torna al Manager.
    func routeDispatch(_ e: HookEvent) {
        guard e.name == "Stop", let msg = e.lastAssistantMessage, !msg.isEmpty, let s = sessions[e.sessionId] else { return }
        let role = AgentRegistry.shared.ref(for: e.sessionId).flatMap { DottRole(rawValue: $0.role) }

        if role == .manager {
            enqueueTasks(from: msg)
        } else {
            returnResult(of: s, role: role, message: msg)
        }
    }

    /// Rilegge l'ultima risposta del Manager e, se ci sono compiti, mostra la scheda (anche se Dott se l'era persa).
    func rescanManager() {
        guard let chat = chatTarget(AgentRegistry.managerKey), let text = Transcript.lastAssistantText(sessionId: chat.id) else {
            showRecap([RecapLine(symbol: "questionmark.circle", text: "Non trovo una risposta del Manager")], title: "Compiti", gesture: .tilt)
            return
        }
        let before = dispatches.count
        enqueueTasks(from: text, force: true)
        if dispatches.count == before {
            showRecap([RecapLine(symbol: "checkmark.circle", text: "Nessun compito da affidare nell'ultima risposta")], title: "Compiti", gesture: .nod)
        }
    }

    private func enqueueTasks(from message: String, force: Bool = false) {
        var tasks: [DispatchTask] = []
        for p in Self.parseTasks(message) {
            let proj = project(named: p.project)
            let text = p.text
            let signature = "\(p.dest)|\(proj?.key ?? p.project)|\(text)"
            if !force, let t = dispatchSeen[signature], Date().timeIntervalSince(t) < 1800 { continue }
            dispatchSeen[signature] = Date()
            if p.dest == "capo" || p.dest == "lead" || p.dest == "capoprogetto" {
                guard let proj else { continue }                  // il capo serve un progetto riconosciuto
                tasks.append(DispatchTask(destKey: proj.key, destTitle: "\(DottRoster.shared.name(for: proj.key)), capo di \(proj.name)",
                                          projectName: proj.name, projectFolder: folder(for: proj.key), text: text))
            } else if let r = destination(p.dest) {
                tasks.append(DispatchTask(destKey: r.agentKey, destTitle: r.agentTitle, projectName: proj?.name ?? p.project,
                                          projectFolder: proj.flatMap { folder(for: $0.key) }, text: text))
            }
        }
        guard !tasks.isEmpty else { return }
        dispatches.append(DispatchBatch(tasks: tasks))
        Sounds.play(.attention)
        peek(8)
        trigger(.tilt)
        recompute()
    }

    // MARK: Approvazione

    func toggleTask(_ id: UUID, in batch: UUID) {
        guard let b = dispatches.firstIndex(where: { $0.id == batch }), let t = dispatches[b].tasks.firstIndex(where: { $0.id == id }) else { return }
        dispatches[b].tasks[t].selected.toggle()
    }

    func cancelDispatch(_ batch: UUID) {
        dispatches.removeAll { $0.id == batch }
        recompute()
    }

    /// Manda i compiti scelti: uno per destinatario (i compiti per lo stesso agente si riuniscono), uno dopo l'altro.
    func approveDispatch(_ batch: UUID) {
        guard let b = dispatches.first(where: { $0.id == batch }) else { return }
        dispatches.removeAll { $0.id == batch }
        let chosen = b.tasks.filter(\.selected)
        recompute()
        guard !chosen.isEmpty else { return }

        var byDest: [(key: String, title: String, tasks: [DispatchTask])] = []
        for t in chosen {
            if let i = byDest.firstIndex(where: { $0.key == t.destKey }) { byDest[i].tasks.append(t) }
            else { byDest.append((t.destKey, t.destTitle, [t])) }
        }
        let managerKey = AgentRegistry.managerKey
        log(managerKey, "paperplane.fill", "info", chosen.count == 1 ? "Ha affidato 1 compito" : "Ha affidato \(chosen.count) compiti",
            byDest.map(\.title).joined(separator: ", "))
        for d in byDest {
            let message = Self.taskMessage(d.tasks)
            awaiting[d.key] = AwaitedTask(title: d.title, projects: d.tasks.compactMap(\.projectName))
            AwaitedTask.save(awaiting)
            AutomationQueue.shared.enqueue { [weak self] in self?.ask(message, key: d.key) }
        }
    }

    /// Per le prove: i messaggi che partirebbero se si approvasse il primo blocco (senza mandarli).
    func dispatchPreview() -> String {
        guard let b = dispatches.first else { return "nessun blocco in attesa" }
        var out = ""
        var seen: [String] = []
        for t in b.tasks.filter(\.selected) where !seen.contains(t.destKey) {
            seen.append(t.destKey)
            let group = b.tasks.filter { $0.selected && $0.destKey == t.destKey }
            out += "=== a \(t.destTitle) [\(t.destKey)] cartella \(folder(for: t.destKey) ?? "-") chat: \(chatTarget(t.destKey)?.title ?? "nuova")\n"
            out += Self.taskMessage(group) + "\n\n"
        }
        return out
    }

    /// Il messaggio per chi riceve i compiti: cosa, su quale progetto e in quale cartella.
    fileprivate static func taskMessage(_ tasks: [DispatchTask]) -> String {
        var lines = [tasks.count == 1 ? "Compito dal Manager:" : "Compiti dal Manager:"]
        for (i, t) in tasks.enumerated() {
            var head = tasks.count == 1 ? "" : "\(i + 1). "
            if let p = t.projectName { head += "Progetto \(p)" + (t.projectFolder.map { " (cartella \($0.replacingOccurrences(of: NSHomeDirectory(), with: "~")))" } ?? "") + ": " }
            lines.append(head + t.text)
        }
        lines.append("Quando hai finito, chiudi con una breve sintesi del risultato" + (tasks.count > 1 ? " per ogni compito." : "."))
        return lines.joined(separator: "\n")
    }

    // MARK: Il ritorno

    /// Riporta a mano al Manager l'ultima risposta di un capo progetto o di un agente (per esempio se Dott se l'era persa).
    func reportToManager(from key: String) {
        guard let chat = chatTarget(key), let text = Transcript.lastAssistantText(sessionId: chat.id), !text.isEmpty else {
            showRecap([RecapLine(symbol: "questionmark.circle", text: "Non trovo una risposta da riportare")], title: "Al Manager", gesture: .tilt)
            return
        }
        let who: String
        if let role = AgentRegistry.role(forKey: key) { who = role.agentTitle }
        else { who = "\(DottRoster.shared.name(for: key)), capo di \(ProjectResolver.shared.groupName(key) ?? "")" }
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3500))
        awaiting[key] = nil
        AwaitedTask.save(awaiting)
        log(AgentRegistry.managerKey, "arrow.uturn.left.circle.fill", "ok", "Risposta di \(who)", String(body.prefix(100)))
        AutomationQueue.shared.enqueue { [weak self] in
            self?.ask("[Risposta di \(who)]\n\(body)", key: AgentRegistry.managerKey)
        }
    }

    /// Un agente (o un capo progetto) a cui avevamo affidato qualcosa ha finito: la sua risposta torna al Manager.
    private func returnResult(of s: Session, role: DottRole?, message: String) {
        guard AppSettings.shared.returnToManager else { return }
        let key = role.map(\.agentKey) ?? Self.projectKey(s)
        guard let wait = awaiting[key], Date().timeIntervalSince(wait.sent) < 3600 else { return }
        awaiting[key] = nil
        AwaitedTask.save(awaiting)
        let body = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3500))
        let from = wait.projects.isEmpty ? wait.title : "\(wait.title) · \(wait.projects.joined(separator: ", "))"
        log(AgentRegistry.managerKey, "arrow.uturn.left.circle.fill", "ok", "Risposta di \(wait.title)", String(body.prefix(100)))
        AutomationQueue.shared.enqueue { [weak self] in
            self?.ask("[Risposta di \(from)]\n\(body)", key: AgentRegistry.managerKey)
        }
    }
}

/// Le azioni sull'app Claude (apri la chat, clicca, incolla, invia) vanno una alla volta, con un po' di margine.
@MainActor
final class AutomationQueue {
    static let shared = AutomationQueue()
    private var jobs: [() -> Void] = []
    private var running = false

    func enqueue(_ job: @escaping () -> Void) {
        jobs.append(job)
        if !running { next() }
    }

    private func next() {
        guard !jobs.isEmpty else { running = false; return }
        running = true
        let job = jobs.removeFirst()
        job()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in self?.next() }
    }
}

// MARK: - La scheda nel notch

struct DispatchBody: View {
    @ObservedObject var model: IslandModel
    let batch: DispatchBatch

    private var count: Int { batch.tasks.filter(\.selected).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.tasks.count == 1 ? "Il Manager vuole affidare un compito" : "Il Manager vuole affidare \(batch.tasks.count) compiti")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.amber)
                    Text("Scegli quali mandare")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                if model.dispatches.count > 1 {
                    Text("+\(model.dispatches.count - 1) in coda").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                }
            }
            ForEach(batch.tasks.prefix(5)) { t in DispatchRow(model: model, batch: batch, task: t, fullText: false) }
            HStack(spacing: 8) {
                Button("Annulla") { model.cancelDispatch(batch.id) }
                    .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: Palette.coral))
                Spacer(minLength: 0)
                Button(count == 1 ? "Invia 1 compito" : "Invia \(count) compiti") { model.approveDispatch(batch.id) }
                    .buttonStyle(IslandButton(fill: count == 0 ? .white.opacity(0.10) : Palette.lime, text: count == 0 ? .white.opacity(0.35) : Palette.ink))
                    .disabled(count == 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Un compito proposto, con la spunta: nel notch il testo e' corto, nella conversazione col Manager e' per intero.
struct DispatchRow: View {
    @ObservedObject var model: IslandModel
    let batch: DispatchBatch
    let task: DispatchTask
    var fullText: Bool

    var body: some View {
        Button { model.toggleTask(task.id, in: batch.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: task.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14)).foregroundStyle(task.selected ? Palette.lime : .white.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(task.destTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        if let p = task.projectName { Text("· \(p)").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)) }
                    }
                    Text(task.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(fullText ? nil : 2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(task.selected ? 0.09 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
