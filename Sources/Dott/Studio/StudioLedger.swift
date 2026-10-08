import Charts
import DottKit
import SwiftUI

private struct Segment: Identifiable {
    let date: Date
    let kind: String
    let value: Int
    var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
}

private struct RateRow: Identifiable {
    var id = UUID()
    var pattern = ""
    var input = 0.0
    var output = 0.0
    var cacheWrite = 0.0
    var cacheRead = 0.0
}

/// Il registro dei consumi: quanti token sono passati, dove e (se imposti i prezzi) quanto varrebbero.
/// Si legge dalle trascrizioni di Claude Code: Dott non chiama nessuna API e non spende nulla.
struct StudioLedger: View {
    @ObservedObject private var companion = Companion.shared
    @State private var range = 30
    @State private var showRates = false

    private let format = DayFormat()

    private var days: ClosedRange<String> {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(range - 1), to: end) ?? end
        return format.stamp(start)...format.stamp(end)
    }

    private var rows: [LedgerRow] { companion.ledgerRows.filter { days.contains($0.day) } }

    var body: some View {
        StudioPage(title: "Registro", subtitle: "Quanto lavoro e' passato dai modelli, letto dalle tue chat. Non costa nulla leggerlo.") {
            controls
            if !CompanionSettings.shared.ledger {
                EmptyNote(symbol: "pause.circle", title: "La lettura dei consumi e' spenta", text: "Riaccendila in «Dati e privacy».")
            } else if rows.isEmpty {
                EmptyNote(symbol: companion.scanning ? "arrow.triangle.2.circlepath" : "tray",
                          title: companion.scanning ? "Sto leggendo le tue chat…" : "Niente da mostrare",
                          text: companion.scanning ? "La prima lettura puo' richiedere qualche istante."
                                                   : "Non ci sono consumi nel periodo scelto. Controlla in «Salute» che Claude Code abbia una cronologia.")
            } else {
                summary
                dailyChart
                HStack(alignment: .top, spacing: 14) {
                    breakdown(title: "Per progetto", groups: LedgerQuery.group(rows, by: { companion.project(of: $0) }))
                    breakdown(title: "Per modello", groups: LedgerQuery.group(rows, by: { $0.model }))
                }
                orchestration
            }
            footer
        }
        .sheet(isPresented: $showRates) { RatesEditor(isPresented: $showRates) }
        .onAppear { companion.refreshLedger() }
    }

    private var controls: some View {
        HStack {
            Picker("Periodo", selection: $range) {
                Text("7 giorni").tag(7)
                Text("30 giorni").tag(30)
                Text("90 giorni").tag(90)
            }
            .pickerStyle(.segmented).frame(maxWidth: 280).labelsHidden()
            Spacer()
            Button { showRates = true } label: { Label("Prezzi", systemImage: "dollarsign.circle") }
            Button { companion.refreshLedger() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }.disabled(companion.scanning)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Numeri

    private var summary: some View {
        let total = rows.reduce(UsageTotals()) { $0 + $1.totals }
        let byModel = Dictionary(grouping: rows, by: \.model).mapValues { $0.reduce(UsageTotals()) { $0 + $1.totals } }
        let cost = companion.rates.cost(byModel: byModel)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatTile(title: "Token nuovi", value: Compact.tokens(total.fresh), caption: "scritti, letti per la prima volta o salvati in cache", tint: Brand.accent)
            StatTile(title: "Riletti dalla cache", value: Compact.tokens(total.cacheRead), caption: "pesano molto meno sul limite")
            StatTile(title: "Risposte", value: "\(total.messages)", caption: "~\(Compact.tokens(total.fresh / max(1, total.messages))) token nuovi l'una")
            if companion.rates.isEmpty {
                StatTile(title: "Costo stimato", value: "—", caption: "Imposta i prezzi per vederlo")
            } else if let cost {
                StatTile(title: "Costo stimato", value: Compact.dollars(cost), caption: "a listino, come se pagassi a token", tint: Brand.amber)
            } else {
                StatTile(title: "Costo stimato", value: "—", caption: "Manca il prezzo di un modello usato")
            }
        }
    }

    private var dailyChart: some View {
        let perDay = LedgerQuery.perDay(rows, last: range, endingAt: Date(), format: format)
        let segments: [Segment] = perDay.flatMap { g -> [Segment] in
            guard let d = Compact.day(g.key) else { return [] }
            return [Segment(date: d, kind: "Nuovi in ingresso", value: g.totals.input),
                    Segment(date: d, kind: "Risposte", value: g.totals.output),
                    Segment(date: d, kind: "Scritti in cache", value: g.totals.cacheWrite)]
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Token nuovi al giorno").font(.system(size: 13, weight: .semibold))
                Chart(segments) { s in
                    BarMark(x: .value("Giorno", s.date, unit: .day), y: .value("Token", s.value))
                        .foregroundStyle(by: .value("Tipo", s.kind))
                }
                .chartForegroundStyleScale(["Nuovi in ingresso": Brand.sky, "Risposte": Brand.accent, "Scritti in cache": Brand.amber])
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(Compact.tokens(n)) } } } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 190)
            }
        }
    }

    private func breakdown(title: String, groups: [LedgerGroup]) -> some View {
        let top = groups.prefix(6)
        let maxValue = max(1, top.map(\.totals.fresh).max() ?? 1)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold))
                ForEach(Array(top), id: \.key) { g in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(g.key).font(.system(size: 12.5)).lineLimit(1)
                            Spacer()
                            Text(Compact.tokens(g.totals.fresh)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Brand.accent).frame(width: max(4, geo.size.width * Double(g.totals.fresh) / Double(maxValue)))
                                }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }

    private var orchestration: some View {
        let share = LedgerQuery.orchestrationShare(rows, isOrchestrated: { companion.isOrchestrated($0) })
        let all = share.orchestrated.fresh + share.other.fresh
        let pct = all == 0 ? 0 : Int((Double(share.orchestrated.fresh) / Double(all) * 100).rounded())
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Il Manager conviene?", systemImage: "crown.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.amber)
                if share.orchestrated.messages == 0 {
                    Text("Nel periodo non hai usato il Manager o gli agenti. Quando lo farai, qui vedrai quanto pesano sul totale, per decidere se orchestrare vale i token.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    Text("Il Manager e gli agenti hanno usato \(Compact.tokens(share.orchestrated.fresh)) token nuovi, il \(pct)% del totale, in \(share.orchestrated.messages) risposte.")
                        .font(.system(size: 12.5))
                    Text("Confrontalo con quanto hanno prodotto (file, commit, test nella pagina Oggi): se il peso e' alto e il risultato no, usa una chat singola.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if companion.scanning { ProgressView().controlSize(.small) }
            Text(companion.lastScan.map { "Aggiornato \(format.ago($0, now: Date()))" } ?? "Non ancora aggiornato")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// I prezzi si scrivono a mano: i listini cambiano e Dott non inventa cifre. Il nome e' una parola contenuta nel modello ("opus", "sonnet").
private struct RatesEditor: View {
    @Binding var isPresented: Bool
    @State private var rows: [RateRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prezzi dei modelli").font(.system(size: 18, weight: .bold, design: .rounded))
            Text("Dollari per milione di token. Il nome puo' essere una parte del modello: «opus» vale per tutti i modelli Opus.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Text("Modello").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Ingresso").frame(width: 80, alignment: .leading)
                        Text("Risposta").frame(width: 80, alignment: .leading)
                        Text("Scrive cache").frame(width: 80, alignment: .leading)
                        Text("Legge cache").frame(width: 80, alignment: .leading)
                        Spacer().frame(width: 28)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach($rows) { $row in
                        HStack {
                            TextField("opus", text: $row.pattern).textFieldStyle(.roundedBorder)
                            TextField("0", value: $row.input, format: .number).frame(width: 80)
                            TextField("0", value: $row.output, format: .number).frame(width: 80)
                            TextField("0", value: $row.cacheWrite, format: .number).frame(width: 80)
                            TextField("0", value: $row.cacheRead, format: .number).frame(width: 80)
                            Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).frame(width: 28)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Button { rows.append(RateRow()) } label: { Label("Aggiungi", systemImage: "plus") }
                Spacer()
                Button("Annulla") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Salva") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 640, height: 400)
        .onAppear {
            rows = Companion.shared.rates.rates.sorted { $0.key < $1.key }.map {
                RateRow(pattern: $0.key, input: $0.value.input, output: $0.value.output, cacheWrite: $0.value.cacheWrite, cacheRead: $0.value.cacheRead)
            }
            if rows.isEmpty { rows = [RateRow()] }
        }
    }

    private func save() {
        var card = RateCard()
        for r in rows {
            let key = r.pattern.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            card.rates[key] = ModelRate(input: r.input, output: r.output, cacheWrite: r.cacheWrite, cacheRead: r.cacheRead)
        }
        Companion.shared.saveRates(card)
        isPresented = false
    }
}
