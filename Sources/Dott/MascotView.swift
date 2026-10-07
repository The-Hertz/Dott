import SwiftUI

/// Porta lo sguardo verso il cursore con un movimento morbido, invece di saltarci.
final class GazeSmoother {
    private var x = 0.0, y = 0.0, w = 0.0
    private var last = 0.0

    func update(target: CGPoint?, weight: Double, now: Double) -> (CGPoint, Double) {
        let dt = min(0.1, max(0, now - last))
        last = now
        let a = 1 - exp(-dt * 14)
        x += ((target?.x ?? 0) - x) * a
        y += ((target?.y ?? 0) - y) * a
        w += (weight - w) * a
        return (CGPoint(x: x, y: y), w)
    }
}

/// Quanto e' sveglio Dott, da 0 (dorme) a 1 (sveglio): sale in fretta, scende piano.
/// Cosi' il risveglio e l'addormentarsi sono movimenti, non scatti.
final class WakeState {
    private(set) var value = 0.0
    private var last = 0.0
    private var started = false

    func update(awake: Bool, now: Double) -> Double {
        if !started { started = true; value = awake ? 1 : 0; last = now; return value }
        let dt = min(0.1, max(0, now - last))
        last = now
        value = awake ? min(1, value + dt / 2.8) : max(0, value - dt / 3.2)
        return value
    }
}

/// Quanto e' indossato ciascun accessorio o vestito (0...1): entrano ed escono in dissolvenza.
struct Dress {
    var glasses = 0.0, pencil = 0.0, headphones = 0.0, helmet = 0.0, broom = 0.0
    var santa = 0.0, scarf = 0.0, witch = 0.0, party = 0.0
}

final class DressFader {
    private var w: [String: Double] = [:]
    private var last = 0.0

    func update(accessory: Accessory?, outfit: Set<Outfit>, now: Double) -> Dress {
        let dt = min(0.1, max(0, now - last))
        last = now
        let a = 1 - exp(-dt * 6)
        func step(_ k: String, _ on: Bool) -> Double {
            let cur = w[k] ?? 0
            let v = cur + ((on ? 1 : 0) - cur) * a
            w[k] = v
            return v < 0.01 ? 0 : v
        }
        return Dress(glasses: step("g", accessory == .glasses), pencil: step("p", accessory == .pencil),
                     headphones: step("h", accessory == .headphones), helmet: step("m", accessory == .helmet),
                     broom: step("r", accessory == .broom),
                     santa: step("s", outfit.contains(.santa)), scarf: step("f", outfit.contains(.scarf)),
                     witch: step("w", outfit.contains(.witch)), party: step("b", outfit.contains(.party)))
    }
}

/// Il colore di Dott passa da uno all'altro in mezzo secondo (cambia progetto, cambia scelta nelle impostazioni).
final class TintFader {
    private var cur: [Double]?
    private var last = 0.0

    private static func rgb(_ c: Color) -> [Double] {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return [0, 0, 0] }
        return [n.redComponent, n.greenComponent, n.blueComponent]
    }

    func update(target: (top: Color, bottom: Color), now: Double) -> (top: Color, bottom: Color) {
        let goal = Self.rgb(target.top) + Self.rgb(target.bottom)
        let dt = min(0.1, max(0, now - last))
        last = now
        var v = cur ?? goal
        let a = 1 - exp(-dt * 6)
        for i in 0..<6 { v[i] += (goal[i] - v[i]) * a }
        cur = v
        return (Color(red: v[0], green: v[1], blue: v[2]), Color(red: v[3], green: v[4], blue: v[5]))
    }
}

/// Dott: un blob lime con occhi e un'antennina. Ogni umore ha il suo modo di muoversi.
struct MascotView: View {
    var mood: Mood
    var size: CGFloat
    /// Effetti (zzz, punto esclamativo, coriandoli…) solo quando c'e' spazio.
    var effects = true
    /// Sfasa il movimento: serve a non far muovere all'unisono i piccoli aiutanti.
    var offset = 0.0
    /// Colori propri (gli aiutanti); senza, il lime di Dott.
    var tint: (top: Color, bottom: Color)?
    /// Dove sta Dott sullo schermo (coordinate di macOS): se c'e', gli occhi seguono il cursore.
    var gazeFrom: CGPoint?
    /// Il cursore e' sull'isola: Dott si sveglia e ti guarda.
    var attentive = false

    /// Il cursore si muove vicino alla mascotte: servono piu' fotogrammi per seguirlo bene.
    var following = false
    /// L'ultimo gesto da eseguire (se e' recente).
    var gesture: GestureEvent?
    /// 0 di giorno, 1 a notte fonda: palpebre pesanti, piu' sbadigli.
    var night = 0.0
    /// Accessorio legato a cosa sta facendo, e vestiti di stagione.
    var accessory: Accessory?
    var outfit: Set<Outfit> = []
    /// Sta suonando musica: Dott si sveglia e balla.
    var music = false
    /// Avatar scelto; se nil, usa quello delle impostazioni.
    var avatar: DottAvatar? = nil

    @State private var changedAt = Date.distantPast
    @State private var prevMood: Mood?
    @State private var smoother = GazeSmoother()
    @State private var wakeState = WakeState()
    @State private var dressFader = DressFader()
    @State private var grooveState = WakeState()
    @State private var tintFader = TintFader()

    /// Quanto spesso ridisegnare: piu' spesso se il cursore e' vicino e si muove, poco se dorme.
    private var frameInterval: Double {
        if following { return 1.0 / 60 }
        if mood == .sleeping && !attentive { return 1.0 / 20 }
        return 1.0 / 30
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { tl in
            Canvas { ctx, sz in
                let t = tl.date.timeIntervalSinceReferenceDate + offset
                let pop = t - offset - changedAt.timeIntervalSinceReferenceDate
                var gaze: CGPoint?
                var gazeWeight = 0.0
                if let from = gazeFrom {
                    let m = NSEvent.mouseLocation
                    let dx = m.x - from.x, dy = from.y - m.y   // y verso il basso
                    let len = max(hypot(dx, dy), 1)
                    let k = min(1, len / 90)
                    // Pieno entro ~300 punti, sfuma fino a ~700: lontano, Dott si fa i fatti suoi.
                    let (g, w) = smoother.update(target: CGPoint(x: dx / len * k, y: dy / len * k),
                                                 weight: min(1, max(0, 1 - (len - 300) / 400)), now: t)
                    gaze = g
                    gazeWeight = w
                }
                let groove = grooveState.update(awake: music, now: t)
                let wake = wakeState.update(awake: mood != .sleeping || attentive || music, now: t)
                let dress = dressFader.update(accessory: accessory, outfit: outfit, now: t)
                var g: (kind: GestureKind, u: Double)?
                if let ev = gesture {
                    let u = tl.date.timeIntervalSince(ev.at) / ev.kind.duration
                    if u >= 0, u < 1 { g = (ev.kind, u) }
                }
                // Passaggio dall'umore di prima a quello nuovo in mezzo secondo.
                let k = Mascot.smooth(0, 0.5, pop)
                let smoothTint = tintFader.update(target: tint ?? (Palette.lime, Palette.limeDeep), now: tl.date.timeIntervalSinceReferenceDate)
                Mascot.draw(&ctx, size: sz, mood: mood, t: t, pop: pop, effects: effects, tint: smoothTint,
                            gaze: gaze, gazeWeight: gazeWeight, attentive: attentive, wake: wake, prev: prevMood, blend: k,
                            night: night, gesture: g, dress: dress, groove: groove, avatar: avatar)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: mood) { old, _ in prevMood = old; changedAt = Date() }
    }
}

fileprivate enum Eyes { case open, wide, closed, happy, dead, spiral }
fileprivate enum Mouth { case none, flat, small, smile, grin, o, wavy, yawn }

/// Tutto cio' che cambia da un umore all'altro. Due pose si possono fondere: niente scatti.
fileprivate struct Pose {
    var dx = 0.0, dy = 0.0, sx = 1.0, sy = 1.0, rot = 0.0
    var look = CGPoint.zero
    var eyes = Eyes.open
    var mouth = Mouth.small
    var blinks = true
    var awake = false
    var yawn = 0.0
    var lid = 1.0        // apertura delle palpebre quando gli occhi sono aperti
    var droop = 0.0      // antennina abbassata
    var cheeks = 0.0     // guance rosa
    var hurt = 0.0       // tinta rossa
    var alert = 0.0      // ambra: alone e punta dell'antenna
    var tipSway = 0.0    // l'antennina si agita (frazione di u)
    // Occhi e bocca "sovrapposti" da un gesto: si dissolvono sopra quelli dell'umore.
    var eyes2: Eyes?
    var eyes2w = 0.0
    var mouth2: Mouth?
    var mouth2w = 0.0
}

enum Mascot {
    private static let ink = Palette.ink

    /// Passaggio morbido da 0 a 1 tra a e b.
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    private static func mix(_ a: Color, _ b: Color, _ k: Double) -> Color {
        if k <= 0 { return a }
        if k >= 1 { return b }
        guard let x = NSColor(a).usingColorSpace(.sRGB), let y = NSColor(b).usingColorSpace(.sRGB) else { return a }
        return Color(red: lerp(x.redComponent, y.redComponent, k),
                     green: lerp(x.greenComponent, y.greenComponent, k),
                     blue: lerp(x.blueComponent, y.blueComponent, k))
    }

