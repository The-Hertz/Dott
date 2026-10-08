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
                        HStack(spacing: 10) {
                            TextField(g.name, text: Binding(get: { roster.name(for: g.key) },
                                                            set: { roster.rename(g.key, to: $0) }))
                                .frame(width: 120)
                            Picker("", selection: Binding(get: { roster.color(for: g.key) },
                                                          set: { roster.recolor(g.key, to: $0) })) {
                                ForEach(DottColor.allCases) { c in
                                    HStack {
                                        Circle().fill(LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: .bottom))
                                            .frame(width: 12, height: 12)
                                        Text(c.label)
                                    }.tag(c)
                                }
                            }
                            .labelsHidden()
                            Text(g.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
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
