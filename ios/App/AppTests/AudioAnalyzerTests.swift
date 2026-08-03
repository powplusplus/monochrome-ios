import AVFoundation
import XCTest
@testable import App

/// Covers the "is this FLAC actually FLAC" analysis.
///
/// Two layers: the pure decision functions (cutoff → verdict, LSB mask → depth,
/// badge strings), and an end-to-end pass over real PCM files written to disk, so
/// the `AVAssetReader` decode path and the format-description reading are
/// exercised rather than assumed.
///
/// Test signals are linear chirps: a sweep from 0 Hz to a chosen ceiling has flat
/// energy up to that ceiling once the analyzer averages its windows, and exactly
/// nothing above it — the same shape a lossy encoder's lowpass leaves behind.
final class AudioAnalyzerTests: XCTestCase {

    // MARK: - Spectral cutoff

    func testCutoffFindsAFullBandSignalNearNyquist() throws {
        let signal = Self.chirp(sampleRate: 44_100, seconds: 2, top: 21_500)
        let cutoff = try XCTUnwrap(AudioAnalyzer.spectralCutoff(mono: signal, sampleRate: 44_100))
        XCTAssertEqual(cutoff, 21_500, accuracy: 800)
    }

    func testCutoffFindsTheLowpassOfALossySource() throws {
        // 16 kHz is where a 128 kbps MP3 stops.
        let signal = Self.chirp(sampleRate: 44_100, seconds: 2, top: 16_000)
        let cutoff = try XCTUnwrap(AudioAnalyzer.spectralCutoff(mono: signal, sampleRate: 44_100))
        XCTAssertEqual(cutoff, 16_000, accuracy: 800)
    }

    func testCutoffIsNilWhenThereIsNotEnoughAudio() {
        let signal = Self.chirp(sampleRate: 44_100, seconds: 0.2, top: 20_000)
        XCTAssertNil(AudioAnalyzer.spectralCutoff(mono: signal, sampleRate: 44_100))
    }

    func testCutoffIgnoresSilentWindows() throws {
        // Half the analysed audio is a silent gap. Silence has no high content
        // and would drag the cutoff down if it were averaged in.
        let tone = Self.chirp(sampleRate: 44_100, seconds: 2, top: 21_000)
        let signal = tone + [Float](repeating: 0, count: tone.count)
        let cutoff = try XCTUnwrap(AudioAnalyzer.spectralCutoff(mono: signal, sampleRate: 44_100))
        XCTAssertGreaterThan(cutoff, 19_000)
    }

    func testQuietTrebleIsNotMistakenForALowpass() throws {
        // A bass-heavy master with full-band content sitting ~86 dB under the
        // peak. Judging the cutoff against a fixed level below the loudest bin
        // would condemn this file as a transcode; the cliff test must not.
        let bass = Self.tone(sampleRate: 44_100, seconds: 2, frequency: 100, amplitude: 0.9)
        let treble = Self.chirp(sampleRate: 44_100, seconds: 2, top: 21_500, amplitude: 0.00005)
        let signal = zip(bass, treble).map(+)
        let cutoff = try XCTUnwrap(AudioAnalyzer.spectralCutoff(mono: signal, sampleRate: 44_100))
        XCTAssertGreaterThan(cutoff, 20_500)
    }

    // MARK: - Verdict

