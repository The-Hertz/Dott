import Foundation

/// Il canale in ingresso: scrivi a Dott, Dott passa il lavoro a Claude Code.
/// Un "progetto" e' una chiave: il gruppo dell'app Claude ("g:<id>") o, per le sessioni senza gruppo, la cartella.
extension IslandModel {
    /// Entro questo tempo dalla fine di un lavoro, a Dott a riposo i comandi vanno ancora a quel progetto.
    private static let recentWindow: TimeInterval = 30 * 60

    /// Il lavoro (in corso o appena finito) del progetto in primo piano.
    var leadRun: AgentRun? { commandKey.flatMap { agentRuns[$0] } }

    /// Il progetto a cui vanno i comandi: quello in primo piano; a Dott a riposo, l'ultimo lavoro affidato
    /// (se recente), altrimenti l'ultimo progetto visto. Solo se si sa dove lavorare.
    var commandKey: String? {
        func usable(_ k: String?) -> String? { k.flatMap { folder(for: $0) != nil ? $0 : nil } }
        if let l = lead, let k = usable(Self.projectKey(l)) { return k }
        if let r = agentRuns.values.max(by: { $0.started < $1.started }),
           r.isActive || Date().timeIntervalSince(r.ended ?? r.started) < Self.recentWindow, let k = usable(r.key) { return k }
        return usable(lastKey)
    }

    /// La cartella in cui lavora Claude Code per questo progetto.
    func folder(for key: String) -> String? {
        key == DottRoster.freeKey ? ProjectResolver.existingDir(freeCwd) : ProjectResolver.shared.folder(for: key)
    }

    /// Il nome da mostrare per il progetto dei comandi.
    var commandName: String? {
        guard let k = commandKey else { return nil }
        if k == DottRoster.freeKey { return freeCwd.map { ($0 as NSString).lastPathComponent } }
        return ProjectResolver.shared.groupName(k) ?? (k as NSString).lastPathComponent
    }

    /// Il nome proprio del Dott in primo piano (nil se non c'e' nessuna sessione).
    var leadDottName: String? { lead.map { DottRoster.shared.name(for: Self.projectKey($0)) } }

    /// Il nome proprio del Dott a cui vanno i comandi.
    var commandDottName: String { commandKey.map { DottRoster.shared.name(for: $0) } ?? AppSettings.shared.name }

    /// Cambiano i gruppi (o le loro cartelle): le sessioni gia' note si riassegnano.
    func regroup() {
        // Ogni gruppo ha il suo Dott: se ne e' nato uno nuovo (progetto appena creato), lo accogliamo.
        let born = DottRoster.shared.ensure(groups: ProjectResolver.shared.groups().map(\.key))
        if let b = born.first {
            let project = ProjectResolver.shared.groupName(b.key) ?? ""
            showRecap([RecapLine(symbol: "sparkles", text: "\(b.name), per \(project)")], title: "Un nuovo Dott!", gesture: .hop)
            Sounds.play(.done)
        }
        ProjectResolver.shared.ownSessions = Dictionary(uniqueKeysWithValues: agentSessions.map { ($0.value.sid, $0.key) })
        for (id, var s) in sessions where !id.hasPrefix("preview") {
            s.reidentify()
            sessions[id] = s
        }
        recompute()
    }

    func beginCompose() {
        guard commandKey != nil, leadRun?.isActive != true else { return }
        composing = true
        composeIdle = Date()
        recompute()
    }

    func cancelCompose() {
        composing = false
        recompute()
    }

    /// Un comando prosegue la conversazione del progetto; "Nuova" la azzera.
    func sendCommand(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let key = commandKey, leadRun?.isActive != true else { return }
        if prompt.lowercased() == "/compact" { composing = false; compactConversation(); return }
        let info = agentSessions[key]
        composing = false
        startAgent(key: key, prompt: prompt, resume: info?.sid, fork: info?.inDesktop ?? false)
        recompute()
    }

    /// C'e' una conversazione da continuare in questo progetto?
    var continuingConversation: Bool { commandKey.flatMap { agentSessions[$0] } != nil }

