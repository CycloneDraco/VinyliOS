import SwiftUI
import UIKit

/// Full screen, always on: the scene, plus controls that appear on tap.
struct RootView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var spotify: SpotifyAuth
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Sheet: String, Identifiable {
        case settings, crate
        var id: String { rawValue }
    }

    @State private var showControls = false
    @State private var sheet: Sheet?
    @State private var hideTask: Task<Void, Never>?
    @State private var shift = CGSize.zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            stage
                .offset(prefs.pixelShift ? shift : .zero)
                .ignoresSafeArea()

            if prefs.showClock {
                ClockView()
                    .offset(prefs.pixelShift ? shift : .zero)
                    .allowsHitTesting(false)
            }

            // Dimming veil for night-time / bedside use.
            Color.black
                .opacity(prefs.dimming)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if !nowPlaying.hasAnySource {
                OnboardingCard(openSettings: { sheet = .settings })
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            ControlsOverlay(visible: showControls,
                            openCrate: { sheet = .crate },
                            openSettings: { sheet = .settings },
                            interacted: scheduleHide)
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)

            if let notice = nowPlaying.notice {
                NoticeBanner(text: notice)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 4_500_000_000)
                        withAnimation { nowPlaying.notice = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.3), value: nowPlaying.notice)
        .animation(.easeInOut(duration: 0.3), value: nowPlaying.hasAnySource)
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dx) > abs(dy) * 1.5, abs(dx) > 80 else { return }
                    Task { await nowPlaying.perform(dx < 0 ? .next : .previous) }
                }
        )
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: presented(.settings)) { _ in
            SettingsView()
                .environmentObject(prefs)
                .environmentObject(nowPlaying)
                .environmentObject(spotify)
        }
        // The shelf gets the whole screen.
        .fullScreenCover(item: presented(.crate)) { _ in
            CrateView()
                .environmentObject(prefs)
                .environmentObject(nowPlaying)
                .environmentObject(spotify)
        }
        .onAppear {
            applyPhase(scenePhase)
            prefs.hasLaunchedBefore = true
        }
        .onChange(of: scenePhase) { _, phase in applyPhase(phase) }
        .onChange(of: prefs.keepAwake) { _, _ in applyPhase(scenePhase) }
        .task { await runPixelShift() }
    }

    @ViewBuilder
    private var stage: some View {
        if prefs.scene.usesRenderer {
            RendererView(
                payload: RendererPayload.make(scene: prefs.scene, prefs: prefs, nowPlaying: nowPlaying, reduceMotion: reduceMotion),
                paused: scenePhase != .active
            )
        } else {
            SleeveSceneView()
        }
    }

    private func presented(_ kind: Sheet) -> Binding<Sheet?> {
        Binding(get: { sheet == kind ? kind : nil }, set: { sheet = $0 })
    }

    private func applyPhase(_ phase: ScenePhase) {
        let active = phase == .active
        UIApplication.shared.isIdleTimerDisabled = active && prefs.keepAwake
        nowPlaying.setActive(phase != .background)
        if active {
            nowPlaying.pollSpotifySoon()
            LiveActivityController.shared.scheduleSync()
        }
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    /// Moves everything a few points every few minutes so static parts
    /// (sleeve edges, clock) don't burn into OLED screens.
    private func runPixelShift() async {
        let offsets: [CGSize] = [.zero, CGSize(width: 4, height: -3), CGSize(width: -3, height: 4),
                                 CGSize(width: 5, height: 3), CGSize(width: -4, height: -4), CGSize(width: 2, height: 5)]
        var index = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            index = (index + 1) % offsets.count
            withAnimation(.easeInOut(duration: 2)) { shift = offsets[index] }
        }
    }
}

// MARK: - Clock

struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 54, weight: .thin, design: .rounded))
                    .monospacedDigit()
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 16, weight: .medium))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 6)
            .padding(.leading, 32)
            .padding(.top, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Notice

struct NoticeBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 18)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

// MARK: - First run

struct OnboardingCard: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var spotify: SpotifyAuth
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 40, weight: .light))
            Text("Put a record on")
                .font(.system(.title2, design: .serif).weight(.semibold))
            Text("Vinyl shows what you're playing in Spotify (on any device) or Apple Music (on this one).")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            VStack(spacing: 10) {
                Button {
                    Task { await spotify.connect() }
                } label: {
                    Label("Connect Spotify", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.73, blue: 0.33))

                Button {
                    Task {
                        if await AppleMusicSource.requestAccess() {
                            prefs.appleMusicEnabled = true
                        } else {
                            openSettings()
                        }
                    }
                } label: {
                    Label("Use Apple Music", systemImage: "music.note")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)

                Button("More settings", action: openSettings)
                    .font(.footnote)
                    .padding(.top, 2)
            }
            .controlSize(.large)
            if let error = spotify.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(24)
    }
}
