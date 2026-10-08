import Foundation

/// Chi sono i Dott. Uno per progetto (gruppo dell'app Claude), con un'identita' che non cambia: nome proprio,
/// colore, data in cui e' arrivato. Le chat senza gruppo le segue un solo "Dott libero", che e' quello delle impostazioni.
struct DottIdentity: Codable, Equatable {
    var key: String
    var name: String
    var color: String
    var born: Date
    /// Il ruolo (cosa fa di solito) e il carattere (come parla): facoltativi, si scelgono nelle Impostazioni.
    var role: String?
    var trait: String?
}

/// Cosa fa un Dott. Per ora e' un'etichetta che dice a colpo d'occhio a cosa serve; in futuro puo' guidare strumenti e permessi.
enum DottRole: String, CaseIterable, Identifiable {
    case generic, coding, design, research, writing, automation, manager
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manager: "Manager"
        case .generic: "Tuttofare"
        case .coding: "Coding"
        case .design: "Design"
        case .research: "Ricerca"
        case .writing: "Scrittura"
        case .automation: "Automazione"
        }
    }
    var symbol: String {
        switch self {
        case .manager: "crown.fill"
        case .generic: "sparkles"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .design: "paintbrush.pointed.fill"
        case .research: "magnifyingglass"
        case .writing: "text.alignleft"
        case .automation: "bolt.fill"
        }
    }
}

/// Come parla un Dott: cambia le frasi con cui dice che ha finito, che ti aspetta, che qualcosa e' andato storto.
enum DottTrait: String, CaseIterable, Identifiable {
    case calm, sharp, curious, lively
    var id: String { rawValue }
    var label: String {
        switch self {
        case .calm: "Pacato"
        case .sharp: "Preciso"
        case .curious: "Curioso"
        case .lively: "Vivace"
        }
    }
    var finished: String {
        switch self {
        case .calm: "Fatto, con calma."
        case .sharp: "Fatto."
        case .curious: "Fatto! Che bello."
        case .lively: "Fatto, evviva!"
        }
    }
    var waiting: String {
        switch self {
        case .calm: "Quando puoi, ho bisogno di te"
        case .sharp: "Serve il tuo ok"
        case .curious: "Ho una domanda per te"
        case .lively: "Ehi, guarda qui!"
        }
    }
    var hurt: String {
        switch self {
        case .calm: "Ho trovato un intoppo"
        case .sharp: "Errore: serve un'occhiata"
        case .curious: "Uh, non me l'aspettavo"
        case .lively: "Ahia, è andata storta"
        }
    }
}

/// Il carattere del Dott in primo piano: lo imposta il modello (come il nome e il colore).
enum DottVoice {
    nonisolated(unsafe) static var override: DottTrait?
}

/// Il nome con cui parla il Dott in primo piano ("Fava dorme"): come `Palette.override`, lo imposta il modello.
enum DottName {
    nonisolated(unsafe) static var override: String?
    static var current: String { override ?? AppSettings.shared.name }
}

@MainActor
final class DottRoster: ObservableObject {
    static let shared = DottRoster()
    /// La chiave del Dott libero: tutte le sessioni che non appartengono a un gruppo.
    static let freeKey = "free"

    @Published private(set) var map: [String: DottIdentity]
    var onChange: (() -> Void)?
    private let storeKey = "dott.roster"
    private let seededKey = "dott.roster.seeded"

