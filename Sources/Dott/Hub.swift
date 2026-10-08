import AppKit
import SwiftUI

/// Un Dott com'e' nell'hub: chi e', cosa sta facendo, da quanto stanno insieme.
struct HubDott: Identifiable, Equatable {
    var id: String            // la chiave del progetto
    var dottName: String
    var project: String
    var color: DottColor
    var mood: Mood
    var detail: String
    var accessory: Accessory?
    var contextFraction: Double?
    var agents: Int
    var live: Bool
    var days: Int
    var folder: String?
    var role: DottRole = .generic
    var trait: DottTrait?
    var helpers: [Helper] = []

    /// Sta davvero lavorando (non solo ha una sessione aperta).
    var isWorking: Bool { live && [.thinking, .reading, .writing, .running, .searching, .working].contains(mood) }
}

extension IslandModel {
    static let hubWidth: CGFloat = 860
    static let hubHeight: CGFloat = 560

    /// Un Dott per progetto, in ordine fisso (alfabetico, il libero in fondo): le schede non saltano mai.
    var hubDotts: [HubDott] {
        var items: [(key: String, project: String)] = ProjectResolver.shared.groups().map { ($0.key, $0.name) }
        let free = DottRoster.freeKey
        items.append((free, "Chat libere"))
        // Senza gruppi (o per sessioni di cartelle che non ne hanno) restano i Dott delle cartelle.
        for d in dotts where AgentRegistry.role(forKey: d.id) == nil && !items.contains(where: { $0.key == d.id }) { items.append((d.id, d.name)) }
        let mine = AppSettings.shared.color
        return items.map { it in
            let d = dotts.first { $0.id == it.key }
            return HubDott(id: it.key, dottName: DottRoster.shared.name(for: it.key),
                           project: it.project,
                           color: d?.color ?? (AppSettings.shared.projectColors ? DottRoster.shared.color(for: it.key) : mine),
                           mood: d?.mood ?? .sleeping, detail: d?.detail ?? "", accessory: d?.accessory,
                           contextFraction: d?.contextFraction, agents: d?.agents ?? 0, live: d != nil,
                           days: DayLog.forDott(it.key).total, folder: folder(for: it.key),
                           role: DottRoster.shared.role(for: it.key), trait: DottRoster.shared.trait(for: it.key),
                           helpers: hubHelpers(it.key))
        }
    }

    /// Un Dott globale (il Manager o un agente specializzato): il suo stato e' quello della sua chat, se c'e'.
    func hubAgent(_ role: DottRole) -> HubDott {
        let k = role.agentKey
        let s = agentSession(role)
        return HubDott(id: k, dottName: DottRoster.shared.name(for: k), project: role == .manager ? "Tutti i progetti" : role.agentTitle,
                       color: AppSettings.shared.projectColors ? DottRoster.shared.color(for: k) : AppSettings.shared.color,
                       mood: s?.mood ?? .sleeping, detail: s?.detail ?? "", accessory: nil,
                       contextFraction: s?.contextFraction, agents: s?.agents.count ?? 0, live: s != nil,
                       days: DayLog.forDott(k).total, folder: folder(for: k), role: role, trait: DottRoster.shared.trait(for: k),
                       helpers: s.map { Array($0.agents.values) } ?? [])
    }

    var hubManager: HubDott { hubAgent(.manager) }

    /// Gli agenti specializzati: non appartengono a un progetto, ci sono e li dirige il Manager.
    var hubAgents: [HubDott] { DottRole.specialists.map(hubAgent) }

    /// Gli aiutanti (sottoagenti) al lavoro per un Dott, in tutte le sue sessioni.
    func hubHelpers(_ key: String) -> [Helper] {
        sessions.values.filter { Self.projectKey($0) == key }.flatMap { $0.agents.values }.sorted { $0.started < $1.started }
    }

    /// L'hub si apre sul Dott in primo piano.
    func openHub() {
        if hubWindowed { NotificationCenter.default.post(name: Notification.Name("dott.hubWindow.close"), object: nil) }
        // Il Manager e' l'interlocutore principale: l'hub si apre su di lui (se ha gia' una chat), altrimenti sul Dott in primo piano.
        if chatTarget(AgentRegistry.managerKey) != nil {
            hubSelected = AgentRegistry.managerKey
        } else if hubSelected == nil || !(hubDotts.contains(where: { $0.id == hubSelected }) || AgentRegistry.role(forKey: hubSelected ?? "") != nil) {
            hubSelected = lead.map(Self.projectKey) ?? hubDotts.first?.id
        }
        refreshManagerMessages(force: true)
        hubIdle = Date()
        hubOpen = true
        ProjectResolver.shared.refresh()
        AgentRegistry.shared.recover { [weak self] in self?.regroup() }
        recompute()
    }

