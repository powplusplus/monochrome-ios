import AVFoundation
import Accelerate
import Foundation

/// What the decoded samples say about a stream, as opposed to what its container
/// and provider claim. A `.flac` extension only proves the *container*: a FLAC
/// encoded from a 128 kbps MP3 is still FLAC, and a CD rip resampled to 96 kHz
/// still reports 24/96 in its header. Both are visible in the spectrum.
struct AudioAnalysis: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable {
        /// Full-band lossless at CD-ish rate/depth.
        case lossless
        /// Full-band lossless with real content above CD Nyquist, or >16-bit.
        case hiResLossless
        /// Lossless container, lossy source: a hard encoder lowpass is present.
        case transcoded
        /// Hi-res rate declared, nothing above CD Nyquist in the audio.
        case upsampled
        /// 24/32-bit container whose low bits are dead — a 16-bit source widened.
        case padded
        /// Lossy container. Nothing to expose; the badge already says so.
        case lossy
        /// Not enough usable audio to judge (silence, unreadable, HLS/DASH).
        case inconclusive
    }

    var codec: String
    var sampleRate: Double
    /// Bit depth the container declares (FLAC/ALAC source-data flag, PCM header).
    var declaredBitDepth: Int?
    /// Bit depth actually occupied by the samples.
    var effectiveBitDepth: Int?
    var channels: Int
    var bitrateKbps: Int?
    /// Highest frequency still carrying energy.
    var cutoffHz: Double?
    var verdict: Verdict

    /// True when the audio is what the badge would otherwise imply.
    var isHonestLossless: Bool {
        verdict == .lossless || verdict == .hiResLossless
    }

    /// The tier the *audio* supports, which overrides the provider's claim.
    /// `nil` when the analysis proved nothing, so the caller keeps its own guess.
    var tier: PlaybackQuality? {
        switch verdict {
        case .hiResLossless: return .hiResLossless
        case .lossless, .padded: return .lossless
        case .transcoded, .upsampled, .lossy: return .high
        case .inconclusive: return nil
        }
    }

    /// `24/96`-style detail next to the badge. Measured depth wins over the
    /// declared one — reporting `24/44.1` for a padded 16-bit file is the exact
    /// lie this analysis exists to catch.
    var detailLabel: String? {
        if verdict == .lossy {
            if let bitrateKbps, bitrateKbps > 0 { return "\(bitrateKbps) kbps" }
            return sampleRate > 0 ? Self.rateLabel(sampleRate) : nil
        }
        guard sampleRate > 0 else { return nil }
        let depth = verdict == .padded
            ? (effectiveBitDepth ?? declaredBitDepth)
            : (declaredBitDepth ?? effectiveBitDepth)
        guard let depth else { return Self.rateLabel(sampleRate) }
        return "\(depth)/\(Self.rateLabel(sampleRate))"
    }

    /// One short line under the badge when the file is not what it claims.
    var warning: String? {
        switch verdict {
        case .transcoded:
            guard let cutoffHz else { return "Lossy source" }
            return "Lossy source · \(Self.kilohertzLabel(cutoffHz)) cutoff"
        case .upsampled:
            guard let cutoffHz else { return "Upsampled" }
            return "Upsampled · \(Self.kilohertzLabel(cutoffHz)) cutoff"
        case .padded:
            guard let effectiveBitDepth else { return "Padded bit depth" }
            return "\(effectiveBitDepth)-bit source, padded"
        case .lossless, .hiResLossless, .lossy, .inconclusive:
            return nil
        }
    }

    /// `44.1`, `48`, `96` — trailing `.0` dropped so the badge stays narrow.
    static func rateLabel(_ hertz: Double) -> String {
        let kilohertz = hertz / 1000
        let rounded = (kilohertz * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    static func kilohertzLabel(_ hertz: Double) -> String {
        String(format: "%.1f kHz", hertz / 1000)
    }
}

/// Decodes a couple of seconds of the real file and reports what is in it.
///
/// Deliberately *not* driven off the playing item: the level meter's
/// `MTAudioProcessingTap` sees float samples after AVPlayer's own conversion, so
/// the quantisation evidence for bit depth is gone by then. A separate
/// `AVAssetReader` gets integer samples at the file's native rate, which is what
/// both tests below need.
enum AudioAnalyzer {
    /// Seconds decoded per window. Two 4 s windows cost ~1 MB on a CD-rate FLAC
    /// and ~2.5 MB on 24/96 — the price of the feature on a streamed track.
    static let windowSeconds: Double = 4
    /// Where the windows start, as fractions of the track. One window is not
    /// enough: an intro, a fade or a quiet passage has no high content and would
    /// read as a brutal lowpass, condemning a genuine master as a transcode.
    static let windowStarts: [Double] = [0.25, 0.6]
    /// Above every lossy encoder's lowpass — 128 kbps MP3 ≈ 16 kHz, LAME V0 ≈
    /// 19.5 kHz, 320 kbps CBR ≈ 20.5 kHz, AAC ≈ 19–20 kHz — and below the ~21.5 kHz
    /// a real 44.1 kHz master reaches, so a full-band CD rip never trips the
    /// transcode test while a 320-sourced "FLAC" still does. Masters that were
    /// themselves filtered below this (old digital transfers) read as transcodes;
    /// no spectral test can tell those two apart.
    static let transcodeCeilingHz: Double = 21_000
    /// A CD source upsampled to 96 kHz still stops dead at 22.05 kHz. Sits just
    /// above that rather than higher up, because plenty of honest hi-res masters
    /// come off tape and carry little past ~25 kHz.
    static let hiResContentFloorHz: Double = 22_600
    /// 88.2 kHz and up. 48 kHz files are not "hi-res" by rate alone.
    static let hiResSampleRateHz: Double = 64_000
    private static let fftSize = 4096
    /// How big a step counts as an encoder lowpass rather than a mix getting
    /// darker. Real transcodes drop 40–80 dB at the cut; 25 dB leaves margin for
    /// the FFT window's skirts without catching ordinary treble rolloff.
    static let lowpassDropDB: Float = 25

    /// `nil` when the URL cannot be analysed at all (adaptive manifest, no audio
    /// track, unreadable) — the caller then keeps whatever the provider said.
    static func analyze(url: URL, headers: [String: String] = [:]) async -> AudioAnalysis? {
        guard !isAdaptiveManifest(url) else { return nil }
        return await Task.detached(priority: .utility) { () -> AudioAnalysis? in
            let options: [String: Any]? = headers.isEmpty
                ? nil
                : ["AVURLAssetHTTPHeaderFieldsKey": headers]
            let asset = AVURLAsset(url: url, options: options)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let descriptions = try? await track.load(.formatDescriptions),
                  let asbd = descriptions
                    .compactMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
                    .first
            else { return nil }

            let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let rate = try? await track.load(.estimatedDataRate)
            let bitrate = rate.map { Int(($0 / 1000).rounded()) }.flatMap { $0 > 0 ? $0 : nil }

            guard isLosslessCodec(asbd.mFormatID) else {
                // Nothing to expose: an AAC stream badged AAC is already honest,
                // and decoding it would only spend bandwidth to say so.
                return AudioAnalysis(
                    codec: codecName(asbd.mFormatID),
                    sampleRate: sampleRate,
                    declaredBitDepth: nil,
                    effectiveBitDepth: nil,
                    channels: channels,
                    bitrateKbps: bitrate,
                    cutoffHz: nil,
                    verdict: .lossy
                )
            }

            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            var mono: [Float] = []
            var orMask: UInt32 = 0
            for fraction in windowStarts {
                guard !Task.isCancelled else { return nil }
                guard let window = try? decodeWindow(
                    asset: asset, track: track, duration: duration, startFraction: fraction
                ) else { continue }
                mono.append(contentsOf: window.samples)
                orMask |= window.orMask
            }

            let effective = effectiveBitDepth(orMask: orMask)
            let cutoff = spectralCutoff(mono: mono, sampleRate: sampleRate)
            let declared = sourceBitDepth(asbd)
            return AudioAnalysis(
                codec: codecName(asbd.mFormatID),
                sampleRate: sampleRate,
                declaredBitDepth: declared,
                effectiveBitDepth: effective,
                channels: channels,
                bitrateKbps: bitrate,
                cutoffHz: cutoff,
                verdict: verdict(
                    isLossless: true,
                    sampleRate: sampleRate,
                    declaredBitDepth: declared,
                    effectiveBitDepth: effective,
                    cutoffHz: cutoff
                )
            )
        }.value
    }

    // MARK: - Verdict

    static func verdict(
        isLossless: Bool,
        sampleRate: Double,
        declaredBitDepth: Int?,
        effectiveBitDepth: Int?,
        cutoffHz: Double?
    ) -> AudioAnalysis.Verdict {
        guard isLossless else { return .lossy }
        guard let cutoffHz, sampleRate > 0 else { return .inconclusive }
        let nyquist = sampleRate / 2
        // Clear the ceiling every lossy encoder cuts below — or, for files whose
        // own Nyquist is lower than that ceiling, reach their Nyquist instead, so
        // a legitimately low-rate lossless file is not condemned for it.
        guard cutoffHz >= min(nyquist * 0.98, transcodeCeilingHz) else { return .transcoded }
        if sampleRate >= hiResSampleRateHz, cutoffHz < hiResContentFloorHz { return .upsampled }
        if let declaredBitDepth, declaredBitDepth >= 24,
           let effectiveBitDepth, effectiveBitDepth <= 16 {
            return .padded
        }
        if sampleRate > 48_000 || (declaredBitDepth ?? effectiveBitDepth ?? 16) >= 20 {
            return .hiResLossless
        }
        return .lossless
    }

    /// CoreAudio hands 24-bit FLAC/ALAC back left-aligned in 32-bit integers, so
    /// the run of always-zero low bits is exactly the padding. A file whose LSBs
    /// are dead below its declared depth was widened, not mastered that way.
    ///
    /// Under a right-aligning converter this reads *higher* than the truth, so it
    /// can miss padding — it can never invent it. `nil` for digital silence,
    /// which says nothing either way.
    static func effectiveBitDepth(orMask: UInt32) -> Int? {
        guard orMask != 0 else { return nil }
        return 32 - orMask.trailingZeroBitCount
    }

    // MARK: - Spectrum

    /// Where the audio stops, found as the *cliff* in the averaged spectrum
    /// rather than by an absolute level. A lossy encoder zeroes everything above
    /// its lowpass, leaving a 40–80 dB step and a dead band all the way to
    /// Nyquist; music itself never does that.
    ///
    /// Deliberately not "the highest bin above -80 dB of the peak": plenty of
    /// honest masters sit 80–90 dB down at 18 kHz — bass-heavy peak, quiet
    /// treble — and a fixed floor would call every one of them a transcode. The
    /// step is self-calibrating, so it holds for loud and quiet material alike.
    ///
    /// Returns Nyquist when there is no cliff (nothing was cut), and `nil` when
    /// there was not enough non-silent audio to judge.
    static func spectralCutoff(
        mono: [Float],
        sampleRate: Double,
        fftSize: Int = AudioAnalyzer.fftSize,
        dropDB: Float = AudioAnalyzer.lowpassDropDB,
        minimumWindows: Int = 6
    ) -> Double? {
        guard sampleRate > 0, mono.count >= fftSize * minimumWindows,
              let fft = RealFFT(size: fftSize) else { return nil }
        let bins = fftSize / 2
        let window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized,
            count: fftSize, isHalfWindow: false
        )
        var power = [Float](repeating: 0, count: bins)
        var usable = 0
        var offset = 0
        while offset + fftSize <= mono.count {
            defer { offset += fftSize }
            let slice = Array(mono[offset ..< offset + fftSize])
            // Near-silence has no high content to find and would read as a
            // lowpass. This keeps genuinely soft passages and drops dead air.
            guard vDSP.rootMeanSquare(slice) > 0.0005 else { continue }
            power = vDSP.add(power, fft.power(of: vDSP.multiply(slice, window)))
            usable += 1
        }
        guard usable >= minimumWindows else { return nil }

        // Bands of 8 bins (~86 Hz at 44.1 kHz) so one noisy bin cannot move the
        // answer. Bin 0 is skipped: vDSP packs DC *and* Nyquist into it.
        let bandBins = 8
        let bandCount = (bins - 1) / bandBins
        guard bandCount > 16 else { return nil }
        let floorPower = Float(1e-20)
        var levels = [Float](repeating: 0, count: bandCount)
        for band in 0 ..< bandCount {
            let start = 1 + band * bandBins
            let mean = power[start ..< start + bandBins].reduce(0, +) / Float(bandBins)
            levels[band] = 10 * log10(max(mean, floorPower))
        }

        let nyquist = sampleRate / 2
        let bandWidth = nyquist / Double(bandCount)
        // No encoder cuts below 5 kHz, and a step down there is music, not a
        // filter. Leave a few bands at the top so "the band above" means something.
        let firstCandidate = max(1, Int((5_000 / bandWidth).rounded()))
        let lastCandidate = bandCount - 4
        guard firstCandidate < lastCandidate else { return nyquist }

        var bestDrop: Float = 0
        var bestBand = bandCount
        let lookBehind = 8
        for band in firstCandidate ... lastCandidate {
            let behind = levels[max(0, band - lookBehind) ..< band]
            // Everything above the candidate, not a window of it: a dip in the
            // middle of a mix recovers further up, a filter never does.
            let ahead = levels[band ..< bandCount]
            let drop = behind.reduce(0, +) / Float(behind.count)
                - ahead.reduce(0, +) / Float(ahead.count)
            if drop > bestDrop {
                bestDrop = drop
                bestBand = band
            }
        }
        guard bestDrop >= dropDB, bestBand < bandCount else { return nyquist }
        return Double(bestBand) * bandWidth
    }

    /// Real-to-complex FFT. A type rather than a function so the split-complex
    /// buffers are allocated once per analysis instead of once per window.
    private final class RealFFT {
        let size: Int
        private let fft: vDSP.FFT<DSPSplitComplex>
        private var inputReal: [Float]
        private var inputImaginary: [Float]
        private var outputReal: [Float]
        private var outputImaginary: [Float]

        init?(size: Int) {
            let log2n = vDSP_Length(log2(Double(size)))
            guard size > 0, Int(1) << Int(log2n) == size,
                  let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
            else { return nil }
            self.size = size
            self.fft = fft
            let half = size / 2
            inputReal = [Float](repeating: 0, count: half)
            inputImaginary = [Float](repeating: 0, count: half)
            outputReal = [Float](repeating: 0, count: half)
            outputImaginary = [Float](repeating: 0, count: half)
        }

        /// Squared magnitude per bin (`size / 2` bins).
        func power(of samples: [Float]) -> [Float] {
            let half = size / 2
            var magnitudes = [Float](repeating: 0, count: half)
            samples.withUnsafeBufferPointer { source in
                source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { interleaved in
                    inputReal.withUnsafeMutableBufferPointer { inR in
                        inputImaginary.withUnsafeMutableBufferPointer { inI in
                            var input = DSPSplitComplex(realp: inR.baseAddress!, imagp: inI.baseAddress!)
                            vDSP_ctoz(interleaved, 2, &input, 1, vDSP_Length(half))
                            outputReal.withUnsafeMutableBufferPointer { outR in
                                outputImaginary.withUnsafeMutableBufferPointer { outI in
                                    var output = DSPSplitComplex(
                                        realp: outR.baseAddress!, imagp: outI.baseAddress!
                                    )
                                    fft.forward(input: input, output: &output)
                                    vDSP_zvmags(&output, 1, &magnitudes, 1, vDSP_Length(half))
                                }
                            }
                        }
                    }
                }
            }
            return magnitudes
        }
    }

    // MARK: - Decoding

    private struct Window {
        var samples: [Float]
        var orMask: UInt32
    }

    /// Decodes one window as native-rate signed 32-bit PCM. Resampling is
    /// deliberately not requested: a converter's own filter would plant exactly
    /// the lowpass this analysis looks for.
    private static func decodeWindow(
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: Double,
        startFraction: Double
    ) throws -> Window {
        let reader = try AVAssetReader(asset: asset)
        if duration.isFinite, duration > windowSeconds * 2 {
            let start = max(0, min(duration - windowSeconds, duration * startFraction))
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: windowSeconds, preferredTimescale: 600)
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ServiceError.invalidResponse }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ServiceError.invalidResponse }
        defer { reader.cancelReading() }

        // Hard cap so a pathological file cannot balloon memory: one window at
        // 192 kHz plus slack.
        let frameCap = Int(windowSeconds * 192_000 * 1.1)
        var samples: [Float] = []
        samples.reserveCapacity(min(frameCap, Int(windowSeconds * 48_000)))
        var orMask: UInt32 = 0
        var channels = 1

        while samples.count < frameCap, let buffer = output.copyNextSampleBuffer() {
            if let format = CMSampleBufferGetFormatDescription(buffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
               asbd.mChannelsPerFrame > 0 {
                channels = Int(asbd.mChannelsPerFrame)
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Int32>.size else { continue }
            var words = [Int32](repeating: 0, count: length / MemoryLayout<Int32>.size)
            let copied = words.withUnsafeMutableBytes { destination -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: destination.baseAddress!
                )
            }
            guard copied == noErr else { continue }
            // Padding is a property of the file, so the mask takes every channel;
            // the spectrum only needs one, and a downmix would blur mid/side.
            for word in words { orMask |= UInt32(bitPattern: word) }
            for index in stride(from: 0, to: words.count, by: channels) {
                samples.append(Float(words[index]) / Float(Int32.max))
            }
        }
        if reader.status == .failed { throw reader.error ?? ServiceError.invalidResponse }
        return Window(samples: samples, orMask: orMask)
    }

    // MARK: - Format

    static func isLosslessCodec(_ formatID: AudioFormatID) -> Bool {
        switch formatID {
        case kAudioFormatFLAC, kAudioFormatAppleLossless, kAudioFormatLinearPCM:
            return true
        default:
            return false
        }
    }

    /// FLAC and ALAC both report their source depth through `mFormatFlags`
    /// (`kAppleLosslessFormatFlag_*`), not `mBitsPerChannel` — that field is 0
    /// for compressed formats.
    static func sourceBitDepth(_ asbd: AudioStreamBasicDescription) -> Int? {
        switch asbd.mFormatID {
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            switch asbd.mFormatFlags {
            case UInt32(kAppleLosslessFormatFlag_16BitSourceData): return 16
            case UInt32(kAppleLosslessFormatFlag_20BitSourceData): return 20
            case UInt32(kAppleLosslessFormatFlag_24BitSourceData): return 24
            case UInt32(kAppleLosslessFormatFlag_32BitSourceData): return 32
            default: return nil
            }
        case kAudioFormatLinearPCM:
            return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        default:
            return nil
        }
    }

    static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatLinearPCM: return "WAV"
        case kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatOpus: return "OPUS"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return "AAC"
        default:
            return "AUDIO"
        }
    }

    /// HLS/DASH cannot be read by `AVAssetReader`, and its segments are not the
    /// original file anyway.
    static func isAdaptiveManifest(_ url: URL) -> Bool {
        ["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
    }
}
