import AVFoundation
import CoreMedia

/// EBU R128 K-weighted LUFS 响度分析结果。
struct LoudnessResult {
    let lufs: Double
    let sampleRate: Int
    let analyzedMs: Int
}

/// EBU R128 / ITU-R BS.1770-4 integrated loudness(LUFS)分析器(iOS)。
///
/// 完整流程:AVAssetReader 解码为固定 48kHz Float32 单声道 → K-weighting
/// (EBU TECH 3321 标准 48kHz 系数)→ 400ms 滑动窗(100ms hop)分块 → 两轮门限
/// (absolute -70 LUFS + relative -10 LU)→ gated integrated loudness。
///
/// AVAssetReader 输出已混成单声道,故用单通道滤波后求平方(等价于 BS.1770
/// 单声道情形)。零额外依赖、零权限(网络流复用已有 ATS 配置)。
///
/// 支持渐进式:解码过程中每 progressIntervalMs 调一次 onProgress 推送
/// "截至当前"的 integrated LUFS,供 Dart 侧渐进式应用增益。
enum LoudnessAnalyzer {
    /// - Parameters:
    ///   - maxDurationMs: 最多分析的时长,默认 30 分钟(防异常长文件的安全上限;
    ///     正常歌曲会在解码到 EOS 前结束,得到标准 EBU R128 integrated loudness)。
    ///   - progressIntervalMs: 中途推送进度的间隔(ms)。每解码满此时长,调一次
    ///     onProgress 推送"截至当前"的 LUFS。<=0 表示不推中途进度。默认 500ms。
    ///   - isCancelled: 由调用方持有的取消标志,返回 true 时立即结束解码循环。
    ///     切歌时调用方置 true,避免空跑浪费 CPU。
    ///   - onProgress: 中途进度回调 (lufs, analyzedMs)。不包含最终值。
    static func analyze(
        url: URL,
        maxDurationMs: Int = 1800000,
        progressIntervalMs: Int = 500,
        isCancelled: () -> Bool = { false },
        onProgress: (Double, Int) -> Void = { _, _ in }
    ) throws -> LoudnessResult {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(
                domain: "loudness", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no audio track"]
            )
        }

        let reader = try AVAssetReader(asset: asset)
        // 固定 48kHz 单声道 Float32,直接用 48kHz K-weighting 系数
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMBitDepthKey: 32,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(
                domain: "loudness", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "reader start failed"]
            )
        }

        let sampleRate = 48000
        let meter = GatedLoudnessMeter(sampleRate: sampleRate, channels: 1, maxDurationMs: maxDurationMs)
        // 中途进度推送:每解码满 progressIntervalMs 的音频推一次"截至当前"的 LUFS。
        let progressSamples: Int64 = progressIntervalMs > 0
            ? Int64(sampleRate) * Int64(progressIntervalMs) / 1000
            : Int64.max
        var nextProgressAt: Int64 = progressSamples
        // 墙钟时间限流:解码远快于实时,纯按解码音频时长会导致推送间隔压缩到 ~20ms,
        // 刷屏且无意义。加一层墙钟限制:两次推送间隔不少于 progressWallIntervalMs。
        let progressWallIntervalMs: Int64 = 200
        var lastProgressWallMs: Int64 = 0

        while reader.status == .reading {
            // 切歌/取消:立即跳出循环,不再解码。
            if isCancelled() {
                reader.cancelReading()
                throw NSError(
                    domain: "loudness", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "analysis cancelled"]
                )
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            // 新版 iOS SDK 给 CoreMedia 的 C 函数补了参数标签，老写法
            // （位置参数）会报 Missing argument labels。
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &length,
                totalLengthOut: nil,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else {
                continue
            }
            let frameCount = length / 4 // Float32 = 4 bytes
            var stop = false
            ptr.withMemoryRebound(to: Float.self, capacity: frameCount) { floatPtr in
                stop = !meter.feed(floatPtr, count: frameCount)
            }
            // 推中途进度:integratedLufs() 在任何时刻都能基于已累积的 block
            // 算出"截至当前"的响度,算法上正确(非近似)。
            // 双重限流:(1)解码音频时长满 progressIntervalMs (2)墙钟间隔满
            // progressWallIntervalMs。后者防止快速解码导致推送过密。
            if progressSamples != .max && meter.sampleCount >= nextProgressAt {
                let nowWallMs = Int64(Date().timeIntervalSince1970 * 1000)
                if nowWallMs - lastProgressWallMs >= progressWallIntervalMs {
                    let lufs = meter.integratedLufs()
                    if !lufs.isNaN && !lufs.isInfinite {
                        let analyzedMs = Int(meter.sampleCount * 1000 / Int64(sampleRate))
                        onProgress(lufs, analyzedMs)
                    }
                    lastProgressWallMs = nowWallMs
                }
                nextProgressAt = meter.sampleCount + progressSamples
            }
            if stop { break }
        }
        reader.cancelReading()

        let lufs = meter.integratedLufs()
        if lufs.isNaN || lufs.isInfinite {
            throw NSError(
                domain: "loudness", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no samples decoded"]
            )
        }
        let analyzedMs = Int(meter.sampleCount * 1000 / Int64(sampleRate))
        return LoudnessResult(lufs: lufs, sampleRate: sampleRate, analyzedMs: analyzedMs)
    }
}

