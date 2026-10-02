import Foundation

package struct OniSoundResource {
    package let isPCM: Bool
    package let isIMA4: Bool
    package let channels: Int
    package let sampleRate: Int
    package let averageBytesPerSecond: Int
    package let blockAlignment: Int
    package let bitsPerSample: Int
    package let samplesPerBlock: Int
    package let coefficients: [(Int16, Int16)]
    package let data: Data

    package var sampleCount: Int {
        if isIMA4 { return data.count / (34 * channels) * 64 }
        if isPCM { return blockAlignment > 0 ? data.count / blockAlignment : 0 }
        guard blockAlignment > 0 else { return 0 }
        let wholeBlocks = data.count / blockAlignment
        let leftover = data.count % blockAlignment
        let leftoverSamples = leftover >= 7 * channels
            ? 8 * (leftover - 7 * channels) / max(bitsPerSample * channels, 1) + 2
            : 0
        return wholeBlocks * samplesPerBlock + leftoverSamples
    }
}

extension OniDatFile {
    package func soundResource(for instance: OniDatInstance) throws -> OniSoundResource? {
        guard instance.templateTag == "SNDD" else { return nil }
        let reader = BinaryReader(data: data)
        let base = instance.dataOffset

        if header.platformName == "Mac" {
            guard instance.dataSize >= 16 else { return nil }
            let flags = try reader.u32(at: base)
            let size = Int(try reader.u32(at: base + 8))
            let offset = Int(try reader.u32(at: base + 12))
            let channels = flags & 2 == 2 ? 2 : 1
            guard let rawData, soundRangeIsValid(offset: offset, length: size, count: rawData.count) else {
                throw OniDatError.outOfBounds("SNDD audio data in the RAW file")
            }
            let pcm = flags & 1 == 0
            return OniSoundResource(
                isPCM: pcm,
                isIMA4: !pcm,
                channels: channels,
                sampleRate: 22_050,
                averageBytesPerSecond: 22_050 * 2 * channels,
                blockAlignment: 2 * channels,
                bitsPerSample: pcm ? 16 : 4,
                samplesPerBlock: pcm ? 1 : 64,
                coefficients: [],
                data: rawData.subdata(in: offset..<(offset + size))
            )
        }

        guard instance.dataSize >= 64 else { return nil }
        let flags = try reader.u32(at: base)
        let channels = Int(try reader.u16(at: base + 6))
        let size = Int(try reader.u32(at: base + 56))
        let offset = Int(try reader.u32(at: base + 60))
        guard (channels == 1 || channels == 2), let rawData,
              soundRangeIsValid(offset: offset, length: size, count: rawData.count) else {
            throw OniDatError.outOfBounds("SNDD audio data in the RAW file")
        }
        var coefficients: [(Int16, Int16)] = []
        for index in 0..<7 {
            coefficients.append((
                Int16(bitPattern: try reader.u16(at: base + 26 + index * 4)),
                Int16(bitPattern: try reader.u16(at: base + 28 + index * 4))
            ))
        }
        let pcm = flags & 8 == 0
        return OniSoundResource(
            isPCM: pcm,
            isIMA4: false,
            channels: channels,
            sampleRate: Int(try reader.u32(at: base + 8)),
            averageBytesPerSecond: Int(try reader.u32(at: base + 12)),
            blockAlignment: Int(try reader.u16(at: base + 16)),
            bitsPerSample: Int(try reader.u16(at: base + 18)),
            samplesPerBlock: Int(try reader.u16(at: base + 22)),
            coefficients: coefficients,
            data: rawData.subdata(in: offset..<(offset + size))
        )
    }
}

private func soundRangeIsValid(offset: Int, length: Int, count: Int) -> Bool {
    offset >= 0 && length >= 0 && offset <= count && length <= count - offset
}
