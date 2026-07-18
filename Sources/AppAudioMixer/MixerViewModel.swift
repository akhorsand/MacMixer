import Foundation
import SwiftUI
import CoreAudio
import AppKit

final class MixerViewModel: ObservableObject {
    /// Apps shown in the UI: anything currently playing audio, plus anything
    /// we're already controlling (so sliders don't vanish when playback pauses).
    @Published private(set) var displayApps: [AudioApp] = []
    @Published private(set) var volumes: [pid_t: Float] = [:]
    @Published var errorMessage: String?

    private var engines: [pid_t: PerAppAudioEngine] = [:]
    private var latestByPID: [pid_t: AudioApp] = [:]
    private let monitor = AudioProcessMonitor()
    private var terminateObserver: NSObjectProtocol?

    init() {
        monitor.onUpdate = { [weak self] apps in
            DispatchQueue.main.async { self?.apply(apps) }
        }
        monitor.start()
        installDefaultDeviceListener()

        // Tear the taps down on quit so controlled apps go back to normal
        // immediately. (coreaudiod also cleans up automatically if we crash.)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tearDownAllEngines()
        }
    }

    // MARK: - Public API used by the UI

    func volume(for pid: pid_t) -> Float {
        volumes[pid] ?? 1.0
    }

    func volumeBinding(for app: AudioApp) -> Binding<Double> {
        Binding(
            get: { [weak self] in Double(self?.volume(for: app.pid) ?? 1.0) },
            set: { [weak self] newValue in self?.setVolume(Float(newValue), for: app) }
        )
    }

    func setVolume(_ value: Float, for app: AudioApp) {
        volumes[app.pid] = value

        if engines[app.pid] == nil {
            do {
                engines[app.pid] = try PerAppAudioEngine(
                    processObjectID: app.objectID,
                    initialVolume: value
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        engines[app.pid]?.volume = value
        rebuildDisplayList()
    }

    func toggleMute(for app: AudioApp) {
        let current = volume(for: app.pid)
        setVolume(current == 0 ? 1.0 : 0.0, for: app)
    }

    /// Releases every tap: all apps return to native, untouched output.
    func resetAll() {
        tearDownAllEngines()
        volumes.removeAll()
        errorMessage = nil
        rebuildDisplayList()
    }

    // MARK: - Internals

    private func apply(_ apps: [AudioApp]) {
        latestByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // Drop engines whose target process is gone.
        for pid in engines.keys where latestByPID[pid] == nil {
            engines[pid]?.stop()
            engines[pid] = nil
            volumes[pid] = nil
        }
        rebuildDisplayList()
    }

    private func rebuildDisplayList() {
        displayApps = latestByPID.values
            .filter { $0.isRunningOutput || engines[$0.pid] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func tearDownAllEngines() {
        for engine in engines.values { engine.stop() }
        engines.removeAll()
    }

    // Rebuild all engines when the default output device changes
    // (e.g. plugging in headphones), preserving each app's volume.
    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            // Small delay so the new device is fully up before we re-route.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.rebuildEnginesForNewOutputDevice()
            }
        }
    }

    private func rebuildEnginesForNewOutputDevice() {
        let pids = Array(engines.keys)
        for pid in pids {
            engines[pid]?.stop()
            engines[pid] = nil
            guard let app = latestByPID[pid] else {
                volumes[pid] = nil
                continue
            }
            let restoredVolume = volumes[pid] ?? 1.0
            engines[pid] = try? PerAppAudioEngine(
                processObjectID: app.objectID,
                initialVolume: restoredVolume
            )
        }
        rebuildDisplayList()
    }
}
