import AppKit
import SwiftUI

/// `Dott --snapshot <cartella>`: disegna l'isola in PNG, senza finestra. Serve a controllare il disegno.
@MainActor
enum Snapshot {
    static func run(into dir: String) {
        AppSettings.shared.persist = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        hubSheet(into: dir)
        for mood in Mood.allCases {
            for expanded in [false, true] {
                let model = IslandModel()
                model.forceExpanded = expanded
                model.preview(mood)
                write(model, to: "\(dir)/\(mood.rawValue)-\(expanded ? "open" : "closed").png")
            }
        }
        let model = IslandModel()
        let conn = Connection(fd: -1) { _, _ in }
        model.receive(["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/Users/x/Finances",
                       "tool_name": "Bash",
                       "tool_input": ["command": "xcodebuild -scheme Finances -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build"],
                       "permission_suggestions": [["type": "addRules"]]], from: conn)
        write(model, to: "\(dir)/permission.png")

        let qm = IslandModel()
        qm.previewQuestion()
        write(qm, to: "\(dir)/question.png")

        // Scenario completo dagli eventi veri, come li manda Claude Code.
        let em = IslandModel()
        let dummy = Connection(fd: -1) { _, _ in }
        func ev(_ name: String, _ extra: [String: Any] = [:]) {
            var p: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/Users/x/Finances"]
            p.merge(extra) { $1 }
            em.receive(p, from: dummy)
        }
        ev("UserPromptSubmit", ["prompt": "Controlla budget e test"])
        ev("PreToolUse", ["tool_name": "Agent", "tool_input": ["subagent_type": "Explore", "description": "Cerca dove si calcola il budget"]])
        ev("PreToolUse", ["tool_name": "Agent", "tool_input": ["subagent_type": "general-purpose", "description": "Controlla che i test passino"]])
        ev("SubagentStart", ["agent_id": "A", "agent_type": "Explore"])
        ev("SubagentStart", ["agent_id": "B", "agent_type": "general-purpose"])
        ev("PreToolUse", ["agent_id": "A", "agent_type": "Explore", "tool_name": "Read", "tool_input": ["file_path": "/x/BudgetView.swift"]])
        ev("PreToolUse", ["agent_id": "B", "agent_type": "general-purpose", "tool_name": "Bash", "tool_input": ["command": "swift test"]])
        em.forceExpanded = true
        em.refresh()
        write(em, to: "\(dir)/agents-events.png")
        ev("SubagentStop", ["agent_id": "A"])
        write(em, to: "\(dir)/agents-events-after-stop.png")

        // Piu' sessioni, con il contesto letto da una trascrizione finta.
        let tpath = NSTemporaryDirectory() + "dott-snap-transcript.jsonl"
        let line = #"{"type":"assistant","message":{"role":"assistant","model":"claude-x","usage":{"input_tokens":3000,"cache_read_input_tokens":118000,"cache_creation_input_tokens":2000,"output_tokens":900}}}"#
        try? (line + "\n").write(toFile: tpath, atomically: true, encoding: .utf8)
        let sm = IslandModel()
        func sev(_ sid: String, _ proj: String, _ name: String, _ extra: [String: Any] = [:]) {
            var p: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": "/Users/x/\(proj)", "transcript_path": tpath]
            p.merge(extra) { $1 }
            sm.receive(p, from: dummy)
        }
        sev("a", "Finances", "UserPromptSubmit", ["prompt": "Sistema il budget"])
        sev("a", "Finances", "PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/x/BudgetView.swift"]])
        sev("b", "Forma", "UserPromptSubmit", ["prompt": "Aggiungi il timer"])
        sev("b", "Forma", "Notification", ["message": "Serve il tuo ok", "notification_type": "permission_prompt"])
        sev("c", "Serenity", "SessionStart")
        sev("c", "Serenity", "Stop")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        sm.forceExpanded = true
        sm.refresh()
        write(sm, to: "\(dir)/sessions-open.png")
        sm.forceExpanded = false
        sm.refresh()
        write(sm, to: "\(dir)/sessions-closed.png")

        // Piano da approvare.
        let pm = IslandModel()
        pm.receive(["hook_event_name": "PermissionRequest", "session_id": "p", "cwd": "/Users/x/Finances", "tool_name": "ExitPlanMode",
                    "tool_input": ["plan": "## Piano\n\n1. Aggiungere la tabella **goals** con la migrazione 013\n2. Collegare la vista Obiettivi ai nuovi dati\n3. Scrivere i test per il calcolo dei progressi\n4. Verificare su simulatore iPhone 17 Pro\n\nNon tocco le altre schermate."]], from: dummy)
        write(pm, to: "\(dir)/plan.png")

        // Risposta libera.
        let tm = IslandModel()
        tm.previewQuestion()
        if let id = tm.questions.first?.id { tm.beginFreeText(id) }
        write(tm, to: "\(dir)/question-typing.png")

        // Cosa mi sono perso.
        let rm = IslandModel()
        rm.debugRecap([RecapLine(symbol: "checkmark.circle", text: "2 lavori finiti"),
                       RecapLine(symbol: "doc.on.doc", text: "5 file modificati"),
                       RecapLine(symbol: "xmark.octagon", text: "2 test falliti su 13 in Forma"),
                       RecapLine(symbol: "hourglass", text: "In attesa di te: 1 richiesta")])
        write(rm, to: "\(dir)/recap.png")

        // Compiti, modalita' dei permessi, ultima risposta.
        let tm2 = IslandModel()
        let dm = Connection(fd: -1) { _, _ in }
        func tev(_ name: String, _ extra: [String: Any] = [:]) {
            var p: [String: Any] = ["hook_event_name": name, "session_id": "td", "cwd": "/Users/x/Finances", "permission_mode": "acceptEdits"]
            p.merge(extra) { $1 }
            tm2.receive(p, from: dm)
        }
        tev("UserPromptSubmit", ["prompt": "Aggiungi gli obiettivi"])
        tev("PreToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": [
            ["content": "Creare la migrazione", "status": "completed", "activeForm": "Crea la migrazione"],
            ["content": "Collegare la vista", "status": "completed", "activeForm": "Collega la vista"],
            ["content": "Scrivere i test", "status": "in_progress", "activeForm": "Sta scrivendo i test"],
            ["content": "Provare sul simulatore", "status": "pending", "activeForm": "Prova sul simulatore"],
            ["content": "Aggiornare la documentazione", "status": "pending", "activeForm": "Aggiorna la documentazione"],
        ]]])
        tm2.forceExpanded = true
        tm2.refresh()
        write(tm2, to: "\(dir)/todos.png")
        tev("Stop", ["last_assistant_message": "## Fatto\n\nHo aggiunto la tabella degli obiettivi e collegato la vista; i test passano."])
        write(tm2, to: "\(dir)/snippet.png")
        let fm = IslandModel()
        fm.receive(["hook_event_name": "StopFailure", "session_id": "ff", "cwd": "/Users/x/Finances", "error": "rate_limit",
                    "error_details": "Riprova dopo le 18:30"], from: dm)
        fm.forceExpanded = true
        fm.refresh()
        write(fm, to: "\(dir)/failure.png")
        let qm2 = IslandModel()
        qm2.receive(["hook_event_name": "Notification", "session_id": "qq", "cwd": "/Users/x/Finances",
                     "notification_type": "quota_auto_resume", "message": "Limite raggiunto: riprende automaticamente alle 18:30"], from: dm)
        qm2.forceExpanded = true
        qm2.refresh()
        write(qm2, to: "\(dir)/quota.png")

        multiProject(into: dir)
        dressSheet(into: dir)
        broomSheet(into: dir)
        gestureSheet(into: dir)

        let am = IslandModel()
        am.forceExpanded = true
        am.previewAgents()
        write(am, to: "\(dir)/agents-open.png")
        let ac = IslandModel()
        ac.forceExpanded = false
        ac.previewAgents()
        write(ac, to: "\(dir)/agents-closed.png")
    }

    /// Una tavola con tutti gli accessori, i vestiti, le forme e i colori, a piena intensita'.
    private static func dressSheet(into dir: String) {
        let st0 = AppSettings.shared
        let saved = (st0.shape, st0.color, st0.antenna)
        defer { st0.shape = saved.0; st0.color = saved.1; st0.antenna = saved.2 }
        struct Cell: Identifiable { let id = UUID(); let label: String; let dress: Dress; let mood: Mood
            let shape: DottShape; let color: DottColor; let antenna: Bool }
        let none = Dress()
        var cells: [Cell] = []
        func d(_ f: (inout Dress) -> Void) -> Dress { var x = Dress(); f(&x); return x }
        cells += [
            Cell(label: "occhiali", dress: d { $0.glasses = 1 }, mood: .reading, shape: .blob, color: .lime, antenna: true),
            Cell(label: "matita", dress: d { $0.pencil = 1 }, mood: .writing, shape: .blob, color: .lime, antenna: true),
            Cell(label: "cuffie", dress: d { $0.headphones = 1 }, mood: .running, shape: .blob, color: .lime, antenna: true),
            Cell(label: "casco", dress: d { $0.helmet = 1 }, mood: .running, shape: .blob, color: .lime, antenna: true),
            Cell(label: "babbo natale", dress: d { $0.santa = 1; $0.scarf = 1 }, mood: .working, shape: .blob, color: .lime, antenna: true),
            Cell(label: "strega", dress: d { $0.witch = 1 }, mood: .working, shape: .blob, color: .lime, antenna: true),
            Cell(label: "compleanno", dress: d { $0.party = 1 }, mood: .happy, shape: .blob, color: .lime, antenna: true),
            Cell(label: "sciarpa", dress: d { $0.scarf = 1 }, mood: .working, shape: .blob, color: .lime, antenna: true),
        ]
        cells += DottShape.allCases.map { Cell(label: "forma \($0.label)", dress: none, mood: .working, shape: $0, color: .lime, antenna: true) }
        cells.append(Cell(label: "senza antenna", dress: none, mood: .working, shape: .blob, color: .lime, antenna: false))
        cells += DottColor.allCases.dropFirst().map { Cell(label: $0.label, dress: none, mood: .working, shape: .blob, color: $0, antenna: true) }

        let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 8), count: 6), spacing: 8) {
            ForEach(cells) { c in
                VStack(spacing: 2) {
                    Canvas { ctx, sz in
                        let st = AppSettings.shared
                        st.shape = c.shape; st.color = c.color; st.antenna = c.antenna
                        Mascot.draw(&ctx, size: sz, mood: c.mood, t: 1.3, pop: 9, effects: true, dress: c.dress)
                    }
                    .frame(width: 150, height: 130)
                    Text(c.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(4)
                .background(Color.black)
            }
        }
        .padding(8)
        .background(Color(white: 0.25))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/dress.png"))
        }
    }

    /// Due e tre progetti insieme, a isola chiusa e aperta.
    private static func multiProject(into dir: String) {
        let dummy = Connection(fd: -1) { _, _ in }
        for count in [2, 3] {
            let m = IslandModel()
            func ev(_ cwd: String, _ sid: String, _ name: String, _ extra: [String: Any] = [:]) {
                var p: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": cwd]
                p.merge(extra) { $1 }
                m.receive(p, from: dummy)
            }
            ev("/Users/x/Finances", "a", "UserPromptSubmit", ["prompt": "Sistema il budget"])
            ev("/Users/x/Finances", "a", "PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/x/BudgetView.swift"]])
            ev("/Users/x/Forma", "b", "UserPromptSubmit", ["prompt": "Aggiungi il timer"])
            ev("/Users/x/Forma", "b", "PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "xcodebuild test"]])
            if count == 3 {
                ev("/Users/x/Serenity", "c", "PreCompact", ["trigger": "auto"])
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            m.forceExpanded = false
            m.refresh()
            write(m, to: "\(dir)/multi\(count)-closed.png")
            m.forceExpanded = true
            m.refresh()
            write(m, to: "\(dir)/multi\(count)-open.png")
        }
    }

    /// La scopa a sei istanti diversi: si controlla il colpo, i pezzetti, le setole.
    private static func broomSheet(into dir: String) {
        let times = [0.0, 0.18, 0.36, 0.54, 0.72, 0.90]
        let view = HStack(spacing: 8) {
            ForEach(times, id: \.self) { t in
                Canvas { ctx, sz in
                    Mascot.draw(&ctx, size: sz, mood: .working, t: 1.0 + t, pop: 9, effects: true, dress: { var d = Dress(); d.broom = 1; return d }())
                }
                .frame(width: 150, height: 130)
                .background(Color.black)
            }
        }
        .padding(8)
        .background(Color(white: 0.25))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/broom.png"))
        }
    }

    /// I gesti nuovi, a istanti scelti: starnuto, fischietto, lucciola.
    private static func gestureSheet(into dir: String) {
        struct Frame: Identifiable { let id = UUID(); let kind: GestureKind; let u: Double }
        let frames: [Frame] = [0.3, 0.5, 0.57, 0.7].map { Frame(kind: .sneeze, u: $0) }
            + [0.25, 0.6].map { Frame(kind: .whistle, u: $0) }
            + [0.2, 0.45, 0.7, 0.85].map { Frame(kind: .chase, u: $0) }
        let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 8), count: 5), spacing: 8) {
            ForEach(frames) { f in
                Canvas { ctx, sz in
                    Mascot.draw(&ctx, size: sz, mood: .working, t: 2.0 + f.u * f.kind.duration, pop: 9, effects: true, gesture: (f.kind, f.u))
                }
                .frame(width: 150, height: 130)
                .background(Color.black)
            }
        }
        .padding(8)
        .background(Color(white: 0.25))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/gestures-new.png"))
        }
    }

    /// L'hub con la piazzetta: finestra e isola, con tre post-it di prova.
    static func hubSheet(into dir: String) {
        let m = IslandModel()
        m.previewAgents()
        m.hubSelected = m.hubDotts.first?.id
        for (name, w, h, windowed) in [("hub-window", 800.0, 540.0, true),
                                       ("hub-island", Double(IslandModel.hubWidth), Double(IslandModel.hubHeight), false)] {
            let view = HubView(model: m, windowed: windowed, notchHeight: 32, notchWidth: 180)
                .frame(width: w, height: h)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    private static func write(_ model: IslandModel, to path: String) {
        let size = model.size
        let view = IslandView(model: model)
            .frame(width: size.width + 40, height: size.height + 20, alignment: .top)
            .background(Color(white: 0.25))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
