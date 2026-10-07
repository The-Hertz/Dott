import SwiftUI
import Combine

/// I colori che si possono dare a Dott.
enum DottColor: String, CaseIterable, Identifiable {
    case lime, cielo, viola, rosa, menta, arancio, bianco

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lime: "Lime"
        case .cielo: "Cielo"
        case .viola: "Viola"
        case .rosa: "Rosa"
        case .menta: "Menta"
        case .arancio: "Arancio"
        case .bianco: "Bianco"
        }
    }

    var top: Color {
        switch self {
        case .lime: Color(red: 0.78, green: 0.95, blue: 0.21)
        case .cielo: Color(red: 0.45, green: 0.80, blue: 1.00)
        case .viola: Color(red: 0.74, green: 0.60, blue: 1.00)
        case .rosa: Color(red: 1.00, green: 0.58, blue: 0.80)
        case .menta: Color(red: 0.35, green: 0.92, blue: 0.80)
        case .arancio: Color(red: 1.00, green: 0.78, blue: 0.45)
        case .bianco: Color(red: 0.97, green: 0.97, blue: 0.97)
        }
    }

    var bottom: Color {
        switch self {
        case .lime: Color(red: 0.62, green: 0.82, blue: 0.10)
        case .cielo: Color(red: 0.20, green: 0.55, blue: 0.95)
        case .viola: Color(red: 0.52, green: 0.36, blue: 0.92)
        case .rosa: Color(red: 0.92, green: 0.30, blue: 0.62)
        case .menta: Color(red: 0.10, green: 0.68, blue: 0.62)
        case .arancio: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .bianco: Color(red: 0.76, green: 0.77, blue: 0.80)
        }
    }

    /// I colori degli aiutanti: tutti tranne quello di Dott.
    static let helperOrder: [DottColor] = [.cielo, .viola, .rosa, .menta, .arancio, .lime]
}

enum DottShape: String, CaseIterable, Identifiable {
    case blob, tondo, quadro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blob: "Morbido"
        case .tondo: "Tondo"
        case .quadro: "Squadrato"
        }
    }
}

/// Su quali schermi mostrare l'isola.
enum DisplayMode: String, CaseIterable, Identifiable {
    case external   // sul monitor esterno se c'e', altrimenti sul Mac (predefinito)
    case primary    // sempre sullo schermo del Mac
    case follow     // lo schermo dove sta il cursore
    case all        // tutti

    var id: String { rawValue }
    var label: String {
        switch self {
        case .external: "Sul monitor se collegato, altrimenti sul Mac"
        case .primary: "Sempre sul Mac"
        case .follow: "Lo schermo dove sta il cursore"
        case .all: "Tutti gli schermi"
        }
    }
}

/// Oggetti legati a quello che sta facendo.
enum Accessory: CaseIterable {
    case glasses    // legge, cerca
    case pencil     // scrive
    case headphones // una build o un test lunghi
    case helmet     // comandi delicati
    case broom      // sta comprimendo la memoria: spazza via il superfluo
}

/// Vestiti di stagione.
enum Outfit: CaseIterable {
    case santa, scarf, witch, party
}

