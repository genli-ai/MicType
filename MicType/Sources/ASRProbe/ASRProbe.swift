// MicType offline ASR probe — 离线诊断 CLI，不属于 App，不被 App 依赖。
//
// 用途：在不启动 App 的前提下，直接对 WAV 跑 Qwen3-ASR(MLX)，
// 观察长音频的失败模式（超长截断 / 复读 / 报错 / 内存）与各语言质量。
//
// 用法：
//   mictype-asr-probe <model-dir> <wav-file> [options]
//
// options:
//   --language <name>      语言强制（Qwen3-ASR 用英文语言名，如 Chinese / English / Arabic；
//                          auto 或省略 = 自动检测）
//   --context "..."        热词上下文（等价于 App 的「常用词汇」）
//   --chunk-seconds N      分段识别，每段约 N 秒（0 = 整段）
//   --split naive|silence  分段切点策略：naive = 固定长度；silence = 在边界 ±3s 内
//                          找能量最低的 20ms 帧下刀（默认 silence）
//   --max-tokens N         传给 transcribe 的 maxTokens（默认 4096，同 App）
//   --limit-seconds N      只取音频前 N 秒（用于二分长音频阈值，免得重新生成素材）
//   --tokenizer <path>     tokenizer.json 来源（模型目录缺失时复制进去）
//   --quiet-text           只打印统计，不打印转写正文
import Foundation
import AVFoundation
import MLXASR

// MARK: - 小工具

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(2)
}

func nowMs() -> Double { CFAbsoluteTimeGetCurrent() * 1000.0 }

/// 进程峰值内存（MB）——getrusage 的 ru_maxrss，macOS 上单位是字节
func peakRSSMB() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Double(usage.ru_maxrss) / (1024.0 * 1024.0)
}

/// 音频编码器输出长度（CPU 侧复算 MLXASR 的 getAudioEncoderOutputLengths）
/// 每 100 帧 mel（=1 秒）压成 13 个 token
func encoderOutputLength(melFrames: Int) -> Int {
    let leave = melFrames % 100
    let feat = leave > 0 ? (leave - 1) / 2 + 1 : 0
    let s1 = feat > 0 ? (feat - 1) / 2 + 1 : 0
    let s2 = s1 > 0 ? (s1 - 1) / 2 + 1 : 0
    return s2 + (melFrames / 100) * 13
}

// MARK: - 参数解析

struct Options {
    var modelDir: URL
    var audioFile: URL
    var language: String?
    var context: String?
    var chunkSeconds: Double = 0
    var split: String = "silence"
    var maxTokens: Int = 4096
    var limitSeconds: Double = 0
    var tokenizerPath: String?
    var quietText = false
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else {
        fail("""
        usage: mictype-asr-probe <model-dir> <wav-file> [--language <name>] [--context "..."] \
        [--chunk-seconds N] [--split naive|silence] [--max-tokens N] [--limit-seconds N] \
        [--tokenizer <path>] [--quiet-text]
        """)
    }
    var opts = Options(modelDir: URL(fileURLWithPath: args[0]),
                       audioFile: URL(fileURLWithPath: args[1]))
    args = Array(args.dropFirst(2))

    var i = 0
    func next(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) needs a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--language": opts.language = next("--language")
        case "--context": opts.context = next("--context")
        case "--chunk-seconds": opts.chunkSeconds = Double(next("--chunk-seconds")) ?? 0
        case "--split": opts.split = next("--split")
        case "--max-tokens": opts.maxTokens = Int(next("--max-tokens")) ?? 4096
        case "--limit-seconds": opts.limitSeconds = Double(next("--limit-seconds")) ?? 0
        case "--tokenizer": opts.tokenizerPath = next("--tokenizer")
        case "--quiet-text": opts.quietText = true
        default: fail("unknown option \(args[i])")
        }
        i += 1
    }
    if opts.split != "naive", opts.split != "silence" { fail("--split must be naive or silence") }
    return opts
}

// MARK: - tokenizer.json 补齐（复刻 QwenEngine.ensureTokenizerFile 的逻辑）

