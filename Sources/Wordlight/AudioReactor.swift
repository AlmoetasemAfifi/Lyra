import AppKit
import AudioToolbox
import CoreAudio

/// Listens to the audio coming out of Music / Spotify using a Core Audio process tap
/// (macOS 14.2+). Needs only "System Audio Recording" permission, not Screen Recording,
/// and hears only the music apps, so notification sounds don't trigger pulses.
/// Reports bass beats through `onBeat`.
final class AudioReactor {
    var onBeat: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var running = false

    private let queue = DispatchQueue(label: "wordlight.audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []

    // Beat detector state (audio thread only)
    private var lowpass: Float = 0
    private var bassAvg: Double = 0.0001
    private var lastBeat: Double = 0
    private var sampleRate: Double = 48000
    private var heardSound = false
    private var startedAt = Date()

    func start() {
        guard !running else { return }
        guard #available(macOS 14.2, *) else {
            onError?("Reacting to the music needs macOS 14.2 or later.")
            return
        }
        running = true
        startTap()
    }

    func stop() {
        running = false
        teardown()
    }

    /// Re-target the tap if the music apps' audio processes changed (e.g. Spotify was opened).
    func refreshTargets() {
        guard running, #available(macOS 14.2, *) else { return }
        if musicProcesses() != tappedProcesses { teardown(); startTap() }
    }

    // MARK: - Core Audio plumbing

    @available(macOS 14.2, *)
    private func startTap() {
        let targets = musicProcesses()
        tappedProcesses = targets
        // Tap the music apps if they're registered with the audio system yet; otherwise all
        // system audio except Wordlight itself.
        let desc = targets.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: targets)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { fail("Couldn't create audio tap (\(err)).") ; return }
        tapID = tap

        // Tap stream format (we expect Float32).
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 { sampleRate = fmt.mSampleRate }

        guard let outputUID = defaultOutputUID() else { fail("No audio output device."); return }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyra Listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard err == noErr else { fail("Couldn't create audio listener (\(err))."); return }
        aggregateID = aggID

        heardSound = false
        startedAt = Date()
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard err == noErr, let proc else { fail("Couldn't start audio listener (\(err))."); return }
        procID = proc
        err = AudioDeviceStart(aggID, proc)
        guard err == noErr else { fail("Couldn't start audio listener (\(err))."); return }
        NSLog("Wordlight: audio tap on \(targets.isEmpty ? "all system audio" : "\(targets.count) music process(es)")")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func fail(_ msg: String) {
        NSLog("Wordlight: \(msg)")
        teardown()
        running = false
        onError?(msg)
    }

    /// Audio process objects belonging to Music or Spotify (including their helper processes).
    private func musicProcesses() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<CFString?>.size)
            var bid: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &bid) == noErr, let b = bid?.takeRetainedValue() as String? else { return false }
            return b.hasPrefix("com.apple.Music") || b.hasPrefix("com.spotify.client")
        }.sorted()
    }

    private func defaultOutputUID() -> String? {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<CFString?>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    // MARK: - Beat detection (audio thread)

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buf = abl.first, let data = buf.mData else { return }
        let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard n > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let channels = max(1, Int(buf.mNumberChannels))

        // Bass energy via a one-pole low-pass at ~150 Hz (first channel of interleaved data).
        let alpha = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var bass: Float = 0, peak: Float = 0
        var i = 0
        while i < n {
            let x = samples[i]
            lowpass += alpha * (x - lowpass)
            bass += lowpass * lowpass
            peak = max(peak, abs(x))
            i += channels
        }
        let frames = Float(n / channels)
        let bassE = Double(sqrt(bass / max(1, frames)))
        if peak > 0.0005 { heardSound = true }

        let now = CACurrentMediaTime()
        // Compare against a ~0.5 s running average of bass energy; a jump well above it is a hit.
        let ratio = bassE / max(0.0001, bassAvg)
        bassAvg = bassAvg * 0.96 + bassE * 0.04
        if ratio > 1.35, bassE > 0.005, now - lastBeat > 0.18 {
            lastBeat = now
            onBeat?(min(1.5, 0.75 + (ratio - 1.35) * 0.6))
        }

        // Permission denied produces pure silence rather than an error; tell the user once.
        if !heardSound, Date().timeIntervalSince(startedAt) > 8 {
            startedAt = .distantFuture
            onError?("Lyra hears silence. Allow it under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then turn this on again.")
        }
    }
}
