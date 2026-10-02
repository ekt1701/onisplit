import Foundation

package struct OniMetadataField: Identifiable, Hashable {
    package let id: String
    package let name: String
    package let value: String
    package let offset: Int
    package let byteCount: Int

    init(_ name: String, _ value: String, offset: Int, byteCount: Int) {
        self.id = "\(offset):\(name)"
        self.name = name
        self.value = value
        self.offset = offset
        self.byteCount = byteCount
    }
}

package struct OniStructuredMetadata {
    package let templateName: String
    package let fields: [OniMetadataField]
}

extension OniDatFile {
    package func structuredMetadata(for instance: OniDatInstance) -> OniStructuredMetadata? {
        let reader = BinaryReader(data: data)
        let base = instance.dataOffset

        func contains(_ offset: Int, _ count: Int) -> Bool {
            offset >= 0 && count >= 0 && offset <= instance.dataSize && count <= instance.dataSize - offset
        }
        func u16(_ offset: Int) -> UInt16? {
            contains(offset, 2) ? try? reader.u16(at: base + offset) : nil
        }
        func u32(_ offset: Int) -> UInt32? {
            contains(offset, 4) ? try? reader.u32(at: base + offset) : nil
        }
        func hex(_ value: UInt32) -> String { String(format: "0x%08X", value) }
        func field(_ name: String, _ value: CustomStringConvertible?, _ offset: Int, _ size: Int) -> OniMetadataField? {
            guard let value else { return nil }
            return OniMetadataField(name, value.description, offset: offset, byteCount: size)
        }
        func linkField(_ name: String, _ offset: Int) -> OniMetadataField? {
            guard let raw = u32(offset) else { return nil }
            return OniMetadataField(name, linkDescription(raw), offset: offset, byteCount: 4)
        }

        switch instance.templateTag {
        case "TXMP":
            guard instance.dataSize >= 156 else { return nil }
            let formatValue = u32(0x88)
            let formatDescription: String?
            if let formatValue, let format = OniTextureFormat(rawValue: formatValue) {
                formatDescription = "\(formatValue) (\(format.displayName))"
            } else {
                formatDescription = formatValue.map(String.init)
            }
            return OniStructuredMetadata(templateName: "Texture Map", fields: [
                u32(0x80).map { OniMetadataField("Flags", hex($0), offset: 0x80, byteCount: 4) },
                field("Width", u16(0x84), 0x84, 2),
                field("Height", u16(0x86), 0x86, 2),
                formatDescription.map { OniMetadataField("Format", $0, offset: 0x88, byteCount: 4) },
                linkField("Animation", 0x8c),
                linkField("Environment map", 0x90),
                u32(0x94).map { OniMetadataField("RAW offset", hex($0), offset: 0x94, byteCount: 4) },
                u32(0x98).map { OniMetadataField("SEP offset", hex($0), offset: 0x98, byteCount: 4) }
            ].compactMap { $0 })

        case "TXAN":
            guard let frameCount = u32(0x14), frameCount <= 4096 else { return nil }
            var fields = [
                field("Time per frame", u16(0x0c), 0x0c, 2),
                field("Random time minimum", u16(0x0e), 0x0e, 2),
                field("Random time range", u16(0x10), 0x10, 2),
                field("Frame count", frameCount, 0x14, 4)
            ].compactMap { $0 }
            let availableFrames = max(0, (instance.dataSize - 0x18) / 4)
            for index in 0..<min(Int(frameCount), availableFrames) {
                if let frame = linkField("Frame \(index)", 0x18 + index * 4) { fields.append(frame) }
            }
            return OniStructuredMetadata(templateName: "Texture Map Animation", fields: fields)

        case "BINA", "OSBD":
            guard let size = u32(0), let offset = u32(4) else { return nil }
            let templateName = instance.templateTag == "BINA" ? "Binary Data" : "Oni Sound Binary Data"
            let storage = header.platformName == "Mac" ? "SEP" : "RAW"
            return OniStructuredMetadata(templateName: templateName, fields: [
                OniMetadataField("Data size", "\(size) bytes", offset: 0, byteCount: 4),
                OniMetadataField("\(storage) offset", hex(offset), offset: 4, byteCount: 4)
            ])

        case "SNDD":
            if header.platformName == "Mac" {
                guard let flags = u32(0), let duration = u32(4), let size = u32(8), let offset = u32(12) else { return nil }
                return OniStructuredMetadata(templateName: "Sound Data (Mac)", fields: [
                    OniMetadataField("Flags", hex(flags), offset: 0, byteCount: 4),
                    OniMetadataField("Duration", "\(duration)", offset: 4, byteCount: 4),
                    OniMetadataField("Data size", "\(size) bytes", offset: 8, byteCount: 4),
                    OniMetadataField("RAW offset", hex(offset), offset: 12, byteCount: 4)
                ])
            }
            guard let headerSize = u32(0), let format = u16(4), let channels = u16(6),
                  let rate = u32(8), let bytesPerSecond = u32(12), let alignment = u16(16),
                  let bits = u16(18) else { return nil }
            var fields: [OniMetadataField] = [
                OniMetadataField("Wave header size", "\(headerSize)", offset: 0, byteCount: 4),
                OniMetadataField("Format", "\(format)", offset: 4, byteCount: 2),
                OniMetadataField("Channels", "\(channels)", offset: 6, byteCount: 2),
                OniMetadataField("Sample rate", "\(rate) Hz", offset: 8, byteCount: 4),
                OniMetadataField("Bytes per second", "\(bytesPerSecond)", offset: 12, byteCount: 4),
                OniMetadataField("Block alignment", "\(alignment)", offset: 16, byteCount: 2),
                OniMetadataField("Bits per sample", "\(bits)", offset: 18, byteCount: 2)
            ]
            if let duration = u16(54) { fields.append(OniMetadataField("Duration", "\(duration)", offset: 54, byteCount: 2)) }
            if let size = u32(56) { fields.append(OniMetadataField("Data size", "\(size) bytes", offset: 56, byteCount: 4)) }
            if let offset = u32(60) { fields.append(OniMetadataField("RAW offset", hex(offset), offset: 60, byteCount: 4)) }
            return OniStructuredMetadata(templateName: "Sound Data (PC)", fields: fields)

        default:
            return nil
        }
    }

    private func linkDescription(_ raw: UInt32) -> String {
        guard raw != 0 else { return "None" }
        guard raw & 1 == 1 else { return String(format: "0x%08X (invalid)", raw) }
        let index = Int(raw >> 8)
        guard instances.indices.contains(index) else {
            return String(format: "0x%08X (index %d out of range)", raw, index)
        }
        let target = instances[index]
        return "\(target.templateTag) \(target.displayName) [\(index)]"
    }
}