/// HF 上的 Qwen3-ASR 量化仓库普遍缺 tokenizer.json（swift-transformers 必需）。
/// App 从 bundle 资源补一份；CLI 没有 bundle，所以按 --tokenizer 或若干常见路径找。
func ensureTokenizerFile(modelDir: URL, explicit: String?) {
    let dest = modelDir.appendingPathComponent("tokenizer.json")
    if FileManager.default.fileExists(atPath: dest.path) { return }

    var candidates: [String] = []
    if let explicit { candidates.append(explicit) }
    let cwd = FileManager.default.currentDirectoryPath
    candidates += [
        cwd + "/Resources/QwenTokenizer/tokenizer.json",
        cwd + "/MicType/Resources/QwenTokenizer/tokenizer.json",
        cwd + "/../Resources/QwenTokenizer/tokenizer.json",
    ]
    // 可执行文件附近（.build / .xcbuild 产物通常在 MicType/ 下若干层）
    var exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0 ..< 8 {
        candidates.append(exeDir.appendingPathComponent("Resources/QwenTokenizer/tokenizer.json").path)
        exeDir = exeDir.deletingLastPathComponent()
    }

    for path in candidates where FileManager.default.fileExists(atPath: path) {
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dest)
            print("[probe] copied tokenizer.json from \(path)")
            return
        } catch {
            fail("cannot write tokenizer.json: \(error.localizedDescription)")
        }
    }
    fail("tokenizer.json missing in model dir and not found; pass --tokenizer <path>")
}

// MARK: - WAV → 16k mono Float32

func loadSamples16kMono(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0 else { return [] }
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "probe", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate input buffer"])
    }
    try file.read(into: inBuffer)

    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: 16000, channels: 1, interleaved: false)!
    if sourceFormat.sampleRate == 16000, sourceFormat.channelCount == 1,
       sourceFormat.commonFormat == .pcmFormatFloat32 {
        let ptr = inBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(inBuffer.frameLength)))
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
        throw NSError(domain: "probe", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot create converter"])
    }
    let ratio = target.sampleRate / sourceFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 4096)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
        throw NSError(domain: "probe", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate output buffer"])
    }
    var convError: NSError?
    var provided = false
    converter.convert(to: outBuffer, error: &convError) { _, outStatus in
        if provided {
            outStatus.pointee = .endOfStream
            return nil
        }
        provided = true
        outStatus.pointee = .haveData
        return inBuffer
    }
    if let convError { throw convError }
    let ptr = outBuffer.floatChannelData![0]
    return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuffer.frameLength)))
}

// MARK: - 切点

let sampleRate = 16000

/// 固定长度切点
func naiveBoundaries(sampleCount: Int, chunkSamples: Int) -> [Int] {
    var cuts = [0]
    var pos = chunkSamples
    while pos < sampleCount {
        cuts.append(pos)
        pos += chunkSamples
    }
    cuts.append(sampleCount)
    return cuts
}

/// 静音感知切点：在名义边界 ±searchRadius 内找能量最低的 20ms 帧，在该帧中点下刀
func silenceAwareBoundaries(samples: [Float], chunkSamples: Int,
                            searchRadius: Int = 3 * sampleRate) -> [Int] {
    let frame = sampleRate / 50 // 20ms = 320 samples
    var cuts = [0]
    var nominal = chunkSamples
    while nominal < samples.count {
        let prev = cuts[cuts.count - 1]
        let lo = max(prev + frame, nominal - searchRadius)
        let hi = min(samples.count - frame, nominal + searchRadius)
        var best = min(nominal, samples.count)
        if lo < hi {
            var bestEnergy = Float.greatestFiniteMagnitude
            var i = lo
            while i + frame <= hi {
                var energy: Float = 0
                for j in i ..< (i + frame) { energy += samples[j] * samples[j] }
                if energy < bestEnergy {
                    bestEnergy = energy
                    best = i + frame / 2
                }
                i += frame
            }
        }
        let cut = min(max(best, prev + frame), samples.count)
        if cut <= prev { break }
        cuts.append(cut)
        nominal = cut + chunkSamples
    }
    if cuts[cuts.count - 1] != samples.count { cuts.append(samples.count) }
    return cuts
}

// MARK: - 主流程

