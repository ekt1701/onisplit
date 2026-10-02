import Foundation

package struct OniONLVBuildResult {
    package let fileName: String
    package let archiveData: Data
    package let objectQuadMapCount: Int
    package let corpseCount: Int
}

package enum OniONLVBuilder {
    private struct PhysicsLinks {
        let geometry: Int
        let animation: Int?
        let particles: Int?
    }

    package static func build(
        name: String,
        skyName: String,
        geometry: OniAkiraGeometry,
        physicsObjects: [OniLevelPhysicsObject] = [],
        characters: [OniLevelScriptCharacter] = [],
        particles: [OniLevelEnvironmentParticle] = [],
        corpses: [OniLevelCorpse] = []
    ) throws -> OniONLVBuildResult {
        var orderedObjectIDs: [UInt32] = []
        var polygonIndices: [UInt32: [UInt32]] = [:]
        for (index, polygon) in geometry.polygons.enumerated() where polygon.objectID != .max {
            if polygonIndices[polygon.objectID] == nil { orderedObjectIDs.append(polygon.objectID) }
            polygonIndices[polygon.objectID, default: []].append(UInt32(index))
        }

        let pointer: (Int) -> UInt32 = { UInt32($0 << 8) | 1 }
        var supplemental: [OniStandaloneInstanceDefinition] = []
        var referenceIndices: [String: Int] = [:]
        var physicsLinks: [PhysicsLinks] = []
        for object in physicsObjects {
            var geometryIndices: [Int] = []
            for rawName in object.geometryNames {
                let geometryName = normalizedName(rawName, tag: "M3GM")
                let key = "M3GM\0" + geometryName
                if referenceIndices[key] == nil {
                    referenceIndices[key] = 8 + supplemental.count
                    supplemental.append(.init(tag: "M3GM", name: "M3GM" + geometryName))
                }
                geometryIndices.append(referenceIndices[key]!)
            }
            let m3gaIndex = 8 + supplemental.count
            supplemental.append(.init(tag: "M3GA", payload: m3gaPayload(geometryIndices, pointer: pointer)))

            var animationIndex: Int?
            if !object.animationName.isEmpty {
                let animationName = normalizedName(object.animationName, tag: "OBAN")
                let key = "OBAN\0" + animationName
                if referenceIndices[key] == nil {
                    referenceIndices[key] = 8 + supplemental.count
                    supplemental.append(.init(tag: "OBAN", name: "OBAN" + animationName))
                }
                animationIndex = referenceIndices[key]
            }

            var particleIndex: Int?
            if !object.particles.isEmpty {
                particleIndex = 8 + supplemental.count
                supplemental.append(.init(tag: "ENVP", payload: try envpPayload(object.particles)))
            }
            physicsLinks.append(.init(geometry: m3gaIndex, animation: animationIndex, particles: particleIndex))
        }
        for character in characters {
            for (tag, name) in [("ONCC", character.className), ("ONWC", character.weaponClassName)] where !name.isEmpty {
                let key = tag + "\0" + name
                if referenceIndices[key] == nil {
                    referenceIndices[key] = 8 + supplemental.count
                    supplemental.append(.init(tag: tag, name: tag + name))
                }
            }
        }
        for corpse in corpses where corpse.isUsed && !corpse.characterClass.isEmpty {
            let key = "ONCC\0" + corpse.characterClass
            if referenceIndices[key] == nil {
                referenceIndices[key] = 8 + supplemental.count
                supplemental.append(.init(tag: "ONCC", name: "ONCC" + corpse.characterClass))
            }
        }
        let firstIndexInstance = 8 + supplemental.count
        var definitions: [OniStandaloneInstanceDefinition] = [
            .init(tag: "ONLV", name: "ONLV" + name),
            .init(tag: "OBOA"), .init(tag: "AISA"), .init(tag: "ONOA"),
            .init(tag: "ENVP"), .init(tag: "CRSA"),
            .init(tag: "ONSK", name: "ONSK" + skyName),
            .init(tag: "AKEV", name: "AKEV" + name)
        ]
        definitions += supplemental
        for _ in orderedObjectIDs { definitions.append(.init(tag: "IDXA")) }

        definitions[0] = .init(tag: "ONLV", name: "ONLV" + name, payload: try onlvPayload(name: name, pointer: pointer))
        definitions[1] = .init(tag: "OBOA", payload: try oboaPayload(physicsObjects, links: physicsLinks, pointer: pointer))
        definitions[2] = .init(tag: "AISA", payload: try aisaPayload(characters, references: referenceIndices, pointer: pointer))
        definitions[3] = .init(tag: "ONOA", payload: onoaPayload(objectIDs: orderedObjectIDs, firstIndexInstance: firstIndexInstance, pointer: pointer))
        definitions[4] = .init(tag: "ENVP", payload: try envpPayload(particles))
        let crsa = try crsaPayload(corpses, references: referenceIndices, pointer: pointer)
        definitions[5] = .init(tag: "CRSA", payload: crsa.payload)
        for (offset, objectID) in orderedObjectIDs.enumerated() {
            definitions[firstIndexInstance + offset] = .init(tag: "IDXA", payload: indexArrayPayload(polygonIndices[objectID] ?? []))
        }

        return OniONLVBuildResult(
            fileName: "ONLV\(name).oni",
            archiveData: OniStandaloneArchiveBuilder.build(instances: definitions, embeddedRaw: Data()),
            objectQuadMapCount: orderedObjectIDs.count,
            corpseCount: crsa.count
        )
    }

    private static func onlvPayload(name: String, pointer: (Int) -> UInt32) throws -> Data {
        var data = Data()
        try appendFixedString(&data, name, length: 64)
        append(&data, pointer(7))
        append(&data, pointer(1))
        data.append(Data(repeating: 0, count: 12))
        append(&data, pointer(6))
        append(&data, UInt32(0))
        append(&data, pointer(2))
        data.append(Data(repeating: 0, count: 12))
        append(&data, pointer(3))
        append(&data, pointer(4))
        data.append(Data(repeating: 0, count: 644))
        append(&data, pointer(5))
        precondition(data.count == 764)
        return data
    }

    private static func oboaPayload(
        _ objects: [OniLevelPhysicsObject],
        links: [PhysicsLinks],
        pointer: (Int) -> UInt32
    ) throws -> Data {
        guard objects.count == links.count, objects.count + 32 <= Int(UInt16.max) else {
            throw OniNativeXMLError.invalidDocument("level contains too many physics objects")
        }
        var data = Data(repeating: 0, count: 22)
        append(&data, UInt16(objects.count + 32))
        for (object, link) in zip(objects, links) {
            append(&data, pointer(link.geometry))
            append(&data, link.animation.map(pointer) ?? 0)
            append(&data, link.particles.map(pointer) ?? 0)
            append(&data, object.flags | 0x200)
            append(&data, UInt32(0))
            append(&data, object.doorScriptID)
            append(&data, object.physicsType)
            append(&data, object.scriptID)
            append(&data, object.position.x); append(&data, object.position.y); append(&data, object.position.z)
            guard object.orientation.count == 4, object.transform.count == 12 else {
                throw OniNativeXMLError.invalidDocument("physics object transform is invalid")
            }
            for value in object.orientation { append(&data, value) }
            append(&data, object.scale)
            for value in object.transform { append(&data, value) }
            try appendFixedString(&data, object.name, length: 64)
            try appendFixedString(&data, object.fileName, length: 64)
        }
        data.append(Data(repeating: 0, count: 32 * 240))
        return data
    }

    private static func m3gaPayload(_ geometryIndices: [Int], pointer: (Int) -> UInt32) -> Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(geometryIndices.count))
        for index in geometryIndices { append(&data, pointer(index)) }
        return data
    }

    private static func normalizedName(_ name: String, tag: String) -> String {
        name.lowercased().hasPrefix(tag.lowercased()) ? String(name.dropFirst(tag.count)) : name
    }

    private static func aisaPayload(
        _ characters: [OniLevelScriptCharacter],
        references: [String: Int],
        pointer: (Int) -> UInt32
    ) throws -> Data {
        guard characters.count <= Int(UInt16.max) else {
            throw OniNativeXMLError.invalidDocument("level contains too many script characters")
        }
        var data = Data(repeating: 0, count: 22)
        append(&data, UInt16(characters.count))
        for character in characters {
            try appendFixedString(&data, character.name, length: 32)
            append(&data, character.scriptID)
            append(&data, character.flagID)
            append(&data, character.flags)
            append(&data, character.team)
            let classIndex = references["ONCC\0" + character.className]
            append(&data, classIndex.map(pointer) ?? 0)
            data.append(Data(repeating: 0, count: 36))
            for script in character.scripts { try appendFixedString(&data, script, length: 32) }
            let weaponIndex = references["ONWC\0" + character.weaponClassName]
            append(&data, weaponIndex.map(pointer) ?? 0)
            append(&data, character.ammo)
            data.append(Data(repeating: 0, count: 10))
        }
        return data
    }

    private static func envpPayload(_ particles: [OniLevelEnvironmentParticle]) throws -> Data {
        guard particles.count <= Int(UInt16.max) else {
            throw OniNativeXMLError.invalidDocument("level contains too many environment particles")
        }
        var data = Data(repeating: 0, count: 22)
        append(&data, UInt16(particles.count))
        for particle in particles {
            try appendFixedString(&data, particle.particleClass, length: 64)
            try appendFixedString(&data, particle.tag, length: 48)
            guard particle.transform.count == 12 else {
                throw OniNativeXMLError.invalidDocument("environment particle transform requires 12 values")
            }
            for value in particle.transform { append(&data, value) }
            append(&data, particle.decalScale.x)
            append(&data, particle.decalScale.y)
            append(&data, particle.flags)
            data.append(Data(repeating: 0, count: 38))
        }
        return data
    }

    private static func onoaPayload(
        objectIDs: [UInt32], firstIndexInstance: Int, pointer: (Int) -> UInt32
    ) -> Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(objectIDs.count))
        for (offset, objectID) in objectIDs.enumerated() {
            append(&data, objectID)
            append(&data, pointer(firstIndexInstance + offset))
        }
        return data
    }

    private static func crsaPayload(
        _ sourceCorpses: [OniLevelCorpse],
        references: [String: Int],
        pointer: (Int) -> UInt32
    ) throws -> (payload: Data, count: Int) {
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        let unused = OniLevelCorpse(
            isFixed: false, isUsed: false, fileName: "", characterClass: "",
            transforms: Array(repeating: identity, count: 19),
            boundingBoxMinimum: OniLevelVector3(x: 0, y: 0, z: 0),
            boundingBoxMaximum: OniLevelVector3(x: 0, y: 0, z: 0)
        )
        var corpses = sourceCorpses
        while corpses.count < 20 { corpses.append(unused) }
        let fixedCount = corpses.count { $0.isFixed }
        let usedCount = corpses.count { $0.isUsed }
        while corpses.count - usedCount < 5 { corpses.append(unused) }
        corpses = corpses.enumerated().sorted {
            let lhsOrder = $0.element.isFixed ? 1 : ($0.element.isUsed ? 2 : 3)
            let rhsOrder = $1.element.isFixed ? 1 : ($1.element.isUsed ? 2 : 3)
            return lhsOrder == rhsOrder ? $0.offset < $1.offset : lhsOrder < rhsOrder
        }.map(\.element)

        var data = Data(repeating: 0, count: 12)
        append(&data, UInt32(fixedCount))
        append(&data, UInt32(usedCount))
        append(&data, UInt32(corpses.count))
        for corpse in corpses {
            try appendFixedString(&data, corpse.fileName, length: 32)
            data.append(Data(repeating: 0, count: 128))
            if corpse.isUsed {
                let classIndex = references["ONCC\0" + corpse.characterClass]
                append(&data, classIndex.map(pointer) ?? 0)
                guard corpse.transforms.count == 19, corpse.transforms.allSatisfy({ $0.count == 12 }) else {
                    throw OniNativeXMLError.invalidDocument("corpse requires exactly 19 transforms")
                }
                for transform in corpse.transforms {
                    for value in transform { append(&data, value) }
                }
                append(&data, corpse.boundingBoxMinimum.x)
                append(&data, corpse.boundingBoxMinimum.y)
                append(&data, corpse.boundingBoxMinimum.z)
                append(&data, corpse.boundingBoxMaximum.x)
                append(&data, corpse.boundingBoxMaximum.y)
                append(&data, corpse.boundingBoxMaximum.z)
            } else {
                data.append(Data(repeating: 0, count: 940))
            }
        }
        precondition(data.count == 24 + corpses.count * 1_100)
        return (data, corpses.count)
    }

    private static func indexArrayPayload(_ values: [UInt32]) -> Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(values.count))
        for value in values { append(&data, value) }
        return data
    }

    private static func appendFixedString(_ data: inout Data, _ value: String, length: Int) throws {
        let bytes = Data(value.utf8)
        guard bytes.count < length else {
            throw OniNativeXMLError.invalidDocument("level name is too long for ONLV")
        }
        data.append(bytes)
        data.append(Data(repeating: 0, count: length - bytes.count))
    }

    private static func append(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
    }

    private static func append(_ data: inout Data, _ value: Int16) {
        append(&data, UInt16(bitPattern: value))
    }

    private static func append(_ data: inout Data, _ value: Int32) {
        append(&data, UInt32(bitPattern: value))
    }

    private static func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }

    private static func append(_ data: inout Data, _ value: Float) {
        append(&data, value.bitPattern)
    }
}