/// Comandi che meritano un casco.
enum Risk {
    static func isRisky(_ command: String) -> Bool {
        let c = command.lowercased()
        let patterns = [#"\brm\s+(-[a-z]*r|-[a-z]*f)"#, #"\bsudo\b"#, #"--force\b"#, #"push\s+(-f\b|.*--force)"#,
                        #"reset\s+--hard"#, #"\|\s*(sh|bash|zsh)\b"#, #"\bmkfs\b"#, #"\bdd\s+if="#,
                        #"chmod\s+-r"#, #"drop\s+(table|database)"#, #"git\s+clean\s+-[a-z]*f"#]
        return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Le scelte dell'utente, salvate fra un avvio e l'altro.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    /// Nelle prove (istantanee) niente deve finire nelle preferenze vere.
    var persist = true
    private func save(_ value: Any, _ key: String) { if persist { d.set(value, forKey: key) } }

    @Published var name: String { didSet { save(name, "dott.name") } }
    @Published var color: DottColor { didSet { save(color.rawValue, "dott.color") } }
    /// Ogni progetto ha il suo colore (se spento, tutti i Dott hanno il colore scelto qui).
    @Published var projectColors: Bool { didSet { save(projectColors, "dott.projectColors") } }
    @Published var shape: DottShape { didSet { save(shape.rawValue, "dott.shape") } }
    @Published var antenna: Bool { didSet { save(antenna, "dott.antenna") } }
    @Published var accessories: Bool { didSet { save(accessories, "dott.accessories") } }
    @Published var seasonal: Bool { didSet { save(seasonal, "dott.seasonal") } }
    @Published var birthdayEnabled: Bool { didSet { save(birthdayEnabled, "dott.birthdayEnabled") } }
    // Conferme dal notch (spente di default: cambiano quando Claude Code ti interpella).
    @Published var confirmModelSwitch: Bool { didSet { save(confirmModelSwitch, "dott.confirmModel") } }
    @Published var watchConfig: Bool { didSet { save(watchConfig, "dott.watchConfig") } }
    // Extra
    @Published var danceToMusic: Bool { didSet { save(danceToMusic, "dott.dance") } }
    @Published var showGitHub: Bool { didSet { save(showGitHub, "dott.github") } }
    @Published var globalShortcuts: Bool { didSet { save(globalShortcuts, "dott.shortcuts") } }
    @Published var desktopCompanion: Bool { didSet { save(desktopCompanion, "dott.desktop") } }
    @Published var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "dott.displayMode") } }
    @Published var birthday: Date { didSet { save(birthday.timeIntervalSince1970, "dott.birthday") } }

    private init() {
        name = d.string(forKey: "dott.name") ?? "Dott"
        color = DottColor(rawValue: d.string(forKey: "dott.color") ?? "") ?? .lime
        projectColors = d.object(forKey: "dott.projectColors") as? Bool ?? true
        shape = DottShape(rawValue: d.string(forKey: "dott.shape") ?? "") ?? .blob
        antenna = d.object(forKey: "dott.antenna") as? Bool ?? true
        accessories = d.object(forKey: "dott.accessories") as? Bool ?? true
        seasonal = d.object(forKey: "dott.seasonal") as? Bool ?? true
        birthdayEnabled = d.object(forKey: "dott.birthdayEnabled") as? Bool ?? false
        confirmModelSwitch = d.object(forKey: "dott.confirmModel") as? Bool ?? false
        watchConfig = d.object(forKey: "dott.watchConfig") as? Bool ?? false
        danceToMusic = d.object(forKey: "dott.dance") as? Bool ?? true
        showGitHub = d.object(forKey: "dott.github") as? Bool ?? true
        globalShortcuts = d.object(forKey: "dott.shortcuts") as? Bool ?? true
        desktopCompanion = d.object(forKey: "dott.desktop") as? Bool ?? true
        displayMode = DisplayMode(rawValue: d.string(forKey: "dott.displayMode") ?? "") ?? .external
        let t = d.double(forKey: "dott.birthday")
        birthday = t > 0 ? Date(timeIntervalSince1970: t) : Date()
    }

    /// Cosa indossa oggi.
    func outfit(on date: Date) -> Set<Outfit> {
        guard seasonal else { return [] }
        let cal = Calendar.current
        let m = cal.component(.month, from: date), day = cal.component(.day, from: date)
        var out = Set<Outfit>()
        if (m == 12 && day >= 15) || (m == 1 && day <= 6) { out.insert(.santa) }
        if (m == 11 && day >= 20) || m == 12 || m == 1 || m == 2 || (m == 3 && day <= 10) { out.insert(.scarf) }
        if m == 10 && day >= 24 { out.insert(.witch) }
        if birthdayEnabled, cal.component(.month, from: birthday) == m, cal.component(.day, from: birthday) == day { out.insert(.party) }
        return out
    }
}