@main
struct ASRProbe {
    static func main() async {
        let opts = parseOptions()
        setvbuf(stdout, nil, _IOLBF, 0)

        guard FileManager.default.fileExists(
            atPath: opts.modelDir.appendingPathComponent("config.json").path) else {
            fail("no config.json in model dir \(opts.modelDir.path)")
        }
        ensureTokenizerFile(modelDir: opts.modelDir, explicit: opts.tokenizerPath)

        // 音频
        var samples: [Float]
        do {
            samples = try loadSamples16kMono(from: opts.audioFile)
        } catch {
            fail("audio load failed: \(error.localizedDescription)")
        }
        if opts.limitSeconds > 0 {
            let want = Int(opts.limitSeconds * Double(sampleRate))
            if want < samples.count { samples = Array(samples[0 ..< want]) }
        }
        let totalSeconds = Double(samples.count) / Double(sampleRate)
        let melFrames = samples.count / 160
        let encTokens = encoderOutputLength(melFrames: melFrames)
        let maskMB = Double(encTokens) * Double(encTokens) * 4.0 / (1024 * 1024)

        print("=== mictype-asr-probe ===")
        print("model:            \(opts.modelDir.lastPathComponent)")
        print("audio:            \(opts.audioFile.lastPathComponent)")
        print(String(format: "audio seconds:    %.2f  (%d samples @16k)", totalSeconds, samples.count))
        print("mel frames:       \(melFrames)   encoder seqLen (13/s): \(encTokens)")
        print(String(format: "encoder attn mask: %d x %d float32 = %.1f MB (CPU alloc in createBlockAttentionMask)",
                     encTokens, encTokens, maskMB))
        print("language:         \(opts.language ?? "auto")")
        print("context:          \(opts.context == nil ? "none" : "\(opts.context!.count) chars")")
        print("maxTokens:        \(opts.maxTokens)")
        if opts.chunkSeconds > 0 {
            print(String(format: "mode:             chunked %.0fs, split=%@", opts.chunkSeconds, opts.split))
        } else {
            print("mode:             whole file")
        }

        // 载入模型（含 warmup，和 App 一致）
        let loadStart = nowMs()
        let stt: Qwen3ASRSTT
        do {
            stt = try await Qwen3ASRSTT.loadWithWarmup(from: opts.modelDir)
        } catch {
            print("MODEL LOAD FAILED: \(error)")
            exit(3)
        }
        let loadMs = nowMs() - loadStart
        print(String(format: "model load+warmup: %.0f ms", loadMs))

        // 单独一份 tokenizer 用于数 token（TranscriptionResult 不带 token 数）
        var counter: Qwen3ASRTokenizer?
        if let data = try? Data(contentsOf: opts.modelDir.appendingPathComponent("config.json")),
           let cfg = try? JSONDecoder().decode(Qwen3ASRConfig.self, from: data) {
            counter = try? await Qwen3ASRTokenizer.load(from: opts.modelDir, config: cfg)
        }
        func tokenCount(_ text: String) -> Int {
            guard let counter, !text.isEmpty else { return -1 }
            return counter.encode(text).count
        }

        let language = (opts.language?.lowercased() == "auto") ? nil : opts.language

        func runOne(_ audio: [Float], label: String, offset: Double) async -> String {
            let seconds = Double(audio.count) / Double(sampleRate)
            let start = nowMs()
            do {
                let result = try await stt.transcribe(audio: audio,
                                                     language: language,
                                                     context: opts.context,
                                                     maxTokens: opts.maxTokens,
                                                     temperature: 0.0)
                let ms = nowMs() - start
                let text = result.text
                print(String(format: "[%@] %.2fs..%.2fs (%.2fs)  %.0f ms  rtf %.3f  chars %d  tokens %d  lang %@",
                             label, offset, offset + seconds, seconds, ms,
                             ms / 1000.0 / max(seconds, 0.001),
                             text.count, tokenCount(text), result.language ?? "-"))
                if !opts.quietText { print("    \(text)") }
                return text
            } catch {
                let ms = nowMs() - start
                print(String(format: "[%@] %.2fs..%.2fs (%.2fs)  %.0f ms  THREW: %@",
                             label, offset, offset + seconds, seconds, ms, String(describing: error)))
                return ""
            }
        }

        if opts.chunkSeconds <= 0 {
            let text = await runOne(samples, label: "whole", offset: 0)
            print("--- transcript (\(text.count) chars) ---")
            if !opts.quietText { print(text) }
        } else {
            let chunkSamples = max(sampleRate, Int(opts.chunkSeconds * Double(sampleRate)))
            let cuts = opts.split == "naive"
                ? naiveBoundaries(sampleCount: samples.count, chunkSamples: chunkSamples)
                : silenceAwareBoundaries(samples: samples, chunkSamples: chunkSamples)
            print("cuts (s):         " + cuts.map { String(format: "%.2f", Double($0) / Double(sampleRate)) }
                .joined(separator: ", "))
            var pieces: [String] = []
            var totalMs = 0.0
            for idx in 0 ..< (cuts.count - 1) {
                let lo = cuts[idx], hi = cuts[idx + 1]
                guard hi > lo else { continue }
                let chunk = Array(samples[lo ..< hi])
                let t0 = nowMs()
                let text = await runOne(chunk, label: "chunk \(idx + 1)/\(cuts.count - 1)",
                                        offset: Double(lo) / Double(sampleRate))
                totalMs += nowMs() - t0
                pieces.append(text)
            }
            let joined = pieces.filter { !$0.isEmpty }.joined(separator: " ")
            print(String(format: "chunks total:     %.0f ms  chars %d  tokens %d",
                         totalMs, joined.count, tokenCount(joined)))
            print("--- joined transcript (\(joined.count) chars) ---")
            if !opts.quietText { print(joined) }
        }

        print(String(format: "peak RSS:         %.0f MB", peakRSSMB()))
    }
}