    // MARK: pose di ogni umore

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    fileprivate static func pose(_ mood: Mood, t: Double, wake: Double, gaze: CGPoint?, gazeWeight: Double,
                                 night: Double = 0, gesture: (kind: GestureKind, u: Double)? = nil) -> Pose {
        var p = Pose()
        switch mood {
        case .sleeping:
            // `wake` va da 0 (dorme) a 1 (sveglio): palpebre, stiracchiata e sbadiglio seguono la curva.
            let w = wake
            let e = smooth(0.12, 1.0, w)                 // quanto sono aperte le palpebre
            let k = sin(.pi * w)                          // picco a meta' risveglio
            let b = sin(t * 1.6)
            p.sy = 1 + 0.035 * b * (1 - w) + 0.07 * k
            p.sx = 1 - 0.02 * b * (1 - w) - 0.035 * k
            p.dy = -0.03 * k - 0.02 * smooth(0.5, 1, w)
            p.lid = e
            p.eyes = e < 0.12 ? .closed : .open
            p.mouth = w < 0.1 ? .none : (w < 0.8 ? .yawn : .small)
            p.yawn = 0.6 * sin(.pi * min(w / 0.8, 1))
            p.blinks = w > 0.95
            p.look = CGPoint(x: 0, y: 0.3 * e)
            p.droop = 0.05 * (1 - w)
            p.cheeks = 1
            // Vita propria: ogni tanto si guarda intorno, sbadiglia, sogna. Di notte e' piu' assonnato.
            let L = 24 - 8 * night
            let ph = t.truncatingRemainder(dividingBy: L)
            if w < 0.02 {
                let look0 = L * 0.75, yawn0 = look0 + 1.3
                if ph > look0, ph < look0 + 1.3 {
                    // Apre gli occhi e si guarda intorno.
                    p.awake = true
                    p.sy = 1; p.sx = 1
                    p.eyes = .open; p.mouth = .none; p.blinks = false
                    p.look = CGPoint(x: sin((ph - look0) * 5), y: 0.1)
                } else if ph >= yawn0, ph < yawn0 + 2.5 {
                    // Sbadiglio.
                    p.awake = true
                    let y = sin(.pi * (ph - yawn0) / 2.5)
                    p.yawn = y
                    p.sy = 1 + 0.06 * y; p.sx = 1 - 0.03 * y; p.dy = -0.03 * y
                    p.eyes = .closed; p.mouth = .yawn; p.blinks = false
                } else if ph > L * 0.25, ph < L * 0.46 {
                    // Sogna: un sorriso nel sonno.
                    let d = sin(.pi * (ph - L * 0.25) / (L * 0.21))
                    p.mouth2 = .small; p.mouth2w = d
                } else if ph > L * 0.55, ph < L * 0.55 + 1.2 {
                    // L'antennina ha un fremito.
                    p.tipSway = 0.06 * sin((ph - L * 0.55) * 14) * sin(.pi * (ph - L * 0.55) / 1.2)
                }
            }
        case .thinking:
            p.rot = 0.05 * sin(t * 1.3)
            p.look = CGPoint(x: 0.7 * sin(t * 0.9), y: -0.8)
            p.mouth = .small
        case .reading:
            p.look = CGPoint(x: sin(t * 2.2), y: 0.25)
            p.dy = -0.008 * abs(sin(t * 2.2)); p.mouth = .flat
        case .writing:
            p.look = CGPoint(x: 0.35 * sin(t * 3), y: 0.9)
            let k = abs(sin(t * 9))
            p.dy = -0.014 * k; p.rot = 0.02 * sin(t * 9); p.mouth = .small
        case .running:
            let hop = abs(sin(t * .pi * 2.4))
            p.dy = -0.2 * hop
            p.sy = 1 + 0.08 * hop - 0.10 * (1 - hop) * (1 - hop)
            p.sx = 1 - 0.04 * hop + 0.08 * (1 - hop) * (1 - hop)
            p.look = CGPoint(x: 0.8, y: 0); p.rot = 0.06
            p.eyes = .wide; p.mouth = .o
        case .searching:
            p.look = CGPoint(x: cos(t * 1.7), y: 0.6 * sin(t * 2.3))
            p.rot = 0.09 * sin(t * 1.2); p.mouth = .o
        case .working:
            p.look = CGPoint(x: 0.3 * sin(t * 1.1), y: 0.3)
            p.dy = -0.01 * abs(sin(t * 5)); p.mouth = .smile
        case .waiting:
            let b = abs(sin(t * 4.2))
            p.dy = -0.13 * b; p.sy = 1 + 0.06 * b; p.sx = 1 - 0.03 * b
            p.eyes = .wide; p.mouth = .o
            p.cheeks = 1; p.alert = 1
            if let g = gaze { p.look = g }   // ti guarda, aspetta te
        case .happy:
            if let g = gaze { p.look = g }
            let b = abs(sin(t * 5))
            p.dy = -0.17 * b; p.rot = 0.09 * sin(t * 5)
            p.sy = 1 + 0.05 * b; p.eyes = .happy; p.mouth = .grin; p.blinks = false
            p.cheeks = 1
        case .hurt:
            p.rot = 0.07 * sin(t * 30); p.dx = 0.012 * sin(t * 37)
            p.eyes = .dead; p.mouth = .wavy; p.blinks = false
            p.hurt = 1
        }

        // Gli occhi cercano il cursore quando e' vicino, in ogni stato a occhi aperti:
        // gli sguardi del lavoro (leggere, scrivere…) tornano quando si allontana.
        if let g = gaze, gazeWeight > 0, p.eyes == .open || p.eyes == .wide, mood != .hurt {
            p.look = CGPoint(x: p.look.x + (g.x - p.look.x) * gazeWeight, y: p.look.y + (g.y - p.look.y) * gazeWeight)
            p.rot += 0.07 * g.x * gazeWeight          // inclina la testa verso di lui
            p.dx += 0.02 * g.x * gazeWeight
        }

        // Di notte le palpebre sono un po' pesanti.
        if night > 0, p.eyes == .open || p.eyes == .wide, mood != .sleeping {
            p.lid *= 1 - 0.22 * night
        }

        if let g = gesture { apply(g.kind, u: g.u, to: &p) }
        return p
    }

    /// Un dondolio a tempo di musica.
    fileprivate static func applyGroove(_ p: inout Pose, groove: Double, t: Double) {
        let beat = abs(sin(t * .pi * 1.9))
        p.dy -= 0.025 * beat * groove
        p.rot += 0.05 * sin(t * .pi * 1.9) * groove
        p.sy *= 1 + 0.02 * beat * groove
        p.cheeks = max(p.cheeks, groove)
    }

    /// Un gesto: sale e scende con `env`, quindi comincia e finisce sulla posa di base.
    fileprivate static func apply(_ kind: GestureKind, u: Double, to p: inout Pose) {
        let env = sin(.pi * min(max(u, 0), 1))
        switch kind {
        case .nod:
            let d = abs(sin(.pi * 2 * u)) * env
            p.sy *= 1 - 0.07 * d; p.sx *= 1 + 0.03 * d; p.dy += 0.012 * d
        case .tilt:
            p.rot += 0.13 * env; p.look.x += 0.5 * env; p.look.y -= 0.3 * env
        case .sigh:
            let inhale = u < 0.45 ? sin(.pi * u / 0.45) : 0
            let exhale = u >= 0.45 ? sin(.pi * (u - 0.45) / 0.55) : 0
            p.sy *= 1 + 0.06 * inhale - 0.06 * exhale
            p.dy += 0.015 * exhale
            p.eyes2 = .closed; p.eyes2w = min(1, env * 1.4)
            p.mouth2 = .o; p.mouth2w = exhale
        case .giggle:
            p.rot += 0.07 * sin(u * .pi * 14) * env
            p.dy -= 0.035 * abs(sin(u * .pi * 5)) * env
            p.eyes2 = .happy; p.eyes2w = min(1, env * 1.6)
            p.mouth2 = .grin; p.mouth2w = min(1, env * 1.6)
            p.cheeks = max(p.cheeks, env)
        case .hop:
            p.dy -= 0.2 * env; p.sy *= 1 + 0.06 * env; p.sx *= 1 - 0.03 * env
            p.eyes2 = .happy; p.eyes2w = env
        case .spin:
            let c = cos(2 * .pi * u)
            p.sx *= abs(c) < 0.07 ? 0.07 : c
            p.dy -= 0.08 * env
            p.eyes2 = .happy; p.eyes2w = env
        case .wave:
            p.tipSway = 0.12 * sin(u * .pi * 6) * env
            p.rot += 0.04 * sin(u * .pi * 6) * env
            p.eyes2 = .happy; p.eyes2w = env * 0.8
            p.mouth2 = .small; p.mouth2w = env
            p.cheeks = max(p.cheeks, env)
        case .purr:
            let hold = smooth(0, 0.2, u) * (1 - smooth(0.8, 1, u))
            p.sx *= 1 + 0.012 * sin(u * 70) * hold
            p.eyes2 = .happy; p.eyes2w = hold
            p.mouth2 = .small; p.mouth2w = hold
            p.cheeks = max(p.cheeks, hold)
        case .stretch:
            p.sy *= 1 + 0.09 * env; p.sx *= 1 - 0.04 * env; p.dy -= 0.04 * env
            p.eyes2 = .closed; p.eyes2w = env
            p.mouth2 = .yawn; p.mouth2w = env; p.yawn = 0.7
        case .peek:
            p.look.x += 0.9 * sin(2 * .pi * u) * env
        case .annoyed:
            // Seccato: palpebre pesanti, sguardo di traverso, bocca dritta, un brontolio.
            let hold = smooth(0, 0.15, u) * (1 - smooth(0.8, 1, u))
            p.lid = min(p.lid, 1 - 0.55 * hold)
            p.look.x -= 0.9 * hold
            p.mouth2 = .flat; p.mouth2w = hold
            p.rot += 0.02 * sin(u * 34) * hold
            p.sy *= 1 - 0.03 * hold
        case .dizzy:
            // Gli gira la testa: occhi a spirale, dondola, bocca ondulata.
            let hold = smooth(0, 0.12, u) * (1 - smooth(0.85, 1, u))
            p.eyes2 = .spiral; p.eyes2w = hold
            p.mouth2 = .wavy; p.mouth2w = hold
            p.rot += 0.12 * sin(u * 2 * .pi * 3.2) * hold
            p.dx += 0.03 * sin(u * 2 * .pi * 3.2 + 1.2) * hold
        case .sneeze:
            // Si carica all'indietro, "etciu'!", poi si scuote e si riprende.
            let wind = smooth(0.05, 0.5, u) * (1 - smooth(0.5, 0.57, u))
            let burst = exp(-pow((u - 0.54) / 0.045, 2))
            let rec = smooth(0.56, 0.7, u) * (1 - smooth(0.7, 0.95, u))
            p.sy *= 1 + 0.07 * wind - 0.15 * burst
            p.sx *= 1 - 0.03 * wind + 0.10 * burst
            p.dy += -0.03 * wind + 0.02 * burst
            p.look.y -= 0.8 * wind
            p.rot += -0.04 * wind + 0.035 * burst + 0.022 * sin(u * 46) * rec
            p.tipSway += 0.10 * burst + 0.05 * sin(u * 30) * rec
            let shut = smooth(0.3, 0.48, u) * (1 - smooth(0.78, 0.95, u))
            p.eyes2 = .closed; p.eyes2w = shut
            p.mouth2 = .o; p.mouth2w = min(1, wind * 1.6 + burst) * (1 - smooth(0.6, 0.8, u))
            p.cheeks = max(p.cheeks, rec)
        case .whistle:
            // Dondola piano, occhi sereni, la bocca fa "o" e escono le note.
            p.rot += 0.045 * sin(u * 2 * .pi * 2) * env
            p.dy -= 0.012 * abs(sin(u * 2 * .pi * 4)) * env
            p.look = CGPoint(x: p.look.x + 0.55 * sin(u * 2 * .pi * 1.5) * env, y: p.look.y - 0.5 * env)
            p.eyes2 = .happy; p.eyes2w = 0.85 * env
            p.mouth2 = .o; p.mouth2w = env
            p.tipSway += 0.05 * sin(u * 2 * .pi * 4) * env
        case .chase:
            // Una lucciola gli passa davanti: la segue con gli occhi, salta per prenderla, la perde.
            let f = fireflyPos(u)
            let look = smooth(0.04, 0.16, u) * (1 - smooth(0.9, 1, u))
            p.look = CGPoint(x: p.look.x + (f.x - p.look.x) * look, y: p.look.y + (f.y - p.look.y) * look)
            p.rot += 0.07 * f.x * look
            let jump = u > 0.62 && u < 0.78 ? sin(.pi * (u - 0.62) / 0.16) : 0
            p.dy -= 0.19 * jump
            p.sy *= 1 + 0.05 * jump; p.sx *= 1 - 0.025 * jump
            p.eyes2 = .wide; p.eyes2w = look * (1 - smooth(0.82, 0.92, u))
            p.mouth2 = .o; p.mouth2w = smooth(0.5, 0.65, u) * (1 - smooth(0.8, 0.9, u))
            // Poi alza le spalle: un sospiro.
            let shrug = smooth(0.84, 0.92, u) * (1 - smooth(0.94, 1, u))
            p.sy *= 1 - 0.03 * shrug
        }
    }

    /// Dove si trova la lucciola (-1...1 in orizzontale, -1...0.3 in verticale), `u` e' l'avanzamento del gesto.
    fileprivate static func fireflyPos(_ u: Double) -> (x: Double, y: Double) {
        if u > 0.74 {   // dopo il salto sfugge verso l'alto a destra
            let q = smooth(0.74, 0.95, u)
            return (0.55 + 0.5 * q, -0.45 - 0.55 * q)
        }
        return (0.85 * sin(u * 2 * .pi * 1.35 + 0.6), -0.45 + 0.35 * sin(u * 2 * .pi * 2.2))
    }

    /// Fonde le parti continue di due pose; occhi, bocca ed effetti si dissolvono a parte.
    fileprivate static func blend(_ a: Pose, _ b: Pose, _ k: Double) -> Pose {
        var p = b
        p.dx = lerp(a.dx, b.dx, k); p.dy = lerp(a.dy, b.dy, k)
        p.sx = lerp(a.sx, b.sx, k); p.sy = lerp(a.sy, b.sy, k)
        p.rot = lerp(a.rot, b.rot, k)
        p.look = CGPoint(x: lerp(a.look.x, b.look.x, k), y: lerp(a.look.y, b.look.y, k))
        p.droop = lerp(a.droop, b.droop, k)
        p.cheeks = lerp(a.cheeks, b.cheeks, k)
        p.hurt = lerp(a.hurt, b.hurt, k)
        p.alert = lerp(a.alert, b.alert, k)
        return p
    }