    func testFullBandCDAudioIsLossless() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 44_100,
                declaredBitDepth: 16, effectiveBitDepth: 16, cutoffHz: 21_400
            ),
            .lossless
        )
    }

    func testFullBandHiResIsHiResLossless() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 96_000,
                declaredBitDepth: 24, effectiveBitDepth: 24, cutoffHz: 34_000
            ),
            .hiResLossless
        )
    }

    func testTwentyFourBitAtCDRateIsStillHiRes() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 44_100,
                declaredBitDepth: 24, effectiveBitDepth: 24, cutoffHz: 21_400
            ),
            .hiResLossless
        )
    }

    func testEncoderLowpassIsReportedAsTranscoded() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 44_100,
                declaredBitDepth: 16, effectiveBitDepth: 16, cutoffHz: 16_000
            ),
            .transcoded
        )
    }

    func testAHiResContainerWithALossyLowpassIsTranscodedNotUpsampled() {
        // Worst of both. The transcode is the more damning fact, so it wins.
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 96_000,
                declaredBitDepth: 24, effectiveBitDepth: 24, cutoffHz: 19_000
            ),
            .transcoded
        )
    }

    func testCDContentAtAHiResRateIsUpsampled() {
        // Full band for its source, but nothing above 22.05 kHz — a CD rip that
        // was resampled, not a hi-res master.
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 96_000,
                declaredBitDepth: 24, effectiveBitDepth: 24, cutoffHz: 22_050
            ),
            .upsampled
        )
    }

    func testDeadLowBitsAreReportedAsPadded() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 44_100,
                declaredBitDepth: 24, effectiveBitDepth: 16, cutoffHz: 21_400
            ),
            .padded
        )
    }

    func testLossyContainerIsNotAccused() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: false, sampleRate: 44_100,
                declaredBitDepth: nil, effectiveBitDepth: nil, cutoffHz: 16_000
            ),
            .lossy
        )
    }

    func testNoMeasurableCutoffIsInconclusiveRatherThanACondemnation() {
        XCTAssertEqual(
            AudioAnalyzer.verdict(
                isLossless: true, sampleRate: 44_100,
                declaredBitDepth: 16, effectiveBitDepth: nil, cutoffHz: nil
            ),
            .inconclusive
        )
    }

    // MARK: - Bit depth

    func testEffectiveBitDepthCountsTheDeadLowBits() {
        // 24-bit content left-aligned in 32-bit words: 8 dead bits.
        XCTAssertEqual(AudioAnalyzer.effectiveBitDepth(orMask: 0xFFFF_FF00), 24)
        // A 16-bit source widened to 24: 16 dead bits.
        XCTAssertEqual(AudioAnalyzer.effectiveBitDepth(orMask: 0xFFFF_0000), 16)
        XCTAssertEqual(AudioAnalyzer.effectiveBitDepth(orMask: 0x0000_0001), 32)
    }

    func testDigitalSilenceProvesNothingAboutBitDepth() {
        XCTAssertNil(AudioAnalyzer.effectiveBitDepth(orMask: 0))
    }

    // MARK: - Format description

    func testFlacSourceDepthComesFromTheFormatFlags() {
        // `mBitsPerChannel` is 0 for compressed formats; the source depth rides
        // in `mFormatFlags` for both FLAC and ALAC.
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatFLAC
        asbd.mFormatFlags = UInt32(kAppleLosslessFormatFlag_24BitSourceData)
        XCTAssertEqual(AudioAnalyzer.sourceBitDepth(asbd), 24)

        asbd.mFormatFlags = UInt32(kAppleLosslessFormatFlag_16BitSourceData)
        XCTAssertEqual(AudioAnalyzer.sourceBitDepth(asbd), 16)
    }

    func testLinearPCMDepthComesFromTheHeader() {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mBitsPerChannel = 24
        XCTAssertEqual(AudioAnalyzer.sourceBitDepth(asbd), 24)
    }

    func testLossyCodecsAreNotDecoded() {
        XCTAssertFalse(AudioAnalyzer.isLosslessCodec(kAudioFormatMPEG4AAC))
        XCTAssertFalse(AudioAnalyzer.isLosslessCodec(kAudioFormatMPEGLayer3))
        XCTAssertTrue(AudioAnalyzer.isLosslessCodec(kAudioFormatFLAC))
        XCTAssertTrue(AudioAnalyzer.isLosslessCodec(kAudioFormatAppleLossless))
    }

    func testAdaptiveManifestsAreSkipped() {
        XCTAssertTrue(AudioAnalyzer.isAdaptiveManifest(URL(string: "https://cdn.example/a.m3u8")!))
        XCTAssertTrue(AudioAnalyzer.isAdaptiveManifest(URL(string: "https://cdn.example/a.mpd")!))
        XCTAssertFalse(AudioAnalyzer.isAdaptiveManifest(URL(string: "https://cdn.example/a.flac")!))
    }

    // MARK: - Badge strings

    func testDetailLabelReportsDepthOverRate() {
        XCTAssertEqual(Self.analysis(verdict: .hiResLossless, rate: 96_000, declared: 24).detailLabel, "24/96")
        XCTAssertEqual(Self.analysis(verdict: .lossless, rate: 44_100, declared: 16).detailLabel, "16/44.1")
    }

    func testPaddedFilesReportTheirRealDepth() {
        // The whole point: never print the claim the analysis just disproved.
        let analysis = Self.analysis(verdict: .padded, rate: 44_100, declared: 24, effective: 16)
        XCTAssertEqual(analysis.detailLabel, "16/44.1")
        XCTAssertEqual(analysis.warning, "16-bit source, padded")
    }

    func testWarningNamesTheCutoffForTranscodes() {
        let analysis = Self.analysis(verdict: .transcoded, rate: 44_100, declared: 16, cutoff: 16_040)
        XCTAssertEqual(analysis.warning, "Lossy source · 16.0 kHz cutoff")
        XCTAssertEqual(analysis.tier, .high)
        XCTAssertFalse(analysis.isHonestLossless)
    }

    func testHonestLosslessCarriesNoWarning() {
        let analysis = Self.analysis(verdict: .hiResLossless, rate: 96_000, declared: 24, cutoff: 40_000)
        XCTAssertNil(analysis.warning)
        XCTAssertEqual(analysis.tier, .hiResLossless)
        XCTAssertTrue(analysis.isHonestLossless)
    }

    func testInconclusiveAnalysisLeavesTheBadgeAlone() {
        XCTAssertNil(Self.analysis(verdict: .inconclusive, rate: 44_100, declared: nil).tier)
    }

    func testLossyDetailPrefersBitrate() {
        var analysis = Self.analysis(verdict: .lossy, rate: 44_100, declared: nil)
        analysis.bitrateKbps = 320
        XCTAssertEqual(analysis.detailLabel, "320 kbps")
    }

    // MARK: - End to end

    func testFullBandFileIsAcceptedAsLossless() async throws {
        let url = try Self.writeWAV(
            samples: Self.chirp(sampleRate: 44_100, seconds: 3, top: 21_500),
            sampleRate: 44_100, bitDepth: 16
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try XCTUnwrap(await AudioAnalyzer.analyze(url: url))
        XCTAssertEqual(analysis.codec, "WAV")
        XCTAssertEqual(analysis.sampleRate, 44_100)
        XCTAssertEqual(analysis.verdict, .lossless)
        XCTAssertNil(analysis.warning)
    }

    func testLowpassedFileIsCaughtAsATranscode() async throws {
        let url = try Self.writeWAV(
            samples: Self.chirp(sampleRate: 44_100, seconds: 3, top: 16_000),
            sampleRate: 44_100, bitDepth: 16
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try XCTUnwrap(await AudioAnalyzer.analyze(url: url))
        XCTAssertEqual(analysis.verdict, .transcoded)
        XCTAssertEqual(try XCTUnwrap(analysis.cutoffHz), 16_000, accuracy: 900)
    }

    func testCDBandwidthAtNinetySixKilohertzIsCaughtAsUpsampled() async throws {
        let url = try Self.writeWAV(
            samples: Self.chirp(sampleRate: 96_000, seconds: 3, top: 22_000),
            sampleRate: 96_000, bitDepth: 24
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try XCTUnwrap(await AudioAnalyzer.analyze(url: url))
        XCTAssertEqual(analysis.sampleRate, 96_000)
        XCTAssertEqual(analysis.verdict, .upsampled)
    }

    // MARK: - Fixtures

    /// Linear sweep from 0 Hz to `top`. Averaged over the analyzer's windows this
    /// is flat to `top` and empty above it.
    private static func chirp(
        sampleRate: Double, seconds: Double, top: Double, amplitude: Float = 0.5
    ) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float]()
        samples.reserveCapacity(count)
        var phase = 0.0
        let sweepRate = top / seconds
        for index in 0 ..< count {
            let frequency = sweepRate * (Double(index) / sampleRate)
            phase += 2 * .pi * frequency / sampleRate
            samples.append(Float(sin(phase)) * amplitude)
        }
        return samples
    }

    private static func tone(
        sampleRate: Double, seconds: Double, frequency: Double, amplitude: Float
    ) -> [Float] {
        (0 ..< Int(sampleRate * seconds)).map { index in
            Float(sin(2 * .pi * frequency * Double(index) / sampleRate)) * amplitude
        }
    }

    /// Minimal RIFF/PCM writer — enough for `AVAssetReader` to open the file.
    private static func writeWAV(samples: [Float], sampleRate: Int, bitDepth: Int) throws -> URL {
        precondition(bitDepth == 16 || bitDepth == 24)
        let bytesPerSample = bitDepth / 8
        var payload = Data(capacity: samples.count * bytesPerSample)
        let peak = Double((1 << (bitDepth - 1)) - 1)
        for sample in samples {
            let value = Int32((Double(sample).clamped(to: -1 ... 1) * peak).rounded())
            for byte in 0 ..< bytesPerSample {
                payload.append(UInt8((value >> (8 * byte)) & 0xFF))
            }
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                                  // PCM chunk size
        append(UInt16(1))                                   // PCM
        append(UInt16(1))                                   // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))         // byte rate
        append(UInt16(bytesPerSample))                      // block align
        append(UInt16(bitDepth))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payload.count))
        data.append(payload)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func analysis(
        verdict: AudioAnalysis.Verdict,
        rate: Double,
        declared: Int?,
        effective: Int? = nil,
        cutoff: Double? = nil
    ) -> AudioAnalysis {
        AudioAnalysis(
            codec: "FLAC", sampleRate: rate, declaredBitDepth: declared,
            effectiveBitDepth: effective ?? declared, channels: 2,
            bitrateKbps: nil, cutoffHz: cutoff, verdict: verdict
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
