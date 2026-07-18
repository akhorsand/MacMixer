import Foundation
import CoreAudio
import AppKit
import UniformTypeIdentifiers

/// One audio-capable process as seen by Core Audio.
struct AudioApp: Identifiable, Equatable {
    let pid: pid_t
    let objectID: AudioObjectID   // Core Audio process object (needed to create a tap)
    let bundleID: String
    let name: String
    let icon: NSImage
    let isRunningOutput: Bool     // true while the process is actively playing audio

    var id: pid_t { pid }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.pid == rhs.pid
            && lhs.objectID == rhs.objectID
            && lhs.isRunningOutput == rhs.isRunningOutput
            && lhs.name == rhs.name
    }
}

/// Polls Core Audio's process object list and reports audio-capable apps.
final class AudioProcessMonitor {
    var onUpdate: (([AudioApp]) -> Void)?
    private var timer: Timer?

    func start(interval: TimeInterval = 2.0) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var result: [AudioApp] = []
        var seenPIDs = Set<pid_t>()

        for objectID in Self.processObjectList() {
            guard let pid = Self.pid(of: objectID),
                  pid != getpid(),
                  !seenPIDs.contains(pid) else { continue }

            let bundleID = Self.bundleID(of: objectID) ?? ""
            let running = Self.isRunningOutput(objectID)
            let runningApp = NSRunningApplication(processIdentifier: pid)

            let name = runningApp?.localizedName
                ?? Self.friendlyName(fromBundleID: bundleID)
                ?? "PID \(pid)"

            let icon = runningApp?.icon
                ?? NSWorkspace.shared.icon(for: UTType.applicationBundle)

            seenPIDs.insert(pid)
            result.append(AudioApp(
                pid: pid,
                objectID: objectID,
                bundleID: bundleID,
                name: name,
                icon: icon,
                isRunningOutput: running
            ))
        }

        let sorted = result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        onUpdate?(sorted)
    }

    // MARK: - Core Audio property helpers

    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &list)
        guard status == noErr else { return [] }
        return list
    }

    private static func pid(of objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return value
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func friendlyName(fromBundleID bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        let last = bundleID.split(separator: ".").last.map(String.init)
        return last?.capitalized
    }
}