    /// Riduci: l'hub torna a essere l'isola (e la finestra, se c'era, si chiude).
    func closeHub() {
        hubOpen = false
        if hubWindowed { NotificationCenter.default.post(name: Notification.Name("dott.hubWindow.close"), object: nil) }
        recompute()
    }

    /// Dall'isola alla finestra.
    func detachHub() {
        if hubSelected == nil { hubSelected = lead.map(Self.projectKey) ?? hubDotts.first?.id }
        hubOpen = false
        NotificationCenter.default.post(name: Notification.Name("dott.hubWindow.open"), object: nil)
        recompute()
    }

    /// Dalla finestra di nuovo nell'isola.
    func dockHub() {
        NotificationCenter.default.post(name: Notification.Name("dott.hubWindow.close"), object: nil)
        hubIdle = Date()
        hubOpen = true
        recompute()
    }
}

/// La finestra dell'hub: la stessa vista dell'isola, ma libera. Non e' un'app nel Dock: si chiude e si torna all'isola.
@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    static let shared = HubWindowController()
    private var window: NSWindow?
    private weak var model: IslandModel?

    func show(model: IslandModel) {
        self.model = model
        if window == nil {
            let host = NSHostingController(rootView: HubView(model: model, windowed: true, notchHeight: 0, notchWidth: 0))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 940, height: 640))
            w.minSize = NSSize(width: 780, height: 520)
            w.setFrameAutosaveName("DottHub2")
            w.delegate = self
            if !w.setFrameUsingName("DottHub") { w.center() }
            window = w
        }
        model.hubWindowed = true
        model.hubOpen = false
        model.recompute()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let model else { return }
        model.hubWindowed = false
        model.cancelCompose()
    }
}

// MARK: - La vista

/// L'hub: i Dott in griglia e, a destra, quello scelto. Poca roba: chi e', cosa fa, cosa ha fatto, le sue chat.
struct HubView: View {
    @ObservedObject var model: IslandModel
    let windowed: Bool
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    private var dotts: [HubDott] { model.hubDotts }
    private var manager: HubDott { model.hubManager }
    private var agents: [HubDott] { model.hubAgents }
    private var selected: HubDott? {
        if let k = model.hubSelected, AgentRegistry.role(forKey: k) != nil {
            return k == AgentRegistry.managerKey ? manager : agents.first { $0.id == k }
        }
        return dotts.first { $0.id == model.hubSelected } ?? dotts.first
    }

