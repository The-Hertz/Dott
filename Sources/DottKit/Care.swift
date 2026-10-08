import Foundation

/// Un invito gentile di Dott. Mai piu' di uno alla volta e mai ripetuto in fretta.
public enum CareNudge: Equatable, Sendable {
    /// Lavori da tanto senza fermarti.
    case longStretch(minutes: Int)
    /// E' notte fonda e stai ancora lavorando.
    case lateNight

    public var key: String {
        switch self {
        case .longStretch: "longStretch"
        case .lateNight: "lateNight"
        }
    }

    public var title: String {
        switch self {
        case .longStretch: "Una pausa?"
        case .lateNight: "E' tardi"
        }
    }

    public var message: String {
        switch self {
        case .longStretch(let m):
            let t = m >= 120 ? "\(m / 60) ore" : "\(m) minuti"
            return "Sono \(t) che lavori senza fermarti. Alzati un attimo: il lavoro ti aspetta."
        case .lateNight:
            return "Sono le ore piccole. Se non e' urgente, domani lo vedrai con occhi nuovi."
        }
    }
}

/// Decide quando e' il momento di dire qualcosa. Non guarda l'orologio da solo: riceve l'ora, cosi' si prova.
public struct RhythmEngine: Sendable {
    /// Dopo quanto lavoro continuo suggerire una pausa.
    public var longStretch: TimeInterval = 90 * 60
    /// Un vuoto piu' lungo di cosi' conta come pausa.
    public var breakGap: TimeInterval = 10 * 60
    /// Dopo un invito, per quanto tempo restare zitti.
    public var cooldown: TimeInterval = 75 * 60
    /// La "notte" va da `nightStart` (compreso) a `nightEnd` (escluso), in ore.
    public var nightStart = 0
    public var nightEnd = 5
    public var calendar: Calendar

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// `activity`: gli istanti degli ultimi eventi, in ordine. `lastNudges`: quando e' stato mandato l'ultimo invito di ogni tipo.
    public func evaluate(now: Date, activity: [Date], lastNudges: [String: Date]) -> CareNudge? {
        guard let last = activity.last, now.timeIntervalSince(last) <= breakGap else { return nil }

        // L'inizio del lavoro continuo: si torna indietro finche' fra un evento e l'altro non c'e' una pausa.
        var start = last
        for t in activity.reversed() {
            if start.timeIntervalSince(t) > breakGap { break }
            start = min(start, t)
        }

        let hour = calendar.component(.hour, from: now)
        let night = nightStart <= nightEnd ? (hour >= nightStart && hour < nightEnd) : (hour >= nightStart || hour < nightEnd)
        if night, quiet(.lateNight, lastNudges, now) { return .lateNight }

        let worked = now.timeIntervalSince(start)
        if worked >= longStretch, quiet(.longStretch(minutes: 0), lastNudges, now) {
            return .longStretch(minutes: Int(worked / 60 / 5) * 5)
        }
        return nil
    }

    private func quiet(_ nudge: CareNudge, _ last: [String: Date], _ now: Date) -> Bool {
        guard let t = last[nudge.key] else { return true }
        return now.timeIntervalSince(t) >= cooldown
    }
}
