import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    var id: String  // CoreAudio UID
    var name: String
}

enum AudioDevices {
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    static func inputs() -> [AudioInputDevice] {
        allDeviceIDs().filter(hasInput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInputDevice(id: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }
}

/// Captures microphone audio and converts it on the fly to 16 kHz mono Float32 (whisper's input format).
final class AudioRecorder {
    static let sampleRate = 16000.0

    private var engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRunning = false

    /// Called on the main thread with the RMS level (0...1) of each captured buffer.
    var onLevel: ((Float) -> Void)?

    /// Starts capture from the device with the given CoreAudio UID (empty or missing = system default).
    func start(deviceUID: String = "") throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        // A fresh engine picks up device changes (AirPods connected, default input switched…).
        engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, var device = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "LocalFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Nessun microfono disponibile", "No microphone available")])
        }
        converter = AVAudioConverter(from: format, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    /// Number of 16 kHz samples captured so far.
    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    /// Copy of the captured samples in `range` (clamped), readable while recording.
    func snapshot(_ range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let r = range.clamped(to: 0..<samples.count)
        return Array(samples[r])
    }

    /// Stops capture and returns the recorded 16 kHz samples.
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
}

enum AudioUtils {
    /// Removes leading/trailing silence; returns nil when no speech-like energy is found.
    /// Index (absolute) of the quietest 200 ms window inside `searchRange` of `samples`, with its RMS.
    static func quietestPoint(_ samples: [Float], in searchRange: Range<Int>, rate: Double = AudioRecorder.sampleRate) -> (index: Int, rms: Float)? {
        let window = Int(rate * 0.2), hop = Int(rate * 0.05)
        var best: (Int, Float)?
        var i = searchRange.lowerBound
        while i + window <= searchRange.upperBound {
            var sum: Float = 0
            for j in i..<(i + window) { sum += samples[j] * samples[j] }
            let rms = sqrt(sum / Float(window))
            if best == nil || rms < best!.1 { best = (i + window / 2, rms) }
            i += hop
        }
        return best.map { (index: $0.0, rms: $0.1) }
    }

    static func trimSilence(_ samples: [Float], rate: Double = AudioRecorder.sampleRate) -> [Float]? {
        let window = Int(rate * 0.02)
        guard samples.count > window else { return nil }
        var energies: [Float] = []
        var i = 0
        while i + window <= samples.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += samples[j] * samples[j] }
            energies.append(sqrt(sum / Float(window)))
            i += window
        }
        let sorted = energies.sorted()
        let noise = sorted[sorted.count / 10]
        let threshold = max(0.006, noise * 3)
        let voiced = energies.filter { $0 > threshold }.count
        guard Double(voiced) * 0.02 >= 0.2 else { return nil }
        guard let first = energies.firstIndex(where: { $0 > threshold }),
              let last = energies.lastIndex(where: { $0 > threshold }) else { return nil }
        let pad = Int(rate * 0.25)
        let start = max(0, first * window - pad)
        let end = min(samples.count, (last + 1) * window + pad)
        var trimmed = Array(samples[start..<end])
        // whisper needs at least ~1 s of audio to behave; pad short clips with silence.
        let minCount = Int(rate * 1.1)
        if trimmed.count < minCount { trimmed += [Float](repeating: 0, count: minCount - trimmed.count) }
        return trimmed
    }

    static func wavData(_ samples: [Float], rate: Int = Int(AudioRecorder.sampleRate)) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        data.reserveCapacity(data.count + byteCount)
        for s in samples {
            let clamped = max(-1, min(1, s))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
