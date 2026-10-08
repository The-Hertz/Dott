import SwiftUI

/// La finestra delle impostazioni: com'e' fatto Dott e come si comporta.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var roster = DottRoster.shared
    @State private var soundsOn = Sounds.enabled

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            // anteprima
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black)
                    MascotView(mood: .working, size: 130, effects: true,
                               accessory: settings.accessories ? .glasses : nil,
                               outfit: settings.outfit(on: Date()))
                }
                .frame(width: 170, height: 170)
                Text(settings.name.isEmpty ? "Dott" : settings.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }

            Form {
                Section("Aspetto del Dott libero") {
                    TextField("Nome", text: $settings.name)
                        .onChange(of: settings.name) { _, v in if v.count > 14 { settings.name = String(v.prefix(14)) } }

                    Picker("Colore", selection: $settings.color) {
                        ForEach(DottColor.allCases) { c in
                            HStack {
                                Circle().fill(LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 12, height: 12)
                                Text(c.label)
                            }.tag(c)
                        }
                    }
                    Toggle("Un colore diverso per ogni progetto", isOn: $settings.projectColors)
                    Picker("Forma", selection: $settings.shape) {
                        ForEach(DottShape.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Antennina", isOn: $settings.antenna)
                }

                // Un Dott per progetto (gruppo dell'app Claude): nome e colore si scelgono qui.
                Section("I Dott dei progetti") {
                    let groups = ProjectResolver.shared.groups()
                    if groups.isEmpty {
                        Text("Appaiono qui quando l'app Claude ha dei gruppi.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.key) { g in
                        DottSettingsRow(roster: roster, key: g.key, project: g.name)
                    }
                    Text("Il nome e il colore sopra («Aspetto») sono quelli del Dott libero, che segue le chat senza gruppo.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Personalità") {
                    Toggle("Accessori mentre lavora (occhiali, matita, cuffie, casco)", isOn: $settings.accessories)
                    Toggle("Vestiti di stagione", isOn: $settings.seasonal)
                    Toggle("Cappellino nel mio compleanno", isOn: $settings.birthdayEnabled)
                    if settings.birthdayEnabled {
                        DatePicker("Compleanno", selection: $settings.birthday, displayedComponents: .date)
                    }
                }

                Section("Schermi") {
                    Picker("Mostra Dott su", selection: $settings.displayMode) {
                        ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Sui monitor senza notch l'isola appare come una pillola attaccata al bordo alto.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Richieste") {
                    Toggle("Invia subito la richiesta nella chat (altrimenti la incollo e premi Invio tu)", isOn: $settings.autoSendAsk)
                    Toggle("Riporta al Manager le risposte degli agenti", isOn: $settings.returnToManager)
                    Text("Vale per «Chiedi a…» quando continua una chat esistente. In una chat nuova la richiesta resta scritta, da inviare.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Extra") {
                    Toggle("Balla quando suona Music o Spotify", isOn: $settings.danceToMusic)
                    Toggle("Mostra ramo git, pull request e CI", isOn: $settings.showGitHub)
                    Toggle("Scorciatoie globali (⌃⌥Y consenti · ⌃⌥N nega · ⌃⌥Spazio apri · ⌃⌥M silenzio)", isOn: $settings.globalShortcuts)
                    Toggle("Trascina Dott fuori dall'isola, sul desktop", isOn: $settings.desktopCompanion)
                }

                Section("Conferme dal notch") {
                    Toggle("Chiedi conferma quando Claude cambia modello", isOn: $settings.confirmModelSwitch)
                    Toggle("Avvisami se le impostazioni cambiano durante una sessione", isOn: $settings.watchConfig)
                }

                Section("Suoni") {
                    Toggle("Suoni", isOn: $soundsOn)
                        .onChange(of: soundsOn) { _, v in Sounds.enabled = v }
                }
            }
            .formStyle(.grouped)
            .frame(width: 400, height: 640)
        }
        .padding(20)
        .frame(width: 640)
    }
}


/// Le impostazioni di un Dott: nome, colore, ruolo, carattere e la cartella in cui lavora.
private struct DottSettingsRow: View {
    @ObservedObject var roster: DottRoster
    let key: String
    let project: String
    @State private var refresh = 0

    private var folder: String? { ProjectResolver.shared.folder(for: key) }

    var body: some View {
        let _ = refresh
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("", text: Binding(get: { roster.name(for: key) }, set: { roster.rename(key, to: $0) }), prompt: Text(project))
                    .labelsHidden()
                    .frame(width: 120)
                Picker("", selection: Binding(get: { roster.color(for: key) }, set: { roster.recolor(key, to: $0) })) {
                    ForEach(DottColor.allCases) { c in
                        HStack {
                            Circle().fill(LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: .bottom))
                                .frame(width: 12, height: 12)
                            Text(c.label)
                        }.tag(c)
                    }
                }
                .labelsHidden()
                Text(project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                Text("Ruolo").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Picker("", selection: Binding(get: { roster.role(for: key) }, set: { roster.setRole(key, $0) })) {
                    ForEach(DottRole.assignable) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden().frame(width: 140)
                Text("Carattere").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Picker("", selection: Binding(get: { roster.trait(for: key) }, set: { roster.setTrait(key, $0) })) {
                    Text("Neutro").tag(DottTrait?.none)
                    ForEach(DottTrait.allCases) { Text($0.label).tag(DottTrait?.some($0)) }
                }
                .labelsHidden().frame(width: 110)
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folder.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Cartella non trovata")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(folder == nil ? Color.orange : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Scegli…") { choose() }
                if ProjectResolver.shared.isCustomFolder(key) {
                    Button("Automatica") { ProjectResolver.shared.setFolder(key, to: nil); refresh += 1; roster.objectWillChange.send() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scegli"
        panel.message = "La cartella in cui lavora \(roster.name(for: key)) (\(project))"
        if let f = folder { panel.directoryURL = URL(fileURLWithPath: f) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProjectResolver.shared.setFolder(key, to: url.path)
        refresh += 1
        roster.objectWillChange.send()
    }
}
