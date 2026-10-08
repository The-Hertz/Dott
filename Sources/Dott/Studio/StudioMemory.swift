import AppKit
import DottKit
import SwiftUI

private struct ProjectRef: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Cosa Dott ricorda di ogni progetto, e cosa consegna a Claude all'inizio di una chat. Tutto si legge, si corregge e si spegne.
struct StudioMemory: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var companion = Companion.shared
    @ObservedObject private var settings = CompanionSettings.shared
    @State private var selected: String?
    @State private var memory: ProjectMemory?
    @State private var draft = ""
    @State private var draftKind: NoteKind = .decision

    private var projects: [ProjectRef] {
        var list = ProjectResolver.shared.groups().map { ProjectRef(id: $0.key, name: $0.name) }
        for m in companion.memory.all() where !list.contains(where: { $0.id == m.key }) {
            list.append(ProjectRef(id: m.key, name: m.name.isEmpty ? (m.key as NSString).lastPathComponent : m.name))
        }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(projects, selection: $selected) { p in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Brand.accent.opacity(0.8))
                    Text(p.name).lineLimit(1)
                }
                .tag(p.id)
            }
            .frame(width: 210)
            .scrollContentBackground(.hidden)
            Divider()
            Group {
                if let key = selected, let project = projects.first(where: { $0.id == key }) {
                    editor(key: key, name: project.name)
                } else {
                    VStack { EmptyNote(symbol: "brain.head.profile", title: "Scegli un progetto",
                                       text: "Qui decidi cosa Dott ricorda e cosa dice a Claude quando apri una chat nuova.").padding(28); Spacer() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { if selected == nil { selected = model.commandKey ?? projects.first?.id } ; reload() }
        .onChange(of: selected) { _, _ in reload() }
    }

    private func reload() {
        guard let key = selected, let name = projects.first(where: { $0.id == key })?.name else { memory = nil; return }
        memory = companion.memory.load(key, name: name)
    }

    private func change(_ key: String, _ name: String, _ f: (inout ProjectMemory) -> Void) {
        memory = companion.memory.update(key, name: name, f)
    }

    @ViewBuilder
    private func editor(key: String, name: String) -> some View {
        let m = memory ?? ProjectMemory(key: key, name: name)
        StudioPage(title: name, subtitle: "Memoria del progetto") {
            Card {
                Toggle(isOn: Binding(get: { m.briefEnabled }, set: { v in change(key, name) { $0.briefEnabled = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Consegna il promemoria a Claude").font(.system(size: 13, weight: .semibold))
                        Text("All'inizio di ogni chat nuova di questo progetto (non nelle chat riprese).").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            notes(m, key: key, name: name)
            handoff(m, key: key, name: name)
            inbox(m, key: key, name: name)
            preview(m)
            delivered
        }
    }

    // MARK: Note

    private func notes(_ m: ProjectMemory, key: String, name: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Da ricordare").font(.system(size: 13, weight: .semibold))
                if m.notes.isEmpty {
                    Text("Decisioni prese, preferenze, trappole da evitare. Scrivile una volta: Claude le leggera' ogni volta.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                ForEach(m.notes) { n in
                    HStack(alignment: .top, spacing: 8) {
                        Button { change(key, name) { mem in if let i = mem.notes.firstIndex(where: { $0.id == n.id }) { mem.notes[i].pinned.toggle() } } } label: {
                            Image(systemName: n.pinned ? "pin.fill" : "pin").foregroundStyle(n.pinned ? Brand.amber : .secondary)
                        }
                        .buttonStyle(.borderless).help("Una nota fissata entra per prima nel promemoria")
                        Text(n.kind.label).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.1)))
                        Text(n.text).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(n.enabled ? 1 : 0.4).textSelection(.enabled)
                        Toggle("", isOn: Binding(get: { n.enabled }, set: { v in
                            change(key, name) { mem in if let i = mem.notes.firstIndex(where: { $0.id == n.id }) { mem.notes[i].enabled = v } }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        Button { change(key, name) { $0.notes.removeAll { $0.id == n.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Picker("", selection: $draftKind) {
                        ForEach(NoteKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    TextField("Una cosa che Claude deve sapere…", text: $draft).textFieldStyle(.roundedBorder).onSubmit { addNote(key, name) }
                    Button("Aggiungi") { addNote(key, name) }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addNote(_ key: String, _ name: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        change(key, name) { $0.notes.append(MemoryNote(kind: draftKind, text: text, pinned: draftKind == .gotcha)) }
        draft = ""
    }

    // MARK: Dove eravamo e appunti

    @ViewBuilder
    private func handoff(_ m: ProjectMemory, key: String, name: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Dove eravamo").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if m.handoff != nil {
                        Button("Dimentica") { change(key, name) { $0.handoff = nil } }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                if let h = m.handoff {
                    Text("Salvato \(companion.format.ago(h.savedAt, now: Date()))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let p = h.lastPrompt { line("Ultima richiesta", "«\(p)»") }
                    if let o = h.lastOutcome { line("Come era finita", o) }
                    if !h.openTodos.isEmpty { line("Ancora aperto", h.openTodos.joined(separator: "; ")) }
                    if !h.files.isEmpty { line("File toccati", h.files.joined(separator: ", ")) }
                    if let b = h.branch { line("Ramo", b) }
                } else {
                    Text("Si scrive da solo quando una chat si ferma. Alla prossima chat Claude sa da dove ripartire.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func line(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(text).font(.system(size: 12.5)).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func inbox(_ m: ProjectMemory, key: String, name: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Appunti in attesa").font(.system(size: 13, weight: .semibold))
                if m.inbox.isEmpty {
                    Text("Con ⌃⌥D scrivi un pensiero al volo: arriva a Claude nella prossima chat di questo progetto, una volta sola.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                ForEach(m.inbox) { item in
                    HStack {
                        Text(item.text).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                        Button { change(key, name) { $0.inbox.removeAll { $0.id == item.id } } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Anteprima

    @ViewBuilder
    private func preview(_ m: ProjectMemory) -> some View {
        let options = BriefOptions(tokenBudget: settings.briefBudget, ownerName: DottRole.owner)
        let brief = BriefBuilder.build(m, now: Date(), options: options, format: companion.format)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Cosa leggera' Claude", systemImage: "eye").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let b = brief {
                        Text("~\(b.estimatedTokens) token su \(settings.briefBudget)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                if let b = brief {
                    Text(b.text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
                    if b.droppedNotes > 0 {
                        Label("\(b.droppedNotes) note non entrano nel limite di token: fissa quelle importanti o alza il limite in «Dati e privacy».",
                              systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Brand.amber)
                    }
                } else {
                    Text(m.briefEnabled ? "Per ora non c'e' niente da consegnare: Claude parte da zero, come sempre." : "Il promemoria e' spento per questo progetto.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var delivered: some View {
        if !companion.briefs.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ultimi promemoria consegnati").font(.system(size: 13, weight: .semibold))
                    ForEach(companion.briefs.prefix(5)) { b in
                        DisclosureGroup {
                            Text(b.text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
                        } label: {
                            Text("\(b.project) · \(companion.format.ago(b.at, now: Date())) · ~\(b.tokens) token").font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }
}