/// EBU R128 gated integrated loudness 分块计量器(iOS),与 Android 版算法一致。
/// 流式逐帧喂入 PCM,内部维护 K-weighting 滤波器(状态跨块连续)、400ms 环形缓冲
/// (存 K-weighted 平方值)、100ms hop 产出块,最终两轮门限求得 integrated loudness。
final class GatedLoudnessMeter {
    private let channels: Int
    private let filters: [KWeightingFilter]
    private let blockLen: Int          // 400ms 样本数
    private let hopLen: Int            // 100ms 样本数
    private var ringSq: [[Double]]     // [channel][blockLen] 环形:K-weighted 平方值
    private var runningSum: [Double]   // [channel] 当前窗口内平方和
    private var writePos: Int = 0
    private(set) var sampleCount: Int64 = 0  // 已处理样本数(每通道计数)
    private var blockZs: [Double] = []       // 各块 combined mean square
    private let maxSamplesPerChannel: Int64
    private var totalSq: Double = 0          // 兜底:全段 combined mean square
    private var totalSamples: Int64 = 0

    init(sampleRate: Int, channels: Int, maxDurationMs: Int) {
        precondition(channels >= 1)
        self.channels = min(channels, 2)
        self.filters = (0..<self.channels).map { _ in KWeightingFilter() }
        self.blockLen = max(sampleRate * 400 / 1000, 1)
        self.hopLen = max(sampleRate * 100 / 1000, 1)
        self.ringSq = Array(repeating: Array(repeating: 0.0, count: self.blockLen), count: self.channels)
        self.runningSum = Array(repeating: 0.0, count: self.channels)
        self.maxSamplesPerChannel = Int64(sampleRate) * Int64(maxDurationMs / 1000)
    }

    /// 喂入一块 Float32 PCM(交错)。返回 false 表示已达分析时长上限,应停止喂入。
    func feed(_ data: UnsafePointer<Float>, count: Int) -> Bool {
        let ch = channels
        for frame in 0..<count {
            if sampleCount >= maxSamplesPerChannel { return false }
            var combinedSq: Double = 0
            for c in 0..<ch {
                let f = data[frame * ch + c]
                guard f.isFinite else { continue }
                let x = Double(f)
                let y = filters[c].process(x)
                let sq = y * y
                let old = ringSq[c][writePos]
                runningSum[c] += sq - old
                ringSq[c][writePos] = sq
                combinedSq += sq
            }
            totalSq += combinedSq
            totalSamples += 1
            writePos = (writePos + 1) % blockLen
            sampleCount += 1
            if sampleCount >= Int64(blockLen) &&
                (sampleCount - Int64(blockLen)) % Int64(hopLen) == 0 {
                var z: Double = 0
                for c in 0..<ch { z += runningSum[c] }
                z /= Double(blockLen)
                blockZs.append(z)
            }
        }
        return true
    }

    /// 计算 gated integrated loudness(LUFS)。无有效数据返回 NaN。
    func integratedLufs() -> Double {
        if blockZs.isEmpty || totalSamples == 0 { return .nan }

        let absGate = pow(10.0, (-70.0 + 0.691) / 10.0)
        var absSum: Double = 0
        var absCount = 0
        for z in blockZs {
            if z > absGate { absSum += z; absCount += 1 }
        }
        if absCount == 0 {
            let z = totalSq / Double(totalSamples)
            return -0.691 + 10.0 * log10(max(z, 1e-12))
        }
        let zMeanAbs = absSum / Double(absCount)
        let relGate = zMeanAbs * 0.1
        var relSum: Double = 0
        var relCount = 0
        for z in blockZs {
            if z > absGate && z > relGate { relSum += z; relCount += 1 }
        }
        let finalZ = relCount == 0 ? zMeanAbs : relSum / Double(relCount)
        return -0.691 + 10.0 * log10(max(finalZ, 1e-12))
    }
}

/// EBU R128 K-weighting:两级 biquad 串联(EBU TECH 3321 标准 48kHz 系数,与 Android 端一致)。
final class KWeightingFilter {
    private let stage1: Biquad
    private let stage2: Biquad

    init() {
        // 48kHz 系数(EBU TECH 3321)
        stage1 = Biquad(
            b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
            a1: -1.69065929318241, a2: 0.73248077421585
        )
        stage2 = Biquad(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: -1.99004745483398, a2: 0.99007225036653
        )
    }

    func process(_ x: Double) -> Double {
        stage2.process(stage1.process(x))
    }
}

/// 直接 II 型转置 biquad。y = b0*x + z1; z1 = b1*x - a1*y + z2; z2 = b2*x - a2*y。
final class Biquad {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var z1: Double = 0
    private var z2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
