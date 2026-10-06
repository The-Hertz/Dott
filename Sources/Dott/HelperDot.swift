import SwiftUI

/// Un aiutante: un puntino luminoso con due occhietti. Piu' piccolo e piu' semplice di Dott,
/// cosi' si capisce subito che e' un suo aiutante.
struct HelperDot: View {
    var mood: Mood
    var size: CGFloat
    var color: (top: Color, bottom: Color)
    var offset = 0.0

    @State private var gaze = GazeSmoother()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { tl in
            Canvas { ctx, sz in
                let t = tl.date.timeIntervalSinceReferenceDate + offset
                let w = sz.width, h = sz.height
                let r = min(w, h) * 0.30
                let bob = sin(t * 2.4) * h * 0.035
                let c = CGPoint(x: w / 2, y: h / 2 + bob)

                // bagliore
                let g = r * 2.1
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                         with: .radialGradient(Gradient(colors: [color.top.opacity(0.42), color.top.opacity(0)]),
                                               center: c, startRadius: r * 0.6, endRadius: g))
                // corpo
                let body = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: body),
                         with: .linearGradient(Gradient(colors: [color.top, color.bottom]),
                                               startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))

                guard size >= 14 else { return }
                // occhi: guardano dove sta lavorando
                var look = CGPoint.zero
                switch mood {
                case .reading: look = CGPoint(x: sin(t * 2.2), y: 0.2)
                case .writing: look = CGPoint(x: 0.3 * sin(t * 3), y: 0.8)
                case .running: look = CGPoint(x: 0.8, y: 0)
                case .searching: look = CGPoint(x: cos(t * 1.7), y: 0.5 * sin(t * 2.3))
                case .thinking: look = CGPoint(x: 0.6 * sin(t), y: -0.8)
                default: look = CGPoint(x: 0.3 * sin(t * 1.1), y: 0.2)
                }
                look = gaze.update(target: look, weight: 1, now: t).0   // lo sguardo scivola da un umore all'altro
                let ex = r * 0.38, ey = r * 0.12
                let ew = r * 0.24, eh = r * (mood == .thinking ? 0.34 : 0.40)
                let blink = t.truncatingRemainder(dividingBy: 3.1) < 0.12 ? 0.15 : 1.0
                for s in [-1.0, 1.0] {
                    let p = CGPoint(x: c.x + s * ex + look.x * r * 0.10, y: c.y - ey + look.y * r * 0.09)
                    if mood == .hurt {
                        var x = Path()
                        let k = ew * 0.8
                        x.move(to: CGPoint(x: p.x - k, y: p.y - k)); x.addLine(to: CGPoint(x: p.x + k, y: p.y + k))
                        x.move(to: CGPoint(x: p.x + k, y: p.y - k)); x.addLine(to: CGPoint(x: p.x - k, y: p.y + k))
                        ctx.stroke(x, with: .color(Palette.ink), style: StrokeStyle(lineWidth: max(1, r * 0.14), lineCap: .round))
                    } else {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - ew / 2, y: p.y - eh * blink / 2, width: ew, height: eh * blink)),
                                 with: .color(Palette.ink))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}
