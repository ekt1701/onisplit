import Foundation

package struct OniUnpackResult {
    package let fileCount: Int
    package let outputURLs: [URL]
}

package enum OniDatUnpacker {
    private struct BinaryKey: Hashable {
        let destination: OniBinaryDestination
        let offset: UInt32
    }

    private struct OutputEntry {
        let sourceIndex: Int
        let hasData: Bool
        let hasName: Bool
        var payload: Data?
        var dataOffset: UInt32 = 0
        var nameOffset: UInt32 = 0
    }

    package static func export(
        file: OniDatFile,
        to outputDirectory: URL,
        namePrefixes: [String] = [],
        overwrite: Bool = true
    ) throws -> OniUnpackResult {
        guard file.header.versionBytes == "VR31" || file.header.versionBytes == "VR32" else {
            throw OniDatError.invalidHeader("-export supports VR31 DAT and VR32 ONI files")
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var usedFileNames = Set<String>()
        var outputURLs: [URL] = []

        let roots = file.instances.filter { instance in
            instance.descriptorFlags & 1 == 0 && instance.descriptorFlags & 2 == 0 && !instance.fullName.isEmpty &&
            (namePrefixes.isEmpty || namePrefixes.contains(where: { prefix in
                instance.fullName.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
            }))
        }
        let binarySizes = try collectBinarySizes(file, roots: roots)

        for root in roots {
            let encodedName = uniqueFileName(encodeFileName(root.fullName), used: &usedFileNames)
            let outputURL = outputDirectory.appendingPathComponent(encodedName).appendingPathExtension("oni")
            if !overwrite && FileManager.default.fileExists(atPath: outputURL.path) {
                continue
            }
            let data = try makeStandaloneFile(file, rootIndex: root.id, binarySizes: binarySizes)
            try data.write(to: outputURL, options: .atomic)
            outputURLs.append(outputURL)
        }

        return OniUnpackResult(fileCount: outputURLs.count, outputURLs: outputURLs)
    }

    package static func standaloneData(
        from file: OniDatFile, rootIndex: Int, rootName: String,
        rootTextureName: String? = nil
    ) throws -> Data {
        guard file.instances.indices.contains(rootIndex), !rootName.isEmpty else {
            throw OniDatError.outOfBounds("standalone root instance")
        }
        let binarySizes = try collectBinarySizes(file, roots: [file.instances[rootIndex]])
        var nameOverrides: [Int: String] = [:]
        if let rootTextureName, !rootTextureName.isEmpty,
           file.instances[rootIndex].templateTag == "M3GM",
           file.instances[rootIndex].dataOffset + 32 <= file.data.count {
            let link = read32(file.data, file.instances[rootIndex].dataOffset + 28)
            let textureIndex = Int(link >> 8)
            if link != 0, file.instances.indices.contains(textureIndex),
               file.instances[textureIndex].templateTag == "TXMP" {
                nameOverrides[textureIndex] = rootTextureName.lowercased().hasPrefix("txmp")
                    ? rootTextureName : "TXMP" + rootTextureName
            }
        }
        return try makeStandaloneFile(
            file, rootIndex: rootIndex, binarySizes: binarySizes,
            rootName: rootName, nameOverrides: nameOverrides
        )
    }

    private static func makeStandaloneFile(
        _ file: OniDatFile,
        rootIndex: Int,
        binarySizes: [BinaryKey: Int],
        rootName: String? = nil,
        nameOverrides: [Int: String] = [:]
    ) throws -> Data {
        var sourceIndices: [Int] = [rootIndex]
        var seen: Set<Int> = [rootIndex]
        var scan = 0

        while scan < sourceIndices.count {
            let sourceIndex = sourceIndices[scan]
            scan += 1
            let source = file.instances[sourceIndex]
            let isNamed = source.descriptorFlags & 1 == 0
            let isPlaceholder = source.descriptorFlags & 2 != 0 || declaredSize(file, sourceIndex) == 0
            if sourceIndex != rootIndex && (isNamed || isPlaceholder) { continue }

            var payload = try sourcePayload(file, index: sourceIndex)
            guard let schema = OniPackSchema.source(source.templateTag, checksum: file.header.checksum) else {
                throw OniDatError.invalidHeader("export metadata is unavailable for \(source.templateTag)")
            }
            var cursor = 0
            do {
                try OniPackSchema.walk(schema.layout, data: &payload, cursor: &cursor, pointer: { _, value in
                    let dependency = Int(value >> 8)
                    guard dependency >= 0, dependency < file.instances.count else {
                        throw OniDatError.outOfBounds("link from \(source.fullName.isEmpty ? source.templateTag : source.fullName)")
                    }
                    if seen.insert(dependency).inserted { sourceIndices.append(dependency) }
                    return value
                }, binary: { _, value, _ in value })
            } catch let error as OniDatError {
                throw error.withContext("while reading \(source.templateTag) #\(sourceIndex)")
            }
        }

        let newIndex = Dictionary(uniqueKeysWithValues: sourceIndices.enumerated().map { ($0.element, $0.offset) })
        var entries = sourceIndices.map { sourceIndex -> OutputEntry in
            let source = file.instances[sourceIndex]
            let hasName = source.descriptorFlags & 1 == 0 || (sourceIndex == rootIndex && rootName != nil)
            let hasData = sourceIndex == rootIndex || (!hasName && source.descriptorFlags & 2 == 0 && declaredSize(file, sourceIndex) > 0)
            return OutputEntry(sourceIndex: sourceIndex, hasData: hasData, hasName: hasName, payload: nil)
        }

        var embeddedRaw = Data(repeating: 0, count: 32)
        var binaryOffsets: [BinaryKey: UInt32] = [:]

        func allocateBinary(_ key: BinaryKey) throws -> UInt32 {
            if let existing = binaryOffsets[key] { return existing }
            let storage: Data?
            switch key.destination {
            case .raw: storage = file.rawData
            case .sep: storage = file.sepData
            }
            guard let storage, let size = binarySizes[key], Int(key.offset) + size <= storage.count else {
                throw OniDatError.outOfBounds("binary data at offset \(key.offset)")
            }
            pad32(&embeddedRaw)
            let outputOffset = UInt32(embeddedRaw.count)
            embeddedRaw.append(storage.subdata(in: Int(key.offset)..<(Int(key.offset) + size)))
            binaryOffsets[key] = outputOffset
            return outputOffset
        }

        for index in entries.indices where entries[index].hasData {
            let sourceIndex = entries[index].sourceIndex
            let source = file.instances[sourceIndex]
            var payload = try sourcePayload(file, index: sourceIndex)
            guard let schema = OniPackSchema.source(source.templateTag, checksum: file.header.checksum) else {
                throw OniDatError.invalidHeader("export metadata is unavailable for \(source.templateTag)")
            }
            var cursor = 0
            do {
                try OniPackSchema.walk(schema.layout, data: &payload, cursor: &cursor, pointer: { _, value in
                    let oldIndex = Int(value >> 8)
                    guard let mapped = newIndex[oldIndex] else {
                        throw OniDatError.invalidHeader("an exported dependency was not collected")
                    }
                    return UInt32(mapped << 8) | 1
                }, binary: { _, value, destination in
                    try allocateBinary(BinaryKey(destination: destination, offset: value))
                })
            } catch let error as OniDatError {
                throw error.withContext("while exporting \(source.templateTag) #\(sourceIndex)")
            }

            // Standalone files use PC TXMP field ordering, even when exported from a Mac DAT.
            if source.templateTag == "TXMP", file.header.checksum == 0x0003_bcdf_23c1_3061, payload.count >= 156 {
                for byte in 0..<4 { payload.swapAt(148 + byte, 152 + byte) }
                payload[129] |= 0x10
            }
            entries[index].payload = payload
        }

        var names = Data()
        for index in entries.indices where entries[index].hasName {
            entries[index].nameOffset = UInt32(names.count)
            let source = file.instances[entries[index].sourceIndex]
            let name = nameOverrides[entries[index].sourceIndex]
                ?? (entries[index].sourceIndex == rootIndex ? (rootName ?? source.fullName) : source.fullName)
            names.append(Data((name + "\0").utf8))
        }

        let descriptorEnd = 64 + entries.count * 20
        let nameBlockOffset = align32(descriptorEnd)
        let dataBlockOffset = align32(nameBlockOffset + names.count)
        var dataBlockLength = 0
        for index in entries.indices where entries[index].hasData {
            entries[index].dataOffset = UInt32(dataBlockLength + 8)
            dataBlockLength += declaredSize(file, entries[index].sourceIndex)
        }
        let rawBlockOffset = align32(dataBlockOffset + dataBlockLength)
        let containsMacSound = entries.contains {
            file.instances[$0.sourceIndex].templateTag == "SNDD" && file.header.checksum == 0x0003_bcdf_23c1_3061
        }
        let checksum: UInt64 = containsMacSound ? 0x0003_bcdf_23c1_3061 : 0x0003_bcdf_33dc_271f

        var output = Data()
        append64(&output, checksum)
        output.append(Data("23RV".utf8))
        append64(&output, 0x0008_0010_0014_0040)
        append32(&output, UInt32(entries.count))
        append32(&output, 0)
        append32(&output, 0)
        append32(&output, UInt32(dataBlockOffset))
        append32(&output, UInt32(dataBlockLength))
        append32(&output, UInt32(nameBlockOffset))
        append32(&output, UInt32(names.count))
        append32(&output, UInt32(rawBlockOffset))
        append32(&output, UInt32(embeddedRaw.count))
        output.append(Data(repeating: 0, count: 8))

        for entry in entries {
            let source = file.instances[entry.sourceIndex]
            output.append(Data(String(source.templateTag.reversed()).utf8))
            append32(&output, entry.hasData ? entry.dataOffset : 0)
            append32(&output, entry.hasName ? entry.nameOffset : 0)
            append32(&output, entry.hasData ? UInt32(declaredSize(file, entry.sourceIndex)) : 0)
            var flags: UInt32 = entry.hasName ? 0 : 1
            if !entry.hasData { flags |= 2 }
            append32(&output, flags)
        }

        pad(&output, nameBlockOffset)
        output.append(names)
        pad(&output, dataBlockOffset)
        for (index, entry) in entries.enumerated() where entry.hasData {
            append32(&output, UInt32(index << 8) | 1)
            append32(&output, 0)
            if let payload = entry.payload { output.append(payload) }
            pad(&output, dataBlockOffset + Int(entry.dataOffset) - 8 + declaredSize(file, entry.sourceIndex))
        }
        pad(&output, rawBlockOffset)
        output.append(embeddedRaw)
        return output
    }

    private static func collectBinarySizes(_ file: OniDatFile, roots: [OniDatInstance]) throws -> [BinaryKey: Int] {
        var offsets: [OniBinaryDestination: Set<UInt32>] = [.raw: [], .sep: []]
        var pending = roots.map(\.id)
        var visited = Set<Int>()

        while let index = pending.popLast() {
            guard visited.insert(index).inserted else { continue }
            guard file.instances.indices.contains(index) else {
                throw OniDatError.outOfBounds("dependency instance \(index)")
            }
            let instance = file.instances[index]
            if instance.descriptorFlags & 2 != 0 || declaredSize(file, index) == 0 { continue }
            guard let schema = OniPackSchema.source(instance.templateTag, checksum: file.header.checksum) else {
                throw OniDatError.invalidHeader("export metadata is unavailable for \(instance.templateTag)")
            }
            var payload = try sourcePayload(file, index: instance.id)
            var cursor = 0
            do {
                try OniPackSchema.walk(schema.layout, data: &payload, cursor: &cursor, pointer: { _, value in
                    let dependency = Int(value >> 8)
                    guard dependency >= 0, dependency < file.instances.count else {
                        throw OniDatError.outOfBounds("link from \(instance.fullName.isEmpty ? instance.templateTag : instance.fullName)")
                    }
                    pending.append(dependency)
                    return value
                }, binary: { _, value, destination in
                    offsets[destination, default: []].insert(value)
                    return value
                })
            } catch let error as OniDatError {
                throw error.withContext("while scanning \(instance.templateTag) #\(instance.id)")
            }
        }

        var result: [BinaryKey: Int] = [:]
        for destination in [OniBinaryDestination.raw, .sep] {
            let storage: Data?
            switch destination {
            case .raw: storage = file.rawData
            case .sep: storage = file.sepData
            }
            let sorted = offsets[destination, default: []].sorted()
            if sorted.isEmpty { continue }
            guard let storage else { throw OniDatError.invalidHeader("a required companion data file is missing") }
            for (index, offset) in sorted.enumerated() {
                let end = index + 1 < sorted.count ? Int(sorted[index + 1]) : storage.count
                guard Int(offset) <= end, end <= storage.count else {
                    throw OniDatError.outOfBounds("binary data at offset \(offset)")
                }
                result[BinaryKey(destination: destination, offset: offset)] = end - Int(offset)
            }
        }
        return result
    }

    private static func sourcePayload(_ file: OniDatFile, index: Int) throws -> Data {
        let instance = file.instances[index]
        let count = max(0, declaredSize(file, index) - 8)
        let available = max(0, min(count, file.data.count - instance.dataOffset))
        guard instance.dataOffset >= 0, instance.dataOffset <= file.data.count else {
            throw OniDatError.outOfBounds("instance \(index)")
        }
        var result = file.data.subdata(in: instance.dataOffset..<(instance.dataOffset + available))
        if available < count { result.append(Data(repeating: 0, count: count - available)) }
        return result
    }

    private static func declaredSize(_ file: OniDatFile, _ index: Int) -> Int {
        let descriptor = file.header.headerSize + index * file.header.instanceDescriptorSize
        guard descriptor >= 0, descriptor + 16 <= file.data.count else { return 0 }
        return Int(read32(file.data, descriptor + 12))
    }

    private static func encodeFileName(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar.value == 0 || scalar == "/" || scalar == ":" {
                result += String(format: "%%%02X", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func uniqueFileName(_ candidate: String, used: inout Set<String>) -> String {
        var value = candidate
        while used.contains(value.lowercased()) {
            let insertion = min(4, value.count)
            let index = value.index(value.startIndex, offsetBy: insertion)
            value.insert(contentsOf: "%00", at: index)
        }
        used.insert(value.lowercased())
        return value
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func append32(_ data: inout Data, _ value: UInt32) {
        for byte in 0..<4 { data.append(UInt8((value >> UInt32(byte * 8)) & 0xff)) }
    }

    private static func append64(_ data: inout Data, _ value: UInt64) {
        for byte in 0..<8 { data.append(UInt8((value >> UInt64(byte * 8)) & 0xff)) }
    }

    private static func align32(_ value: Int) -> Int { (value + 31) & ~31 }
    private static func pad32(_ data: inout Data) { pad(&data, align32(data.count)) }
    private static func pad(_ data: inout Data, _ count: Int) {
        if data.count < count { data.append(Data(repeating: 0, count: count - data.count)) }
    }
}
