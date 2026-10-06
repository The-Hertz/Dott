import Foundation

/// Dove e' arrivata una sessione, letto dalla trascrizione. Serve quando l'evento `Stop` non arriva:
/// succede se interrompi con Esc, e non e' detto che l'app Claude lo mandi a fine turno.
enum TranscriptState {
    case working
    case finished       // l'ultimo messaggio di Claude chiude il turno
    case interrupted    // hai interrotto con Esc

    static func read(path: String) -> TranscriptState {
        guard let h = FileHandle(forReadingAtPath: path) else { return .working }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return .working }
        let chunk = min(size, 200_000)
        try? h.seek(toOffset: size - chunk)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return .working }

        // Contano solo i messaggi veri: in coda ci sono anche righe di servizio (titolo, ultimo prompt…).
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"message\""),
                  let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["isSidechain"] as? Bool) != true,
                  let type = o["type"] as? String, type == "assistant" || type == "user",
                  let msg = o["message"] as? [String: Any] else { continue }
            if type == "assistant" {
                return (msg["stop_reason"] as? String) == "end_turn" ? .finished : .working
            }
            return line.contains("Request interrupted by user") ? .interrupted : .working
        }
        return .working
    }
}

/// Quanto contesto ha usato una sessione, letto dall'ultima risposta nella trascrizione.
enum ContextMeter {
    struct Reading {
        let tokens: Int
        let window: Int
    }

    static func read(path: String) -> Reading? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return nil }
        let chunk = min(size, 400_000)
        try? h.seek(toOffset: size - chunk)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"usage\"") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["isSidechain"] as? Bool) != true,
                  let msg = o["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant",
                  let u = msg["usage"] as? [String: Any] else { continue }
            func n(_ k: String) -> Int { u[k] as? Int ?? 0 }
            let tokens = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens") + n("output_tokens")
            let model = (msg["model"] as? String ?? "").lowercased()
            // La finestra non e' scritta nella trascrizione: e' una stima.
            let window = (model.contains("1m") || tokens > 200_000) ? 1_000_000 : 200_000
            return Reading(tokens: tokens, window: window)
        }
        return nil
    }
}
