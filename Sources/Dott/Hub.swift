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

    /// Sta davvero lavorando (non solo ha una sessione aperta).
    var isWorking: Bool { live && [.thinking, .reading, .writing, .running, .searching, .working].contains(mood) }
}

extension IslandModel {
    static let hubWidth: CGFloat = 780
    static let hubHeight: CGFloat = 480

    /// Un Dott per progetto, in ordine fisso (alfabetico, il libero in fondo): le schede non saltano mai.
    var hubDotts: [HubDott] {
        var items: [(key: String, project: String)] = ProjectResolver.shared.groups().map { ($0.key, $0.name) }
        let free = DottRoster.freeKey
        items.append((free, "Chat libere"))
        // Senza gruppi (o per sessioni di cartelle che non ne hanno) restano i Dott delle cartelle.
        for d in dotts where !items.contains(where: { $0.key == d.id }) { items.append((d.id, d.name)) }
        let mine = AppSettings.shared.color
        return items.map { it in
            let d = dotts.first { $0.id == it.key }
            return HubDott(id: it.key, dottName: DottRoster.shared.name(for: it.key),
                           project: it.project,
                           color: d?.color ?? (AppSettings.shared.projectColors ? DottRoster.shared.color(for: it.key) : mine),
                           mood: d?.mood ?? .sleeping, detail: d?.detail ?? "", accessory: d?.accessory,
                           contextFraction: d?.contextFraction, agents: d?.agents ?? 0, live: d != nil,
                           days: DayLog.forDott(it.key).total, folder: folder(for: it.key))
        }
    }

    /// L'hub si apre sul Dott in primo piano.
    func openHub() {
        if hubWindowed { NotificationCenter.default.post(name: Notification.Name("dott.hubWindow.close"), object: nil) }
        if hubSelected == nil || !hubDotts.contains(where: { $0.id == hubSelected }) {
            hubSelected = lead.map(Self.projectKey) ?? hubDotts.first?.id
        }
        hubIdle = Date()
        hubOpen = true
        ProjectResolver.shared.refresh()
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
    private var selected: HubDott? { dotts.first { $0.id == model.hubSelected } ?? dotts.first }

    var body: some View {
        ZStack {
            if windowed { background }
            VStack(spacing: 0) {
                topBar
                HStack(alignment: .top, spacing: 12) {
                    grid
                    if let h = selected { DetailPanel(model: model, h: h).frame(width: 340) }
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

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 10)], spacing: 10) {
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
                    Text(h.dottName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(h.project).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    StatusPill(h: h, small: true)
                }
                Spacer(minLength: 0)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    now
                    lastDone
                    chats
                }
                .padding(16)
            }
            if h.folder != nil {
                AskRow(model: model, key: h.id).padding(.horizontal, -4).padding(.bottom, 6)
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
