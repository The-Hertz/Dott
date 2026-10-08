import AppKit
import Foundation
import SwiftUI

/// Un messaggio di una chat, letto dalla sua trascrizione.
struct ChatMessage: Identifiable, Equatable {
    enum Kind: Equatable { case you, manager, agentReply(String) }
    let id: String
    var kind: Kind
    var text: String
    var time: Date?
}

extension Transcript {
    /// Gli ultimi messaggi di una chat (i tuoi, quelli di Claude, e le risposte degli agenti che Dott ha riportato).
    static func messages(sessionId: String, limit: Int = 16) -> (messages: [ChatMessage], modified: Date)? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            let url = base.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: url.path), let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let size = (try? h.seekToEnd()) ?? 0
            let tail: UInt64 = 2_000_000
            try? h.seek(toOffset: size > tail ? size - tail : 0)
            guard let data = try? h.readToEnd() else { continue }
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            if size > tail, !lines.isEmpty { lines.removeFirst() }   // la prima riga puo' essere tagliata
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var out: [ChatMessage] = []
            for line in lines {
                guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
                      let type = o["type"] as? String, type == "user" || type == "assistant",
                      let msg = o["message"] as? [String: Any] else { continue }
                let id = (o["uuid"] as? String) ?? UUID().uuidString
                let time = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
                var text = ""
                if let s = msg["content"] as? String { text = s }
                else if let blocks = msg["content"] as? [[String: Any]] {
                    text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                }
                text = clean(text)
                guard !text.isEmpty else { continue }
                if type == "assistant" {
                    out.append(ChatMessage(id: id, kind: .manager, text: text, time: time))
                } else if text.hasPrefix("[Risposta di "), let end = text.firstIndex(of: "]") {
                    let from = String(text[text.index(text.startIndex, offsetBy: 13)..<end])
                    let body = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(ChatMessage(id: id, kind: .agentReply(from), text: body, time: time))
                } else {
                    out.append(ChatMessage(id: id, kind: .you, text: userRequest(text), time: time))
                }
            }
            return (Array(out.suffix(limit)), modified)
        }
        return nil
    }

    /// Toglie gli avvisi dell'app (<system-reminder>) e gli spazi.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Il primo messaggio del Manager porta le istruzioni di Dott: di quello che hai scritto tu conta l'ultima parte.
    private static func userRequest(_ s: String) -> String {
        guard AgentRegistry.marker(in: s) != nil, let r = s.range(of: "\n\n", options: .backwards) else { return s }
        let tail = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? s : tail
    }
}

extension IslandModel {
    /// Rilegge la conversazione del Manager se la chat e' cambiata (o subito, con `force`).
    func refreshManagerMessages(force: Bool = false) {
        guard let chat = chatTarget(AgentRegistry.managerKey) else {
            if !managerMessages.isEmpty { managerMessages = [] }
            return
        }
        let id = chat.id
        let known = managerMessagesStamp
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            // Si legge solo se il file e' cambiato dall'ultima volta.
            if !force, let mod = Self.transcriptModified(id: id, in: url), let known, mod <= known { return }
            guard let r = Transcript.messages(sessionId: id) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.managerMessagesStamp = r.modified
                    if r.messages != self.managerMessages { self.managerMessages = r.messages }
                }
            }
        }
    }

    nonisolated private static func transcriptModified(id: String, in base: URL) -> Date? {
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            let url = base.appendingPathComponent(dir).appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        return nil
    }
}

// MARK: - La conversazione col Manager

