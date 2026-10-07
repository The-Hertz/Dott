import Foundation

/// La memoria dei giorni passati insieme: un giorno conta quando hai lavorato con Dott.
/// Serve per i saluti speciali (una settimana insieme, cinque giorni di fila…).
final class DayLog {
    static let shared = DayLog()
    private let key = "dott.days"
    private var days: [String]   // "yyyy-MM-dd", ordinati

    private init() {
        days = (UserDefaults.standard.stringArray(forKey: key) ?? []).sorted()
    }

    private static func stamp(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var total: Int { days.count }

    /// Giorni di fila che finiscono oggi (o l'ultimo giorno registrato).
    var streak: Int {
        var n = 0
        var day = Date()
        let set = Set(days)
        while set.contains(Self.stamp(day)) {
            n += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    /// Registra oggi. Se e' il primo evento della giornata e cade una ricorrenza, la restituisce.
    func touch(_ date: Date, name: String) -> (title: String, detail: String)? {
        let today = Self.stamp(date)
        guard !days.contains(today) else { return nil }
        days.append(today)
        days = Array(days.sorted().suffix(800))
        UserDefaults.standard.set(days, forKey: key)

        let total = days.count
        switch total {
        case 7: return ("Una settimana insieme!", "Sette giorni di lavoro con \(name)")
        case 30: return ("Un mese insieme!", "Trenta giorni di lavoro: che squadra")
        case 100: return ("Cento giorni!", "Cento giorni insieme, \(name) è commosso")
        case 365: return ("Un anno insieme!", "Trecentosessantacinque giorni di lavoro")
        default: break
        }
        let s = streak
        if s == 5 { return ("Cinque giorni di fila!", "Non ti fermi più") }
        if s == 10 { return ("Dieci giorni di fila!", "Che costanza") }
        return nil
    }
}

/// Il colore di ogni progetto: lo si assegna la prima volta e poi resta quello (tra un avvio e l'altro).
/// Fra i progetti attivi due Dott non hanno mai lo stesso colore.
final class ProjectColors {
    static let shared = ProjectColors()
    private let key = "dott.projectColors.map"
    private var map: [String: String]

    private init() {
        map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Dal primo progetto (il piu' vecchio fra gli attivi) in poi. Il primo ha il colore scelto nelle impostazioni.
    func resolve(keys: [String]) -> [String: DottColor] {
        let mine = AppSettings.shared.color
        guard AppSettings.shared.projectColors else { return Dictionary(uniqueKeysWithValues: keys.map { ($0, mine) }) }
        let order = [mine] + DottColor.helperOrder.filter { $0 != mine }
        var used = Set<DottColor>()
        var out: [String: DottColor] = [:]
        var changed = false
        for k in keys {
            var c = map[k].flatMap(DottColor.init(rawValue:))
            if c == nil || used.contains(c!) {
                c = order.first(where: { !used.contains($0) }) ?? order[0]
                map[k] = c!.rawValue
                changed = true
            }
            used.insert(c!)
            out[k] = c!
        }
        if changed, AppSettings.shared.persist {
            if map.count > 60 { map = map.filter { out[$0.key] != nil } }
            UserDefaults.standard.set(map, forKey: key)
        }
        return out
    }
}
