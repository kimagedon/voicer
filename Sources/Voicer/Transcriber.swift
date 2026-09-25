import CWhisper
import Foundation

/// Owns the whisper.cpp context. All calls run on one serial queue, so the
/// context is never touched concurrently.
final class Transcriber: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "voicer.whisper", qos: .userInitiated)

    /// Whisper's well-known outputs on silence / noise (mostly from subtitle-heavy
    /// training data), in the languages it hallucinates them in.
    private static let hallucinations: [String] = [
        "продолжение следует", "субтитры", "редактор субтитров", "корректор", "спасибо за просмотр",
        "подписывайтесь на канал", "dimatorzok", "thank you for watching", "thanks for watching",
        "amara.org", "[music]", "[музыка]", "(музыка)",
    ]

    func load(path: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            if let old = self.ctx { whisper_free(old); self.ctx = nil }
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            self.ctx = whisper_init_from_file_with_params(path, params)
            completion(self.ctx != nil)
        }
    }

    /// Frees the context synchronously. Must run before process exit, otherwise
    /// ggml-metal's static destructors assert on still-live buffers.
    func unload() {
        queue.sync {
            if let ctx { whisper_free(ctx) }
            ctx = nil
        }
    }

    /// Transcribes 16 kHz mono audio; the spoken language is detected automatically.
    func transcribe(_ samples: [Float], completion: @escaping (String) -> Void) {
        queue.async {
            guard let ctx = self.ctx, !samples.isEmpty else { return completion("") }

            // Whisper needs at least ~1 s of audio; pad short clips with silence.
            var audio = samples
            let minSamples = 16_000 + 1_600
            if audio.count < minSamples { audio += [Float](repeating: 0, count: minSamples - audio.count) }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.no_context = true
            params.no_timestamps = true
            params.suppress_blank = true
            params.suppress_nst = true

            // A short punctuated prompt nudges the model toward punctuated, capitalised
            // output. It is bilingual because detection runs on audio alone and the
            // speaker mixes Russian and English.
            let prompt = "Hello, привет. Clean, punctuated text."

            let status: Int32 = "auto".withCString { lang in
                prompt.withCString { promptPtr in
                    params.language = lang
                    params.detect_language = false
                    params.initial_prompt = promptPtr
                    return audio.withUnsafeBufferPointer { buf in
                        whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                    }
                }
            }
            guard status == 0 else { return completion("") }

            var text = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let seg = whisper_full_get_segment_text(ctx, i) { text += String(cString: seg) }
            }
            completion(Self.clean(text))
        }
    }

    private static func clean(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if hallucinations.contains(where: { lower.contains($0) }) && text.count < 80 { return "" }
        return text
    }
}