/// La vista principale quando il Manager e' scelto: tutto quello che si sono detti, per intero, i compiti da approvare e il campo per scrivergli.
struct ManagerConversation: View {
    @ObservedObject var model: IslandModel
    let h: HubDott

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.managerMessages.isEmpty { empty }
                        ForEach(model.managerMessages) { m in bubble(m).id(m.id) }
                        if let b = model.dispatches.first { proposals(b).id("proposals") }
                        waitingChips
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: model.managerMessages.last?.id) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.dispatches.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            ManagerComposer(model: model)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 1))
        .onAppear { model.refreshManagerMessages(force: true) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MascotView(mood: h.mood, size: 40, effects: false, tint: (h.color.top, h.color.bottom), outfit: model.outfit)
                .frame(width: 48, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(h.dottName).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Image(systemName: "crown.fill").font(.system(size: 10)).foregroundStyle(Palette.amber)
                    Text("Manager").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.amber.opacity(0.9))
                }
                Text(h.live ? (h.detail.isEmpty ? h.mood.title : h.detail) : "A riposo").font(.system(size: 11.5))
                    .foregroundStyle(h.mood == .waiting ? Palette.amber : .white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if h.isWorking {
                Button { model.interrupt(h.id) } label: {
                    HStack(spacing: 5) { Image(systemName: "stop.circle").font(.system(size: 11)); Text("Interrompi") }
                }
                .buttonStyle(IslandButton(fill: .white.opacity(0.12), text: .white))
            }
            Button { model.openChat(model.chatTarget(h.id)?.id ?? "", in: h.id) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Apri la chat del Manager nell’app Claude")
            .disabled(model.chatTarget(h.id) == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Qui parli con il Manager.").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text("Dagli un obiettivo: lui lo scompone e propone a chi affidare ogni compito. Vedrai qui le sue risposte, le sue proposte e i risultati degli agenti, e potrai correggerlo.")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .you:
            HStack {
                Spacer(minLength: 60)
                RichText(text: m.text, size: 13, color: .white.opacity(0.92))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.11)))
            }
        case .manager:
            VStack(alignment: .leading, spacing: 4) {
                Text(h.dottName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(h.color.top.opacity(0.9))
                RichText(text: m.text, size: 13, color: .white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .agentReply(let from):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.left.circle.fill").font(.system(size: 11))
                    Text("Risposta di \(from)").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.45, green: 0.90, blue: 0.60))
                RichText(text: m.text, size: 12.5, color: .white.opacity(0.84))
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.2, green: 0.5, blue: 0.3).opacity(0.18)))
        }
    }

    /// Le proposte del Manager, nel punto in cui le fa: si scelgono e si mandano da qui.
    private func proposals(_ b: DispatchBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill").font(.system(size: 11))
                Text(b.tasks.count == 1 ? "Compito proposto" : "\(b.tasks.count) compiti proposti")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Palette.amber)
            ForEach(b.tasks) { t in DispatchRow(model: model, batch: b, task: t, fullText: true) }
            HStack(spacing: 8) {
                Button("Annulla") { model.cancelDispatch(b.id) }
                    .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: Palette.coral))
                Spacer(minLength: 0)
                let n = b.tasks.filter(\.selected).count
                Button(n == 1 ? "Invia 1 compito" : "Invia \(n) compiti") { model.approveDispatch(b.id) }
                    .buttonStyle(IslandButton(fill: n == 0 ? .white.opacity(0.10) : Palette.lime, text: n == 0 ? .white.opacity(0.35) : Palette.ink))
                    .disabled(n == 0)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.amber.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.amber.opacity(0.35), lineWidth: 1))
    }

    /// Chi sta lavorando a un compito mandato.
    @ViewBuilder private var waitingChips: some View {
        if !model.awaiting.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                ForEach(Array(model.awaiting.values), id: \.title) { a in
                    Text(a.projects.isEmpty ? a.title : "\(a.title) · \(a.projects.joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                Text("in attesa della risposta").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Il campo per scrivere al Manager: piu' righe, Invio manda, e va nella sua chat (che resta una sola).
struct ManagerComposer: View {
    @ObservedObject var model: IslandModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasChat: Bool { model.chatTarget(AgentRegistry.managerKey) != nil }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(hasChat ? "Scrivi al Manager: un obiettivo, una correzione…" : "Dai un obiettivo al Manager (apre la sua chat)…",
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { send() }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                .onTapGesture {
                    // Nell'isola la finestra prende la tastiera solo mentre scrivi; nella finestra dell'hub e' gia' normale.
                    if !model.hubWindowed { model.beginCompose(key: AgentRegistry.managerKey) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
                }
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(empty ? .white.opacity(0.4) : Palette.ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(empty ? .white.opacity(0.12) : Palette.lime))
            }
            .buttonStyle(PressStyle())
            .disabled(empty)
        }
        .padding(12)
    }

    private func send() {
        guard !empty else { return }
        model.ask(text, key: AgentRegistry.managerKey)
        text = ""
        // La risposta arrivera' fra poco: si rilegge la conversazione dopo l'invio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { model.refreshManagerMessages(force: true) }
    }
}

// MARK: - Testo con titoli, elenchi e tabelle

/// Una risposta di Claude letta bene: titoli, elenchi, tabelle e codice, con il grassetto e i link dentro il testo.
struct RichText: View {
    let text: String
    var size: CGFloat = 13
    var color: Color = .white.opacity(0.9)

    private enum Block: Identifiable {
        case heading(Int, String)
        case table(Int, [[String]])
        case code(Int, String)
        case paragraph(Int, String)
        var id: Int {
            switch self { case .heading(let i, _), .table(let i, _), .code(let i, _), .paragraph(let i, _): return i }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var table: [[String]] = []
        var code: [String]? = nil
        func flushPara() { if !para.isEmpty { out.append(.paragraph(out.count, para.joined(separator: "\n"))); para = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(out.count, table)); table = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(out.count, c.joined(separator: "\n"))); code = nil }
                else { flushPara(); flushTable(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix("|") {
                flushPara()
                let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = !cells.isEmpty && cells.allSatisfy { $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }
                if !isSeparator, !cells.isEmpty { table.append(Array(cells)) }
                continue
            }
            flushTable()
            if line.isEmpty { flushPara(); continue }
            if line.hasPrefix("#") {
                flushPara()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                continue
            }
            para.append(raw)
        }
        flushPara(); flushTable()
        if let c = code { out.append(.code(out.count, c.joined(separator: "\n"))) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { b in
                switch b {
                case .heading(_, let t):
                    Text(inline(t)).font(.system(size: size + 1.5, weight: .semibold)).foregroundStyle(color)
                case .paragraph(_, let t):
                    Text(inline(t)).font(.system(size: size)).foregroundStyle(color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(_, let t):
                    Text(t).font(.system(size: size - 1.5, design: .monospaced)).foregroundStyle(color.opacity(0.9))
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35)))
                case .table(_, let rows):
                    table(rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func table(_ rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell)).font(.system(size: size - 1, weight: i == 0 ? .semibold : .regular))
                            .foregroundStyle(i == 0 ? color : color.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if i == 0 { Divider().overlay(.white.opacity(0.15)) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
