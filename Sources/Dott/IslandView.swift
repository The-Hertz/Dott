import SwiftUI

/// Su quale schermo sta l'isola e con quale geometria (la notch cambia da schermo a schermo).
struct ScreenContext {
    let id: UInt32?
    let geometry: NotchGeometry
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    /// Senza indicazione: lo schermo principale di Dott.
    let screen: ScreenContext?

    init(model: IslandModel, screen: ScreenContext? = nil) {
        self.model = model
        self.screen = screen
    }

    private var g: NotchGeometry { screen?.geometry ?? model.geometry }
    private var expandedHere: Bool { model.isExpanded(on: screen?.id) }
    private var islandSize: CGSize { model.computeSize(g, expanded: expandedHere) }
    /// Il colore di Dott e' l'accento di tutta l'isola: se cambia nelle impostazioni, si ridisegna.
    @ObservedObject private var settings = AppSettings.shared

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)

    var body: some View {
        let size = islandSize
        let tr = IslandModel.topRadius
        let shape = NotchShape(topRadius: tr, bottomRadius: expandedHere ? 26 : 12)

        ZStack(alignment: .topLeading) {
            shape.fill(Color.black)
            content
                .frame(width: size.width - 2 * tr, height: size.height, alignment: .topLeading)
                .padding(.leading, tr)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { model.focus() }
        .contextMenu {
            Button {
                NotificationCenter.default.post(name: Notification.Name("dott.openSettings"), object: nil)
            } label: {
                Label("Impostazioni…", systemImage: "gearshape")
            }
            Divider()
            Menu("Cambia personaggio") {
                ForEach(DottAvatar.allCases) { av in
                    Button {
                        AppSettings.shared.avatar = av
                    } label: {
                        HStack {
                            if settings.avatar == av {
                                Image(systemName: "checkmark")
                            }
                            Text(av.label)
                        }
                    }
                }
            }
            Divider()
            Button {
                DesktopCompanion.shared.detach(model: model)
            } label: {
                Label("Porta Dott sul desktop", systemImage: "arrow.down.forward.and.arrow.up.backward")
            }
            Divider()
            Button("Esci da Dott") {
                NSApplication.shared.terminate(nil)
            }
        }
        .animation(spring, value: size)
        .animation(spring, value: expandedHere)
        .animation(spring, value: model.version)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    // MARK: contenuto

    private var content: some View {
        let ear = model.earWidth
        let bodyW = islandSize.width - 2 * IslandModel.topRadius
        let expanded = expandedHere
        let blocking = !model.permissions.isEmpty || !model.questions.isEmpty || !model.elicitations.isEmpty
        // Con l'hub aperto le proposte del Manager stanno dentro la sua conversazione: la scheda nel notch serve solo a hub chiuso.
        let hubShown = expanded && model.hubOpen && !model.hubWindowed && !blocking
        let hasPermission = blocking || (!model.dispatches.isEmpty && !hubShown)

        let mascotSize: CGFloat = expanded ? (hasPermission ? 44 : 60) : g.notchHeight - 8
        // Piu' progetti: a isola chiusa i Dott fanno gruppetto nell'orecchio sinistro, quello in primo piano davanti.
        let companions = Array(model.otherDotts.prefix(2))
        let step: CGFloat = 15
        let huddle = CGFloat(companions.count) * step
        let mascotCenter: CGPoint = expanded
            ? CGPoint(x: 20 + mascotSize / 2, y: g.notchHeight + (hasPermission ? 14 : 12) + mascotSize / 2)
            : CGPoint(x: ear / 2 + 2 - huddle / 2, y: g.notchHeight / 2)

        return ZStack(alignment: .topLeading) {
            if expanded {
                if !hubShown { header }
                if let item = model.permissions.first {
                    Group {
                        if item.tool == "ExitPlanMode" { PlanBody(model: model, item: item) }
                        else { PermissionBody(model: model, item: item) }
                    }
                    .padding(.top, g.notchHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if let q = model.questions.first {
                    QuestionBody(model: model, state: q)
                        .id(q.id.uuidString + "-\(q.index)")
                        .padding(.top, g.notchHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if let el = model.elicitations.first {
                    ElicitationBody(model: model, state: el)
                        .id(el.id)
                        .padding(.top, g.notchHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if let d = model.dispatches.first, !hubShown {
                    DispatchBody(model: model, batch: d)
                        .padding(.top, g.notchHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if hubShown {
                    HubView(model: model, windowed: false, notchHeight: g.notchHeight, notchWidth: g.notchWidth)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                } else if let r = model.recap {
                    RecapBody(recap: r)
                        .padding(.top, g.notchHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else {
                    statusBody
                        .padding(.top, g.notchHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            } else {
                indicator
                    .frame(width: ear, height: g.notchHeight)
                    .position(x: bodyW - ear / 2 - 2, y: g.notchHeight / 2)
                    .transition(.opacity)
            }

            if !expanded {
                ForEach(Array(companions.enumerated()), id: \.element.id) { i, d in
                    MascotView(mood: d.mood, size: mascotSize, effects: false, offset: 1.7 * Double(i + 1),
                               tint: (d.color.top, d.color.bottom), accessory: d.accessory, outfit: model.outfit)
                        .position(x: mascotCenter.x + step * CGFloat(i + 1), y: mascotCenter.y)
                        .zIndex(-Double(i + 1))
                        .transition(.opacity)
                }
            }

            MascotView(mood: model.mood, size: mascotSize, effects: expanded,
                       gazeFrom: CGPoint(x: g.screenFrame.midX - islandSize.width / 2 + IslandModel.topRadius + mascotCenter.x,
                                         y: g.screenFrame.maxY - mascotCenter.y),
                       attentive: model.hovering || model.recap != nil, following: model.cursorNear,
                       gesture: model.gesture, night: model.night,
                       accessory: model.accessory, outfit: model.outfit, music: model.musicPlaying && AppSettings.shared.danceToMusic)
                .contentShape(Rectangle())
                // Un tocco lo fa ridere o saltare, due tocchi una giravolta, tenerlo premuto le fusa.
                .onTapGesture(count: 2) { model.poke(double: true) }
                .onTapGesture { model.poke() }
                .onLongPressGesture(minimumDuration: 0.55) { model.trigger(.purr) }
                // Trascinandolo fuori dall'isola, Dott esce sul desktop.
                .simultaneousGesture(DragGesture(minimumDistance: 30).onChanged { v in
                    if AppSettings.shared.desktopCompanion, !model.detached, hypot(v.translation.width, v.translation.height) > 40 {
                        DesktopCompanion.shared.detach(model: model)
                    }
                })
                .opacity(model.detached || hubShown ? 0 : 1)
                .allowsHitTesting(!model.detached && !hubShown)
                .position(mascotCenter)
        }
    }

    /// Riga alta dell'isola: ai lati del notch fisico.
    private var header: some View {
        let sessions = model.sessions.values.filter { !$0.id.hasPrefix("preview") }.count
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                ((model.leadDottName.map { Text($0).foregroundStyle(.white.opacity(0.8)) + Text(" · ") } ?? Text(""))
                    + Text(model.lead?.project ?? model.commandName ?? ""))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                if let badge = ModeBadge.from(model.lead?.permissionMode) {
                    HStack(spacing: 3) {
                        Image(systemName: badge.symbol).font(.system(size: 9, weight: .bold))
                        if let t = badge.text { Text(t).font(.system(size: 9, weight: .bold, design: .rounded)) }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(badge.solid ? Palette.ink : badge.color)
                    .background(Capsule().fill(badge.solid ? badge.color : badge.color.opacity(0.18)))
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: g.notchWidth)
            HStack(spacing: 8) {
                Button { model.openHub() } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Apri l’hub dei Dott")
                if let f = model.lead?.contextFraction {
                    HStack(spacing: 4) {
                        ContextRing(fraction: f, size: 12, line: 2)
                        Text("\(Int((f * 100).rounded()))%").monospacedDigit().contentTransition(.numericText())
                    }
                }
                if let start = model.lead?.turnStart, model.mood != .happy {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text(IslandModel.format(tl.date.timeIntervalSince(start)))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                } else if sessions > 1 {
                    Text("\(sessions) sessioni")
                }

                Button {
                    NotificationCenter.default.post(name: Notification.Name("dott.openSettings"), object: nil)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Impostazioni di Dott")
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 18)
        .frame(height: g.notchHeight)
        .transition(.opacity)
    }

    private var statusBody: some View {
        VStack(spacing: 0) {
            statusRow
            if model.commandKey != nil { AskRow(model: model) }
            if AppSettings.shared.showGitHub, let pr = model.lead?.pr { RepoChip(info: pr) }
            if let np = model.nowPlaying { NowPlayingBar(info: np, model: model) }
            HelperList(helpers: model.leadHelpers, avatar: settings.avatar)
            TodoSection(todos: model.lead?.todos ?? [])
            ProjectList(model: model)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Color.clear.frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.lead?.headline ?? model.mood.title)
                    .contentTransition(.opacity)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.mood.accent == .white.opacity(0.35) ? Color.white : model.mood.accent)
                Text(model.lead?.detail ?? "Nessuna sessione di Claude attiva")
                    .contentTransition(.opacity)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(2)
                if model.mood == .happy, let sn = model.lead?.snippet {
                    Text("“\(sn)”")
                        .font(.system(size: 12).italic())
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(height: (model.mood == .happy && model.lead?.snippet != nil) ? 118 : 84, alignment: .center)
    }

    /// Orecchio destro, a isola chiusa: un simbolo che dice cosa sta succedendo,
    /// con un anello che mostra quanto contesto ha usato la sessione.
    private var indicator: some View {
        let count = model.sessions.values.filter { !$0.id.hasPrefix("preview") }.count
        let agents = model.totalAgents
        let frac = model.lead?.contextFraction
        return HStack(spacing: 3) {
            if agents > 0 {
                Helpers(helpers: model.helpers, size: 15, overlap: 3, avatar: settings.avatar)
            } else {
                ZStack {
                    if let frac { ContextRing(fraction: frac, size: 22, line: 2) }
                    if model.mood != .sleeping {
                        Image(systemName: model.mood.symbol)
                            .contentTransition(.symbolEffect(.replace))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(model.mood.accent)
                            .symbolEffect(.pulse, isActive: model.mood == .waiting || model.mood == .thinking)
                    }
                }
            }
            if count > 1 {
                Text("\(count)")
                    .contentTransition(.numericText())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Anello del contesto: pieno man mano che la sessione si riempie.
struct ContextRing: View {
    let fraction: Double
    let size: CGFloat
    let line: CGFloat

    private var color: Color {
        fraction < 0.6 ? Palette.lime : (fraction < 0.85 ? Palette.amber : Palette.coral)
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

// MARK: - Cosa mi sono perso

private struct RecapBody: View {
    let recap: Recap

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear.frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text(recap.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.lime)
                    .padding(.top, 4)
                ForEach(Array(recap.lines.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 8) {
                        Image(systemName: l.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(l.symbol == "xmark.octagon" || l.symbol == "exclamationmark.triangle" ? Palette.coral
                                             : (l.symbol == "hourglass" ? Palette.amber : Palette.lime))
                            .frame(width: 16)
                        Text(l.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    .frame(height: 20)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Ramo e pull request

private struct RepoChip: View {
    let info: PRInfo

    private var ci: (text: String, color: Color)? {
        switch info.ci {
        case .passing: ("CI ok", Palette.lime)
        case .failing: ("CI fallita", Palette.coral)
        case .pending: ("CI in corso", Palette.amber)
        case .none: nil
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 60)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                Text(info.branch ?? "").lineLimit(1)
                if let n = info.number {
                    Text("·"); Text("PR #\(n)")
                }
                if let ci {
                    Circle().fill(ci.color).frame(width: 6, height: 6)
                    Text(ci.text).foregroundStyle(ci.color)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 22)
    }
}

// MARK: - Musica in riproduzione

/// Barra del brano in riproduzione: titolo, artista e controlli di riproduzione.
private struct NowPlayingBar: View {
    let info: NowPlayingInfo
    @ObservedObject var model: IslandModel

    private var sourceIcon: String {
        info.source == "Music" ? "music.note" : "antenna.radiowaves.left.and.right"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Icona sorgente
            Image(systemName: sourceIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.lime.opacity(0.8))
                .frame(width: 60)

            // Info brano
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(info.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Controlli di riproduzione
            HStack(spacing: 2) {
                Button { model.musicWatcher?.previousTrack() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MusicControlStyle())

                Button { model.musicWatcher?.togglePlayPause() } label: {
                    Image(systemName: info.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.lime.opacity(0.22)))
                        .contentShape(Circle())
                }
                .buttonStyle(MusicControlStyle())

                Button { model.musicWatcher?.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MusicControlStyle())
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }
}

/// Stile per i bottoncini dei controlli musicali: un po' di feedback visivo al tocco.
private struct MusicControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Modalita' dei permessi

/// L'etichetta della modalita' con cui gira la sessione (si vede soprattutto se e' pericolosa).
struct ModeBadge {
    let symbol: String
    let text: String?
    let color: Color
    let solid: Bool

    static func from(_ mode: String?) -> ModeBadge? {
        switch mode ?? "" {
        case "plan": return ModeBadge(symbol: "list.bullet.clipboard", text: nil, color: Palette.lime, solid: false)
        case "acceptEdits": return ModeBadge(symbol: "pencil", text: nil, color: Palette.amber, solid: false)
        case "bypassPermissions": return ModeBadge(symbol: "exclamationmark.shield.fill", text: "BYPASS", color: Palette.coral, solid: true)
        case "dontAsk": return ModeBadge(symbol: "hand.raised.slash", text: nil, color: Palette.amber, solid: false)
        case "auto": return ModeBadge(symbol: "bolt.fill", text: nil, color: Palette.amber, solid: false)
        default: return nil
        }
    }
}

// MARK: - Compiti

/// L'avanzamento della lista di Claude: una barra e i prossimi compiti.
private struct TodoSection: View {
    let todos: [TodoItem]

    var body: some View {
        if !todos.isEmpty {
            let done = todos.filter { $0.status == .completed }.count
            let open = todos.filter { $0.status != .completed }
            let shown = Array((open.filter { $0.status == .inProgress } + open.filter { $0.status == .pending }).prefix(3))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Text("\(done)/\(todos.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 60)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(Palette.lime)
                                .frame(width: g.size.width * CGFloat(done) / CGFloat(max(todos.count, 1)))
                        }
                    }
                    .frame(height: 4)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: done)
                }
                .frame(height: 26)
                ForEach(shown) { t in
                    HStack(spacing: 14) {
                        Image(systemName: t.status == .inProgress ? "arrow.right.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(t.status == .inProgress ? Palette.lime : .white.opacity(0.3))
                            .frame(width: 60)
                        Text(t.status == .inProgress ? (t.active ?? t.text) : t.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(t.status == .inProgress ? 0.9 : 0.5))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 20)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }
}

// MARK: - Altri progetti

/// Gli altri progetti attivi: ognuno ha il suo Dott, che lavora per conto suo. Un tocco lo porta in primo piano.
private struct ProjectList: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let rows = model.otherDotts.filter { !$0.sessionId.hasPrefix("preview") }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.bottom, 6)
                ForEach(Array(rows.prefix(4).enumerated()), id: \.element.id) { i, d in
                    HStack(spacing: 0) {
                        Button { model.selectProject(d.id) } label: {
                            HStack(spacing: 14) {
                                MascotView(mood: d.mood, size: 36, effects: false, offset: 1.7 * Double(i + 1),
                                           tint: (d.color.top, d.color.bottom), accessory: d.accessory, outfit: model.outfit)
                                    .frame(width: 60, height: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    (Text(d.dottName).foregroundStyle(.white.opacity(0.92))
                                        + Text("  \(d.name)").font(.system(size: 11.5, weight: .regular)).foregroundStyle(.white.opacity(0.45)))
                                        .contentTransition(.opacity)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(1)
                                    Text(d.mood == .sleeping ? "In attesa di te" : (d.detail.isEmpty ? d.mood.title : d.detail))
                                        .contentTransition(.opacity)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(d.mood == .waiting ? Palette.amber : .white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if d.agents > 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "person.2.fill").font(.system(size: 9))
                                        Text("\(d.agents)").monospacedDigit()
                                    }
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                }
                                if let f = d.contextFraction {
                                    ContextRing(fraction: f, size: 12, line: 2)
                                }
                            }
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        Button { model.focus(d.sessionId) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 30, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        .help("Apri il terminale di questo progetto")
                    }
                    .transition(.opacity)
                }
                if rows.count > 4 {
                    Text("+\(rows.count - 4) altri")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 74)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .padding(.top, 8)
        }
    }
}

// MARK: - Aiutanti

/// A isola chiusa: i puntini degli aiutanti, ognuno col suo colore.
private struct Helpers: View {
    let helpers: [Helper]
    let size: CGFloat
    var overlap: CGFloat = 4
    let avatar: DottAvatar

    var body: some View {
        if !helpers.isEmpty {
            HStack(spacing: -overlap) {
                ForEach(Array(helpers.prefix(4).enumerated()), id: \.element.id) { i, h in
                    MascotView(mood: h.mood, size: size, effects: false, offset: Double(i) * 0.37,
                               tint: Palette.helper(h.colorIndex), avatar: avatar)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
                if helpers.count > 4 {
                    Text("+\(helpers.count - 4)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.leading, overlap + 2)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: helpers.count)
        }
    }
}

/// A isola aperta: gli aiutanti appesi sotto Dott, lungo la stessa linea, un filo li unisce.
/// Per ognuno: il compito, e a destra cosa sta facendo adesso.
private struct HelperList: View {
    let helpers: [Helper]
    let avatar: DottAvatar
    private let rowHeight: CGFloat = 34
    private let gap: CGFloat = 4

    var body: some View {
        if !helpers.isEmpty {
            let shown = Array(helpers.prefix(4).enumerated())
            ZStack(alignment: .topLeading) {
                // il filo che parte da Dott
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: 1.5, height: CGFloat(shown.count) * (rowHeight + gap) - gap * 0.5 + 6)
                    .offset(x: 30 - 0.75, y: -6)

                VStack(alignment: .leading, spacing: gap) {
                    ForEach(shown, id: \.element.id) { i, h in
                        let c = Palette.helper(h.colorIndex)
                        HStack(spacing: 14) {
                            MascotView(mood: h.mood, size: 24, effects: false, offset: Double(i) * 0.37,
                                       tint: c, avatar: avatar)
                                .frame(width: 60)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.task)
                                    .contentTransition(.opacity)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                Text(h.activity)
                                    .contentTransition(.opacity)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(c.top.opacity(0.9))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: rowHeight)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                    if helpers.count > 4 {
                        Text("+\(helpers.count - 4) altri")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 74)
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: helpers.count)
        }
    }
}

// MARK: - Domanda di Claude

private struct QuestionBody: View {
    @ObservedObject var model: IslandModel
    let state: QuestionState

    var body: some View {
        let spec = state.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Color.clear.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.header.isEmpty ? "Claude ti chiede" : spec.header.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(Palette.amber)
                    Text(spec.text)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if state.specs.count > 1 {
                    Text("\(state.index + 1)/\(state.specs.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(minHeight: 48, alignment: .top)

            ForEach(spec.options, id: \.self) { opt in
                Button { model.pick(state.id, opt.label) } label: {
                    HStack(spacing: 10) {
                        if spec.multi {
                            Image(systemName: state.selected.contains(opt.label) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(state.selected.contains(opt.label) ? Palette.lime : .white.opacity(0.35))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(opt.label)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            if !opt.detail.isEmpty {
                                Text(opt.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(state.selected.contains(opt.label) ? Palette.lime.opacity(0.18) : .white.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }

            if state.typing {
                FreeTextRow(model: model, id: state.id)
            } else {
                HStack(spacing: 14) {
                    Button("Rispondi nel terminale") { model.askInTerminal(state.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.45))
                    Button("Altro…") { model.beginFreeText(state.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if spec.multi {
                        Button(state.index + 1 < state.specs.count ? "Avanti" : "Invia") { model.confirmMulti(state.id) }
                            .buttonStyle(IslandButton(fill: state.selected.isEmpty ? .white.opacity(0.10) : Palette.lime,
                                                      text: state.selected.isEmpty ? .white.opacity(0.35) : Palette.ink))
                            .disabled(state.selected.isEmpty)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .frame(height: 34)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Scrivi a un Dott: una riga e Invio. L'app Claude si apre su una chat nuova, nella cartella del suo progetto,
/// con la tua richiesta gia' scritta (la mandi tu). Cosi' tutto resta nell'app, con la sua storia.
struct AskRow: View {
    @ObservedObject var model: IslandModel
    /// Il Dott a cui parla la riga: nil = quello in primo piano.
    var key: String? = nil
    @State private var text = ""
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A chi si scrive, a parole: "Birba", "il Designer di Birba", "il Manager".
    private var addressee: String {
        if let k = model.target(key), let role = AgentRegistry.role(forKey: k) {
            return role == .manager ? "al Manager" : "al \(role.agentTitle)"
        }
        return "a \(model.dottName(for: key))"
    }

    var body: some View {
        Group {
            if model.composing { composer } else { idle }
        }
        .padding(.horizontal, 20)
        .frame(height: IslandModel.commandRowHeight)
        .transition(.opacity)
    }

    private var chat: (id: String, title: String)? { model.chatTarget(key) }
    /// Il Manager e gli agenti hanno una chat sola: niente "nuova chat".
    private var isRole: Bool { model.target(key).flatMap(AgentRegistry.role(forKey:)) != nil }

    private var idle: some View {
        Button { text = ""; model.beginCompose(key: key) } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                Text("Chiedi \(addressee)…")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 6)
                if let c = chat {
                    Text(c.title).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.28)).lineLimit(1)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(chat.map { "Scrive nella chat «\($0.title)»" } ?? "Apre una chat nuova")
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(chat.map { "Nella chat «\($0.title)»" } ?? "Cosa facciamo?", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { send(newChat: chat == nil && !isRole) }
                .onExitCommand { model.cancelCompose() }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12)))
            Button(chat == nil ? (isRole ? "Apri chat" : "Nuova chat") : "Invia") { send(newChat: chat == nil && !isRole) }
                .buttonStyle(IslandButton(fill: empty ? .white.opacity(0.10) : Palette.lime,
                                          text: empty ? .white.opacity(0.35) : Palette.ink))
                .disabled(empty)
            if chat != nil && !isRole {
                Button { send(newChat: true) } label: {
                    Image(systemName: "plus.bubble").font(.system(size: 12))
                        .foregroundStyle(empty ? .white.opacity(0.25) : .white.opacity(0.7))
                        .frame(width: 30, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(empty)
                .help("Apri invece una chat nuova")
            }
            Button { model.cancelCompose() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45)).frame(width: 22, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            text = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    private func send(newChat: Bool) {
        guard !empty else { return }
        model.ask(text, key: key, newChat: newChat)
    }
}

/// Risposta libera: una riga di testo, Invio per mandare.
private struct FreeTextRow: View {
    @ObservedObject var model: IslandModel
    let id: UUID
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Scrivi la tua risposta", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { model.submitFreeText(id, text) }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.10)))
            Button("Annulla") { model.cancelFreeText(id) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Button("Invia") { model.submitFreeText(id, text) }
                .buttonStyle(IslandButton(fill: text.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.10) : Palette.lime,
                                          text: text.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.35) : Palette.ink))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(height: 34)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Piano da approvare

private struct PlanBody: View {
    @ObservedObject var model: IslandModel
    let item: PermissionItem

    private func inline(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
    }

    /// Markdown a righe: titoli, elenchi puntati e numerati, il resto in linea.
    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Color.clear.frame(height: 4)
        } else if t.hasPrefix("#") {
            Text(inline(t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 2)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(Palette.lime)
                Text(inline(String(t.dropFirst(2))))
            }
        } else {
            Text(inline(t))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Il piano è pronto")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.amber)
                    Text("Leggilo e decidi")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(item.preview.components(separatedBy: "\n").enumerated()), id: \.offset) { _, l in
                        line(l)
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 148)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))

            HStack(spacing: 8) {
                Button("Rifiuta") { model.resolve(item, .deny) }
                    .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: Palette.coral))
                Spacer(minLength: 0)
                Button("Approva") { model.resolve(item, .allow) }
                    .buttonStyle(IslandButton(fill: Palette.lime, text: Palette.ink))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Richiesta di permesso

private struct PermissionBody: View {
    @ObservedObject var model: IslandModel
    let item: PermissionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? "Posso usare \(item.tool)?")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.amber)
                    Text(item.subtitle ?? "Claude chiede il permesso")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                if model.permissions.count > 1 {
                    Text("+\(model.permissions.count - 1) in coda")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Text(item.preview.isEmpty ? " " : item.preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))

            if AppSettings.shared.globalShortcuts {
                Text("⌃⌥Y consenti · ⌃⌥N nega")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, -4)
            }
            HStack(spacing: 8) {
                Button(item.denyLabel ?? "Nega") { model.resolve(item, .deny) }
                    .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: Palette.coral))
                Spacer(minLength: 0)
                if !item.suggestions.isEmpty {
                    Button("Consenti sempre") { model.resolve(item, .always) }
                        .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: .white))
                }
                Button(item.allowLabel ?? "Consenti") { model.resolve(item, .allow) }
                    .buttonStyle(IslandButton(fill: Palette.lime, text: Palette.ink))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Modulo di un server MCP

private struct ElicitationBody: View {
    @ObservedObject var model: IslandModel
    let state: ElicState
    @State private var text: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(state.server) chiede un dato")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.amber)
                    Text(state.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if state.mode == "url", let u = state.url {
                Text(u)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            } else {
                ForEach(state.fields.prefix(3)) { f in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title + (f.required ? " *" : ""))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        field(f)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Rifiuta") { model.declineElicitation(state.id) }
                    .buttonStyle(IslandButton(fill: .white.opacity(0.10), text: Palette.coral))
                Button("Terminale") { model.elicitationInTerminal(state.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                if state.mode == "url" {
                    Button("Apri e conferma") { model.openElicitationURL(state.id) }
                        .buttonStyle(IslandButton(fill: Palette.lime, text: Palette.ink))
                } else {
                    Button("Invia") { model.submitElicitation(state.id, text: text, flags: flags) }
                        .buttonStyle(IslandButton(fill: Palette.lime, text: Palette.ink))
                }
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            for f in state.fields {
                text[f.id] = f.initialText
                flags[f.id] = f.initialFlag
            }
            if let first = state.fields.first(where: { $0.kind == .text || $0.kind == .number || $0.kind == .integer }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = first.id }
            }
        }
    }

    @ViewBuilder
    private func field(_ f: ElicField) -> some View {
        switch f.kind {
        case .bool:
            Toggle(isOn: Binding(get: { flags[f.id] ?? false }, set: { flags[f.id] = $0 })) {
                Text(f.help ?? f.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
            .toggleStyle(.switch).controlSize(.small)
        case .choice:
            HStack(spacing: 6) {
                ForEach(f.options.prefix(4), id: \.self) { o in
                    let on = (text[f.id] ?? f.initialText) == o
                    Button(o) { text[f.id] = o }
                        .buttonStyle(IslandButton(fill: on ? Palette.lime : .white.opacity(0.10), text: on ? Palette.ink : .white))
                }
            }
        case .text, .number, .integer:
            TextField(f.help ?? "", text: Binding(get: { text[f.id] ?? "" }, set: { text[f.id] = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($focused, equals: f.id)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.10)))
                .onSubmit { model.submitElicitation(state.id, text: text, flags: flags) }
        }
    }
}

struct IslandButton: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
