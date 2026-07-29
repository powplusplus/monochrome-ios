import Foundation
import CommonCrypto

/// Ports Monochrome's SW Amazon CENC decryptor enough for AVPlayer: download
/// encrypted fMP4, AES-CTR decrypt samples from `senc`, strip DRM boxes.
enum AmazonCencDecryptor {
    static func decryptFile(from sourceURL: URL, keyHex: String, codec: String = "flac", session: URLSession = .shared) async throws -> URL {
        guard let key = Data(hexString: keyHex), key.count == 16 else {
            throw ServiceError.malformed("Amazon decryption key")
        }

        // Every play used to download and decrypt the whole file again, even when
        // it was the same track seconds earlier — repeat-one, a scrub past the end
        // and back, or simply replaying an album re-paid the full cost. The signed
        // query string rotates per request but the object behind it does not, so
        // key the cache on the stable part of the URL.
        let target = cacheURL(for: sourceURL, codec: codec)
        if let existing = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, existing > 0 {
            return target
        }
        _ = pruneCacheOnce

        var latestError: Error = ServiceError.unavailable("Amazon stream download failed")
        for attempt in 0..<4 {
            do {
                let (data, response) = try await session.data(from: sourceURL)
                guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
                guard data.count > 4096 else { throw ServiceError.malformed("Amazon stream was truncated") }
                let clear = try decrypt(data: data, key: key, codec: codec)
                try clear.write(to: target, options: .atomic)
                return target
            } catch {
                latestError = error
                guard attempt < 3, isRetryable(error) else { throw error }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(350 + attempt * 650) * 1_000_000)
            }
        }
        throw latestError
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(urlError.code)
        }
        if let serviceError = error as? ServiceError, case .http(let status) = serviceError {
            // 403/404 commonly mean the signed CDN URL expired between lookup and
            // download; the outer resolver will mint a fresh URL if this one stays bad.
            return status == 403 || status == 404 || status == 408 || status == 429 || status >= 500
        }
        return false
    }

    private static func cacheURL(for sourceURL: URL, codec: String) -> URL {
        let seed = (sourceURL.host ?? "") + sourceURL.path
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let seedBytes = Data(seed.utf8)
        seedBytes.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(seedBytes.count), &digest) }
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("monochrome-amz-\(name)-\(codec).m4a")
    }

    /// Decrypted FLAC runs tens of megabytes a track. The OS clears the temp
    /// directory eventually, but not before a long session can fill a device, so
    /// drop yesterday's files. `static let` gives us a thread-safe run-once
    /// without a flag or a lock.
    private static let pruneCacheOnce: Void = {
        let directory = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries where entry.lastPathComponent.hasPrefix("monochrome-amz-") {
                let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let modified, modified > cutoff { continue }
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }()

    static func decrypt(data: Data, key: Data, codec: String = "flac") throws -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        var offset = 0
        var sampleSizes: [Int] = []
        var sampleIVs: [Data] = []
        var defaultSampleSize = 0

        while offset + 8 <= data.count {
            let (boxSize, headerSize, type) = try readBoxHeader(data, at: offset)
            guard boxSize >= headerSize, offset + boxSize <= data.count else { break }

            if ["moov", "trak", "mdia", "minf", "stbl", "moof", "traf"].contains(type) {
                output.append(data.subdata(in: offset..<(offset + headerSize)))
                offset += headerSize
                continue
            }

            let box = data.subdata(in: offset..<(offset + boxSize))
            if type == "tfhd" {
                // `trun` may omit per-sample sizes and defer to tfhd's
                // default_sample_size; without it those samples stay encrypted.
                if let size = parseTfhdDefaultSampleSize(box) { defaultSampleSize = size }
                output.append(box)
            } else if type == "trun" {
                parseTrun(box, sampleSizes: &sampleSizes, defaultSampleSize: &defaultSampleSize)
                output.append(box)
            } else if type == "senc" {
                sampleIVs = parseSenc(box)
                var free = box
                renameBoxToFree(&free)
                output.append(free)
            } else if type == "stsd" {
                // Amazon delivers encrypted `enca` sample entries. AVPlayer refuses
                // them, so rewrite `enca` -> real codec fourcc and swap the DRM `sinf`
                // for a FLAC `dfLa` config (ports sw-decrypter.js `modifyBox`).
                output.append(modifyStsd(box, codec: codec))
            } else if ["sinf", "sbgp", "sgpd", "pssh"].contains(type) {
                var free = box
                renameBoxToFree(&free)
                output.append(free)
            } else if type == "mdat" {
                let header = box.prefix(headerSize)
                output.append(header)
                let payload = Data(box.dropFirst(headerSize))
                if sampleSizes.isEmpty {
                    output.append(payload)
                } else {
                    var cursor = 0
                    for (index, size) in sampleSizes.enumerated() {
                        guard size > 0, cursor + size <= payload.count else { break }
                        let sample = payload.subdata(in: cursor..<(cursor + size))
                        let iv = index < sampleIVs.count ? sampleIVs[index] : Data(count: 16)
                        output.append(aesCTR(key: key, iv: iv, data: sample))
                        cursor += size
                    }
                    if cursor < payload.count {
                        output.append(payload.subdata(in: cursor..<payload.count))
                    }
                }
                sampleSizes.removeAll(keepingCapacity: true)
                sampleIVs.removeAll(keepingCapacity: true)
            } else {
                output.append(box)
            }
            offset += boxSize
        }
        return output
    }

    /// Faithful port of sw-decrypter.js `modifyBox` for the `stsd` box: rewrite the
    /// encrypted `enca` sample entry to the clear codec fourcc, and for FLAC replace
    /// the DRM `sinf` with a `dfLa` decoder-config box (preserving an existing dfLa
    /// when present). Byte-scan heuristic matches the reference implementation.
    private static func modifyStsd(_ box: Data, codec: String) -> Data {
        var bytes = [UInt8](box)
        guard bytes.count > 12 else { return box }
        let wantFlac = codec == "flac"
        var isFlac = false
        let hasDfLa = containsBox(bytes, "dfLa")

        var i = 8
        while i < bytes.count - 4 {
            // 'enca' -> clear codec fourcc
            if bytes[i] == 0x65, bytes[i + 1] == 0x6e, bytes[i + 2] == 0x63, bytes[i + 3] == 0x61 {
                if wantFlac {
                    bytes[i] = 0x66; bytes[i + 1] = 0x4c; bytes[i + 2] = 0x61; bytes[i + 3] = 0x43 // fLaC
                    isFlac = true
                } else {
                    bytes[i] = 0x6d; bytes[i + 1] = 0x70; bytes[i + 2] = 0x34; bytes[i + 3] = 0x61 // mp4a
                }
            }

            // 'sinf' -> dfLa (FLAC only). Needs the size dword at i-4.
            if isFlac, i >= 4,
               bytes[i] == 0x73, bytes[i + 1] == 0x69, bytes[i + 2] == 0x6e, bytes[i + 3] == 0x66 {
                let start = i - 4
                let sinfSize = Int(readU32(bytes, start))
                guard sinfSize >= 8, start + sinfSize <= bytes.count else { i += 1; continue }
                if hasDfLa {
                    renameNestedToFree(&bytes, at: start, size: sinfSize)
                } else if sinfSize >= 50 {
                    // 50-byte dfLa (FullBox) with dummy 44.1kHz/16-bit/stereo STREAMINFO.
                    let dfLa: [UInt8] = [
                        0x00, 0x00, 0x00, 0x32, 0x64, 0x66, 0x4c, 0x61,
                        0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x22,
                        0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x0a, 0xc4, 0x42, 0xf0, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00,
                    ]
                    for k in 0..<50 { bytes[start + k] = dfLa[k] }
                    let remaining = sinfSize - 50
                    if remaining >= 8 {
                        writeU32(&bytes, start + 50, UInt32(remaining))
                        bytes[start + 54] = 0x66; bytes[start + 55] = 0x72
                        bytes[start + 56] = 0x65; bytes[start + 57] = 0x65 // free
                        for j in (start + 58)..<(start + sinfSize) { bytes[j] = 0x00 }
                    }
                }
            }
            i += 1
        }
        return Data(bytes)
    }

    private static func containsBox(_ bytes: [UInt8], _ type: String) -> Bool {
        let t = [UInt8](type.utf8)
        guard t.count == 4, bytes.count >= 8 else { return false }
        var i = 4
        while i < bytes.count - 4 {
            if bytes[i] == t[0], bytes[i + 1] == t[1], bytes[i + 2] == t[2], bytes[i + 3] == t[3] {
                let size = Int(readU32(bytes, i - 4))
                if size >= 8, i - 4 + size <= bytes.count { return true }
            }
            i += 1
        }
        return false
    }

    private static func renameNestedToFree(_ bytes: inout [UInt8], at start: Int, size: Int) {
        guard start >= 0, size >= 8, start + size <= bytes.count else { return }
        bytes[start + 4] = 0x66; bytes[start + 5] = 0x72
        bytes[start + 6] = 0x65; bytes[start + 7] = 0x65 // free
        for i in (start + 8)..<(start + size) { bytes[i] = 0x00 }
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func writeU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private static func readBoxHeader(_ data: Data, at offset: Int) throws -> (size: Int, headerSize: Int, type: String) {
        let size32 = Int(readUInt32(data, offset))
        let typeBytes = data.subdata(in: (offset + 4)..<(offset + 8))
        let type = String(data: typeBytes, encoding: .ascii) ?? "????"
        if size32 == 1 {
            guard offset + 16 <= data.count else { throw ServiceError.malformed("MP4 box") }
            let high = UInt64(readUInt32(data, offset + 8))
            let low = UInt64(readUInt32(data, offset + 12))
            return (Int((high << 32) | low), 16, type)
        }
        if size32 == 0 {
            return (data.count - offset, 8, type)
        }
        return (size32, 8, type)
    }

    private static func parseTfhdDefaultSampleSize(_ box: Data) -> Int? {
        guard box.count >= 16 else { return nil }
        let flags = Int(readUInt32(box, 8) & 0x00FF_FFFF)
        var offset = 16 // 8 header + 4 version/flags + 4 track_ID
        if flags & 0x000001 != 0 { offset += 8 } // base_data_offset
        if flags & 0x000002 != 0 { offset += 4 } // sample_description_index
        if flags & 0x000008 != 0 { offset += 4 } // default_sample_duration
        guard flags & 0x000010 != 0, offset + 4 <= box.count else { return nil } // default_sample_size
        return Int(readUInt32(box, offset))
    }

    private static func parseTrun(_ box: Data, sampleSizes: inout [Int], defaultSampleSize: inout Int) {
        guard box.count >= 16 else { return }
        let flags = Int(readUInt32(box, 8) & 0x00FF_FFFF)
        let sampleCount = Int(readUInt32(box, 12))
        var offset = 16
        if flags & 0x1 != 0 { offset += 4 } // data_offset
        if flags & 0x4 != 0 { offset += 4 } // first_sample_flags
        let sampleDurationPresent = flags & 0x100 != 0
        let sampleSizePresent = flags & 0x200 != 0
        let sampleFlagsPresent = flags & 0x400 != 0
        let sampleCTOPresent = flags & 0x800 != 0
        sampleSizes.removeAll(keepingCapacity: true)
        for _ in 0..<sampleCount {
            if sampleDurationPresent { offset += 4 }
            if sampleSizePresent {
                guard offset + 4 <= box.count else { return }
                sampleSizes.append(Int(readUInt32(box, offset)))
                offset += 4
            } else {
                sampleSizes.append(defaultSampleSize)
            }
            if sampleFlagsPresent { offset += 4 }
            if sampleCTOPresent { offset += 4 }
        }
    }

    private static func parseSenc(_ box: Data) -> [Data] {
        guard box.count >= 16 else { return [] }
        let flags = Int(readUInt32(box, 8) & 0x00FF_FFFF)
        let sampleCount = Int(readUInt32(box, 12))
        var offset = 16
        let ivSize = 8
        var ivs: [Data] = []
        for _ in 0..<sampleCount {
            guard offset + ivSize <= box.count else { break }
            var iv = Data(count: 16)
            iv.replaceSubrange(0..<ivSize, with: box.subdata(in: offset..<(offset + ivSize)))
            ivs.append(iv)
            offset += ivSize
            if flags & 0x2 != 0 {
                guard offset + 2 <= box.count else { break }
                let subsampleCount = Int(readUInt16(box, offset))
                offset += 2 + subsampleCount * 6
            }
        }
        return ivs
    }

    private static func renameBoxToFree(_ box: inout Data) {
        guard box.count >= 8 else { return }
        let free = Data("free".utf8)
        box.replaceSubrange(4..<8, with: free)
    }

    private static func aesCTR(key: Data, iv: Data, data: Data) -> Data {
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress, key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }

        // `Data(count:)` zero-fills before CommonCrypto immediately overwrites
        // every byte. Once per sample across a whole album that is a lot of
        // pointless memset; hand CommonCrypto uninitialized storage instead.
        var outLength = 0
        var updateStatus = CCCryptorStatus(kCCSuccess)
        let outBytes = [UInt8](unsafeUninitializedCapacity: data.count) { buffer, initialized in
            updateStatus = data.withUnsafeBytes { inBytes in
                CCCryptorUpdate(
                    cryptor,
                    inBytes.baseAddress, data.count,
                    buffer.baseAddress, data.count,
                    &outLength
                )
            }
            initialized = updateStatus == kCCSuccess ? outLength : 0
        }
        guard updateStatus == kCCSuccess else { return data }
        return Data(outBytes)
    }

    // `subdata` heap-allocates a fresh Data per read, and these run once per
    // sample inside `parseTrun` / `parseSenc` — tens of thousands of throwaway
    // allocations for a single track. Index the bytes directly instead.
    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let index = data.startIndex + offset
        guard index >= data.startIndex, index + 2 <= data.endIndex else { return 0 }
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        guard index >= data.startIndex, index + 4 <= data.endIndex else { return 0 }
        return UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var data = Data()
        data.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
