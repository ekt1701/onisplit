import AppKit
import Foundation

package enum OniDatError: LocalizedError {
    case fileTooSmall
    case invalidHeader(String)
    case outOfBounds(String)

    package var errorDescription: String? {
        switch self {
        case .fileTooSmall:
            return "The file is too small to be an Oni DAT file."
        case .invalidHeader(let detail):
            return "The DAT header is not valid: \(detail)"
        case .outOfBounds(let detail):
            return "The DAT file contains an invalid offset: \(detail)"
        }
    }
}

package extension OniDatError {
    func withContext(_ context: String) -> OniDatError {
        switch self {
        case .fileTooSmall:
            return .invalidHeader("\(context): file is too small")
        case .invalidHeader(let detail):
            return .invalidHeader("\(context): \(detail)")
        case .outOfBounds(let detail):
            return .outOfBounds("\(context): \(detail)")
        }
    }
}

package struct OniDatHeader {
    package let checksum: UInt64
    package let versionBytes: String
    package let headerSize: Int
    package let instanceDescriptorSize: Int
    package let templateDescriptorSize: Int
    package let nameDescriptorSize: Int
    package let instanceCount: Int
    package let nameCount: Int
    package let templateCount: Int
    package let dataBlockOffset: Int
    package let dataBlockLength: Int
    package let nameBlockOffset: Int
    package let nameBlockLength: Int
    package let rawBlockOffset: Int
    package let rawBlockLength: Int

    package var platformName: String {
        switch checksum {
        case 0x0003_bcdf_23c1_3061: "Mac"
        case 0x0003_bcdf_33dc_271f: "PC"
        default: "Unknown"
        }
    }
}

package struct OniDatInstance: Identifiable, Hashable {
    package let id: Int
    package let templateTag: String
    package let fullName: String
    package let displayName: String
    package let dataOffset: Int
    package let dataSize: Int
    package let descriptorFlags: UInt32
    package let nameOffset: UInt32
}

package enum OniTextureFormat: UInt32 {
    case bgra4444 = 0
    case bgr555 = 1
    case bgra5551 = 2
    case rgba = 7
    case bgr = 8
    case dxt1 = 9

    package var displayName: String {
        switch self {
        case .bgra4444: "BGRA4444"
        case .bgr555: "BGR555"
        case .bgra5551: "BGRA5551"
        case .rgba: "RGBA"
        case .bgr: "BGR"
        case .dxt1: "DXT1"
        }
    }
}

package struct OniTextureInfo {
    package let flags: UInt32
    package let width: Int
    package let height: Int
    package let format: OniTextureFormat
    package let pixelDataOffset: Int
    package let storageName: String

    package var hasMipMaps: Bool { flags & 0x0000_0001 != 0 }
}

package struct OniTexturePreview {
    package let info: OniTextureInfo
    package let image: NSImage?
    package let rgba: Data?
    package let error: String?
}

