import AppKit
import DottKit
import SwiftUI

/// Il colore di Dott per le superfici di Studio: fisso, cosi' la finestra non cambia col progetto in primo piano.
enum Brand {
    static let accent = Color(red: 0.78, green: 0.95, blue: 0.21)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.14)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.36)
    static let sky = Color(red: 0.45, green: 0.80, blue: 1.00)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.09)
}

enum StudioSection: String, CaseIterable, Identifiable {
    case today, ledger, memory, health, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Oggi"
        case .ledger: "Registro"
        case .memory: "Memoria"
        case .health: "Salute"
        case .data: "Dati e privacy"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .ledger: "chart.bar.xaxis"
        case .memory: "brain.head.profile"
        case .health: "heart.text.square.fill"
        case .data: "lock.shield.fill"
        }
    }
}

@MainActor
final class StudioState: ObservableObject {
    static let shared = StudioState()
    @Published var section: StudioSection = .today
}

@MainActor
final class StudioWindowController {
    static let shared = StudioWindowController()
    private var window: NSWindow?

    func show(model: IslandModel, section: StudioSection? = nil) {
        if let section { StudioState.shared.section = section }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: StudioRoot(model: model)))
            w.title = "Dott Studio"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.setContentSize(NSSize(width: 1000, height: 680))
            w.minSize = NSSize(width: 860, height: 560)
            w.isReleasedWhenClosed = false
            if !w.setFrameAutosaveName("DottStudio") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct StudioRoot: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var state = StudioState.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<StudioSection?>(get: { state.section }, set: { state.section = $0 ?? .today })) {
                ForEach(StudioSection.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .safeAreaInset(edge: .top, spacing: 0) { header }
        } detail: {
            Group {
                switch state.section {
                case .today: StudioToday()
                case .ledger: StudioLedger()
                case .memory: StudioMemory(model: model)
                case .health: StudioHealth(model: model)
                case .data: StudioData()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.07, green: 0.075, blue: 0.065))
        }
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MascotView(mood: model.lead?.mood ?? .sleeping, size: 34, effects: false,
                       tint: (DottColor.lime.top, DottColor.lime.bottom), outfit: model.outfit)
                .frame(width: 40, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text("Dott Studio").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(model.lead.map { "\($0.project) · \($0.mood.title)" } ?? "A riposo")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 10)
    }
}

// MARK: - Pezzi in comune

struct StudioPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
                }
                content
            }
            .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.stroke, lineWidth: 1))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var tint: Color = .white

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        Card(padding: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum Compact {
    /// 1.234 → "1,2 k", 2.500.000 → "2,5 M"
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1f k", d / 1_000).replacingOccurrences(of: ".", with: ",")
        default: return String(format: "%.2f M", d / 1_000_000).replacingOccurrences(of: ".", with: ",")
        }
    }

    static func dollars(_ v: Double) -> String {
        String(format: "$%.2f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func day(_ stamp: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: stamp)
    }
}
