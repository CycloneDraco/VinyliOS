import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var spotify: SpotifyAuth
    @Environment(\.dismiss) private var dismiss
    @State private var appleMusicDenied = false

    var body: some View {
        NavigationStack {
            Form {
                musicSection
                sceneSection
                if prefs.scene == .sleeve { lookSection }
                displaySection
                liveActivitySection
                widgetSection
                Section {
                    Picker("Energy", selection: $prefs.energy) {
                        ForEach(EnergyMode.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(prefs.energy.detail)
                }
                aboutSection
            }
            .navigationTitle("Vinyl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var musicSection: some View {
        Section {
            if spotify.isConnected {
                LabeledContent("Spotify") {
                    Text(spotify.accountName.map { "Connected as \($0)" } ?? "Connected")
                        .foregroundStyle(.secondary)
                }
                Button("Disconnect Spotify", role: .destructive) { spotify.disconnect() }
            } else {
                Button {
                    Task { await spotify.connect() }
                } label: {
                    Label("Connect Spotify", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            if let error = spotify.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Toggle(isOn: Binding(
                get: { prefs.appleMusicEnabled },
                set: { wanted in
                    guard wanted else { prefs.appleMusicEnabled = false; return }
                    Task {
                        let granted = await AppleMusicSource.requestAccess()
                        prefs.appleMusicEnabled = granted
                        appleMusicDenied = !granted
                    }
                }
            )) {
                Label("Apple Music", systemImage: "music.note")
            }
            if appleMusicDenied {
                Text("Allow Vinyl under Settings → Privacy & Security → Media & Apple Music.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if spotify.isConnected && prefs.appleMusicEnabled {
                Picker("Show", selection: $prefs.source) {
                    ForEach(SourcePreference.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Music")
        } footer: {
            Text("Spotify works whichever device it plays on (phone, Mac, speaker), so this can be a display for music playing anywhere. Play, pause and skip need Spotify Premium; showing the album doesn't. Apple Music covers the Music app on this device.")
        }
    }

    private var sceneSection: some View {
        Section("Scene") {
            ForEach(VinylScene.allCases) { scene in
                Button {
                    prefs.scene = scene
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: scene.symbol)
                            .font(.title3)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene.title).foregroundStyle(.primary)
                            Text(scene.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if prefs.scene == scene {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            if prefs.scene.usesRenderer {
                VStack(alignment: .leading) {
                    Text("Size")
                    Slider(value: Binding(get: { prefs.currentSize }, set: { prefs.currentSize = $0 }), in: 0...1) {
                        Text("Size")
                    } minimumValueLabel: {
                        Image(systemName: "minus.magnifyingglass")
                    } maximumValueLabel: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
            }
            Picker("Record Label", selection: $prefs.labelStyle) {
                ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Spin When Nothing Is Playing", isOn: $prefs.spinWhenIdle)
        }
    }

    private var lookSection: some View {
        Section {
            Picker("Record", selection: $prefs.vinylStyle) {
                ForEach(VinylStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Background", selection: $prefs.sleeveBackground) {
                ForEach(SleeveBackground.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show Song and Artist", isOn: $prefs.showTrackInfo)
        } header: {
            Text("Sleeve")
        } footer: {
            Text("Coloured records are pressed in each album's own colours. Match the Album picks a different pressing per album, like a real shelf. Tap the record to play or pause, turn it to move through the song, or pick up the tonearm and drop it where you want to listen.")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Keep Screen On", isOn: $prefs.keepAwake)
            VStack(alignment: .leading) {
                Text("Dim")
                Slider(value: $prefs.dimming, in: 0...0.85) {
                    Text("Dim")
                } minimumValueLabel: {
                    Image(systemName: "sun.max")
                } maximumValueLabel: {
                    Image(systemName: "moon")
                }
            }
            Toggle("Show Clock", isOn: $prefs.showClock)
            Toggle("Burn-in Protection", isOn: $prefs.pixelShift)
        } header: {
            Text("Display")
        } footer: {
            Text("To keep Vinyl on screen like a desk display, leave Keep Screen On on and plug the device in. To lock the device to Vinyl, use Guided Access: Settings → Accessibility → Guided Access, then triple-click the side or top button while Vinyl is open. Tap the screen for controls, tap the record to play or pause, swipe sideways to skip.")
        }
    }

    private var liveActivitySection: some View {
        Section {
            Toggle("Live Activity", isOn: $prefs.liveActivity)
                .disabled(!LiveActivityController.shared.isSupported && !prefs.liveActivity)
        } header: {
            Text("Lock Screen")
        } footer: {
            if LiveActivityController.shared.isSupported {
                Text("Shows the record on the Lock Screen and in the Dynamic Island, with play, pause and skip. It updates live while Vinyl is open. When Vinyl is closed, the progress bar keeps running to the end of the song; open Vinyl or tap a button to catch it up.")
            } else {
                Text("Live Activities aren't available on this device, or they're turned off for Vinyl in Settings. On iPad, Vinyl's full-screen display does the same job.")
            }
        }
    }

    private var widgetSection: some View {
        Section {
            Toggle("Spin the Record in Widgets", isOn: $prefs.widgetSpin)
        } header: {
            Text("Widgets")
        } footer: {
            Text("Add Vinyl from the widget gallery on your Home Screen or Lock Screen. Spinning keeps the record turning while music plays; it uses a little more battery, and iOS may slow it down when the battery is low.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            Link(destination: URL(string: "https://github.com/CycloneDraco/Vinyl")!) {
                Label("Based on Vinyl for macOS", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } footer: {
            Text("Open source under the MIT License. The 3D scenes, textures and artwork come from Vinyl for macOS by CycloneDraco and contributors.")
        }
    }
}