package struct OniAnimationInfo {
    package let flags: UInt32
    package let moveDirection: UInt16
    package let framesPerSecond: UInt16
    package let compressionSize: UInt16
    package let type: UInt16
    package let aimingType: UInt16
    package let fromState: UInt16
    package let toState: UInt16
    package let partCount: UInt16
    package let frameCount: UInt16
    package let duration: UInt16
    package let variant: UInt16

    package var blocksHigh: Bool { flags & 0x0000_0004 != 0 }
    package var blocksLow: Bool { flags & 0x0000_0008 != 0 }

    package var flagsDescription: String {
        Self.describeBits(flags, names: Self.animationFlags)
    }

    package var variantDescription: String {
        Self.describeBits(UInt32(variant), names: Self.animationVariants)
    }

    package var directionDescription: String {
        Self.directions[moveDirection].map { "\(moveDirection) (\($0))" } ?? "\(moveDirection)"
    }

    package var typeDescription: String {
        Self.animationTypes[type].map { "\(type) (\($0))" } ?? "\(type)"
    }

    package func stateDescription(_ state: UInt16) -> String {
        Self.animationStates[state].map { "\(state) (\($0))" } ?? "\(state)"
    }

    private static func describeBits(_ value: UInt32, names: [(UInt32, String)]) -> String {
        let found = names.compactMap { mask, name in value & mask != 0 ? name : nil }
        return found.isEmpty ? "None" : found.joined(separator: ", ")
    }

    private static let animationTypes: [UInt16: String] = [
        0: "None", 1: "Anything", 2: "Walk", 3: "Run", 4: "Slide", 5: "Jump",
        6: "Stand", 7: "Standing Turn Left", 8: "Standing Turn Right", 9: "Run Backwards",
        10: "Run Sidestep Left", 11: "Run Sidestep Right", 12: "Kick", 13: "Walk Sidestep Left",
        14: "Walk Sidestep Right", 15: "Walk Backwards", 16: "Stance", 17: "Crouch",
        18: "Jump Forward", 19: "Jump Backward", 20: "Jump Left", 21: "Jump Right",
        22: "Punch", 23: "Block", 24: "Land", 25: "Fly", 26: "Kick Forward",
        27: "Kick Left", 28: "Kick Right", 29: "Kick Back", 30: "Kick Low",
        31: "Punch Forward", 32: "Punch Left", 33: "Punch Right", 34: "Punch Back",
        35: "Punch Low", 36: "Kick 2", 37: "Kick 3", 38: "Punch 2", 39: "Punch 3",
        40: "Land Forward", 41: "Land Right", 42: "Land Left", 43: "Land Back",
        44: "PPK", 45: "PKK", 46: "PKP", 47: "KPK", 48: "KPP", 49: "KKP",
        50: "PK", 51: "KP", 52: "Punch Heavy", 53: "Kick Heavy",
        54: "Punch Forward Heavy", 55: "Kick Forward Heavy", 56: "Aiming Overlay",
        57: "Hit Overlay", 93: "Idle", 94: "Taunt", 95: "Throw", 198: "Stagger",
        212: "Stun", 214: "Blown Up", 219: "Powerup", 222: "Teleport In",
        223: "Teleport Out", 224: "Ninja Fireball", 225: "Ninja Invisible"
    ]

    private static let animationStates: [UInt16: String] = [
        0: "None", 1: "Anything", 2: "Running Left Down", 3: "Running Right Down",
        4: "Sliding", 5: "Walking Left Down", 6: "Walking Right Down", 7: "Standing",
        8: "Run Start", 9: "Run Accel", 10: "Run Sidestep Left", 11: "Run Sidestep Right",
        12: "Run Slide", 13: "Run Jump", 14: "Run Jump Land", 15: "Run Back Start",
        16: "Running Back Right Down", 17: "Running Back Left Down", 18: "Fallen Back",
        19: "Crouch", 20: "Running Upstairs Right Down", 21: "Running Upstairs Left Down",
        22: "Sidestep Left Left Down", 23: "Sidestep Left Right Down",
        24: "Sidestep Right Left Down", 25: "Sidestep Right Right Down",
        26: "Sidestep Right Jump", 27: "Sidestep Left Jump", 28: "Jump Forward",
        29: "Jump Up", 30: "Run Back Slide", 31: "Lie Back", 32: "Sidestep Left Start",
        33: "Sidestep Right Start", 34: "Walking Sidestep Left", 35: "Crouch Walk",
        36: "Walking Sidestep Right", 37: "Flying", 38: "Falling", 39: "Flying Forward",
        40: "Falling Forward", 41: "Flying Back", 42: "Falling Back", 43: "Flying Left",
        44: "Falling Left", 45: "Flying Right", 46: "Falling Right", 47: "Crouch Start",
        48: "Walking Back Left Down", 49: "Walking Back Right Down", 50: "Fallen Front",
        51: "Sidestep Left Start", 52: "Sidestep Right Start", 53: "Sit", 54: "Punch Low",
        55: "Stand Special", 56: "Acting", 57: "Crouch Run Left", 58: "Crouch Run Right",
        59: "Crouch Run Back Left", 60: "Crouch Run Back Right", 61: "Blocking 1",
        62: "Blocking 2", 63: "Blocking 3", 64: "Crouch Blocking 1", 65: "Gliding",
        66: "Watch Idle", 67: "Stunned", 68: "Powerup", 69: "Thunderbolt"
    ]

    private static let directions: [UInt16: String] = [
        0: "None", 1: "Forward", 2: "Backward", 3: "Left", 4: "Right"
    ]

    private static let animationVariants: [(UInt32, String)] = [
        (0x0100, "Sprint"), (0x0200, "Combat"), (0x0800, "Right Pistol"),
        (0x1000, "Left Pistol"), (0x2000, "Right Rifle"), (0x4000, "Left Rifle"),
        (0x8000, "Panic")
    ]

    private static let animationFlags: [(UInt32, String)] = [
        (0x00000001, "Runtime Loaded"), (0x00000002, "Invulnerable"),
        (0x00000004, "Block High"), (0x00000008, "Block Low"),
        (0x00000010, "Attack"), (0x00000020, "Drop Weapon"), (0x00000040, "In Air"),
        (0x00000080, "Atomic"), (0x00000100, "No Turn"), (0x00000200, "Attack Forward"),
        (0x00000400, "Attack Left"), (0x00000800, "Attack Right"),
        (0x00001000, "Attack Backward"), (0x00002000, "Overlay"),
        (0x00004000, "Don't Interpolate Velocity"), (0x00008000, "Throw Source"),
        (0x00010000, "Throw Target"), (0x00020000, "Real World"),
        (0x00040000, "Do Aim"), (0x00080000, "Don't Aim"), (0x00100000, "Can Pickup"),
        (0x00200000, "Aim 360"), (0x00400000, "Disable Shield"), (0x00800000, "No AI Pickup")
    ]
}