    /// Compatta il contesto della conversazione del progetto (`/compact`): piu' spazio, stessa conversazione.
    func compactConversation() {
        guard let key = commandKey, let info = agentSessions[key], leadRun?.isActive != true else { return }
        composing = false
        startAgent(key: key, prompt: "/compact", resume: info.sid, fork: info.inDesktop, compact: true)
        recompute()
    }

    /// Riparti da zero: il prossimo comando apre una conversazione nuova.
    func newConversation() {
        guard let key = commandKey, leadRun?.isActive != true else { return }
        agentSessions[key] = nil
        AgentSessionInfo.save(agentSessions)
        ProjectResolver.shared.ownSessions = Dictionary(uniqueKeysWithValues: agentSessions.map { ($0.value.sid, $0.key) })
        beginCompose()
        recompute()
    }

    func stopCommand() {
        if let r = leadRun, r.isActive { AgentRunner.shared.stop(r.id) }
    }

    /// Porta alla sessione vera: nell'app Claude (la chat resta nello storico), oppure l'app da cui parte la sessione.
    func openClaude() {
        guard let key = commandKey, let cwd = folder(for: key) else { return }
        if let r = agentRuns[key], r.isActive { return }
        if let sid = agentRuns[key]?.sessionId ?? agentSessions[key]?.sid {
            AgentRunner.openInDesktop(cwd: cwd, sessionId: sid) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.agentRuns[key]?.inDesktop = true
                    if self.agentSessions[key]?.sid == sid {
                        self.agentSessions[key]?.inDesktop = true
                        AgentSessionInfo.save(self.agentSessions)
                    }
                } else {
                    AgentRunner.openInTerminal(cwd: cwd, sessionId: sid)
                }
            }
        } else if lead?.bundleId != nil {
            focus()
        } else {
            AgentRunner.openInTerminal(cwd: cwd, sessionId: nil)
        }
    }

    /// Per le prove: un comando dato una cartella (la sua chiave e' quella del gruppo, se la cartella ne ha uno).
    func keyForFolder(_ cwd: String) -> String {
        ProjectResolver.shared.resolve(sessionId: "-", cwd: cwd)?.key ?? cwd
    }

    func startAgent(key: String, prompt: String, resume: String?, fork: Bool = false, compact: Bool = false) {
        guard let cwd = folder(for: key) else { return }
        if !agentBound {
            agentBound = true
            AgentRunner.shared.onChange = { [weak self] run in self?.agentChanged(run) }
        }
        trigger(.nod)
        AgentRunner.shared.start(key: key, cwd: cwd, prompt: prompt, resume: resume, fork: fork, compact: compact)
    }

    private func agentChanged(_ run: AgentRun) {
        let before = agentRuns[run.key]
        agentRuns[run.key] = run
        // La conversazione del progetto: si fissa quando il lavoro e' arrivato in fondo (o e' stato fermato).
        if (run.state == .done || run.state == .stopped), let sid = run.sessionId, before?.state != run.state {
            agentSessions[run.key] = AgentSessionInfo(sid: sid, inDesktop: false)
            AgentSessionInfo.save(agentSessions)
        }
        // Le sessioni di Dott appartengono al progetto per cui le ha lanciate (l'app Claude non le conosce).
        if let sid = run.sessionId, ProjectResolver.shared.ownSessions[sid] != run.key {
            ProjectResolver.shared.ownSessions[sid] = run.key
            regroup()
        }
        // La sessione che volevi riprendere non esiste piu' (trascrizioni ripulite): si riparte da zero, senza dirtelo.
        if run.state == .failed, run.resumed, before?.state != .failed,
           (run.raw ?? "").localizedCaseInsensitiveContains("No conversation found") {
            agentSessions[run.key] = nil
            AgentSessionInfo.save(agentSessions)
            AgentRunner.shared.start(key: run.key, cwd: run.cwd, prompt: run.prompt, resume: nil)
            return
        }
        if before?.id != run.id || before?.state != run.state {
            if run.state == .failed {
                trigger(.tilt)
                Sounds.play(.attention)
                peek(6)
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/dott-agent.txt"),
           let h = FileHandle(forWritingAtPath: "/tmp/dott-agent.txt") {
            let line = "\(run.state) key=\(run.key) session=\(run.sessionId ?? "-") summary=\(run.summary ?? "-") raw=\(run.raw ?? "-")\n"
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        }
        recompute()
    }
}
