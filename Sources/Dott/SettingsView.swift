import SwiftUI

/// La finestra delle impostazioni: com'e' fatto Dott e come si comporta.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var soundsOn = Sounds.enabled

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            // anteprima
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black)
                    MascotView(mood: .working, size: 130, effects: true,
                               accessory: settings.accessories ? .glasses : nil,
                               outfit: settings.outfit(on: Date()),
                               avatar: settings.avatar)
                }
                .frame(width: 170, height: 170)
                Text(settings.name.isEmpty ? "Dott" : settings.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }

            Form {
                Section("Aspetto") {
                    TextField("Nome", text: $settings.name)
                        .onChange(of: settings.name) { _, v in if v.count > 14 { settings.name = String(v.prefix(14)) } }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Personaggio").font(.system(size: 13, weight: .medium))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(DottAvatar.allCases) { av in
                                    Button {
                                        settings.avatar = av
                                    } label: {
                                        VStack(spacing: 4) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(settings.avatar == av ? settings.color.top.opacity(0.22) : Color.white.opacity(0.06))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                            .stroke(settings.avatar == av ? settings.color.top : Color.white.opacity(0.12), lineWidth: 1.5)
                                                    )
                                                MascotView(mood: .happy, size: 28, effects: false, avatar: av)
                                                    .frame(width: 36, height: 36)
                                            }
                                            .frame(width: 46, height: 46)
                                            Text(av.label)
                                                .font(.system(size: 10, weight: settings.avatar == av ? .semibold : .regular))
                                                .foregroundStyle(settings.avatar == av ? .white : .white.opacity(0.75))
                                                .lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }

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

                    if settings.avatar == .classic {
                        Picker("Forma", selection: $settings.shape) {
                            ForEach(DottShape.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Antennina", isOn: $settings.antenna)
                    }
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
