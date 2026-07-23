import Foundation
import CommonCrypto

/// Ports Monochrome's SW Amazon CENC decryptor enough for AVPlayer: download
/// encrypted fMP4, AES-CTR decrypt samples from `senc`, strip DRM boxes.
enum AmazonCencDecryptor {
    static func decryptFile(from sourceURL: URL, keyHex: String, session: URLSession = .shared) async throws -> URL {
        guard let key = Data(hexString: keyHex), key.count == 16 else {
            throw ServiceError.malformed("Amazon decryption key")
        }
        let (data, response) = try await session.data(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.unavailable("Amazon stream download failed")
        }
        let clear = try decrypt(data: data, key: key)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("monochrome-amz-\(UUID().uuidString).m4a")
        try clear.write(to: target, options: .atomic)
        return target
    }

    static func decrypt(data: Data, key: Data) throws -> Data {
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
            if type == "trun" {
                parseTrun(box, sampleSizes: &sampleSizes, defaultSampleSize: &defaultSampleSize)
                output.append(box)
            } else if type == "senc" {
                sampleIVs = parseSenc(box)
                var free = box
                renameBoxToFree(&free)
                output.append(free)
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

        var outLength = 0
        var outData = Data(count: data.count)
        let updateStatus = outData.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                CCCryptorUpdate(
                    cryptor,
                    inBytes.baseAddress, data.count,
                    outBytes.baseAddress, data.count,
                    &outLength
                )
            }
        }
        guard updateStatus == kCCSuccess else { return data }
        return outData
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
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
