import Foundation

/// La memoria dei giorni passati insieme: un giorno conta quando hai lavorato con Dott.
/// Serve per i saluti speciali (una settimana insieme, cinque giorni di fila…).
final class DayLog {
    /// Il registro generale (tutti i progetti insieme).
    static let shared = DayLog(key: "dott.days")
    nonisolated(unsafe) private static var perDott: [String: DayLog] = [:]
    /// Il registro di un Dott: i giorni passati insieme a lui, sul suo progetto.
    static func forDott(_ key: String) -> DayLog {
        if let l = perDott[key] { return l }
        let l = DayLog(key: "dott.days." + key)
        perDott[key] = l
        return l
    }

    private let key: String
    private var days: [String]   // "yyyy-MM-dd", ordinati

    private init(key: String) {
        self.key = key
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
        if AppSettings.shared.persist { UserDefaults.standard.set(days, forKey: key) }

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