package struct OniDatFile {
    package let url: URL
    package let data: Data
    package let header: OniDatHeader
    package let instances: [OniDatInstance]
    package let rawData: Data?
    package let sepData: Data?

    package static func load(from url: URL) throws -> OniDatFile {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let reader = BinaryReader(data: data)
        guard data.count >= 64 else { throw OniDatError.fileTooSmall }

        let header = OniDatHeader(
            checksum: try reader.u64(at: 0),
            versionBytes: String(bytes: try reader.bytes(at: 8, length: 4).reversed(), encoding: .ascii) ?? "????",
            headerSize: Int(try reader.u16(at: 12)),
            instanceDescriptorSize: Int(try reader.u16(at: 14)),
            templateDescriptorSize: Int(try reader.u16(at: 16)),
            nameDescriptorSize: Int(try reader.u16(at: 18)),
            instanceCount: Int(try reader.u32(at: 20)),
            nameCount: Int(try reader.u32(at: 24)),
            templateCount: Int(try reader.u32(at: 28)),
            dataBlockOffset: Int(try reader.u32(at: 32)),
            dataBlockLength: Int(try reader.u32(at: 36)),
            nameBlockOffset: Int(try reader.u32(at: 40)),
            nameBlockLength: Int(try reader.u32(at: 44)),
            rawBlockOffset: Int(try reader.u32(at: 48)),
            rawBlockLength: Int(try reader.u32(at: 52))
        )

        guard header.headerSize >= 48 else {
            throw OniDatError.invalidHeader("header size is \(header.headerSize)")
        }
        guard header.instanceDescriptorSize >= 20 else {
            throw OniDatError.invalidHeader("instance descriptors are only \(header.instanceDescriptorSize) bytes")
        }
        // Some OniSplit VR32 files omit the unused alignment bytes at the very
        // end of the declared data block. Validate the block start and every
        // actual instance below instead of rejecting harmless missing padding.
        guard header.dataBlockOffset >= 0, header.dataBlockOffset <= data.count,
              checkedRange(offset: header.nameBlockOffset, length: header.nameBlockLength, count: data.count) else {
            throw OniDatError.outOfBounds("a data or name block lies outside the file")
        }

        let tableLength = try checkedMultiply(header.instanceCount, header.instanceDescriptorSize)
        guard checkedRange(offset: header.headerSize, length: tableLength, count: data.count) else {
            throw OniDatError.outOfBounds("the instance table lies outside the file")
        }

        var instances: [OniDatInstance] = []
        instances.reserveCapacity(header.instanceCount)

        for index in 0..<header.instanceCount {
            let descriptorOffset = header.headerSize + index * header.instanceDescriptorSize
            let rawTag = try reader.bytes(at: descriptorOffset, length: 4)
            let tag = String(bytes: rawTag.reversed(), encoding: .ascii) ?? "????"
            let relativeDataOffset = Int(try reader.u32(at: descriptorOffset + 4))
            let nameOffset = try reader.u32(at: descriptorOffset + 8)
            let dataSize = Int(try reader.u32(at: descriptorOffset + 12))
            let flags = try reader.u32(at: descriptorOffset + 16)

            let absoluteDataOffset = header.dataBlockOffset + relativeDataOffset
            let availableDataSize: Int
            if checkedRange(offset: absoluteDataOffset, length: dataSize, count: data.count) {
                availableDataSize = dataSize
            } else if header.versionBytes == "VR32", absoluteDataOffset >= 0,
                      absoluteDataOffset <= data.count, dataSize - (data.count - absoluteDataOffset) <= 63 {
                // Standalone OniSplit VR32 files can declare the complete
                // allocation while omitting one unused 32-byte tail block and
                // the normal trailing alignment bytes.
                availableDataSize = data.count - absoluteDataOffset
            } else {
                throw OniDatError.outOfBounds("instance \(index) data")
            }

            let fullName: String
            if nameOffset == UInt32.max || Int(nameOffset) >= header.nameBlockLength {
                fullName = ""
            } else {
                fullName = try reader.cString(
                    at: header.nameBlockOffset + Int(nameOffset),
                    limit: header.nameBlockOffset + header.nameBlockLength
                )
            }

            let displayName: String
            if fullName.count >= 4 && fullName.hasPrefix(tag) {
                displayName = String(fullName.dropFirst(4))
            } else if fullName.isEmpty {
                displayName = "Unnamed #\(index)"
            } else {
                displayName = fullName
            }

            instances.append(OniDatInstance(
                id: index,
                templateTag: tag,
                fullName: fullName,
                displayName: displayName,
                dataOffset: absoluteDataOffset,
                dataSize: availableDataSize,
                descriptorFlags: flags,
                nameOffset: nameOffset
            ))
        }

        let baseURL = url.deletingPathExtension()
        let embeddedRaw: Data?
        if header.rawBlockLength > 0,
           checkedRange(offset: header.rawBlockOffset, length: header.rawBlockLength, count: data.count) {
            embeddedRaw = data.subdata(in: header.rawBlockOffset..<(header.rawBlockOffset + header.rawBlockLength))
        } else {
            embeddedRaw = nil
        }
        let rawData = embeddedRaw ?? (try? Data(contentsOf: baseURL.appendingPathExtension("raw"), options: [.mappedIfSafe]))
        let sepData = try? Data(contentsOf: baseURL.appendingPathExtension("sep"), options: [.mappedIfSafe])

        return OniDatFile(
            url: url,
            data: data,
            header: header,
            instances: instances,
            rawData: rawData,
            sepData: sepData
        )
    }

    package func texturePreview(for instance: OniDatInstance) -> OniTexturePreview? {
        guard instance.templateTag == "TXMP", instance.dataSize >= 156 else { return nil }
        let reader = BinaryReader(data: data)
        let base = instance.dataOffset

        // The DAT instance payload begins after the resource/level IDs shown in
        // standalone binary-layout documentation, so serialized fields are 8 bytes earlier.
        guard let flags = try? reader.u32(at: base + 0x80),
              let widthValue = try? reader.u16(at: base + 0x84),
              let heightValue = try? reader.u16(at: base + 0x86),
              let formatValue = try? reader.u32(at: base + 0x88),
              let rawOffsetValue = try? reader.u32(at: base + 0x94),
              let sepOffsetValue = try? reader.u32(at: base + 0x98),
              let format = OniTextureFormat(rawValue: formatValue) else { return nil }

        let width = Int(widthValue)
        let height = Int(heightValue)
        guard width > 0, height > 0 else { return nil }

        let source: Data
        let offset: Int
        let storageName: String
        if sepOffsetValue > 0, let sepData {
            source = sepData
            offset = Int(sepOffsetValue)
            storageName = url.deletingPathExtension().lastPathComponent + ".sep"
        } else if rawOffsetValue > 0, let rawData {
            source = rawData
            offset = Int(rawOffsetValue)
            storageName = url.deletingPathExtension().lastPathComponent + ".raw"
        } else {
            let info = OniTextureInfo(
                flags: flags,
                width: width,
                height: height,
                format: format,
                pixelDataOffset: Int(sepOffsetValue > 0 ? sepOffsetValue : rawOffsetValue),
                storageName: sepOffsetValue > 0 ? ".sep (not found)" : ".raw (not found)"
            )
            return OniTexturePreview(info: info, image: nil, rgba: nil, error: "The matching texture-data file could not be found.")
        }

        let info = OniTextureInfo(
            flags: flags,
            width: width,
            height: height,
            format: format,
            pixelDataOffset: offset,
            storageName: storageName
        )

        do {
            let rgba = try decodeTexture(
                source: source,
                offset: offset,
                width: width,
                height: height,
                format: format
            )
            guard let provider = CGDataProvider(data: rgba as CFData),
                  let cgImage = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else {
                return OniTexturePreview(info: info, image: nil, rgba: nil, error: "The decoded pixels could not be converted into an image.")
            }
            return OniTexturePreview(
                info: info,
                image: NSImage(cgImage: cgImage, size: NSSize(width: width, height: height)),
                rgba: rgba,
                error: nil
            )
        } catch {
            return OniTexturePreview(info: info, image: nil, rgba: nil, error: error.localizedDescription)
        }
    }

    package func animationInfo(for instance: OniDatInstance) -> OniAnimationInfo? {
        // These offsets are the serialized TRAM layout used by Oni's template manager.
        guard instance.templateTag == "TRAM", instance.dataSize >= 362 else { return nil }
        let reader = BinaryReader(data: data)
        let base = instance.dataOffset
        guard let flags = try? reader.u32(at: base + 52),
              let moveDirection = try? reader.u16(at: base + 76),
              let fps = try? reader.u16(at: base + 342),
              let compression = try? reader.u16(at: base + 344),
              let type = try? reader.u16(at: base + 346),
              let aimingType = try? reader.u16(at: base + 348),
              let fromState = try? reader.u16(at: base + 350),
              let toState = try? reader.u16(at: base + 352),
              let partCount = try? reader.u16(at: base + 354),
              let frameCount = try? reader.u16(at: base + 356),
              let duration = try? reader.u16(at: base + 358),
              let variant = try? reader.u16(at: base + 360) else { return nil }

        return OniAnimationInfo(
            flags: flags,
            moveDirection: moveDirection,
            framesPerSecond: fps,
            compressionSize: compression,
            type: type,
            aimingType: aimingType,
            fromState: fromState,
            toState: toState,
            partCount: partCount,
            frameCount: frameCount,
            duration: duration,
            variant: variant
        )
    }

    package func hexDump(for instance: OniDatInstance, maximumBytes: Int = 4096) -> String {
        let count = min(instance.dataSize, maximumBytes)
        guard count > 0 else { return "This instance has no data." }
        let bytes = [UInt8](data[instance.dataOffset..<(instance.dataOffset + count)])
        var lines: [String] = []
        lines.reserveCapacity((bytes.count + 15) / 16)

        for lineStart in stride(from: 0, to: bytes.count, by: 16) {
            let lineEnd = min(lineStart + 16, bytes.count)
            let slice = bytes[lineStart..<lineEnd]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = slice.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%08X  %@  |%@|", lineStart, paddedHex, String(ascii)))
        }

        if instance.dataSize > maximumBytes {
            lines.append("\nShowing the first \(maximumBytes) of \(instance.dataSize) bytes.")
        }
        return lines.joined(separator: "\n")
    }

    package var templateCounts: [(String, Int)] {
        Dictionary(grouping: instances, by: \.templateTag)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 < $1.0 }
    }
}