    // MARK: disegno

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, mood: Mood, t: Double, pop: Double, effects: Bool,
                     tint: (top: Color, bottom: Color)? = nil, gaze: CGPoint? = nil, gazeWeight: Double = 0,
                     attentive: Bool = false, wake: Double = 0, prev: Mood? = nil, blend k: Double = 1,
                     night: Double = 0, gesture: (kind: GestureKind, u: Double)? = nil, dress: Dress = Dress(), groove: Double = 0,
                     avatar: DottAvatar? = nil) {
        let w = size.width, h = size.height
        let u = min(w, h) * (effects ? 0.78 : 0.96)

        var pb = pose(mood, t: t, wake: wake, gaze: gaze, gazeWeight: gazeWeight, night: night, gesture: gesture)
        if groove > 0.01 { applyGroove(&pb, groove: groove, t: t) }
        var pa: Pose?
        var p = pb
        if let prev, prev != mood, k < 1 {
            let a = pose(prev, t: t, wake: wake, gaze: gaze, gazeWeight: gazeWeight, night: night, gesture: gesture)
            pa = a
            p = blend(a, pb, k)
        }

        // Con la scopa in mano: si china, segue il colpo con gli occhi, dondola a ogni passata.
        if dress.broom > 0.01 { applySweep(&p, weight: dress.broom, t: t) }

        // piccolo "pop" quando cambia umore
        let pp = max(0, pop)
        if pp < 0.6 {
            let q = exp(-pp * 7) * cos(pp * 22)
            p.sy *= 1 + 0.16 * q
            p.sx *= 1 - 0.10 * q
        }

        // --- alone dietro ---------------------------------------------------
        if p.alert > 0.01 && effects {
            let a = (0.14 + 0.12 * (0.5 + 0.5 * sin(t * 4.2))) * p.alert
            let r = u * 0.62
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - r, y: h * 0.58 - r, width: 2 * r, height: 2 * r)),
                     with: .color(Palette.amber.opacity(a)))
        }

        // --- corpo ----------------------------------------------------------
        var c = ctx
        c.translateBy(x: w / 2 + p.dx * u, y: h * 0.93 + p.dy * u)
        c.rotate(by: .radians(p.rot))
        c.scaleBy(x: p.sx, y: p.sy)

        let bw = 0.74 * u, bh = 0.64 * u
        let bodyRect = CGRect(x: -bw / 2, y: -bh, width: bw, height: bh)

        let baseTop = tint?.top ?? Palette.lime, baseBottom = tint?.bottom ?? Palette.limeDeep
        let top = mix(baseTop, Color(red: 1, green: 0.55, blue: 0.46), p.hurt)
        let bottom = mix(baseBottom, Palette.coral, p.hurt)

        let st = AppSettings.shared
        let av = avatar ?? st.avatar

        // matita dietro l'"orecchio": sta dietro al corpo, quindi si disegna prima
        if dress.pencil > 0 { drawPencil(c, weight: dress.pencil, u: u, bw: bw, bh: bh) }

        // Caratteristiche dietro al corpo (antenna, orecchie, bulloni, cornini)
        drawAvatarHeadgearBehind(c, avatar: av, u: u, bw: bw, bh: bh, top: top, bottom: bottom, t: t, p: p, antenna: st.antenna)

        // corpo: la figura principale varia a seconda dell'avatar
        let body = buildAvatarBody(avatar: av, shape: st.shape, bodyRect: bodyRect, u: u, bw: bw, bh: bh, t: t)
        c.fill(body, with: .linearGradient(Gradient(colors: [top, bottom]),
                                           startPoint: CGPoint(x: 0, y: -bh), endPoint: CGPoint(x: 0, y: 0)))

        // Dettagli sul viso dell'avatar (musetto, baffetti, rivetti, pannello WALL-E)
        drawAvatarFaceDetails(c, avatar: av, u: u, bw: bw, bh: bh, top: top, bottom: bottom, p: p, mood: mood, t: t)

        // guance (per WALL-E c'è il cuoricino dedicato sui binocoli)
        if p.cheeks > 0.01 && av != .walle {
            let cheek = Color(red: 1, green: 0.55, blue: 0.5).opacity(0.38 * p.cheeks)
            for s in [-1.0, 1.0] {
                c.fill(Path(ellipseIn: CGRect(x: s * bw * 0.34 - 0.05 * u, y: -bh * 0.40 - 0.03 * u,
                                              width: 0.10 * u, height: 0.06 * u)), with: .color(cheek))
            }
        }

        // occhi e bocca: se l'umore sta cambiando, quelli vecchi svaniscono mentre arrivano i nuovi
        if let a = pa {
            var old = p; old.eyes = a.eyes; old.lid = a.lid; old.blinks = a.blinks; old.mouth = a.mouth; old.yawn = a.yawn
            var cOld = c; cOld.opacity = c.opacity * (1 - k)
            eyesLayer(cOld, p: old, u: u, bw: bw, bh: bh, t: t, avatar: av, dress: dress, top: top, bottom: bottom)
            mouthLayer(cOld, p: old, u: u, bh: bh, t: t, avatar: av)
            var new = p; new.eyes = pb.eyes; new.lid = pb.lid; new.blinks = pb.blinks; new.mouth = pb.mouth; new.yawn = pb.yawn
            var cNew = c; cNew.opacity = c.opacity * k
            eyesLayer(cNew, p: new, u: u, bw: bw, bh: bh, t: t, avatar: av, dress: dress, top: top, bottom: bottom)
            mouthLayer(cNew, p: new, u: u, bh: bh, t: t, avatar: av)
        } else {
            eyesLayer(c, p: p, u: u, bw: bw, bh: bh, t: t, avatar: av, dress: dress, top: top, bottom: bottom)
            mouthLayer(c, p: p, u: u, bh: bh, t: t, avatar: av)
        }

        drawDress(c, dress: dress, u: u, bw: bw, bh: bh, body: body, avatar: av)
        if dress.broom > 0.01 { drawBroom(c, weight: dress.broom, u: u, bw: bw, bh: bh, t: t, wide: effects) }

        // effetti (zzz, punto esclamativo, coriandoli…), anche loro in dissolvenza
        guard effects else { return }
        func effectAlpha(_ m: Mood, _ q: Pose) -> Double {
            m == .sleeping ? ((q.awake || wake > 0.35) ? 0 : 1 - wake / 0.35) : 1
        }
        if let a = pa, let prev {
            var e = ctx; e.opacity = ctx.opacity * (1 - k) * effectAlpha(prev, a)
            if e.opacity > 0.01 { drawEffects(&e, size: size, mood: prev, t: t, dy: p.dy * u) }
        }
        var e = ctx; e.opacity = ctx.opacity * (pa == nil ? 1 : k) * effectAlpha(mood, pb)
        if e.opacity > 0.01 { drawEffects(&e, size: size, mood: mood, t: t, dy: p.dy * u) }
        if let g = gesture { drawGestureEffects(ctx, kind: g.kind, u: g.u, size: size, t: t) }
        if groove > 0.05 { drawMusic(ctx, groove: groove, size: size, t: t) }
    }

    // MARK: - Sagome e dettagli per ogni avatar

    private static func drawAvatarHeadgearBehind(_ c: GraphicsContext, avatar: DottAvatar, u: Double,
                                                 bw: Double, bh: Double, top: Color, bottom: Color,
                                                 t: Double, p: Pose, antenna: Bool) {
        switch avatar {
        case .classic:
            if antenna {
                let tip = CGPoint(x: 0.07 * u * sin(t * 2 + 1) + p.tipSway * u, y: -bh - 0.17 * u + p.droop * u)
                var stalk = Path()
                stalk.move(to: CGPoint(x: 0, y: -bh + 0.02 * u))
                stalk.addQuadCurve(to: tip, control: CGPoint(x: tip.x * 0.2 - 0.03 * u, y: -bh - 0.09 * u))
                c.stroke(stalk, with: .color(bottom), style: StrokeStyle(lineWidth: max(1, 0.04 * u), lineCap: .round))
                let tipR = 0.05 * u
                c.fill(Path(ellipseIn: CGRect(x: tip.x - tipR, y: tip.y - tipR, width: 2 * tipR, height: 2 * tipR)),
                       with: .color(mix(top, Palette.amber, p.alert)))
            }
        case .kitty:
            let droop = p.droop * u
            for s in [-1.0, 1.0] {
                var ear = Path()
                let baseOut = CGPoint(x: s * bw * 0.42, y: -bh * 0.86)
                let tip = CGPoint(x: s * bw * 0.33, y: -bh - 0.17 * u + droop)
                let baseIn = CGPoint(x: s * bw * 0.12, y: -bh * 0.98)
                ear.move(to: baseOut)
                ear.addLine(to: tip)
                ear.addLine(to: baseIn)
                ear.closeSubpath()
                c.fill(ear, with: .linearGradient(Gradient(colors: [top, bottom]),
                                                  startPoint: CGPoint(x: 0, y: -bh - 0.17 * u),
                                                  endPoint: CGPoint(x: 0, y: -bh * 0.86)))
                var inner = Path()
                inner.move(to: CGPoint(x: s * bw * 0.38, y: -bh * 0.88))
                inner.addLine(to: CGPoint(x: s * bw * 0.33, y: -bh - 0.12 * u + droop))
                inner.addLine(to: CGPoint(x: s * bw * 0.18, y: -bh * 0.96))
                inner.closeSubpath()
                c.fill(inner, with: .color(Color(red: 1.0, green: 0.65, blue: 0.78).opacity(0.65)))
            }
        case .bear:
            let earR = 0.115 * u
            for s in [-1.0, 1.0] {
                let center = CGPoint(x: s * bw * 0.34, y: -bh * 0.94)
                let earRect = CGRect(x: center.x - earR, y: center.y - earR, width: 2 * earR, height: 2 * earR)
                c.fill(Path(ellipseIn: earRect), with: .linearGradient(Gradient(colors: [top, bottom]),
                                                                       startPoint: CGPoint(x: center.x, y: center.y - earR),
                                                                       endPoint: CGPoint(x: center.x, y: center.y + earR)))
                let innerR = 0.065 * u
                let innerRect = CGRect(x: center.x - innerR, y: center.y - innerR, width: 2 * innerR, height: 2 * innerR)
                c.fill(Path(ellipseIn: innerRect), with: .color(mix(bottom, Color.white, 0.35)))
            }
        case .robot:
            for s in [-1.0, 1.0] {
                let boltRect = CGRect(x: s > 0 ? bw / 2 - 0.01 * u : -bw / 2 - 0.05 * u,
                                      y: -bh * 0.58, width: 0.06 * u, height: 0.16 * u)
                c.fill(Path(roundedRect: boltRect, cornerRadius: 0.02 * u), with: .color(bottom))
                c.stroke(Path(roundedRect: boltRect, cornerRadius: 0.02 * u), with: .color(top),
                         style: StrokeStyle(lineWidth: max(1, 0.015 * u)))
            }
            var ant = Path()
            ant.move(to: CGPoint(x: 0, y: -bh + 0.01 * u))
            ant.addLine(to: CGPoint(x: 0, y: -bh - 0.14 * u))
            c.stroke(ant, with: .color(bottom), style: StrokeStyle(lineWidth: max(1, 0.035 * u), lineCap: .round))
            let pulse = 0.5 + 0.5 * sin(t * 5)
            let ledR = 0.045 * u
            let ledRect = CGRect(x: -ledR, y: -bh - 0.14 * u - 2 * ledR, width: 2 * ledR, height: 2 * ledR)
            c.fill(Path(roundedRect: ledRect, cornerRadius: 0.015 * u), with: .color(mix(top, Color.cyan, 0.6 * pulse)))
        case .monster:
            for s in [-1.0, 1.0] {
                var horn = Path()
                let baseOut = CGPoint(x: s * bw * 0.26, y: -bh * 0.94)
                let tip = CGPoint(x: s * (bw * 0.38 + 0.02 * u * sin(t * 2)), y: -bh - 0.17 * u + p.droop * u)
                let baseIn = CGPoint(x: s * bw * 0.10, y: -bh * 0.98)
                horn.move(to: baseOut)
                horn.addQuadCurve(to: tip, control: CGPoint(x: s * bw * 0.20, y: -bh - 0.11 * u))
                horn.addQuadCurve(to: baseIn, control: CGPoint(x: s * bw * 0.18, y: -bh - 0.08 * u))
                horn.closeSubpath()
                let hornColor1 = Color(red: 1.0, green: 0.88, blue: 0.45)
                let hornColor2 = Color(red: 0.96, green: 0.60, blue: 0.20)
                c.fill(horn, with: .linearGradient(Gradient(colors: [hornColor1, hornColor2]),
                                                   startPoint: CGPoint(x: 0, y: -bh - 0.17 * u),
                                                   endPoint: CGPoint(x: 0, y: -bh * 0.94)))
            }
        case .ghost, .star:
            break
        case .walle:
            // Collare alla base del collo idraulico
            let collarRect = CGRect(x: -0.06 * u, y: -0.375 * u, width: 0.12 * u, height: 0.03 * u)
            c.fill(Path(roundedRect: collarRect, cornerRadius: 0.01 * u), with: .color(Color(white: 0.38)))

            // Colonna del collo idraulico
            let neckW = 0.088 * u
            let neckTop = -0.49 * u + p.droop * 0.02 * u
            let neckRect = CGRect(x: -neckW / 2, y: neckTop, width: neckW, height: -0.36 * u - neckTop)
            let neckGold = mix(Color(red: 0.92, green: 0.72, blue: 0.18), bottom, 0.30)
            c.fill(Path(roundedRect: neckRect, cornerRadius: 0.015 * u), with: .color(neckGold))
            c.stroke(Path(roundedRect: neckRect, cornerRadius: 0.015 * u), with: .color(Color(white: 0.28)),
                     style: StrokeStyle(lineWidth: max(1, 0.015 * u)))

            // Scanalatura centrale del pistone
            var ridge = Path()
            ridge.move(to: CGPoint(x: 0, y: neckTop + 0.01 * u))
            ridge.addLine(to: CGPoint(x: 0, y: -0.36 * u - 0.01 * u))
            c.stroke(ridge, with: .color(Color(white: 0.22)),
                     style: StrokeStyle(lineWidth: max(1, 0.018 * u), lineCap: .round))

            // Snodo superiore del binocolo
            let swivelRect = CGRect(x: -0.05 * u, y: neckTop - 0.025 * u, width: 0.10 * u, height: 0.035 * u)
            c.fill(Path(roundedRect: swivelRect, cornerRadius: 0.012 * u), with: .color(Color(white: 0.42)))
        }
    }

    private static func buildAvatarBody(avatar: DottAvatar, shape: DottShape, bodyRect: CGRect,
                                        u: Double, bw: Double, bh: Double, t: Double) -> Path {
        switch avatar {
        case .classic:
            switch shape {
            case .blob: return Path(roundedRect: bodyRect, cornerRadius: 0.30 * u, style: .continuous)
            case .tondo: return Path(ellipseIn: bodyRect)
            case .quadro: return Path(roundedRect: bodyRect, cornerRadius: 0.14 * u, style: .continuous)
            }
        case .kitty:
            return Path(roundedRect: bodyRect, cornerRadius: 0.28 * u, style: .continuous)
        case .bear:
            return Path(roundedRect: bodyRect, cornerRadius: 0.33 * u, style: .continuous)
        case .robot:
            return Path(roundedRect: bodyRect, cornerRadius: 0.13 * u, style: .continuous)
        case .ghost:
            var pth = Path()
            let wave = 0.018 * u * sin(t * 3.5)
            pth.move(to: CGPoint(x: -bw / 2, y: -bh * 0.25))
            pth.addCurve(to: CGPoint(x: bw / 2, y: -bh * 0.25),
                         control1: CGPoint(x: -bw / 2, y: -bh * 1.15),
                         control2: CGPoint(x: bw / 2, y: -bh * 1.15))
            pth.addLine(to: CGPoint(x: bw / 2, y: 0.02 * u + wave))
            let step = bw / 3
            pth.addQuadCurve(to: CGPoint(x: bw / 2 - step, y: -0.01 * u - wave),
                             control: CGPoint(x: bw / 2 - step * 0.5, y: -0.05 * u))
            pth.addQuadCurve(to: CGPoint(x: bw / 2 - 2 * step, y: 0.02 * u + wave),
                             control: CGPoint(x: bw / 2 - 1.5 * step, y: -0.05 * u))
            pth.addQuadCurve(to: CGPoint(x: -bw / 2, y: -0.01 * u - wave),
                             control: CGPoint(x: -bw / 2 + step * 0.5, y: -0.05 * u))
            pth.closeSubpath()
            return pth
        case .monster:
            return Path(roundedRect: bodyRect, cornerRadius: 0.31 * u, style: .continuous)
        case .star:
            var starPath = Path()
            let cx = 0.0, cy = -bh * 0.52
            let rOut = 0.39 * u, rIn = 0.24 * u
            let points = 5
            for i in 0..<(points * 2) {
                let angle = -Double.pi / 2 + Double(i) * Double.pi / Double(points)
                let r = i % 2 == 0 ? rOut : rIn
                let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                if i == 0 { starPath.move(to: pt) } else { starPath.addLine(to: pt) }
            }
            starPath.closeSubpath()
            return starPath
        case .walle:
            let cw = 0.58 * u, ch = 0.36 * u
            let bRect = CGRect(x: -cw / 2, y: -ch, width: cw, height: ch)
            return Path(roundedRect: bRect, cornerRadius: 0.07 * u)
        }
    }

    private static func drawAvatarFaceDetails(_ c: GraphicsContext, avatar: DottAvatar, u: Double,
                                              bw: Double, bh: Double, top: Color, bottom: Color, p: Pose,
                                              mood: Mood, t: Double) {
        switch avatar {
        case .kitty:
            let wColor = Color.primary.opacity(0.35)
            let wStyle = StrokeStyle(lineWidth: max(1, 0.022 * u), lineCap: .round)
            for s in [-1.0, 1.0] {
                var w1 = Path()
                w1.move(to: CGPoint(x: s * bw * 0.36, y: -bh * 0.36))
                w1.addLine(to: CGPoint(x: s * bw * 0.54, y: -bh * 0.40))
                c.stroke(w1, with: .color(wColor), style: wStyle)

                var w2 = Path()
                w2.move(to: CGPoint(x: s * bw * 0.36, y: -bh * 0.28))
                w2.addLine(to: CGPoint(x: s * bw * 0.54, y: -bh * 0.25))
                c.stroke(w2, with: .color(wColor), style: wStyle)
            }
            var nose = Path()
            let ny = -bh * 0.35, nw = 0.045 * u, nh = 0.028 * u
            nose.move(to: CGPoint(x: -nw / 2, y: ny))
            nose.addLine(to: CGPoint(x: nw / 2, y: ny))
            nose.addLine(to: CGPoint(x: 0, y: ny + nh))
            nose.closeSubpath()
            c.fill(nose, with: .color(Color(red: 1.0, green: 0.6, blue: 0.72)))
        case .bear:
            let muzzleRect = CGRect(x: -0.12 * u, y: -bh * 0.42, width: 0.24 * u, height: 0.20 * u)
            c.fill(Path(ellipseIn: muzzleRect), with: .color(Color.white.opacity(0.24)))
            let noseRect = CGRect(x: -0.03 * u, y: -bh * 0.38, width: 0.06 * u, height: 0.04 * u)
            c.fill(Path(ellipseIn: noseRect), with: .color(Color(white: 0.25)))
        case .robot:
            let rivetR = 0.016 * u
            let rivetColor = Color.primary.opacity(0.22)
            for s in [-1.0, 1.0] {
                for dy in [-bh * 0.88, -bh * 0.12] {
                    let rRect = CGRect(x: s * bw * 0.40 - rivetR, y: dy - rivetR, width: 2 * rivetR, height: 2 * rivetR)
                    c.fill(Path(ellipseIn: rRect), with: .color(rivetColor))
                }
            }
        case .walle:
            let cw = 0.58 * u, ch = 0.36 * u
            let topH = ch * 0.40
            let topPlateRect = CGRect(x: -cw / 2, y: -ch, width: cw, height: topH)
            let plateBg = Color(red: 0.58, green: 0.56, blue: 0.52)
            c.fill(Path(roundedRect: topPlateRect, cornerRadius: 0.07 * u), with: .color(plateBg))
            var seam = Path()
            seam.move(to: CGPoint(x: -cw / 2, y: -ch + topH))
            seam.addLine(to: CGPoint(x: cw / 2, y: -ch + topH))
            c.stroke(seam, with: .color(Color(white: 0.22)), style: StrokeStyle(lineWidth: max(1, 0.016 * u)))

            // Indicatore di carica solare (Solar Battery Gauge)
            let gw = 0.13 * u, gh = 0.068 * u
            let gx = 0.05 * u, gy = -ch + 0.034 * u
            let gaugeRect = CGRect(x: gx, y: gy, width: gw, height: gh)
            c.fill(Path(roundedRect: gaugeRect, cornerRadius: 0.012 * u), with: .color(Color(white: 0.12)))
            c.stroke(Path(roundedRect: gaugeRect, cornerRadius: 0.012 * u), with: .color(Color(white: 0.25)),
                     style: StrokeStyle(lineWidth: max(1, 0.012 * u)))

            let barCount = 3
            let barPad = 0.007 * u
            let barH = (gh - barPad * Double(barCount + 1)) / Double(barCount)
            let barW = gw - 0.014 * u

            let isSleepingOrDead = mood == .sleeping || p.eyes == .dead || !p.awake
            let isLowPower = p.hurt > 0.3 || p.droop > 0.4 || mood == .hurt

            for i in 0..<barCount {
                let barIndexFromBottom = (barCount - 1) - i
                let bby = gy + barPad + Double(i) * (barH + barPad)
                let barRect = CGRect(x: gx + 0.007 * u, y: bby, width: barW, height: barH)
                let isLit: Bool
                let barColor: Color
                if isSleepingOrDead {
                    isLit = false
                    barColor = Color(white: 0.22)
                } else if isLowPower {
                    isLit = (barIndexFromBottom == 0)
                    barColor = Color(red: 0.95, green: 0.32, blue: 0.20)
                } else {
                    isLit = true
                    barColor = Color(red: 0.98, green: 0.88, blue: 0.22)
                }
                c.fill(Path(roundedRect: barRect, cornerRadius: 0.006 * u), with: .color(isLit ? barColor : Color(white: 0.20)))
            }

            // Indicatori sul pannello superiore: punto rosso e pulsante metallico
            let redDotR = 0.016 * u
            c.fill(Path(ellipseIn: CGRect(x: -0.16 * u - redDotR, y: -ch + 0.068 * u - redDotR, width: 2 * redDotR, height: 2 * redDotR)),
                   with: .color(Color(red: 0.92, green: 0.22, blue: 0.20)))
            let btnW = 0.024 * u
            c.fill(Path(roundedRect: CGRect(x: -0.09 * u - btnW / 2, y: -ch + 0.068 * u - btnW / 2, width: btnW, height: btnW), cornerRadius: 0.006 * u),
                   with: .color(Color(white: 0.40)))

            // Pannello inferiore compattatore: fessura / maniglia nera
            let slotW = 0.22 * u, slotH = 0.040 * u
            let slotRect = CGRect(x: -slotW / 2, y: -0.09 * u, width: slotW, height: slotH)
            c.fill(Path(roundedRect: slotRect, cornerRadius: 0.012 * u), with: .color(Color(white: 0.14)))
            c.stroke(Path(roundedRect: slotRect, cornerRadius: 0.012 * u), with: .color(Color(white: 0.26)),
                     style: StrokeStyle(lineWidth: max(1, 0.012 * u)))

            // Punto rosso luminoso in basso a destra
            let bRedR = 0.022 * u
            c.fill(Path(ellipseIn: CGRect(x: 0.18 * u - bRedR, y: -0.07 * u - bRedR, width: 2 * bRedR, height: 2 * bRedR)),
                   with: .color(Color(red: 0.92, green: 0.20, blue: 0.20)))
            c.fill(Path(ellipseIn: CGRect(x: 0.18 * u - bRedR * 0.3, y: -0.07 * u - bRedR * 0.5, width: bRedR * 0.6, height: bRedR * 0.4)),
                   with: .color(.white.opacity(0.65)))
        case .classic, .ghost, .monster, .star:
            break
        }
    }

    /// Gli occhi dell'umore, con sopra (in dissolvenza) quelli di un eventuale gesto.
    private static func eyesLayer(_ c: GraphicsContext, p: Pose, u: Double, bw: Double, bh: Double, t: Double,
                                  avatar: DottAvatar, dress: Dress, top: Color, bottom: Color) {
        if avatar == .walle {
            drawWalleEyes(c, p: p, u: u, bw: bw, bh: bh, t: t, dress: dress, top: top, bottom: bottom)
            return
        }
        if let e2 = p.eyes2, p.eyes2w > 0.01 {
            var c1 = c; c1.opacity = c.opacity * (1 - p.eyes2w)
            drawEyes(c1, p: p, u: u, bw: bw, bh: bh, t: t)
            var q = p; q.eyes = e2; q.lid = 1; q.blinks = false
            var c2 = c; c2.opacity = c.opacity * p.eyes2w
            drawEyes(c2, p: q, u: u, bw: bw, bh: bh, t: t)
        } else {
            drawEyes(c, p: p, u: u, bw: bw, bh: bh, t: t)
        }
    }

    private static func mouthLayer(_ c: GraphicsContext, p: Pose, u: Double, bh: Double, t: Double, avatar: DottAvatar) {
        guard avatar != .walle else { return }
        if let m2 = p.mouth2, p.mouth2w > 0.01 {
            var c1 = c; c1.opacity = c.opacity * (1 - p.mouth2w)
            drawMouth(c1, p: p, u: u, bh: bh, t: t)
            var q = p; q.mouth = m2
            var c2 = c; c2.opacity = c.opacity * p.mouth2w
            drawMouth(c2, p: q, u: u, bh: bh, t: t)
        } else {
            drawMouth(c, p: p, u: u, bh: bh, t: t)
        }
    }

    // MARK: - WALL-E Occhi binoculari e mimica
    private static func drawWalleEyes(_ c: GraphicsContext, p: Pose, u: Double, bw: Double, bh: Double,
                                      t: Double, dress: Dress, top: Color, bottom: Color) {
        let by = -0.58 * u
        let eyeSpan = 0.145 * u
        let ow = 0.27 * u
        let oh = 0.195 * u

        // Ponte centrale tra i due binocoli
        let bridgeRect = CGRect(x: -0.035 * u, y: by - 0.035 * u, width: 0.07 * u, height: 0.07 * u)
        c.fill(Path(roundedRect: bridgeRect, cornerRadius: 0.018 * u), with: .color(Color(white: 0.28)))
        let boltR = 0.015 * u
        c.fill(Path(ellipseIn: CGRect(x: -boltR, y: by - boltR, width: 2 * boltR, height: 2 * boltR)),
               with: .color(Color(white: 0.48)))

        let effectiveEyes = (p.eyes2 != nil && p.eyes2w > 0.4) ? p.eyes2! : p.eyes

        for s in [-1.0, 1.0] {
            let cx = s * eyeSpan
            let cy = by
            var ec = c
            ec.translateBy(x: cx, y: cy)

            // Inclinazione espressiva: triste piega in giù all'esterno, arrabbiato/allerta piega in giù all'interno
            let droopEffect = p.droop * 0.28
            let alertEffect = p.alert * 0.22
            let tilt = -s * droopEffect + s * alertEffect - s * 0.03
            ec.rotate(by: .radians(tilt))
            ec.scaleBy(x: s, y: 1.0)

            // Scocca esterna del binocolo (geometricamente specchiata)
            var casing = Path()
            casing.move(to: CGPoint(x: -ow * 0.46, y: -oh * 0.44))
            casing.addLine(to: CGPoint(x: ow * 0.40, y: -oh * 0.38))
            casing.addQuadCurve(to: CGPoint(x: ow * 0.49, y: -oh * 0.15), control: CGPoint(x: ow * 0.49, y: -oh * 0.38))
            casing.addLine(to: CGPoint(x: ow * 0.49, y: oh * 0.22))
            casing.addQuadCurve(to: CGPoint(x: ow * 0.32, y: oh * 0.47), control: CGPoint(x: ow * 0.49, y: oh * 0.47))
            casing.addLine(to: CGPoint(x: -ow * 0.36, y: oh * 0.47))
            casing.addQuadCurve(to: CGPoint(x: -ow * 0.48, y: oh * 0.32), control: CGPoint(x: -ow * 0.48, y: oh * 0.47))
            casing.addLine(to: CGPoint(x: -ow * 0.48, y: -oh * 0.30))
            casing.addQuadCurve(to: CGPoint(x: -ow * 0.46, y: -oh * 0.44), control: CGPoint(x: -ow * 0.48, y: -oh * 0.44))
            casing.closeSubpath()

            ec.fill(casing, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.68, green: 0.67, blue: 0.66),
                    Color(red: 0.48, green: 0.47, blue: 0.46)
                ]),
                startPoint: CGPoint(x: 0, y: -oh * 0.46),
                endPoint: CGPoint(x: 0, y: oh * 0.47)
            ))
            ec.stroke(casing, with: .color(Color(red: 0.25, green: 0.25, blue: 0.27)),
                      style: StrokeStyle(lineWidth: max(1.2, 0.024 * u), lineJoin: .round))

            // Visiera / palpebra metallica superiore ("sopracciglio" WALL-E)
            var visor = Path()
            visor.move(to: CGPoint(x: -ow * 0.50, y: -oh * 0.46))
            visor.addLine(to: CGPoint(x: ow * 0.52, y: -oh * 0.39))
            visor.addLine(to: CGPoint(x: ow * 0.50, y: -oh * 0.28))
            visor.addLine(to: CGPoint(x: -ow * 0.50, y: -oh * 0.35))
            visor.closeSubpath()
            ec.fill(visor, with: .color(Color(red: 0.22, green: 0.22, blue: 0.24)))
            ec.stroke(visor, with: .color(Color(white: 0.12)), style: StrokeStyle(lineWidth: max(1, 0.015 * u)))

            // Alloggiamento ottico incassato
            let lw = ow * 0.72, lh = oh * 0.68
            let lensRect = CGRect(x: -ow * 0.34, y: -oh * 0.25, width: lw, height: lh)
            let lensPath = Path(roundedRect: lensRect, cornerRadius: 0.038 * u)
            ec.fill(lensPath, with: .color(Color(red: 0.11, green: 0.11, blue: 0.13)))
            ec.stroke(lensPath, with: .color(Color(red: 0.20, green: 0.20, blue: 0.22)),
                      style: StrokeStyle(lineWidth: max(1, 0.016 * u)))

            // Pupilla / otturatore e sguardo
            let px = (-ow * 0.34 + lw / 2) + p.look.x * s * 0.025 * u
            let py = (-oh * 0.25 + lh / 2) + p.look.y * 0.025 * u

            switch effectiveEyes {
            case .open, .wide:
                var blinkScale = 1.0
                if p.blinks {
                    let ph = t.truncatingRemainder(dividingBy: 3.7)
                    if ph < 0.14 { blinkScale = max(0.08, abs(ph - 0.07) / 0.07) }
                }
                let pr = (effectiveEyes == .wide ? 0.052 : 0.042) * u
                let prH = pr * p.lid * blinkScale
                let pupilRect = CGRect(x: px - pr, y: py - prH, width: 2 * pr, height: 2 * prH)
                ec.fill(Path(ellipseIn: pupilRect), with: .color(Color(white: 0.04)))
                if prH > 0.015 * u {
                    let glintR = 0.014 * u
                    ec.fill(Path(ellipseIn: CGRect(x: px + pr * 0.25 - glintR, y: py - prH * 0.45 - glintR, width: 2 * glintR, height: 2 * glintR)),
                            with: .color(.white.opacity(0.90)))
                    let glint2 = 0.007 * u
                    ec.fill(Path(ellipseIn: CGRect(x: px - pr * 0.30 - glint2, y: py + prH * 0.35 - glint2, width: 2 * glint2, height: 2 * glint2)),
                            with: .color(.white.opacity(0.60)))
                }
            case .happy:
                var arc = Path()
                let aw = 0.065 * u
                arc.move(to: CGPoint(x: px - aw, y: py + 0.016 * u))
                arc.addQuadCurve(to: CGPoint(x: px + aw, y: py + 0.016 * u), control: CGPoint(x: px, y: py - 0.045 * u))
                ec.stroke(arc, with: .color(Color(white: 0.06)), style: StrokeStyle(lineWidth: max(2.2, 0.034 * u), lineCap: .round))
            case .closed:
                var slit = Path()
                let sw = 0.058 * u
                slit.move(to: CGPoint(x: px - sw, y: py))
                slit.addLine(to: CGPoint(x: px + sw, y: py))
                ec.stroke(slit, with: .color(Color(white: 0.12)), style: StrokeStyle(lineWidth: max(1.8, 0.026 * u), lineCap: .round))
            case .dead:
                let dr = 0.038 * u
                var cross = Path()
                cross.move(to: CGPoint(x: px - dr, y: py - dr)); cross.addLine(to: CGPoint(x: px + dr, y: py + dr))
                cross.move(to: CGPoint(x: px + dr, y: py - dr)); cross.addLine(to: CGPoint(x: px - dr, y: py + dr))
                ec.stroke(cross, with: .color(Color(white: 0.06)), style: StrokeStyle(lineWidth: max(2, 0.028 * u), lineCap: .round))
            case .spiral:
                var sp = Path()
                let steps = 24
                for i in 0...steps {
                    let f = Double(i) / Double(steps)
                    let ang = f * 2 * .pi * 2 + t * 6
                    let rad = 0.045 * u * f
                    let pt = CGPoint(x: px + rad * cos(ang), y: py + rad * sin(ang))
                    if i == 0 { sp.move(to: pt) } else { sp.addLine(to: pt) }
                }
                ec.stroke(sp, with: .color(Color(white: 0.06)), style: StrokeStyle(lineWidth: max(1.5, 0.022 * u), lineCap: .round))
            }

            // Ombra di depressione / buio in caso di ferita o dead (Inspo riga 2 #1)
            if p.hurt > 0.4 || effectiveEyes == .dead {
                var shadowPath = Path()
                shadowPath.move(to: CGPoint(x: -ow * 0.48, y: -oh * 0.44))
                shadowPath.addLine(to: CGPoint(x: ow * 0.48, y: -oh * 0.38))
                shadowPath.addLine(to: CGPoint(x: ow * 0.48, y: 0.02 * u))
                shadowPath.addLine(to: CGPoint(x: -ow * 0.48, y: 0.02 * u))
                shadowPath.closeSubpath()
                let shadowGrad = Gradient(colors: [
                    Color(red: 0.18, green: 0.12, blue: 0.32).opacity(0.85),
                    Color(red: 0.18, green: 0.12, blue: 0.32).opacity(0.0)
                ])
                ec.fill(shadowPath, with: .linearGradient(shadowGrad, startPoint: CGPoint(x: 0, y: -oh * 0.44), endPoint: CGPoint(x: 0, y: 0.02 * u)))
            }

            // Lacrime quando piange (Inspo riga 1 #2, #3, riga 2 #5)
            if p.droop > 0.25 || p.hurt > 0.3 {
                let tearColor = Color(red: 0.35, green: 0.82, blue: 1.0, opacity: 0.88)
                var tear = Path()
                let tx = 0.04 * u
                let ty = oh * 0.44
                tear.move(to: CGPoint(x: tx, y: ty))
                tear.addQuadCurve(to: CGPoint(x: tx + 0.025 * u, y: ty + 0.07 * u), control: CGPoint(x: tx + 0.03 * u, y: ty + 0.035 * u))
                tear.addQuadCurve(to: CGPoint(x: tx - 0.025 * u, y: ty + 0.07 * u), control: CGPoint(x: tx, y: ty + 0.095 * u))
                tear.addQuadCurve(to: CGPoint(x: tx, y: ty), control: CGPoint(x: tx - 0.03 * u, y: ty + 0.035 * u))
                tear.closeSubpath()
                ec.fill(tear, with: .color(tearColor))
            }
        }

        // Segni di stress verticali ||| (Inspo riga 2 #1)
        if p.hurt > 0.4 || p.eyes == .dead {
            let strk = StrokeStyle(lineWidth: max(1.5, 0.02 * u), lineCap: .round)
            let col = Color(red: 0.22, green: 0.15, blue: 0.38)
            for i in 0..<3 {
                let lx = -0.29 * u + Double(i) * 0.028 * u
                var lp = Path()
                lp.move(to: CGPoint(x: lx, y: by - 0.16 * u))
                lp.addLine(to: CGPoint(x: lx, y: by - 0.08 * u))
                c.stroke(lp, with: .color(col), style: strk)
            }
        }

        // Cuoricino innamorato (Inspo riga 2 #3)
        if p.cheeks > 0.2 {
            var hp = Path()
            let hx = 0.24 * u, hy = by + 0.03 * u, hs = 0.045 * u * (0.8 + 0.2 * sin(t * 4))
            hp.move(to: CGPoint(x: hx, y: hy + hs * 0.8))
            hp.addCurve(to: CGPoint(x: hx - hs, y: hy), control1: CGPoint(x: hx - hs * 0.8, y: hy + hs * 0.5), control2: CGPoint(x: hx - hs, y: hy + hs * 0.2))
            hp.addCurve(to: CGPoint(x: hx, y: hy - hs * 0.4), control1: CGPoint(x: hx - hs, y: hy - hs * 0.6), control2: CGPoint(x: hx, y: hy - hs * 0.2))
            hp.addCurve(to: CGPoint(x: hx + hs, y: hy), control1: CGPoint(x: hx, y: hy - hs * 0.2), control2: CGPoint(x: hx + hs, y: hy - hs * 0.6))
            hp.addCurve(to: CGPoint(x: hx, y: hy + hs * 0.8), control1: CGPoint(x: hx + hs, y: hy + hs * 0.2), control2: CGPoint(x: hx + hs * 0.8, y: hy + hs * 0.5))
            hp.closeSubpath()
            c.fill(hp, with: .color(Color(red: 0.94, green: 0.18, blue: 0.22)))
        }

        // Occhiali da sole da duro (Inspo riga 1 #4)
        if dress.glasses > 0.01 {
            let gc = faded(c, dress.glasses, rise: 0.04 * u)
            let gy = by - 0.01 * u
            for s in [-1.0, 1.0] {
                let sx = s * eyeSpan
                let sRect = CGRect(x: sx - 0.14 * u, y: gy - 0.09 * u, width: 0.28 * u, height: 0.18 * u)
                gc.fill(Path(roundedRect: sRect, cornerRadius: 0.04 * u), with: .color(Color(white: 0.08)))
                gc.stroke(Path(roundedRect: sRect, cornerRadius: 0.04 * u), with: .color(Color(white: 0.22)), style: StrokeStyle(lineWidth: max(1.5, 0.02 * u)))
                var shine = Path()
                shine.move(to: CGPoint(x: sx - 0.07 * u, y: gy + 0.06 * u))
                shine.addLine(to: CGPoint(x: sx + 0.04 * u, y: gy - 0.06 * u))
                gc.stroke(shine, with: .color(Color.white.opacity(0.35)), style: StrokeStyle(lineWidth: max(1.5, 0.025 * u), lineCap: .round))
            }
            var br = Path()
            br.move(to: CGPoint(x: -0.06 * u, y: gy - 0.04 * u))
            br.addLine(to: CGPoint(x: 0.06 * u, y: gy - 0.04 * u))
            gc.stroke(br, with: .color(Color(white: 0.08)), style: StrokeStyle(lineWidth: max(2, 0.035 * u), lineCap: .round))
        }
    }


    // MARK: la scopa (compattazione)

    /// Un colpo di scopa dura poco piu' di un secondo: da -1 (a sinistra) a +1 (a destra).
    private static func sweepPhase(_ t: Double) -> Double { sin(t * 4.4) }

    fileprivate static func applySweep(_ p: inout Pose, weight w: Double, t: Double) {
        let s = sweepPhase(t)
        p.rot += 0.05 * s * w
        p.dx += 0.018 * s * w
        p.dy -= 0.012 * abs(s) * w
        p.sy *= 1 - 0.025 * w
        p.look = CGPoint(x: p.look.x + (0.7 * s - p.look.x) * w, y: p.look.y + (0.65 - p.look.y) * w)
        p.mouth = .small
    }

    /// La scopa sta davanti al corpo e spazza il pavimento; i pezzetti di troppo scappano a sinistra.
    private static func drawBroom(_ c: GraphicsContext, weight: Double, u: Double, bw: Double, bh: Double, t: Double, wide: Bool) {
        let amp = wide ? 1.0 : 0.5
        let s = sweepPhase(t), ds = cos(t * 4.4)
        let cc = faded(c, weight, rise: 0.06 * u)

        // Pezzetti di memoria che la scopa spinge via.
        for i in 0..<7 {
            let ph = (t * 0.85 + Double(i) / 7).truncatingRemainder(dividingBy: 1)
            let x = bw * 0.30 - ph * bw * 1.35 + 0.02 * u * hash(i)
            let y = -0.02 * u - 0.07 * u * sin(.pi * ph) * (0.4 + hash(i + 3))
            let r = 0.034 * u * (1 - 0.45 * ph) * (0.7 + 0.5 * hash(i + 6))
            var d = cc
            d.opacity = cc.opacity * sin(.pi * ph) * 0.85
            let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
            d.fill(hash(i + 1) > 0.5 ? Path(rect) : Path(ellipseIn: rect),
                   with: .color(hash(i + 2) > 0.45 ? Color.white : Palette.lime))
        }

        // Il manico va dalla mano (in alto a destra) alla testa della scopa, che striscia sul pavimento.
        let head = CGPoint(x: bw * 0.52 + s * 0.09 * u * amp, y: -0.075 * u)
        let top = CGPoint(x: bw * 0.47 + s * 0.03 * u * amp, y: -bh * 1.02)
        var handle = Path()
        handle.move(to: top); handle.addLine(to: head)
        cc.stroke(handle, with: .color(Color(red: 0.62, green: 0.43, blue: 0.24)),
                  style: StrokeStyle(lineWidth: max(1, 0.036 * u), lineCap: .round))

        var b = cc
        b.translateBy(x: head.x, y: head.y)
        b.rotate(by: .radians(atan2(-(head.x - top.x), head.y - top.y)))
        let lag = -ds * 0.05 * u * amp   // le setole restano un po' indietro rispetto al colpo
        var bristles = Path()
        bristles.move(to: CGPoint(x: -0.045 * u, y: 0))
        bristles.addLine(to: CGPoint(x: 0.045 * u, y: 0))
        bristles.addQuadCurve(to: CGPoint(x: 0.105 * u + lag, y: 0.17 * u), control: CGPoint(x: 0.09 * u, y: 0.09 * u))
        bristles.addLine(to: CGPoint(x: -0.105 * u + lag, y: 0.17 * u))
        bristles.addQuadCurve(to: CGPoint(x: -0.045 * u, y: 0), control: CGPoint(x: -0.09 * u, y: 0.09 * u))
        bristles.closeSubpath()
        b.fill(bristles, with: .linearGradient(Gradient(colors: [Color(red: 0.96, green: 0.80, blue: 0.42), Color(red: 0.80, green: 0.58, blue: 0.22)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: 0.17 * u)))
        for k in [-0.5, 0.0, 0.5] {
            var line = Path()
            line.move(to: CGPoint(x: k * 0.07 * u, y: 0.06 * u)); line.addLine(to: CGPoint(x: k * 0.17 * u + lag, y: 0.16 * u))
            b.stroke(line, with: .color(Color(red: 0.62, green: 0.42, blue: 0.16).opacity(0.55)),
                     style: StrokeStyle(lineWidth: max(0.5, 0.012 * u), lineCap: .round))
        }
        // Il laccio che stringe le setole.
        b.fill(Path(roundedRect: CGRect(x: -0.062 * u, y: -0.004 * u, width: 0.124 * u, height: 0.036 * u), cornerRadius: 0.014 * u),
               with: .color(Palette.lime.opacity(0.95)))
    }

    // MARK: accessori e vestiti

    private static func faded(_ c: GraphicsContext, _ weight: Double, rise: Double) -> GraphicsContext {
        var cc = c
        cc.opacity = c.opacity * weight
        cc.translateBy(x: 0, y: -(1 - weight) * rise)
        return cc
    }

    /// La matita: sta dietro al corpo, spunta con la gomma.
    private static func drawPencil(_ c: GraphicsContext, weight: Double, u: Double, bw: Double, bh: Double) {
        var cc = faded(c, weight, rise: 0.08 * u)
        cc.translateBy(x: bw * 0.34, y: -bh * 0.90)
        cc.rotate(by: .radians(0.55))
        cc.fill(Path(roundedRect: CGRect(x: -0.024 * u, y: -0.14 * u, width: 0.048 * u, height: 0.30 * u), cornerRadius: 0.01 * u),
                with: .color(Color(red: 1.0, green: 0.80, blue: 0.20)))
        cc.fill(Path(roundedRect: CGRect(x: -0.024 * u, y: -0.19 * u, width: 0.048 * u, height: 0.05 * u), cornerRadius: 0.012 * u),
                with: .color(Color(red: 1.0, green: 0.55, blue: 0.62)))
        cc.fill(Path(CGRect(x: -0.024 * u, y: -0.145 * u, width: 0.048 * u, height: 0.018 * u)),
                with: .color(Color(white: 0.75)))
    }

    // swiftlint:disable:next function_body_length
    // swiftlint:disable:next function_body_length
    private static func drawDress(_ c: GraphicsContext, dress: Dress, u: Double, bw: Double, bh: Double, body: Path, avatar: DottAvatar = .classic) {
        let headFree = 1 - max(dress.helmet, dress.headphones)
        let hatLift = avatar == .walle ? 0.06 * u : 0.0

        // sciarpa: segue la forma del corpo
        if dress.scarf > 0 {
            var cc = faded(c, dress.scarf, rise: 0.04 * u)
            cc.clip(to: body)
            let red = Color(red: 0.86, green: 0.18, blue: 0.24)
            let scarfY = avatar == .walle ? -0.36 * u * 0.40 : -bh * 0.115
            cc.fill(Path(CGRect(x: -bw / 2, y: scarfY, width: bw, height: 0.085 * u)), with: .color(red))
            for dx in [-0.20, 0.0, 0.20] {
                cc.fill(Path(CGRect(x: bw * dx - 0.012 * u, y: scarfY, width: 0.024 * u, height: 0.085 * u)),
                        with: .color(.white.opacity(0.85)))
            }
            cc.fill(Path(roundedRect: CGRect(x: bw * 0.14, y: scarfY + 0.05 * u, width: 0.085 * u, height: 0.12 * u), cornerRadius: 0.02 * u),
                    with: .color(red))
        }

        // occhiali (per WALL-E disegnati custom sopra i binocoli in drawWalleEyes)
        if dress.glasses > 0 && avatar != .walle {
            let cc = faded(c, dress.glasses, rise: 0.05 * u)
            let r = 0.115 * u, ex = bw * 0.22, ey = -bh * 0.60
            let frame = StrokeStyle(lineWidth: 0.028 * u, lineCap: .round)
            for s in [-1.0, 1.0] {
                let lens = Path(ellipseIn: CGRect(x: s * ex - r, y: ey - r, width: 2 * r, height: 2 * r))
                cc.fill(lens, with: .color(.white.opacity(0.14)))
                cc.stroke(lens, with: .color(ink), style: frame)
                var temple = Path()
                temple.move(to: CGPoint(x: s * (ex + r), y: ey - 0.01 * u))
                temple.addLine(to: CGPoint(x: s * (bw / 2 - 0.005 * u), y: ey - 0.03 * u))
                cc.stroke(temple, with: .color(ink), style: frame)
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: -ex + r, y: ey)); bridge.addQuadCurve(to: CGPoint(x: ex - r, y: ey), control: CGPoint(x: 0, y: ey - 0.03 * u))
            cc.stroke(bridge, with: .color(ink), style: frame)
        }

        // cuffie
        if dress.headphones > 0 {
            let cc = faded(c, dress.headphones, rise: 0.08 * u)
            var band = Path()
            band.move(to: CGPoint(x: -bw * 0.47, y: -bh * 0.50))
            band.addQuadCurve(to: CGPoint(x: bw * 0.47, y: -bh * 0.50), control: CGPoint(x: 0, y: -bh * 1.62))
            cc.stroke(band, with: .color(Color(white: 0.22)), style: StrokeStyle(lineWidth: 0.05 * u, lineCap: .round))
            for s in [-1.0, 1.0] {
                let cup = CGRect(x: s * bw * 0.50 - 0.045 * u, y: -bh * 0.50 - 0.10 * u, width: 0.09 * u, height: 0.20 * u)
                cc.fill(Path(roundedRect: cup, cornerRadius: 0.035 * u), with: .color(Color(white: 0.92)))
                cc.fill(Path(roundedRect: cup.insetBy(dx: 0.02 * u, dy: 0.04 * u), cornerRadius: 0.02 * u), with: .color(Color(white: 0.35)))
            }
        }

        // casco da cantiere
        if dress.helmet > 0 {
            var cc = faded(c, dress.helmet, rise: 0.10 * u)
            cc.translateBy(x: 0, y: -hatLift)
            let yellow = Color(red: 1.0, green: 0.78, blue: 0.15)
            var dome = Path()
            dome.move(to: CGPoint(x: -bw * 0.46, y: -bh * 0.82))
            dome.addQuadCurve(to: CGPoint(x: bw * 0.46, y: -bh * 0.82), control: CGPoint(x: 0, y: -bh * 1.55))
            dome.closeSubpath()
            cc.fill(dome, with: .linearGradient(Gradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.35), yellow]),
                                                 startPoint: CGPoint(x: 0, y: -bh * 1.2), endPoint: CGPoint(x: 0, y: -bh * 0.82)))
            cc.fill(Path(roundedRect: CGRect(x: -bw * 0.53, y: -bh * 0.86, width: bw * 1.06, height: 0.05 * u), cornerRadius: 0.025 * u),
                    with: .color(Color(red: 0.95, green: 0.65, blue: 0.10)))
            cc.fill(Path(roundedRect: CGRect(x: -0.022 * u, y: -bh * 1.17, width: 0.044 * u, height: bh * 0.30), cornerRadius: 0.02 * u),
                    with: .color(Color(red: 0.95, green: 0.65, blue: 0.10).opacity(0.7)))
        }

        // cappello di Babbo Natale
        if dress.santa > 0 {
            var cc = faded(c, dress.santa * headFree, rise: 0.10 * u)
            cc.translateBy(x: -bw * 0.04, y: -bh * 0.92 - hatLift)
            cc.rotate(by: .radians(-0.22))
            var cone = Path()
            cone.move(to: CGPoint(x: -bw * 0.36, y: -0.02 * u))
            cone.addQuadCurve(to: CGPoint(x: bw * 0.34, y: -0.34 * u), control: CGPoint(x: -bw * 0.18, y: -0.32 * u))
            cone.addLine(to: CGPoint(x: bw * 0.36, y: -0.02 * u))
            cone.closeSubpath()
            cc.fill(cone, with: .color(Color(red: 0.88, green: 0.15, blue: 0.20)))
            cc.fill(Path(ellipseIn: CGRect(x: bw * 0.34 - 0.045 * u, y: -0.34 * u - 0.045 * u, width: 0.09 * u, height: 0.09 * u)), with: .color(.white))
            cc.fill(Path(roundedRect: CGRect(x: -bw * 0.40, y: -0.045 * u, width: bw * 0.80, height: 0.09 * u), cornerRadius: 0.045 * u), with: .color(.white))
        }

        // cappello da strega
        if dress.witch > 0 {
            var cc = faded(c, dress.witch * headFree, rise: 0.10 * u)
            cc.translateBy(x: 0, y: -bh * 0.92 - hatLift)
            cc.rotate(by: .radians(0.12))
            let purple = Color(red: 0.30, green: 0.14, blue: 0.46)
            var cone = Path()
            cone.move(to: CGPoint(x: -bw * 0.28, y: 0))
            cone.addQuadCurve(to: CGPoint(x: bw * 0.10, y: -0.42 * u), control: CGPoint(x: -bw * 0.05, y: -0.22 * u))
            cone.addLine(to: CGPoint(x: bw * 0.28, y: 0))
            cone.closeSubpath()
            cc.fill(cone, with: .color(purple))
            cc.fill(Path(CGRect(x: -bw * 0.28, y: -0.06 * u, width: bw * 0.56, height: 0.05 * u)), with: .color(Color(red: 0.98, green: 0.55, blue: 0.12)))
            cc.fill(Path(ellipseIn: CGRect(x: -bw * 0.50, y: -0.03 * u, width: bw, height: 0.07 * u)), with: .color(purple))
        }

        // cappellino di compleanno
        if dress.party > 0 {
            var cc = faded(c, dress.party * headFree, rise: 0.10 * u)
            cc.translateBy(x: bw * 0.10, y: -bh * 0.94 - hatLift)
            cc.rotate(by: .radians(0.20))
            var cone = Path()
            cone.move(to: CGPoint(x: -0.10 * u, y: 0)); cone.addLine(to: CGPoint(x: 0, y: -0.28 * u)); cone.addLine(to: CGPoint(x: 0.10 * u, y: 0))
            cone.closeSubpath()
            cc.fill(cone, with: .color(Color(red: 1.0, green: 0.45, blue: 0.70)))
            for (i, y) in [-0.05, -0.12, -0.19].enumerated() {
                cc.fill(Path(CGRect(x: -0.07 * u + 0.02 * u * Double(i), y: y * u, width: 0.14 * u - 0.04 * u * Double(i), height: 0.025 * u)),
                        with: .color(.white.opacity(0.85)))
            }
            cc.fill(Path(ellipseIn: CGRect(x: -0.035 * u, y: -0.31 * u, width: 0.07 * u, height: 0.07 * u)), with: .color(Color(red: 1.0, green: 0.85, blue: 0.2)))
        }
    }

    private static func drawEyes(_ ctx: GraphicsContext, p: Pose, u: Double, bw: Double, bh: Double, t: Double) {
        let c = ctx
        let eyeY = -bh * 0.60
        let eyeX = bw * 0.22
        var ew = 0.125 * u, eh = 0.18 * u
        if p.eyes == .wide { ew = 0.15 * u; eh = 0.22 * u }
        if p.blinks {
            let ph = t.truncatingRemainder(dividingBy: 3.7)
            if ph < 0.14 { eh *= max(0.08, abs(ph - 0.07) / 0.07) }
        }
        let lw = max(1, 0.035 * u)
        for s in [-1.0, 1.0] {
            let cx = s * eyeX + p.look.x * 0.075 * u
            let cy = eyeY + p.look.y * 0.05 * u
            switch p.eyes {
            case .open, .wide:
                // La palpebra scende dall'alto: occhio piu' basso e schiacciato finche' non e' sveglio.
                let h2 = eh * p.lid
                let cy2 = cy + eh * (1 - p.lid) * 0.3
                let rect = CGRect(x: cx - ew / 2, y: cy2 - h2 / 2, width: ew, height: h2)
                c.fill(Path(ellipseIn: rect), with: .color(ink))
                let g = 0.035 * u
                c.fill(Path(ellipseIn: CGRect(x: cx - ew * 0.05, y: cy2 - h2 * 0.34, width: g, height: g)),
                       with: .color(.white.opacity(h2 < 0.1 * u ? 0 : 0.9 * p.lid)))
            case .closed:
                var a = Path()
                a.move(to: CGPoint(x: cx - ew * 0.9, y: cy - 0.01 * u))
                a.addQuadCurve(to: CGPoint(x: cx + ew * 0.9, y: cy - 0.01 * u),
                               control: CGPoint(x: cx, y: cy + ew * 1.4))
                c.stroke(a, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .happy:
                var a = Path()
                a.move(to: CGPoint(x: cx - ew * 0.95, y: cy + 0.02 * u))
                a.addQuadCurve(to: CGPoint(x: cx + ew * 0.95, y: cy + 0.02 * u),
                               control: CGPoint(x: cx, y: cy - ew * 1.5))
                c.stroke(a, with: .color(ink), style: StrokeStyle(lineWidth: lw * 1.15, lineCap: .round))
            case .spiral:
                var a = Path()
                let steps = 36
                for i in 0...steps {
                    let f = Double(i) / Double(steps)
                    let ang = f * 2.3 * 2 * .pi + t * 7 * (s > 0 ? 1 : -1)
                    let r = ew * (0.08 + 0.62 * f)
                    let pt = CGPoint(x: cx + r * cos(ang), y: cy + r * sin(ang))
                    if i == 0 { a.move(to: pt) } else { a.addLine(to: pt) }
                }
                c.stroke(a, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round, lineJoin: .round))
            case .dead:
                let r = ew * 0.7
                var a = Path()
                a.move(to: CGPoint(x: cx - r, y: cy - r)); a.addLine(to: CGPoint(x: cx + r, y: cy + r))
                a.move(to: CGPoint(x: cx + r, y: cy - r)); a.addLine(to: CGPoint(x: cx - r, y: cy + r))
                c.stroke(a, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
        }
    }

    private static func drawMouth(_ ctx: GraphicsContext, p: Pose, u: Double, bh: Double, t: Double) {
        let c = ctx
        let my = -bh * 0.27
        let mx = p.look.x * 0.012 * u
        let lw = max(1, 0.035 * u)
        let ms = StrokeStyle(lineWidth: lw, lineCap: .round)
        switch p.mouth {
        case .none:
            let r = 0.018 * u * (1 + 0.4 * sin(t * 1.6))
            c.fill(Path(ellipseIn: CGRect(x: -r, y: my - r, width: 2 * r, height: 2 * r)), with: .color(ink.opacity(0.75)))
        case .flat:
            var m = Path(); m.move(to: CGPoint(x: mx - 0.045 * u, y: my)); m.addLine(to: CGPoint(x: mx + 0.045 * u, y: my))
            c.stroke(m, with: .color(ink), style: ms)
        case .small:
            var m = Path(); m.move(to: CGPoint(x: mx - 0.05 * u, y: my - 0.005 * u))
            m.addQuadCurve(to: CGPoint(x: mx + 0.05 * u, y: my - 0.005 * u), control: CGPoint(x: mx, y: my + 0.05 * u))
            c.stroke(m, with: .color(ink), style: ms)
        case .smile:
            var m = Path(); m.move(to: CGPoint(x: mx - 0.07 * u, y: my - 0.01 * u))
            m.addQuadCurve(to: CGPoint(x: mx + 0.07 * u, y: my - 0.01 * u), control: CGPoint(x: mx, y: my + 0.09 * u))
            c.stroke(m, with: .color(ink), style: ms)
        case .grin:
            var m = Path(); m.move(to: CGPoint(x: -0.09 * u, y: my - 0.02 * u))
            m.addQuadCurve(to: CGPoint(x: 0.09 * u, y: my - 0.02 * u), control: CGPoint(x: 0, y: my + 0.17 * u))
            m.closeSubpath()
            c.fill(m, with: .color(ink))
        case .o:
            let r = 0.04 * u * (1 + 0.15 * sin(t * 6))
            c.fill(Path(ellipseIn: CGRect(x: mx - r, y: my - r * 1.1, width: 2 * r, height: 2.4 * r)), with: .color(ink))
        case .yawn:
            let rw = 0.045 * u * (0.6 + 0.8 * p.yawn), rh = 0.015 * u + 0.075 * u * p.yawn
            c.fill(Path(ellipseIn: CGRect(x: mx - rw, y: my - rh * 0.6, width: 2 * rw, height: 2 * rh)), with: .color(ink))
        case .wavy:
            var m = Path()
            m.move(to: CGPoint(x: -0.08 * u, y: my))
            for i in 1...8 {
                let f = Double(i) / 8
                m.addLine(to: CGPoint(x: -0.08 * u + 0.16 * u * f, y: my + 0.018 * u * sin(f * .pi * 4)))
            }
            c.stroke(m, with: .color(ink), style: ms)
        }
    }

    // MARK: effetti

    private static func hash(_ i: Int) -> Double {
        let v = sin(Double(i) * 12.9898) * 43758.5453
        return v - floor(v)
    }

    /// Decorazioni dei gesti: stelline che girano attorno alla testa, cuoricini per le fusa.
    private static func drawGestureEffects(_ ctx: GraphicsContext, kind: GestureKind, u: Double, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let env = sin(.pi * min(max(u, 0), 1))
        switch kind {
        case .dizzy:
            var c = ctx
            c.opacity = ctx.opacity * min(1, env * 2)
            for i in 0..<3 {
                let ang = t * 5 + Double(i) * 2 * .pi / 3
                let x = w * 0.5 + w * 0.26 * cos(ang), y = h * 0.20 + h * 0.06 * sin(ang)
                let r = h * 0.045
                var star = Path()
                star.move(to: CGPoint(x: x, y: y - r)); star.addLine(to: CGPoint(x: x + r * 0.3, y: y - r * 0.3))
                star.addLine(to: CGPoint(x: x + r, y: y)); star.addLine(to: CGPoint(x: x + r * 0.3, y: y + r * 0.3))
                star.addLine(to: CGPoint(x: x, y: y + r)); star.addLine(to: CGPoint(x: x - r * 0.3, y: y + r * 0.3))
                star.addLine(to: CGPoint(x: x - r, y: y)); star.addLine(to: CGPoint(x: x - r * 0.3, y: y - r * 0.3))
                star.closeSubpath()
                c.fill(star, with: .color(Palette.amber))
            }
        case .purr:
            for i in 0..<3 {
                let ph = (u * 2.2 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                var c = ctx
                c.opacity = ctx.opacity * sin(.pi * ph) * env
                c.draw(Text("♥").font(.system(size: h * (0.11 + 0.03 * Double(i % 2)), weight: .heavy))
                        .foregroundColor(Color(red: 1, green: 0.55, blue: 0.7)),
                       at: CGPoint(x: w * (0.22 + 0.28 * Double(i)) + w * 0.03 * sin(ph * 6), y: h * (0.30 - 0.24 * ph)), anchor: .center)
            }
        case .sneeze:
            // Una nuvoletta di polvere parte dal viso, con un "Etciu'!".
            guard u > 0.5 else { break }
            let q = min(1, (u - 0.5) / 0.32)
            for i in 0..<9 {
                let ang = -0.55 + 0.9 * hash(i)
                let dist = w * (0.10 + 0.40 * q) * (0.55 + 0.7 * hash(i + 4))
                let x = w * 0.58 + dist * cos(ang), y = h * 0.74 + dist * sin(ang) * 0.9 - h * 0.05 * q
                let r = h * 0.032 * (1 - 0.6 * q) * (0.6 + hash(i + 8))
                var c = ctx
                c.opacity = ctx.opacity * (1 - q) * 0.9
                c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                       with: .color(i % 3 == 0 ? Palette.lime : Color.white))
            }
            var c = ctx
            c.opacity = ctx.opacity * smooth(0.5, 0.56, u) * (1 - smooth(0.78, 0.92, u))
            c.draw(Text("Etciù!").font(.system(size: h * 0.15, weight: .heavy, design: .rounded)).foregroundColor(.white),
                   at: CGPoint(x: w * 0.74, y: h * (0.30 - 0.05 * q)), anchor: .center)
        case .whistle:
            for i in 0..<3 {
                let ph = (u * 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                var c = ctx
                c.opacity = ctx.opacity * sin(.pi * ph) * env * 0.9
                c.draw(Text(i % 2 == 0 ? "♪" : "♫").font(.system(size: h * 0.17, weight: .bold, design: .rounded)).foregroundColor(.white),
                       at: CGPoint(x: w * (0.72 + 0.12 * sin(ph * 5 + Double(i))), y: h * (0.50 - 0.38 * ph)), anchor: .center)
            }
        case .chase:
            let f = fireflyPos(u)
            let fade = smooth(0.02, 0.12, u) * (1 - smooth(0.9, 1, u))
            let x = w * (0.5 + 0.38 * f.x), y = h * (0.44 + 0.25 * f.y)
            let glow = 0.75 + 0.25 * sin(t * 12)
            var c = ctx
            c.opacity = ctx.opacity * fade
            for (r, a) in [(0.12, 0.10), (0.075, 0.22)] {
                c.fill(Path(ellipseIn: CGRect(x: x - h * r, y: y - h * r, width: 2 * h * r, height: 2 * h * r)),
                       with: .color(Palette.amber.opacity(a * glow)))
            }
            let r = h * 0.03
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(Color(red: 1, green: 0.95, blue: 0.6)))
        default:
            break
        }
    }

    /// Note musicali che salgono quando suona qualcosa.
    private static func drawMusic(_ ctx: GraphicsContext, groove: Double, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        for i in 0..<2 {
            let ph = (t * 0.45 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            var c = ctx
            c.opacity = ctx.opacity * sin(.pi * ph) * groove * 0.85
            c.draw(Text(i == 0 ? "♪" : "♫").font(.system(size: h * 0.16, weight: .bold, design: .rounded)).foregroundColor(.white),
                   at: CGPoint(x: w * (0.86 + 0.06 * sin(ph * 5 + Double(i))), y: h * (0.42 - 0.32 * ph)), anchor: .center)
        }
    }

    private static func drawEffects(_ ctx: inout GraphicsContext, size: CGSize, mood: Mood, t: Double, dy: Double) {
        let w = size.width, h = size.height

        switch mood {
        case .sleeping:
            // Ogni tanto sogna: una bollicina con un cuore che sale.
            let L = 24.0
            let dph = t.truncatingRemainder(dividingBy: L)
            if dph > L * 0.25, dph < L * 0.46 {
                let d = (dph - L * 0.25) / (L * 0.21)
                var c = ctx
                c.opacity = ctx.opacity * sin(.pi * d) * 0.9
                let rise = d * 0.06
                for (i, r) in [0.022, 0.032].enumerated() {
                    let q = CGPoint(x: w * (0.80 + 0.06 * Double(i)), y: h * (0.26 - 0.08 * Double(i) - rise))
                    c.fill(Path(ellipseIn: CGRect(x: q.x - h * r, y: q.y - h * r, width: 2 * h * r, height: 2 * h * r)),
                           with: .color(.white.opacity(0.7)))
                }
                c.draw(Text("♥").font(.system(size: h * 0.20, weight: .heavy, design: .rounded))
                        .foregroundColor(Color(red: 1, green: 0.55, blue: 0.7)),
                       at: CGPoint(x: w * 0.93, y: h * (0.10 - rise)), anchor: .center)
            }
            for i in 0..<2 {
                let ph = (t * 0.32 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                var c = ctx
                c.opacity = ctx.opacity * sin(ph * .pi) * 0.85
                let s = h * (0.13 + 0.07 * Double(i))
                c.draw(Text("z").font(.system(size: s, weight: .heavy, design: .rounded)).foregroundColor(.white),
                       at: CGPoint(x: w * (0.74 + 0.10 * ph), y: h * (0.30 - 0.22 * ph)), anchor: .center)
            }
        case .thinking:
            for i in 0..<3 {
                let a = 0.30 + 0.70 * max(0, sin(t * 4 - Double(i) * 0.9))
                let r = h * (0.028 + 0.016 * Double(i))
                let p = CGPoint(x: w * (0.78 + 0.075 * Double(i)), y: h * (0.27 - 0.085 * Double(i)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(a)))
            }
        case .writing:
            for i in 0..<4 {
                let ph = (t * 3.2 + hash(i) * 3).truncatingRemainder(dividingBy: 1)
                let r = h * 0.022 * (1 - ph)
                let p = CGPoint(x: w * (0.84 + 0.1 * hash(i + 9)), y: h * (0.78 - 0.34 * ph))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Palette.lime.opacity(1 - ph)))
            }
        case .running:
            for i in 0..<3 {
                let ph = (t * 3.6 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                var line = Path()
                let y = h * (0.52 + 0.12 * Double(i))
                let x = w * (0.18 - 0.16 * ph)
                line.move(to: CGPoint(x: x, y: y)); line.addLine(to: CGPoint(x: x - w * 0.12, y: y))
                ctx.stroke(line, with: .color(.white.opacity(0.55 * (1 - ph))),
                           style: StrokeStyle(lineWidth: max(1, h * 0.022), lineCap: .round))
            }
        case .searching:
            let cx = w * 0.84 + w * 0.03 * sin(t * 2), cy = h * 0.30
            let r = h * 0.075
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white.opacity(0.85)), lineWidth: max(1, h * 0.026))
            var hnd = Path()
            hnd.move(to: CGPoint(x: cx + r * 0.7, y: cy + r * 0.7))
            hnd.addLine(to: CGPoint(x: cx + r * 1.7, y: cy + r * 1.7))
            ctx.stroke(hnd, with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: max(1, h * 0.03), lineCap: .round))
        case .waiting:
            let pulse = 1 + 0.12 * sin(t * 8.4)
            var c = ctx
            c.translateBy(x: w * 0.86, y: h * 0.20 + dy * 0.4)
            c.scaleBy(x: pulse, y: pulse)
            c.draw(Text("!").font(.system(size: h * 0.34, weight: .heavy, design: .rounded)).foregroundColor(Palette.amber),
                   at: .zero, anchor: .center)
        case .happy:
            let colors: [Color] = [Palette.amber, Palette.lime, .white, Color(red: 1, green: 0.55, blue: 0.7)]
            for i in 0..<9 {
                let ph = (t * 0.85 + hash(i) * 2).truncatingRemainder(dividingBy: 1)
                let x = w * (0.5 + (hash(i + 3) - 0.5) * 1.0)
                let y = h * (0.62 - ph * 0.55)
                var c = ctx
                c.opacity = ctx.opacity * (1 - ph)
                c.translateBy(x: x, y: y)
                c.rotate(by: .radians(ph * 8 + hash(i)))
                let s = h * 0.035
                c.fill(Path(CGRect(x: -s, y: -s * 0.5, width: 2 * s, height: s)), with: .color(colors[i % colors.count]))
            }
        case .hurt:
            let drop = h * 0.05
            let ph = t.truncatingRemainder(dividingBy: 1.2) / 1.2
            var c = ctx
            c.opacity = ctx.opacity * (1 - ph * 0.6)
            var d = Path()
            let p = CGPoint(x: w * 0.2, y: h * (0.26 + 0.14 * ph))
            d.move(to: CGPoint(x: p.x, y: p.y - drop))
            d.addQuadCurve(to: CGPoint(x: p.x, y: p.y + drop * 0.6), control: CGPoint(x: p.x + drop * 1.2, y: p.y + drop * 0.5))
            d.addQuadCurve(to: CGPoint(x: p.x, y: p.y - drop), control: CGPoint(x: p.x - drop * 1.2, y: p.y + drop * 0.5))
            c.fill(d, with: .color(Color(red: 0.5, green: 0.8, blue: 1)))
        case .reading, .working:
            break
        }
    }
}
