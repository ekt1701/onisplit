import AppKit
import Foundation

private struct OniTextureSurface {
    let width: Int
    let height: Int
    var rgba: Data

    func resized(width newWidth: Int, height newHeight: Int) -> OniTextureSurface {
        guard newWidth != width || newHeight != height else { return self }
        var output = Data(repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let y0 = y * height / newHeight
            let y1 = max(y0 + 1, (y + 1) * height / newHeight)
            for x in 0..<newWidth {
                let x0 = x * width / newWidth
                let x1 = max(x0 + 1, (x + 1) * width / newWidth)
                var totals = [Int](repeating: 0, count: 4)
                var count = 0
                for sourceY in y0..<min(y1, height) {
                    for sourceX in x0..<min(x1, width) {
                        let source = (sourceY * width + sourceX) * 4
                        for component in 0..<4 { totals[component] += Int(rgba[source + component]) }
                        count += 1
                    }
                }
                let destination = (y * newWidth + x) * 4
                for component in 0..<4 { output[destination + component] = UInt8(totals[component] / max(count, 1)) }
            }
        }
        return OniTextureSurface(width: newWidth, height: newHeight, rgba: output)
    }
}

package struct OniTextureXMLExport {
    package let xml: Data
    package let images: [(fileName: String, data: Data)]
}