private func decodeTexture(
    source: Data,
    offset: Int,
    width: Int,
    height: Int,
    format: OniTextureFormat
) throws -> Data {
    let pixelCount = try checkedMultiply(width, height)
    var output = Data(repeating: 0, count: try checkedMultiply(pixelCount, 4))

    func writePixel(_ x: Int, _ storedY: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
        guard x >= 0, x < width, storedY >= 0, storedY < height else { return }
        let y = height - 1 - storedY
        let destination = (y * width + x) * 4
        output[destination] = red
        output[destination + 1] = green
        output[destination + 2] = blue
        output[destination + 3] = alpha
    }

    func expanded5(_ value: UInt16) -> UInt8 {
        let component = UInt8(value & 0x1F)
        return (component << 3) | (component >> 2)
    }

    switch format {
    case .bgra4444, .bgr555, .bgra5551:
        let byteCount = try checkedMultiply(pixelCount, 2)
        guard checkedRange(offset: offset, length: byteCount, count: source.count) else {
            throw OniDatError.outOfBounds("TXMP pixel data in the companion file")
        }
        for storedY in 0..<height {
            for x in 0..<width {
                let sourceOffset = offset + (storedY * width + x) * 2
                let value = UInt16(source[sourceOffset]) | UInt16(source[sourceOffset + 1]) << 8
                switch format {
                case .bgra4444:
                    let blue = UInt8(value & 0xF) * 17
                    let green = UInt8((value >> 4) & 0xF) * 17
                    let red = UInt8((value >> 8) & 0xF) * 17
                    let alpha = UInt8((value >> 12) & 0xF) * 17
                    writePixel(x, storedY, red, green, blue, alpha)
                case .bgr555:
                    writePixel(x, storedY, expanded5(value >> 10), expanded5(value >> 5), expanded5(value), 255)
                case .bgra5551:
                    let alpha: UInt8 = value & 0x8000 == 0 ? 0 : 255
                    writePixel(x, storedY, expanded5(value >> 10), expanded5(value >> 5), expanded5(value), alpha)
                default:
                    break
                }
            }
        }

    case .rgba, .bgr:
        let byteCount = try checkedMultiply(pixelCount, 4)
        guard checkedRange(offset: offset, length: byteCount, count: source.count) else {
            throw OniDatError.outOfBounds("TXMP pixel data in the companion file")
        }
        for storedY in 0..<height {
            for x in 0..<width {
                let sourceOffset = offset + (storedY * width + x) * 4
                writePixel(
                    x,
                    storedY,
                    source[sourceOffset + 2],
                    source[sourceOffset + 1],
                    source[sourceOffset],
                    format == .rgba ? source[sourceOffset + 3] : 255
                )
            }
        }

    case .dxt1:
        let blocksWide = max(1, (width + 3) / 4)
        let blocksHigh = max(1, (height + 3) / 4)
        let byteCount = try checkedMultiply(try checkedMultiply(blocksWide, blocksHigh), 8)
        guard checkedRange(offset: offset, length: byteCount, count: source.count) else {
            throw OniDatError.outOfBounds("DXT1 pixel data in the companion file")
        }

        for blockY in 0..<blocksHigh {
            for blockX in 0..<blocksWide {
                let blockOffset = offset + (blockY * blocksWide + blockX) * 8
                let color0 = UInt16(source[blockOffset]) | UInt16(source[blockOffset + 1]) << 8
                let color1 = UInt16(source[blockOffset + 2]) | UInt16(source[blockOffset + 3]) << 8
                let first = rgba565(color0)
                let second = rgba565(color1)
                var colors = [first, second, (UInt8(0), UInt8(0), UInt8(0), UInt8(255)), (UInt8(0), UInt8(0), UInt8(0), UInt8(255))]
                if color0 > color1 {
                    colors[2] = interpolate(first, second, firstWeight: 2, divisor: 3)
                    colors[3] = interpolate(first, second, firstWeight: 1, divisor: 3)
                } else {
                    colors[2] = interpolate(first, second, firstWeight: 1, divisor: 2)
                    colors[3] = (0, 0, 0, 0)
                }
                let indices = UInt32(source[blockOffset + 4]) |
                    UInt32(source[blockOffset + 5]) << 8 |
                    UInt32(source[blockOffset + 6]) << 16 |
                    UInt32(source[blockOffset + 7]) << 24

                for localY in 0..<4 {
                    for localX in 0..<4 {
                        let shift = UInt32((localY * 4 + localX) * 2)
                        let color = colors[Int((indices >> shift) & 0x3)]
                        writePixel(blockX * 4 + localX, blockY * 4 + localY, color.0, color.1, color.2, color.3)
                    }
                }
            }
        }
    }

    return output
}