    var body: some View {
        ZStack {
            if windowed { background }
            VStack(spacing: 0) {
                topBar
                HStack(alignment: .top, spacing: 12) {
                    if selected?.id == manager.id {
                        sideList.frame(width: 232)
                        ManagerConversation(model: model, h: manager)
                    } else {
                        grid
                        if let h = selected { DetailPanel(model: model, h: h).frame(width: 340) }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var background: some View {
        LinearGradient(colors: [Color(red: 0.07, green: 0.10, blue: 0.22), Color(red: 0.03, green: 0.04, blue: 0.10), .black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    /// Nell'isola: la riga alta ai lati del notch. Nella finestra: il titolo, sotto i semafori.
    private var topBar: some View {
        let n = dotts.filter(\.isWorking).count
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                if windowed { Color.clear.frame(width: 62, height: 1) }   // semafori della finestra
                Text("I tuoi Dott").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Text(n == 0 ? "tutti a riposo" : "\(n) al lavoro").foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            HStack(spacing: 4) {
                if windowed {
                    barButton("arrow.down.right.and.arrow.up.left", "Riporta nell’isola") { model.dockHub() }
                } else {
                    barButton("arrow.up.left.and.arrow.down.right", "Apri in finestra") { model.detachHub() }
                    barButton("chevron.up", "Riduci") { model.closeHub() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 18)
        .frame(height: windowed ? 44 : notchHeight)
    }

    private func barButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    /// Con la conversazione del Manager aperta, i Dott stanno in una colonna stretta a sinistra.
    private var sideList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                ManagerCard(model: model, h: manager, isSelected: true, dotts: dotts, compact: true)
                sectionTitle("Agenti")
                ForEach(agents) { a in AgentCard(model: model, h: a, isSelected: false) }
                sectionTitle("Progetti")
                ForEach(dotts) { d in DottCard(model: model, h: d, isSelected: false) }
            }
            .padding(.vertical, 2)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.32))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14).padding(.bottom, 6).padding(.leading, 2)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ManagerCard(model: model, h: manager, isSelected: selected?.id == manager.id, dotts: dotts)
            sectionTitle("Agenti")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 300), spacing: 10)], spacing: 10) {
                ForEach(agents) { a in AgentCard(model: model, h: a, isSelected: a.id == selected?.id) }
            }
            sectionTitle("Progetti")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 300), spacing: 10)], spacing: 10) {
                ForEach(dotts) { h in
                    DottCard(model: model, h: h, isSelected: h.id == selected?.id)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Una scheda

struct DottCard: View {
    @ObservedObject var model: IslandModel
    let h: HubDott
    let isSelected: Bool

    var body: some View {
        Button { model.hubSelected = h.id } label: {
            HStack(spacing: 10) {
                MascotView(mood: h.mood, size: 46, effects: false, tint: (h.color.top, h.color.bottom),
                           accessory: h.accessory, outfit: model.outfit)
                    .frame(width: 54, height: 50)
                    .opacity(h.live ? 1 : 0.8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(h.dottName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        if h.role != .generic {
                            Image(systemName: h.role.symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(h.color.top.opacity(0.8))
                        }
                    }
                    Text(h.project).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    StatusPill(h: h, small: true)
                }
                Spacer(minLength: 0)
                if !h.helpers.isEmpty {
                    // Gli aiutanti accanto al Dott che lavora: un pallino ciascuno, del loro colore.
                    HStack(spacing: -4) {
                        ForEach(h.helpers.prefix(4)) { x in
                            Circle().fill(Palette.helper(x.colorIndex).top).frame(width: 11, height: 11)
                                .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(isSelected ? 0.10 : 0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? h.color.top.opacity(0.85) : .white.opacity(0.07), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// Un agente specializzato: una scheda piccola, senza progetto.
struct AgentCard: View {
    @ObservedObject var model: IslandModel
    let h: HubDott
    let isSelected: Bool

    var body: some View {
        Button { model.hubSelected = h.id } label: {
            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    MascotView(mood: h.mood, size: 36, effects: false, tint: (h.color.top, h.color.bottom), outfit: model.outfit)
                        .frame(width: 42, height: 40)
                        .opacity(h.live ? 1 : 0.8)
                    Image(systemName: h.role.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 14, height: 14).background(Circle().fill(h.color.top)).offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.project).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    Text(h.dottName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    StatusPill(h: h, small: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(isSelected ? 0.10 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? h.color.top.opacity(0.85) : .white.opacity(0.07), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// Il Manager di tutti i progetti: una scheda larga in cima, con il riassunto di cosa succede nei progetti.
struct ManagerCard: View {
    @ObservedObject var model: IslandModel
    let h: HubDott
    let isSelected: Bool
    let dotts: [HubDott]
    /// Nella colonna stretta accanto alla conversazione: solo il nome e lo stato.
    var compact = false

    private var working: Int { dotts.filter(\.isWorking).count }
    private var waiting: Int { dotts.filter { $0.live && $0.mood == .waiting }.count }

    var body: some View {
        Button { model.hubSelected = h.id } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    MascotView(mood: h.mood, size: 46, effects: false, tint: (h.color.top, h.color.bottom), outfit: model.outfit)
                        .frame(width: 54, height: 50)
                    Image(systemName: "crown.fill").font(.system(size: 10)).foregroundStyle(Palette.amber).offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(h.dottName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                        if !compact { Text("Manager").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amber.opacity(0.9)) }
                    }
                    if compact { StatusPill(h: h, small: true) }
                    else { Text(summary).font(.system(size: 11.5)).foregroundStyle(waiting > 0 ? Palette.amber : .white.opacity(0.55)).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if !compact { StatusPill(h: h, small: true) }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(isSelected ? 0.10 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Palette.amber.opacity(0.85) : .white.opacity(0.07), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    private var summary: String {
        if working == 0 && waiting == 0 { return "Nessun progetto al lavoro" }
        var parts: [String] = []
        if working > 0 { parts.append(working == 1 ? "1 progetto al lavoro" : "\(working) progetti al lavoro") }
        if waiting > 0 { parts.append(waiting == 1 ? "1 ti aspetta" : "\(waiting) ti aspettano") }
        return parts.joined(separator: " · ")
    }
}

struct StatusPill: View {
    let h: HubDott
    var small = false

    private var style: (String, Color) {
        if !h.live { return ("A riposo", .white.opacity(0.35)) }
        switch h.mood {
        case .waiting: return ("Ti aspetta", Palette.amber)
        case .hurt: return ("Problema", Palette.coral)
        case .happy: return ("Ha finito", Color(red: 0.45, green: 0.90, blue: 0.60))
        case .sleeping: return ("In attesa", .white.opacity(0.35))
        default: return ("Al lavoro", Color(red: 0.35, green: 0.88, blue: 0.55))
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(style.1).frame(width: small ? 6 : 7, height: small ? 6 : 7)
            Text(style.0)
        }
        .font(.system(size: small ? 10.5 : 11, weight: .medium))
        .foregroundStyle(style.1 == .white.opacity(0.35) ? .white.opacity(0.5) : style.1)
    }
}

struct ActivityRow: View {
    let item: ActivityItem

    private var color: Color {
        switch item.tone {
        case "ok": return Color(red: 0.40, green: 0.90, blue: 0.60)
        case "warn": return Palette.amber
        case "bad": return Palette.coral
        default: return Color(red: 0.45, green: 0.78, blue: 1.0)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: item.symbol).font(.system(size: 10.5)).foregroundStyle(color)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(HubTime.ago(item.at)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.vertical, 4)
    }
}

enum HubTime {
    static func ago(_ d: Date) -> String {
        guard d > .distantPast else { return "" }
        if Date().timeIntervalSince(d) < 15 { return "adesso" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Il Dott scelto

struct DetailPanel: View {
    @ObservedObject var model: IslandModel
    let h: HubDott
    private var isManager: Bool { h.id == AgentRegistry.managerKey }
    /// Il Manager o un agente specializzato (non appartengono a un progetto).
    private var isGlobal: Bool { AgentRegistry.role(forKey: h.id) != nil }

    /// Chi riceve la richiesta sta lavorando? Allora si puo' interromperlo.
    private var targetWorking: Bool {
        guard let s = model.targetSession(h.id) else { return false }
        return [.thinking, .reading, .writing, .running, .searching, .working].contains(s.mood)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    now
                    if targetWorking { interruptButton }
                    if !isManager && h.folder != nil && model.chatTarget(h.id) != nil { reportButton }
                    if isManager { overview }
                    if h.role.isAgent { agentNote }
                    helpersSection
                    if !isManager { lastDone }
                    if !isGlobal { chats }
                }
                .padding(16)
            }
            if h.folder != nil {
                AskRow(model: model, key: h.id).id(h.id)
                    .padding(.horizontal, -4).padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(RadialGradient(colors: [h.color.top.opacity(0.35), .clear], center: .center, startRadius: 4, endRadius: 64))
                    .frame(width: 120, height: 110)
                MascotView(mood: h.mood, size: 78, effects: true, tint: (h.color.top, h.color.bottom),
                           accessory: h.accessory, outfit: model.outfit)
            }
            .frame(width: 100, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                StatusPill(h: h)
                Text(h.dottName).font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(h.project).font(.system(size: 13)).foregroundStyle(h.color.top)
                if h.role != .generic || h.trait != nil {
                    HStack(spacing: 5) {
                        if h.role != .generic { Image(systemName: h.role.symbol).font(.system(size: 10)) }
                        Text([h.role == .generic ? nil : h.role.label, h.trait?.label].compactMap { $0 }.joined(separator: " · "))
                    }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Text(h.days == 0 ? "Appena arrivato" : (h.days == 1 ? "1 giorno insieme" : "\(h.days) giorni insieme"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
    }

    /// Cosa sta facendo adesso, in una riga.
    @ViewBuilder private var now: some View {
        if h.live {
            Text(h.detail.isEmpty ? h.mood.title : h.detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(h.mood == .waiting ? Palette.amber : .white.opacity(0.88))
                .lineLimit(2)
        } else if h.folder == nil {
            Text("Non so in quale cartella lavora: scegli la cartella dalle Impostazioni.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
    }

    /// Il Manager vede tutti i progetti e tutti gli agenti: chi lavora, chi aspetta, chi riposa.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.rescanManager() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 11))
                    Text("Cerca compiti nell’ultima risposta")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: .white))
            .help("Rilegge l’ultima risposta del Manager e mostra i compiti da affidare")
            .padding(.bottom, 6)
            section("Agenti")
            ForEach(model.hubAgents) { a in
                Button { model.hubSelected = a.id } label: {
                    HStack(spacing: 8) {
                        Image(systemName: a.role.symbol).font(.system(size: 11)).foregroundStyle(a.color.top).frame(width: 22)
                        Text(a.project).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        Text(a.dottName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        Spacer(minLength: 6)
                        StatusPill(h: a, small: true)
                    }
                    .frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            section("Progetti").padding(.top, 8)
            ForEach(model.hubDotts) { d in
                Button { model.hubSelected = d.id } label: {
                    HStack(spacing: 8) {
                        MascotView(mood: d.mood, size: 22, effects: false, tint: (d.color.top, d.color.bottom), outfit: model.outfit)
                            .frame(width: 26, height: 24)
                        Text(d.project).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Text(d.dottName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        Spacer(minLength: 6)
                        StatusPill(h: d, small: true)
                    }
                    .frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
    }

    /// Un agente non appartiene a un progetto: gli strumenti che di solito usa e chi lo dirige.
    private var agentNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = h.role.tools {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 10))
                    Text(t)
                }
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            Text("Non appartiene a nessun progetto: lo dirige il Manager, che gli dice cosa fare e dove.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
    }

    /// Riporta al Manager l'ultima risposta di questo Dott (capo progetto o agente).
    private var reportButton: some View {
        Button { model.reportToManager(from: h.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.left.circle").font(.system(size: 12))
                Text("Riporta al Manager l’ultima risposta")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: .white))
        .help("Manda la sua ultima risposta nella chat del Manager")
        .disabled(model.chatTarget(AgentRegistry.managerKey) == nil || model.chatTarget(h.id) == nil)
    }

    /// Ferma il lavoro: apre la chat e preme Esc nel suo campo.
    private var interruptButton: some View {
        Button { model.interrupt(h.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.circle").font(.system(size: 12))
                Text("Interrompi")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(IslandButton(fill: .white.opacity(0.12), text: .white))
        .help("Porta la chat in primo piano e preme Esc")
    }

    /// Gli aiutanti che stanno lavorando insieme a lui.
    @ViewBuilder private var helpersSection: some View {
        if !h.helpers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                section("Aiutanti")
                ForEach(h.helpers.prefix(4)) { x in
                    HStack(spacing: 8) {
                        Circle().fill(Palette.helper(x.colorIndex).top).frame(width: 9, height: 9)
                        Text(x.type).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                        Text(x.activity.isEmpty ? x.task : x.activity)
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if h.helpers.count > 4 {
                    Text("+\(h.helpers.count - 4) altri").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    /// L'ultima cosa fatta (al massimo due voci).
    @ViewBuilder private var lastDone: some View {
        let items = model.activity(for: h.id, limit: 2)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                section("Ultime cose")
                ForEach(items) { ActivityRow(item: $0) }
            }
        }
    }

    @ViewBuilder private var chats: some View {
        let items = ProjectResolver.shared.chats(for: h.id, limit: 5)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                section("Chat")
                ForEach(items) { c in
                    Button { model.openChat(c.id, in: h.id) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(dot(c.id) ?? .white.opacity(0.15)).frame(width: 6, height: 6)
                            Text(c.title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(HubTime.ago(c.activity)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                        }
                        .frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help("Apri questa chat nell’app Claude")
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.32))
            .padding(.bottom, 3)
    }

    /// Il pallino di una chat: acceso se la sua sessione sta lavorando o aspetta te.
    private func dot(_ sid: String) -> Color? {
        guard let s = model.sessions[sid], s.mood != .sleeping else { return nil }
        return s.mood == .waiting ? Palette.amber : Palette.lime
    }
}