package enum OniTextureXMLExporter {
    private static let exportedFlags: [(UInt32, String)] = [
        (0x0001, "HasMipMaps"), (0x0004, "DisableUWrap"), (0x0008, "DisableVWrap"),
        (0x0040, "AnimBackToBack"), (0x0080, "AnimRandom"), (0x0100, "AnimUseLocalTime"),
        (0x0400, "AdditiveBlend"), (0x4000, "AnimIgnoreGlobalTime"),
        (0x8000, "ShieldEffect"), (0x10000, "InvisibilityEffect"), (0x20000, "DaodanEffect")
    ]

    package static func supports(file: OniDatFile) -> Bool {
        let tags = Set(file.instances.map(\.templateTag))
        return !file.instances.isEmpty && tags.isSubset(of: ["TXMP", "TXAN"]) &&
            file.instances.contains { $0.templateTag == "TXMP" && !$0.fullName.isEmpty && $0.descriptorFlags & 0x0002 == 0 }
    }

    package static func export(file: OniDatFile) throws -> OniTextureXMLExport {
        guard supports(file: file),
              let main = file.instances.first(where: { $0.templateTag == "TXMP" && !$0.fullName.isEmpty && $0.descriptorFlags & 0x0002 == 0 }),
              let preview = file.texturePreview(for: main) else {
            throw OniNativeXMLError.invalidDocument("the file does not contain an exportable named texture")
        }
        guard preview.error == nil, preview.rgba != nil else {
            throw OniNativeXMLError.invalidDocument(preview.error ?? "the texture pixels could not be decoded")
        }
        let flags = readU32(file.data, main.dataOffset + 0x80)
        let animationLink = readU32(file.data, main.dataOffset + 0x8c)
        let environmentLink = readU32(file.data, main.dataOffset + 0x90)
        var frames = [main]
        var speed: Int?
        if animationLink != 0 {
            let animationIndex = Int(animationLink >> 8)
            guard animationIndex < file.instances.count else { throw OniNativeXMLError.invalidDocument("TXMP animation link is invalid") }
            let animation = file.instances[animationIndex]
            guard animation.templateTag == "TXAN", animation.dataSize >= 28 else { throw OniNativeXMLError.invalidDocument("TXMP animation link does not point to TXAN") }
            speed = Int(Int16(bitPattern: readU16(file.data, animation.dataOffset + 0x0c)))
            let count = Int(readU32(file.data, animation.dataOffset + 0x14))
            guard count > 0, count <= 4096 else { throw OniNativeXMLError.invalidDocument("TXAN frame count is invalid") }
            for frameNumber in 1..<count {
                let linkOffset = animation.dataOffset + 0x18 + frameNumber * 4
                guard linkOffset + 4 <= file.data.count else { throw OniNativeXMLError.invalidDocument("TXAN frame table is truncated") }
                let frameIndex = Int(readU32(file.data, linkOffset) >> 8)
                guard frameIndex < file.instances.count, file.instances[frameIndex].templateTag == "TXMP" else {
                    throw OniNativeXMLError.invalidDocument("TXAN frame \(frameNumber) does not point to TXMP")
                }
                frames.append(file.instances[frameIndex])
            }
        }

        let baseName = file.url.deletingPathExtension().lastPathComponent
        let root = XMLElement(name: "Oni")
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"; document.characterEncoding = "utf-8"
        let texture = XMLElement(name: "Texture"); root.addChild(texture)
        let cleanedFlags = flags & ~(0x0010 | 0x0200 | 0x1000)
        add(texture, "Flags", exportedFlags.compactMap { cleanedFlags & $0.0 != 0 ? $0.1 : nil }.joined(separator: "  "))
        add(texture, "Format", preview.info.format.displayName)
        if environmentLink != 0 {
            let index = Int(environmentLink >> 8)
            guard index < file.instances.count else { throw OniNativeXMLError.invalidDocument("TXMP environment-map link is invalid") }
            add(texture, "EnvMap", file.instances[index].fullName)
        }
        if let speed { add(texture, "Speed", String(speed)) }
        var images: [(String, Data)] = []
        for (index, frame) in frames.enumerated() {
            guard let framePreview = file.texturePreview(for: frame), let rgba = framePreview.rgba, framePreview.error == nil else {
                throw OniNativeXMLError.invalidDocument("texture frame \(index) could not be decoded")
            }
            let fileName = frames.count == 1 ? "\(baseName).tga" : String(format: "%@_%03d.tga", baseName, index)
            add(texture, "Image", fileName)
            images.append((fileName, tgaData(width: framePreview.info.width, height: framePreview.info.height, rgba: rgba)))
        }
        return OniTextureXMLExport(xml: document.xmlData(options: [.nodePrettyPrint]), images: images)
    }

    private static func add(_ parent: XMLElement, _ name: String, _ value: String) {
        parent.addChild(XMLElement(name: name, stringValue: value))
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func tgaData(width: Int, height: Int, rgba: Data) -> Data {
        var output = Data(repeating: 0, count: 18)
        output[2] = 2
        output[12] = UInt8(width & 0xff); output[13] = UInt8((width >> 8) & 0xff)
        output[14] = UInt8(height & 0xff); output[15] = UInt8((height >> 8) & 0xff)
        output[16] = 32; output[17] = 8
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                output.append(rgba[offset + 2]); output.append(rgba[offset + 1])
                output.append(rgba[offset]); output.append(rgba[offset + 3])
            }
        }
        return output
    }
}

