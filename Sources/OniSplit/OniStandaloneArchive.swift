import Foundation

package struct OniStandaloneInstanceDefinition {
    package let tag: String
    package let name: String?
    package let payload: Data?

    package init(tag: String, name: String? = nil, payload: Data? = nil) {
        precondition(tag.utf8.count == 4)
        self.tag = tag
        self.name = name
        self.payload = payload
    }
}

package enum OniStandaloneArchiveBuilder {
    private struct Entry {
        let definition: OniStandaloneInstanceDefinition
        var dataOffset: UInt32 = 0
        var nameOffset: UInt32 = 0
    }

    package static func build(instances definitions: [OniStandaloneInstanceDefinition], embeddedRaw: Data) -> Data {
        var entries = definitions.map { Entry(definition: $0) }
        var names = Data()
        for index in entries.indices where entries[index].definition.name != nil {
            entries[index].nameOffset = UInt32(names.count)
            names.append(Data((entries[index].definition.name! + "\0").utf8))
        }

        let descriptorEnd = 64 + entries.count * 20
        let nameBlockOffset = align32(descriptorEnd)
        let dataBlockOffset = align32(nameBlockOffset + names.count)
        var dataBlockLength = 0
        for index in entries.indices where entries[index].definition.payload != nil {
            entries[index].dataOffset = UInt32(dataBlockLength + 8)
            dataBlockLength += entries[index].definition.payload!.count + 8
        }
        let rawBlockOffset = align32(dataBlockOffset + dataBlockLength)

        var output = Data()
        append(&output, UInt64(0x0003_bcdf_33dc_271f))
        output.append(Data("23RV".utf8))
        append(&output, UInt64(0x0008_0010_0014_0040))
        append(&output, UInt32(entries.count))
        append(&output, UInt32(0)); append(&output, UInt32(0))
        append(&output, UInt32(dataBlockOffset)); append(&output, UInt32(dataBlockLength))
        append(&output, UInt32(nameBlockOffset)); append(&output, UInt32(names.count))
        append(&output, UInt32(rawBlockOffset)); append(&output, UInt32(embeddedRaw.count))
        output.append(Data(repeating: 0, count: 8))

        for entry in entries {
            output.append(Data(String(entry.definition.tag.reversed()).utf8))
            append(&output, entry.definition.payload == nil ? 0 : entry.dataOffset)
            append(&output, entry.definition.name == nil ? 0 : entry.nameOffset)
            append(&output, entry.definition.payload == nil ? 0 : UInt32(entry.definition.payload!.count + 8))
            var flags: UInt32 = entry.definition.name == nil ? 1 : 0
            if entry.definition.payload == nil { flags |= 2 }
            append(&output, flags)
        }

        pad(&output, to: nameBlockOffset)
        output.append(names)
        pad(&output, to: dataBlockOffset)
        for (index, entry) in entries.enumerated() {
            guard let payload = entry.definition.payload else { continue }
            append(&output, UInt32(index << 8) | 1)
            append(&output, UInt32(0))
            output.append(payload)
        }
        pad(&output, to: rawBlockOffset)
        output.append(embeddedRaw)
        return output
    }

    private static func align32(_ value: Int) -> Int { (value + 31) & ~31 }
    private static func pad(_ data: inout Data, to count: Int) {
        if data.count < count { data.append(Data(repeating: 0, count: count - data.count)) }
    }
    private static func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
    private static func append(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }
}
