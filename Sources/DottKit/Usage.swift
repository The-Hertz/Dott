import Foundation

/// I token di un blocco di lavoro, divisi come li conta Claude: quelli nuovi, quelli scritti in cache e quelli riletti dalla cache.
public struct UsageTotals: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    public var messages = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, messages: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.messages = messages
    }

    /// Tutto quello che e' passato dal modello.
    public var total: Int { input + output + cacheWrite + cacheRead }
    /// Quello che il modello ha letto o scritto davvero di nuovo (la cache riletta pesa pochissimo sul limite).
    public var fresh: Int { input + output + cacheWrite }

    public mutating func add(_ other: UsageTotals) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        messages += other.messages
    }

    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        var r = a
        r.add(b)
        return r
    }
}

/// Un messaggio di Claude con il suo consumo, letto da una riga di trascrizione.
public struct UsageEntry: Equatable, Sendable {
    public var timestamp: Date
    public var sessionId: String
    public var cwd: String?
    public var model: String
    public var sidechain: Bool
    public var dedupeKey: String?
    public var totals: UsageTotals
}

public enum TranscriptParser {
    private static let needle = Data("\"usage\"".utf8)

    /// Legge una riga di trascrizione. Restituisce nil per tutto cio' che non e' una risposta di Claude con un consumo vero.
    public static func parse(line: Data, dates: DateParser = DateParser()) -> UsageEntry? {
        // La stragrande maggioranza delle righe non ha il consumo: evitiamo di decodificarle.
        guard line.range(of: needle) != nil,
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (o["type"] as? String) == "assistant",
              let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any] else { return nil }
        let model = msg["model"] as? String ?? ""
        // Gli errori dell'app sono scritti come messaggi "sintetici" senza consumo.
        guard !model.isEmpty, model != "<synthetic>" else { return nil }

        func n(_ k: String) -> Int {
            if let i = u[k] as? Int { return i }
            if let d = u[k] as? Double { return Int(d) }
            return 0
        }
        let totals = UsageTotals(input: n("input_tokens"), output: n("output_tokens"),
                                 cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"), messages: 1)
        guard totals.total > 0, let ts = (o["timestamp"] as? String).flatMap({ dates.parse($0) }) else { return nil }

        var key: String?
        if let mid = msg["id"] as? String {
            key = mid + ":" + (o["requestId"] as? String ?? "")
        }
        return UsageEntry(timestamp: ts, sessionId: o["sessionId"] as? String ?? "", cwd: o["cwd"] as? String, model: model,
                          sidechain: (o["isSidechain"] as? Bool) ?? false, dedupeKey: key, totals: totals)
    }
}

/// Le date delle trascrizioni ("2026-10-08T10:15:30.123Z"), con o senza frazione di secondo.
public struct DateParser: @unchecked Sendable {
    private let withFraction: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    public init() {
        withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    public func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}

// MARK: - Prezzi

/// Il prezzo di un modello in dollari per milione di token. Si imposta a mano: i listini cambiano e Dott non inventa cifre.
public struct ModelRate: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheWrite: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public func cost(of t: UsageTotals) -> Double {
        (Double(t.input) * input + Double(t.output) * output + Double(t.cacheWrite) * cacheWrite + Double(t.cacheRead) * cacheRead) / 1_000_000
    }
}

/// Il listino: una parola del nome del modello ("opus", "sonnet") a un prezzo. Vince la parola piu' lunga che combacia.
public struct RateCard: Codable, Equatable, Sendable {
    public var rates: [String: ModelRate]

    public init(rates: [String: ModelRate] = [:]) { self.rates = rates }

    public var isEmpty: Bool { rates.isEmpty }

    public func rate(for model: String) -> ModelRate? {
        let m = model.lowercased()
        return rates.filter { m.contains($0.key.lowercased()) }.max { $0.key.count < $1.key.count }?.value
    }

    /// Il costo stimato, o nil se per qualche modello usato non c'e' un prezzo (meglio nessuna cifra di una cifra sbagliata).
    public func cost(byModel: [String: UsageTotals]) -> Double? {
        guard !byModel.isEmpty else { return 0 }
        var sum = 0.0
        for (model, t) in byModel {
            guard let r = rate(for: model) else { return nil }
            sum += r.cost(of: t)
        }
        return sum
    }
}
