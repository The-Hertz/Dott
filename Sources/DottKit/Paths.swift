import Foundation

/// Dove Dott tiene i suoi dati. Tutto sta in una cartella sola, cosi' si copia, si cancella o si guarda a mano.
/// Nei collaudi `root` e' una cartella temporanea.
public struct DottPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: DottPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return DottPaths(root: home.appendingPathComponent("Library/Application Support/Dott", isDirectory: true))
    }

    public var journalDir: URL { root.appendingPathComponent("journal", isDirectory: true) }
    public var memoryDir: URL { root.appendingPathComponent("memory", isDirectory: true) }
    public var ledgerFile: URL { root.appendingPathComponent("ledger.json") }
    public var ratesFile: URL { root.appendingPathComponent("rates.json") }
    public var socket: URL { root.appendingPathComponent("dott.sock") }
    public var hookScript: URL { root.appendingPathComponent("dott-hook") }

    /// Il nome di file sicuro per una chiave qualsiasi (un percorso, un nome di gruppo…): leggibile e senza collisioni.
    public static func fileName(for key: String) -> String {
        var readable = ""
        for u in key.unicodeScalars {
            if (u.value >= 48 && u.value <= 57) || (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) {
                readable.unicodeScalars.append(u)
            } else if !readable.hasSuffix("_") {
                readable += "_"
            }
        }
        readable = String(readable.prefix(40))
        return "\(readable)-\(Hashing.hex(key))"
    }
}

/// Un hash stabile (lo `hashValue` di Swift cambia a ogni avvio).
public enum Hashing {
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    public static func hex(_ s: String) -> String {
        let h = String(fnv1a(s), radix: 16)
        return String(repeating: "0", count: max(0, 16 - h.count)) + h
    }
}

/// Lettura e scrittura di file JSON, con scrittura atomica: un blocco a meta' non lascia mai un file rotto.
public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try e.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Giorni e orari in italiano, con un calendario passato dal chiamante (cosi' i collaudi non dipendono dal fuso del Mac).
public struct DayFormat: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// "2026-10-08"
    public func stamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "17:40"
    public func clock(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "oggi alle 17:40", "ieri alle 17:40", "3 giorni fa", "2 settimane fa".
    public func ago(_ date: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1:
            let mins = Int(now.timeIntervalSince(date) / 60)
            if mins < 2 { return "adesso" }
            if mins < 60 { return "\(mins) minuti fa" }
            return "oggi alle \(clock(date))"
        case 1: return "ieri alle \(clock(date))"
        case 2...13: return "\(days) giorni fa"
        case 14...59: return "\(days / 7) settimane fa"
        default: return "\(days / 30) mesi fa"
        }
    }

    /// "1 h 20 min", "45 min", "meno di un minuto".
    public static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "meno di un minuto" }
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
}