private func rgba565(_ value: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
    let red5 = UInt8((value >> 11) & 0x1F)
    let green6 = UInt8((value >> 5) & 0x3F)
    let blue5 = UInt8(value & 0x1F)
    return (
        (red5 << 3) | (red5 >> 2),
        (green6 << 2) | (green6 >> 4),
        (blue5 << 3) | (blue5 >> 2),
        255
    )
}

private func interpolate(
    _ first: (UInt8, UInt8, UInt8, UInt8),
    _ second: (UInt8, UInt8, UInt8, UInt8),
    firstWeight: Int,
    divisor: Int
) -> (UInt8, UInt8, UInt8, UInt8) {
    let secondWeight = divisor - firstWeight
    return (
        UInt8((Int(first.0) * firstWeight + Int(second.0) * secondWeight) / divisor),
        UInt8((Int(first.1) * firstWeight + Int(second.1) * secondWeight) / divisor),
        UInt8((Int(first.2) * firstWeight + Int(second.2) * secondWeight) / divisor),
        UInt8((Int(first.3) * firstWeight + Int(second.3) * secondWeight) / divisor)
    )
}

struct BinaryReader {
    let data: Data

    func bytes(at offset: Int, length: Int) throws -> [UInt8] {
        guard checkedRange(offset: offset, length: length, count: data.count) else {
            throw OniDatError.outOfBounds("byte range \(offset)..<\(offset + max(length, 0))")
        }
        return [UInt8](data[offset..<(offset + length)])
    }

