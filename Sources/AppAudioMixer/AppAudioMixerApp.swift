import SwiftUI
import AppKit

@main
struct AppAudioMixerApp: App {
    @StateObject private var mixer = MixerViewModel()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MixerView: View {
    @EnvironmentObject private var mixer: MixerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Audio Mixer")
                .font(.headline)

            if mixer.displayApps.isEmpty {
                Text("No apps are playing audio right now.\nStart playback somewhere and it will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(mixer.displayApps) { app in
                    AppRow(app: app)
                }
            }

            if let message = mixer.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Reset All") { mixer.resetAll() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct AppRow: View {
    @EnvironmentObject private var mixer: MixerViewModel
    let app: AudioApp

    private var percent: Int {
        Int((mixer.volume(for: app.pid) * 100).rounded())
    }

    private var isMuted: Bool {
        mixer.volume(for: app.pid) == 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Text("\(percent)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: mixer.volumeBinding(for: app), in: 0...2)
                    .controlSize(.small)
            }

            Button {
                mixer.toggleMute(for: app)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isMuted ? .red : .secondary)
            .help(isMuted ? "Unmute" : "Mute")
        }
    }
}
