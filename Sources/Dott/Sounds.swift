import AppKit

/// Suoni piccoli, presi dal sistema. Si spengono dal menu.
enum Sounds {
    enum Kind {
        case done       // Claude ha finito un lavoro lungo
        case attention  // ti serve: permesso, domanda, notifica
        case error
        case sent       // hai risposto dal notch

        fileprivate var name: String {
            switch self {
            case .done: "Glass"
            case .attention: "Ping"
            case .error: "Basso"
            case .sent: "Pop"
            }
        }
    }

    private static var cache: [String: NSSound] = [:]
    private static var lastPlayed = Date.distantPast

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
    }

    static func play(_ kind: Kind) {
        guard enabled else { return }
        // Piu' eventi quasi insieme (notifica + domanda) fanno un suono solo.
        guard Date().timeIntervalSince(lastPlayed) > 0.8 else { return }
        lastPlayed = Date()
        let sound = cache[kind.name] ?? NSSound(named: NSSound.Name(kind.name))
        guard let sound else { return }
        cache[kind.name] = sound
        sound.stop()
        sound.volume = 0.6
        sound.play()
    }
}
