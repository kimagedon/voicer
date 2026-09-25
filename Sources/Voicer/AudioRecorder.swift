import AVFoundation
import Foundation

/// Captures the default input device and resamples it to 16 kHz mono Float32 —
/// the format Whisper expects. Emits a normalised level per buffer for the HUD.
final class AudioRecorder: @unchecked Sendable {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var peakRMS: Float = 0
    private let lock = NSLock()
    private(set) var isRunning = false

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            peakRMS = 0
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: Self.targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Stops capture and returns the recorded audio plus its loudest buffer RMS.
    func stop() -> (samples: [Float], peakRMS: Float) {
        guard isRunning else { return ([], 0) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        return lock.withLock { (samples, peakRMS) }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Map roughly -55 dB … -12 dB onto 0 … 1.
        let db = 20 * log10(max(rms, 1e-7))
        onLevel?(min(max((db + 55) / 43, 0), 1))

        guard let converted = Self.convert(buffer, with: converter) else { return }
        lock.withLock {
            peakRMS = max(peakRMS, rms)
            samples.append(contentsOf: converted)
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?) -> [Float]? {
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// Decodes an audio file into 16 kHz mono samples (used by the `--transcribe` CLI).
    static func load(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        try file.read(into: buffer)
        let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)
        return convert(buffer, with: converter) ?? []
    }
}
