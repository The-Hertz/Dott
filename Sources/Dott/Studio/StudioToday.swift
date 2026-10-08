import AppKit
import Charts
import DottKit
import SwiftUI

private struct DaySeconds: Identifiable {
    let day: Date
    let seconds: TimeInterval
    var id: Date { day }
}

/// La giornata raccontata: quanto hai lavorato, dove, cosa e' successo. Tutto dal diario locale, senza spendere token.
struct StudioToday: View {
    @ObservedObject private var companion = Companion.shared
    @State private var offset = 0
    @State private var digest: DayDigest?
    @State private var week: [DaySeconds] = []
    @State private var copied = false
    private let refresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var day: Date { Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date() }

    private var title: String {
        switch offset {
        case 0: "Oggi"
        case 1: "Ieri"
        default: day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    var body: some View {
        StudioPage(title: title, subtitle: day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())) {
            controls
            if !CompanionSettings.shared.journal {
                EmptyNote(symbol: "pause.circle", title: "Il diario e' spento",
                          text: "Riaccendilo in «Dati e privacy» per vedere qui la giornata.")
            } else if let d = digest, !d.isEmpty {
                tiles(d)
                weekChart
                ForEach(d.projects, id: \.key) { project($0) }
            } else {
                EmptyNote(symbol: "moon.zzz.fill", title: offset == 0 ? "Ancora niente, per oggi" : "Nessun lavoro registrato",
                          text: "Appena Claude Code lavora con un hook di Dott attivo, qui compare la giornata: tempo, file, commit e test.")
                weekChart
            }
        }
        .onAppear(perform: load)
        .onChange(of: offset) { _, _ in load() }
        .onReceive(refresh) { _ in if offset == 0 { load() } }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { offset += 1 } label: { Image(systemName: "chevron.left") }
            Button { offset = max(0, offset - 1) } label: { Image(systemName: "chevron.right") }.disabled(offset == 0)
            if offset != 0 { Button("Oggi") { offset = 0 } }
            Spacer()
            Button {
                guard let d = digest else { return }
                let text = "# \(title)\n\n" + Digester.narrative(d).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                Label(copied ? "Copiato" : "Copia il riepilogo", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(digest?.isEmpty ?? true)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func tiles(_ d: DayDigest) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatTile(title: "Tempo attivo", value: DayFormat.duration(d.activeSeconds), tint: Brand.accent)
            StatTile(title: "Richieste", value: "\(d.totalPrompts)", caption: d.projects.count == 1 ? "in 1 progetto" : "in \(d.projects.count) progetti")
            StatTile(title: "File modificati", value: "\(d.totalFiles)")
            StatTile(title: "Commit", value: "\(d.totalCommits)",
                     caption: d.averagePermissionWait.map { "Rispondi ai permessi in \($0 < 60 ? "\(Int($0.rounded())) s" : DayFormat.duration($0))" })
        }
    }

    private var weekChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ultimi sette giorni").font(.system(size: 13, weight: .semibold))
                Chart(week) { item in
                    BarMark(x: .value("Giorno", item.day, unit: .day), y: .value("Ore", item.seconds / 3600))
                        .foregroundStyle(Calendar.current.isDate(item.day, inSameDayAs: day) ? Brand.accent : Brand.accent.opacity(0.3))
                        .cornerRadius(4)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartYAxisLabel("ore")
                .frame(height: 130)
            }
        }
    }

    private func project(_ p: ProjectDigest) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.name).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(DayFormat.duration(p.activeSeconds)).font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.accent)
                }
                HStack(spacing: 8) {
                    chip("text.bubble", p.prompts == 1 ? "1 richiesta" : "\(p.prompts) richieste")
                    if !p.files.isEmpty { chip("pencil", p.files.count == 1 ? "1 file" : "\(p.files.count) file") }
                    if !p.commits.isEmpty { chip("arrow.triangle.branch", p.commits.count == 1 ? "1 commit" : "\(p.commits.count) commit") }
                    if p.testsPassed + p.testsFailed > 0 {
                        chip(p.testsFailed == 0 ? "checkmark.seal" : "xmark.seal", p.testsFailed == 0 ? "test verdi" : "\(p.testsFailed) test falliti",
                             tint: p.testsFailed == 0 ? Brand.accent : Brand.coral)
                    }
                    if p.buildsFailed > 0 { chip("hammer", "\(p.buildsFailed) build fallite", tint: Brand.coral) }
                    if p.permissionsAsked > 0 { chip("hand.raised", "\(p.permissionsAsked) permessi") }
                }
                if let q = p.lastPrompt, !q.isEmpty {
                    Text("«\(q)»").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !p.commits.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(p.commits.prefix(4).enumerated()), id: \.offset) { _, c in
                            Label(c, systemImage: "arrow.triangle.branch").font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                if !p.files.isEmpty {
                    Text(p.files.prefix(6).joined(separator: " · ") + (p.files.count > 6 ? " …" : ""))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private func chip(_ symbol: String, _ text: String, tint: Color = .white) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func load() {
        let reader = companion.reader
        let cal = Calendar.current
        let selected = day
        digest = Digester.digest(reader.events(on: selected))
        week = (0..<7).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: selected) else { return nil }
            return DaySeconds(day: cal.startOfDay(for: d), seconds: Digester.digest(reader.events(on: d)).activeSeconds)
        }
    }
}