    func ascii(at offset: Int, length: Int) throws -> String {
        String(bytes: try bytes(at: offset, length: length), encoding: .ascii) ?? "????"
    }

    func u16(at offset: Int) throws -> UInt16 {
        let value = try bytes(at: offset, length: 2)
        return UInt16(value[0]) | UInt16(value[1]) << 8
    }

    func u32(at offset: Int) throws -> UInt32 {
        let value = try bytes(at: offset, length: 4)
        return UInt32(value[0]) | UInt32(value[1]) << 8 |
            UInt32(value[2]) << 16 | UInt32(value[3]) << 24
    }

    func u64(at offset: Int) throws -> UInt64 {
        let low = UInt64(try u32(at: offset))
        let high = UInt64(try u32(at: offset + 4))
        return low | high << 32
    }

    func cString(at offset: Int, limit: Int) throws -> String {
        guard offset >= 0, offset < limit, limit <= data.count else {
            throw OniDatError.outOfBounds("string at \(offset)")
        }
        var end = offset
        while end < limit && data[end] != 0 { end += 1 }
        return String(decoding: data[offset..<end], as: UTF8.self)
    }
}

private func checkedRange(offset: Int, length: Int, count: Int) -> Bool {
    guard offset >= 0, length >= 0, offset <= count else { return false }
    return length <= count - offset
}

private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow else { throw OniDatError.invalidHeader("instance count is too large") }
    return result.partialValue
}