    /// Nomi di partenza: brevi e buffi. Il nome si sceglie dall'id del progetto, cosi' resta lo stesso anche se sposti le cartelle.
    static let names = ["Briciola", "Fiocco", "Nocciola", "Gelso", "Ciuffo", "Pepe", "Birba", "Mela", "Zucchero", "Cannella",
                        "Pistacchio", "Cometa", "Fava", "Girasole", "Lampo", "Mirtillo", "Nuvola", "Pallino", "Rondine",
                        "Tulipano", "Biscotto", "Ghiro", "Ciliegia", "Tartufo", "Menta", "Cicala", "Pomo", "Fragola"]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let m = try? JSONDecoder().decode([String: DottIdentity].self, from: data) {
            map = m
        } else {
            map = [:]
        }
    }

    // MARK: Interrogazioni

    /// L'identita' di un Dott; se non esiste ancora, nasce adesso.
    func identity(for key: String) -> DottIdentity {
        if key == Self.freeKey {
            return DottIdentity(key: key, name: AppSettings.shared.name.isEmpty ? "Dott" : AppSettings.shared.name,
                                color: AppSettings.shared.color.rawValue, born: map[key]?.born ?? Date(),
                                role: map[key]?.role, trait: map[key]?.trait)
        }
        if let i = map[key] { return i }
        let i = make(key)
        map[key] = i
        save()
        return i
    }

    func color(for key: String) -> DottColor {
        DottColor(rawValue: identity(for: key).color) ?? AppSettings.shared.color
    }

    func name(for key: String) -> String { identity(for: key).name }

    func role(for key: String) -> DottRole {
        if let r = AgentRegistry.role(forKey: key) { return r }
        return identity(for: key).role.flatMap(DottRole.init(rawValue:)) ?? .generic
    }

    func trait(for key: String) -> DottTrait? { identity(for: key).trait.flatMap(DottTrait.init(rawValue:)) }

    func setRole(_ key: String, _ role: DottRole) {
        var i = map[key] ?? identity(for: key)
        i.role = role == .generic ? nil : role.rawValue
        map[key] = i
        save()
        objectWillChange.send()
        onChange?()
    }

    func setTrait(_ key: String, _ trait: DottTrait?) {
        var i = map[key] ?? identity(for: key)
        i.trait = trait?.rawValue
        map[key] = i
        save()
        objectWillChange.send()
        onChange?()
    }

    // MARK: Modifiche

    func rename(_ key: String, to name: String) {
        if key == Self.freeKey { AppSettings.shared.name = String(name.prefix(14)); onChange?(); return }
        var i = identity(for: key)
        i.name = String(name.prefix(14))
        map[key] = i
        save()
        onChange?()
    }

    func recolor(_ key: String, to color: DottColor) {
        if key == Self.freeKey { AppSettings.shared.color = color; onChange?(); return }
        var i = identity(for: key)
        i.color = color.rawValue
        map[key] = i
        save()
        onChange?()
    }

    /// Un progetto nuovo (gruppo appena creato) ha il suo Dott. La prima volta si registrano in silenzio quelli che
    /// ci sono gia'; da li' in poi, i nuovi vengono restituiti per dare il benvenuto.
    func ensure(groups keys: [String]) -> [DottIdentity] {
        let seeded = UserDefaults.standard.bool(forKey: seededKey)
        var created: [DottIdentity] = []
        for k in keys where map[k] == nil {
            let i = make(k)
            map[k] = i
            created.append(i)
        }
        if !created.isEmpty { save() }
        if !seeded, !keys.isEmpty, AppSettings.shared.persist { UserDefaults.standard.set(true, forKey: seededKey) }
        return seeded ? created : []
    }

    // MARK: Nascita di un Dott

    private func make(_ key: String) -> DottIdentity {
        let h = Self.hash(key)
        let usedNames = Set(map.values.map(\.name)).union([AppSettings.shared.name])
        let name = (0..<Self.names.count).map { Self.names[(h + $0) % Self.names.count] }.first { !usedNames.contains($0) }
            ?? Self.names[h % Self.names.count]
        // Il colore di partenza evita quello del Dott libero e quelli gia' presi.
        let order = (DottColor.helperOrder + DottColor.allCases).reduce(into: [DottColor]()) { if !$0.contains($1) { $0.append($1) } }
            .filter { $0 != AppSettings.shared.color }
        let usedColors = Set(map.values.map(\.color))
        let pool = order.isEmpty ? DottColor.allCases : order
        let color = (0..<pool.count).map { pool[(h / 7 + $0) % pool.count] }.first { !usedColors.contains($0.rawValue) }
            ?? pool[(h / 7) % pool.count]
        return DottIdentity(key: key, name: name, color: color.rawValue, born: Date(), role: nil, trait: nil)
    }

    /// FNV-1a: stabile fra un avvio e l'altro (il `hashValue` di Swift cambia a ogni lancio).
    private static func hash(_ s: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(h % 1_000_003)
    }

    private func save() {
        guard AppSettings.shared.persist, let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