package enum OniTextureXMLImporter {
    private struct Instance {
        let tag: String
        let name: String?
        let payload: Data?
    }

    private static let formats: [String: UInt32] = [
        "BGRA4444": 0, "BGR555": 1, "BGRA5551": 2,
        "RGBA": 7, "BGR": 8, "DXT1": 9
    ]

    private static let flagValues: [String: UInt32] = [
        "HasMipMaps": 0x0001,
        "DisableUWrap": 0x0004, "NoUWrap": 0x0004,
        "DisableVWrap": 0x0008, "NoVWrap": 0x0008,
        "Unknown0010": 0x0010,
        "AnimBackToBack": 0x0040, "AnimPingPong": 0x0040,
        "AnimRandom": 0x0080,
        "AnimUseLocalTime": 0x0100, "AnimGlobalTime": 0x0100,
        "HasEnvMap": 0x0200,
        "AdditiveBlend": 0x0400,
        "SwapBytes": 0x1000,
        "AnimIgnoreGlobalTime": 0x4000, "AnimLoop": 0x4000,
        "ShieldEffect": 0x8000, "Shield": 0x8000,
        "InvisibilityEffect": 0x10000, "Invisibility": 0x10000,
        "DaodanEffect": 0x20000, "Daodan": 0x20000
    ]

    package static func imageDimensions(at url: URL) throws -> (width: Int, height: Int) {
        let surface = try loadImage(url)
        return (surface.width, surface.height)
    }

    package static func build(texture: XMLElement, sourceFileName: String?, resourceBaseURL: URL?) throws -> OniNativeXMLArchive {
        guard let sourceFileName else {
            throw OniNativeXMLError.invalidDocument("Texture XML needs a source filename")
        }
        let formatName = requiredText(texture, "Format").uppercased()
        guard let format = formats[formatName] else {
            throw OniNativeXMLError.invalidDocument("unsupported texture format '\(formatName)'")
        }
        var flags: UInt32 = 0
        for token in requiredText(texture, "Flags").split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
            guard let value = flagValues[String(token)] else {
                throw OniNativeXMLError.invalidDocument("unknown texture flag '\(token)'")
            }
            flags |= value
        }
        // This is the PC VR32 representation used by the native writer.
        flags |= 0x1000

        let imageNames = texture.elements(forName: "Image").compactMap(\.stringValue).filter { !$0.isEmpty }
        guard !imageNames.isEmpty else {
            throw OniNativeXMLError.invalidDocument("Texture must contain at least one Image")
        }
        let baseURL = resourceBaseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var surfaces: [OniTextureSurface] = []
        for imageName in imageNames {
            let imageURL = (imageName.hasPrefix("/")
                ? URL(fileURLWithPath: imageName)
                : baseURL.appendingPathComponent(imageName)).standardizedFileURL
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                throw OniNativeXMLError.invalidDocument("could not find image file '\(imageName)'")
            }
            surfaces.append(try loadImage(imageURL))
        }
        guard let first = surfaces.first, surfaces.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw OniNativeXMLError.invalidDocument("all texture animation frames must have the same size")
        }
        let requestedWidth = optionalInt(texture, "Width") ?? first.width
        let requestedHeight = optionalInt(texture, "Height") ?? first.height
        guard requestedWidth > 0, requestedHeight > 0,
              requestedWidth <= first.width, requestedHeight <= first.height else {
            throw OniNativeXMLError.invalidDocument("texture Width and Height must be positive and cannot upscale images")
        }
        if requestedWidth != first.width || requestedHeight != first.height {
            surfaces = surfaces.map { $0.resized(width: requestedWidth, height: requestedHeight) }
        }

        let envMap = texture.elements(forName: "EnvMap").first?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if envMap != nil { flags |= 0x0200 }
        let speed = optionalInt(texture, "Speed") ?? 1
        guard Int16(exactly: speed) != nil else {
            throw OniNativeXMLError.invalidDocument("texture Speed is outside the supported range")
        }

        var raw = Data(repeating: 0, count: 32)
        var instances: [Instance] = []
        var outputName = decodeFileName(URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent)
        if !outputName.lowercased().hasSuffix(".oni") { outputName += ".oni" }
        let outputBase = URL(fileURLWithPath: outputName).deletingPathExtension().lastPathComponent
        let textureName = outputBase.hasPrefix("TXMP") ? outputBase : "TXMP" + outputBase
        for (index, surface) in surfaces.enumerated() {
            pad32(&raw)
            let rawOffset = raw.count
            var level = surface
            while true {
                raw.append(try encode(level, format: format))
                if flags & 0x0001 == 0 || (level.width == 1 && level.height == 1) { break }
                level = surface.resized(width: max(level.width >> 1, 1), height: max(level.height >> 1, 1))
            }
            var payload = Data(repeating: 0, count: 128)
            appendU32(&payload, flags)
            appendU16(&payload, UInt16(requestedWidth)); appendU16(&payload, UInt16(requestedHeight))
            appendU32(&payload, format)
            appendU32(&payload, index == 0 && surfaces.count > 1 ? instanceID(surfaces.count) : 0)
            let envIndex = surfaces.count + (surfaces.count > 1 ? 1 : 0)
            appendU32(&payload, envMap == nil ? 0 : instanceID(envIndex))
            appendU32(&payload, UInt32(rawOffset))
            payload.append(Data(repeating: 0, count: 12))
            instances.append(Instance(tag: "TXMP", name: index == 0 ? textureName : nil, payload: payload))
        }
        if surfaces.count > 1 {
            var animation = Data(repeating: 0, count: 12)
            appendI16(&animation, Int16(speed)); appendI16(&animation, Int16(speed))
            appendU32(&animation, 0); appendU32(&animation, UInt32(surfaces.count)); appendU32(&animation, 0)
            for index in 1..<surfaces.count { appendU32(&animation, instanceID(index)) }
            instances.append(Instance(tag: "TXAN", name: nil, payload: animation))
        }
        if let envMap {
            let name = envMap.hasPrefix("TXMP") ? envMap : "TXMP" + envMap
            instances.append(Instance(tag: "TXMP", name: name, payload: nil))
        }
        let archiveData = buildArchive(instances: instances, raw: raw)
        return OniNativeXMLArchive(fileName: outputName, archiveData: archiveData)
    }

    private static func requiredText(_ parent: XMLElement, _ name: String) -> String {
        parent.elements(forName: name).first?.stringValue ?? ""
    }

    private static func optionalInt(_ parent: XMLElement, _ name: String) -> Int? {
        guard let text = parent.elements(forName: name).first?.stringValue else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decodeFileName(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func loadTGA(_ url: URL) throws -> OniTextureSurface {
        let data = try Data(contentsOf: url)
        guard data.count >= 18 else { throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) is not a valid TGA file") }
        let idLength = Int(data[0]), colorMapType = data[1], imageType = data[2]
        let width = Int(readU16(data, 12)), height = Int(readU16(data, 14)), depth = Int(data[16])
        guard colorMapType == 0, (imageType == 2 || imageType == 10), width > 0, height > 0,
              depth == 24 || depth == 32 else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) uses an unsupported TGA layout")
        }
        let pixelSize = depth / 8
        var cursor = 18 + idLength
        var sourcePixels: [[UInt8]] = []
        sourcePixels.reserveCapacity(width * height)
        func readPixel(_ offset: Int) throws -> [UInt8] {
            guard offset + pixelSize <= data.count else { throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) contains truncated TGA pixels") }
            return [data[offset + 2], data[offset + 1], data[offset], pixelSize == 4 ? data[offset + 3] : 255]
        }
        if imageType == 2 {
            for _ in 0..<(width * height) { sourcePixels.append(try readPixel(cursor)); cursor += pixelSize }
        } else {
            while sourcePixels.count < width * height {
                guard cursor < data.count else { throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) contains truncated TGA RLE data") }
                let packet = data[cursor]; cursor += 1
                let count = Int(packet & 0x7f) + 1
                if packet & 0x80 != 0 {
                    let pixel = try readPixel(cursor); cursor += pixelSize
                    for _ in 0..<count where sourcePixels.count < width * height { sourcePixels.append(pixel) }
                } else {
                    for _ in 0..<count where sourcePixels.count < width * height { sourcePixels.append(try readPixel(cursor)); cursor += pixelSize }
                }
            }
        }
        var rgba = Data(repeating: 0, count: width * height * 4)
        let topOrigin = data[17] & 0x20 != 0, rightOrigin = data[17] & 0x10 != 0
        for index in 0..<(width * height) {
            let sourceX = index % width, sourceY = index / width
            let x = rightOrigin ? width - 1 - sourceX : sourceX
            let y = topOrigin ? sourceY : height - 1 - sourceY
            let destination = (y * width + x) * 4
            for component in 0..<4 { rgba[destination + component] = sourcePixels[index][component] }
        }
        return OniTextureSurface(width: width, height: height, rgba: rgba)
    }

    private static func loadImage(_ url: URL) throws -> OniTextureSurface {
        if url.pathExtension.lowercased() == "tga" { return try loadTGA(url) }
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) is not a supported image")
        }
        let width = cgImage.width, height = cgImage.height
        var rgba = Data(repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) could not be decoded") }
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[offset + 3])
            if alpha > 0 && alpha < 255 {
                for component in 0..<3 {
                    rgba[offset + component] = UInt8(min(255, Int(rgba[offset + component]) * 255 / alpha))
                }
            }
        }
        return OniTextureSurface(width: width, height: height, rgba: rgba)
    }

    private static func encode(_ surface: OniTextureSurface, format: UInt32) throws -> Data {
        switch format {
        case 0, 1, 2:
            var output = Data(repeating: 0, count: surface.width * surface.height * 2)
            for index in 0..<(surface.width * surface.height) {
                let source = index * 4
                let r = UInt16(surface.rgba[source]), g = UInt16(surface.rgba[source + 1])
                let b = UInt16(surface.rgba[source + 2]), a = UInt16(surface.rgba[source + 3])
                let value: UInt16
                if format == 0 { value = (b >> 4) | ((g >> 4) << 4) | ((r >> 4) << 8) | ((a >> 4) << 12) }
                else if format == 1 { value = (b >> 3) | ((g >> 3) << 5) | ((r >> 3) << 10) | 0x8000 }
                else { value = (b >> 3) | ((g >> 3) << 5) | ((r >> 3) << 10) | (a & 0x80 == 0 ? 0 : 0x8000) }
                output[index * 2] = UInt8(value & 0xff); output[index * 2 + 1] = UInt8(value >> 8)
            }
            return output
        case 7, 8:
            var output = Data(repeating: 0, count: surface.width * surface.height * 4)
            for index in 0..<(surface.width * surface.height) {
                let source = index * 4
                if format == 7 {
                    for component in 0..<4 { output[source + component] = surface.rgba[source + component] }
                } else {
                    output[source] = surface.rgba[source + 2]; output[source + 1] = surface.rgba[source + 1]
                    output[source + 2] = surface.rgba[source]; output[source + 3] = 255
                }
            }
            return output
        case 9: return encodeDXT1(surface)
        default: throw OniNativeXMLError.invalidDocument("unsupported texture format value \(format)")
        }
    }

    private static func encodeDXT1(_ surface: OniTextureSurface) -> Data {
        let width = max(4, (surface.width + 3) & ~3), height = max(4, (surface.height + 3) & ~3)
        var output = Data()
        output.reserveCapacity(width * height / 2)
        for blockY in stride(from: 0, to: height, by: 4) {
            for blockX in stride(from: 0, to: width, by: 4) {
                var pixels: [(Int, Int, Int)] = []
                for y in 0..<4 { for x in 0..<4 {
                    let px = min(blockX + x, surface.width - 1), py = min(blockY + y, surface.height - 1)
                    let offset = (py * surface.width + px) * 4
                    pixels.append((Int(surface.rgba[offset]), Int(surface.rgba[offset + 1]), Int(surface.rgba[offset + 2])))
                }}
                let minimum = (pixels.map(\.0).min()!, pixels.map(\.1).min()!, pixels.map(\.2).min()!)
                let maximum = (pixels.map(\.0).max()!, pixels.map(\.1).max()!, pixels.map(\.2).max()!)
                let c0 = bgr565(minimum), c1 = bgr565(maximum)
                appendU16(&output, c0); appendU16(&output, c1)
                var colors = [minimum, maximum]
                if c0 > c1 {
                    colors.append(interpolate(minimum, maximum, firstWeight: 2, divisor: 3))
                    colors.append(interpolate(minimum, maximum, firstWeight: 1, divisor: 3))
                } else {
                    colors.append(interpolate(minimum, maximum, firstWeight: 1, divisor: 2))
                }
                for row in 0..<4 {
                    var packed: UInt8 = 0
                    for column in stride(from: 3, through: 0, by: -1) {
                        let pixel = pixels[row * 4 + column]
                        var nearest = 0, distance = Int.max
                        for (index, color) in colors.enumerated() {
                            let dr = pixel.0 - color.0, dg = pixel.1 - color.1, db = pixel.2 - color.2
                            let candidate = dr * dr + dg * dg + db * db
                            if candidate < distance { distance = candidate; nearest = index }
                        }
                        packed = (packed << 2) | UInt8(nearest)
                    }
                    output.append(packed)
                }
            }
        }
        return output
    }

    private static func bgr565(_ color: (Int, Int, Int)) -> UInt16 {
        UInt16((color.2 >> 3) | ((color.1 & 0xfc) << 3) | ((color.0 & 0xf8) << 8))
    }

    private static func interpolate(_ a: (Int, Int, Int), _ b: (Int, Int, Int), firstWeight: Int, divisor: Int) -> (Int, Int, Int) {
        ((a.0 * firstWeight + b.0 * (divisor - firstWeight)) / divisor,
         (a.1 * firstWeight + b.1 * (divisor - firstWeight)) / divisor,
         (a.2 * firstWeight + b.2 * (divisor - firstWeight)) / divisor)
    }

    private static func buildArchive(instances: [Instance], raw: Data) -> Data {
        let nameTableOffset = align32(64 + instances.count * 20)
        var nameOffsets: [UInt32] = [], names = Data()
        for instance in instances {
            if let name = instance.name {
                nameOffsets.append(UInt32(names.count)); names.append(Data((name + "\0").utf8))
            } else { nameOffsets.append(0) }
        }
        let dataTableOffset = align32(nameTableOffset + names.count)
        var relativeOffsets = [UInt32](repeating: 0, count: instances.count)
        var dataTableLength = 0
        for (index, instance) in instances.enumerated() where instance.payload != nil {
            relativeOffsets[index] = UInt32(dataTableLength + 8)
            dataTableLength += align32(instance.payload!.count + 8)
        }
        let rawTableOffset = align32(dataTableOffset + dataTableLength)
        var output = Data()
        appendU64(&output, 0x0003_bcdf_33dc_271f); output.append(Data("23RV".utf8))
        appendU16(&output, 64); appendU16(&output, 20); appendU16(&output, 16); appendU16(&output, 8)
        appendU32(&output, UInt32(instances.count)); appendU32(&output, 0); appendU32(&output, 0)
        appendU32(&output, UInt32(dataTableOffset)); appendU32(&output, UInt32(dataTableLength))
        appendU32(&output, UInt32(nameTableOffset)); appendU32(&output, UInt32(names.count))
        appendU32(&output, UInt32(rawTableOffset)); appendU32(&output, UInt32(raw.count)); appendU64(&output, 0)
        for (index, instance) in instances.enumerated() {
            output.append(Data(String(instance.tag.reversed()).utf8))
            appendU32(&output, relativeOffsets[index]); appendU32(&output, nameOffsets[index])
            appendU32(&output, UInt32((instance.payload?.count ?? -8) + 8))
            let descriptorFlags: UInt32 = instance.payload == nil ? 0x0002 : (instance.name == nil ? 0x0001 : 0)
            appendU32(&output, descriptorFlags)
        }
        pad(&output, to: nameTableOffset); output.append(names); pad(&output, to: dataTableOffset)
        for (index, instance) in instances.enumerated() {
            guard let payload = instance.payload else { continue }
            pad32(&output); appendU32(&output, instanceID(index)); appendU32(&output, 0); output.append(payload)
        }
        pad(&output, to: rawTableOffset); output.append(raw)
        return output
    }

    private static func instanceID(_ index: Int) -> UInt32 { UInt32(index << 8) | 1 }
    private static func align32(_ value: Int) -> Int { (value + 31) & ~31 }
    private static func pad32(_ data: inout Data) { pad(&data, to: align32(data.count)) }
    private static func pad(_ data: inout Data, to count: Int) { if data.count < count { data.append(Data(repeating: 0, count: count - data.count)) } }
    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private static func appendU16(_ data: inout Data, _ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
    private static func appendI16(_ data: inout Data, _ value: Int16) { appendU16(&data, UInt16(bitPattern: value)) }
    private static func appendU32(_ data: inout Data, _ value: UInt32) { for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
    private static func appendU64(_ data: inout Data, _ value: UInt64) { for shift in stride(from: 0, through: 56, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) } }
}
