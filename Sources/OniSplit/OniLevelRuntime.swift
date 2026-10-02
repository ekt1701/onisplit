import Foundation

package struct OniLevelScriptCharacter {
    package let name: String
    package let scriptID: Int16
    package let flagID: Int16
    package let flags: UInt16
    package let team: UInt16
    package let className: String
    package let scripts: [String]
    package let weaponClassName: String
    package let ammo: Int16
}

package struct OniLevelEnvironmentParticle {
    package let particleClass: String
    package let tag: String
    package let transform: [Float]
    package let decalScale: OniLevelVector2
    package let flags: UInt16
}

package struct OniLevelPhysicsObject {
    package let name: String
    package let fileName: String
    package let geometryNames: [String]
    package let geometrySourceIndices: [Int]?
    package let importedGeometryURL: URL?
    package let archiveGeometryURL: URL?
    package let archiveGeometryRootIndices: [Int]?
    package let archiveGeometryTextureNames: [String]?
    package let geometryBuildName: String
    package let animationName: String
    package let animationClips: [OniLevelAnimationClip]
    package let animationNodeID: String?
    package let particles: [OniLevelEnvironmentParticle]
    package let flags: UInt32
    package let doorScriptID: Int32
    package let physicsType: UInt32
    package let scriptID: Int32
    package let position: OniLevelVector3
    package let orientation: [Float]
    package let scale: Float
    package let transform: [Float]

    package func applyingAnimationStart(
        scale: Float, orientation: [Float], position: OniLevelVector3,
        physicsType replacementPhysicsType: UInt32? = nil
    ) -> OniLevelPhysicsObject {
        OniLevelPhysicsObject(
            name: name, fileName: fileName, geometryNames: geometryNames,
            geometrySourceIndices: geometrySourceIndices,
            importedGeometryURL: importedGeometryURL,
            archiveGeometryURL: archiveGeometryURL,
            archiveGeometryRootIndices: archiveGeometryRootIndices,
            archiveGeometryTextureNames: archiveGeometryTextureNames,
            geometryBuildName: geometryBuildName,
            animationName: animationName, animationClips: animationClips,
            animationNodeID: animationNodeID, particles: particles, flags: flags,
            doorScriptID: doorScriptID, physicsType: replacementPhysicsType ?? physicsType,
            scriptID: scriptID, position: position,
            orientation: orientation, scale: scale, transform: transform
        )
    }

    package func replacingGeometryNames(_ replacement: [String]) -> OniLevelPhysicsObject {
        OniLevelPhysicsObject(
            name: name, fileName: fileName, geometryNames: replacement,
            geometrySourceIndices: geometrySourceIndices,
            importedGeometryURL: importedGeometryURL,
            archiveGeometryURL: archiveGeometryURL,
            archiveGeometryRootIndices: archiveGeometryRootIndices,
            archiveGeometryTextureNames: archiveGeometryTextureNames,
            geometryBuildName: geometryBuildName,
            animationName: animationName, animationClips: animationClips,
            animationNodeID: animationNodeID, particles: particles, flags: flags,
            doorScriptID: doorScriptID, physicsType: physicsType,
            scriptID: scriptID, position: position,
            orientation: orientation, scale: scale, transform: transform
        )
    }
}

package struct OniLevelCorpse {
    package let isFixed: Bool
    package let isUsed: Bool
    package let fileName: String
    package let characterClass: String
    package let transforms: [[Float]]
    package let boundingBoxMinimum: OniLevelVector3
    package let boundingBoxMaximum: OniLevelVector3
}

package struct OniLevelRuntimeContent {
    package var characters: [OniLevelScriptCharacter] = []
    package var particles: [OniLevelEnvironmentParticle] = []
    package var physicsObjects: [OniLevelPhysicsObject] = []
    package var corpses: [OniLevelCorpse] = []
}

package enum OniLevelRuntimeReader {
    package static func read(_ urls: [URL]) throws -> OniLevelRuntimeContent {
        var content = OniLevelRuntimeContent()
        for url in urls {
            let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
            guard let oni = document.rootElement(), oni.name == "Oni",
                  let section = oni.children?.compactMap({ $0 as? XMLElement }).first else {
                throw OniNativeXMLError.invalidDocument("object file \(url.lastPathComponent) must contain an Oni section")
            }
            switch section.name {
            case "Objects":
                continue
            case "Characters":
                content.characters += try section.elements(forName: "Character").map(readCharacter)
            case "Particles":
                content.particles += try section.elements(forName: "Particle").map(readParticle)
            case "Physics":
                content.physicsObjects += try section.elements(forName: "Object").flatMap {
                    try readPhysicsObject($0, relativeTo: url.deletingLastPathComponent())
                }
            case "Corpses", "CRSA":
                content.corpses += try readCorpses(section, sourceURL: url)
            default:
                throw OniNativeXMLError.invalidDocument("unsupported level object section <\(section.name ?? "unknown")> in \(url.lastPathComponent)")
            }
        }
        return content
    }

    package static func readEnvironmentPhysics(
        models: [URL], propertiesByModel: [String: [String: OniLevelEnvironmentNodeProperties]]
    ) throws -> [OniLevelPhysicsObject] {
        var result: [OniLevelPhysicsObject] = []
        for sourceURL in models {
            let properties = propertiesByModel[sourceURL.standardizedFileURL.path] ?? [:]
            guard properties.values.contains(where: \.hasPhysics) else { continue }
            let fallbackNames = try OniWeaponXMLImporter.standaloneGeometryNames(
                from: sourceURL, name: sourceURL.deletingPathExtension().lastPathComponent
            )
            let nodes = try importedPhysicsNodes(sourceURL, generatedGeometryNames: fallbackNames)
            for node in nodes {
                let inherited = node.ancestorIDs.reversed().compactMap { id in
                    properties[id].map { (id, $0) }
                }.first
                guard let (propertyID, property) = inherited, property.hasPhysics,
                      property.gunkFlags & 0x0000_2000 == 0 else { continue }
                let clips: [OniLevelAnimationClip]
                if propertyID == node.id {
                    clips = property.animationClips
                } else {
                    clips = property.animationClips.enumerated().map { clipIndex, clip in
                        OniLevelAnimationClip(
                            name: node.name, prefix: "",
                            suffix: clipIndex == 0 ? "" : String(format: "_%02d", clipIndex),
                            start: clip.start, end: clip.end, stop: clip.stop, flags: clip.flags
                        )
                    }
                }
                let active = clips.first(where: { $0.flags & 0x0008 != 0 }) ?? clips.first
                let identity = OniLevelVector3(x: 0, y: 0, z: 0)
                result.append(OniLevelPhysicsObject(
                    name: node.name, fileName: sourceURL.lastPathComponent,
                    geometryNames: node.geometryNames,
                    geometrySourceIndices: node.geometrySourceIndices,
                    importedGeometryURL: sourceURL,
                    archiveGeometryURL: nil, archiveGeometryRootIndices: nil,
                    archiveGeometryTextureNames: nil,
                    geometryBuildName: sourceURL.deletingPathExtension().lastPathComponent,
                    animationName: active.map { $0.prefix + $0.name + $0.suffix } ?? "",
                    animationClips: clips, animationNodeID: node.id,
                    particles: propertyID == node.id ? property.particles : [],
                    flags: property.objectFlags,
                    doorScriptID: 0,
                    physicsType: active.map { $0.flags & 0x0008 != 0 } == true
                        ? 3 : (property.physicsType ?? 3),
                    scriptID: property.scriptID, position: identity,
                    orientation: [0, 0, 0, 1], scale: 1,
                    transform: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
                ))
            }
        }
        return result
    }

    private static func readCorpses(_ section: XMLElement, sourceURL: URL) throws -> [OniLevelCorpse] {
        let oldFormat = section.name == "CRSA"
        let container: XMLElement
        let fixedCount: Int
        let usedCount: Int
        if oldFormat {
            guard let corpses = child(section, "Corpses") else {
                throw OniNativeXMLError.invalidDocument("CRSA requires <Corpses>")
            }
            container = corpses
            fixedCount = max(0, integer(text(section, "FixedCount")) ?? 0)
            usedCount = max(0, integer(text(section, "UsedCount")) ?? 0)
        } else {
            container = section
            fixedCount = 0
            usedCount = 0
        }

        let entries = container.children?.compactMap { $0 as? XMLElement } ?? []
        return try entries.enumerated().map { index, element in
            if element.name == "Import" {
                let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !value.isEmpty else {
                    throw OniNativeXMLError.invalidDocument("Corpse Import requires a file path")
                }
                let url = value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL
                    : sourceURL.deletingLastPathComponent().appendingPathComponent(value).standardizedFileURL
                return try readImportedCorpse(url)
            }
            guard element.name == "Corpse" || element.name == "CRSACorpse" else {
                throw OniNativeXMLError.invalidDocument("unsupported corpse element <\(element.name ?? "unknown")>")
            }

            let hasContent = !(element.children?.isEmpty ?? true)
            var isUsed = oldFormat ? index < usedCount : hasContent
            var isFixed = oldFormat ? index < min(fixedCount, usedCount) : child(element, "CanDelete") == nil
            let characterClass = {
                let modern = text(element, "Class")
                return modern.isEmpty ? text(element, "CharacterClass") : modern
            }()
            if characterClass.isEmpty {
                isUsed = false
                isFixed = false
            }

            let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
            var transforms = Array(repeating: identity, count: 19)
            if let transformContainer = child(element, "Transforms") {
                let matrices = transformContainer.children?.compactMap { $0 as? XMLElement }.filter {
                    $0.name == "Matrix4x3" || $0.name == "Matrix"
                } ?? []
                guard matrices.count <= 19 else {
                    throw OniNativeXMLError.invalidDocument("Corpse Transforms contains more than 19 matrices")
                }
                for (matrixIndex, matrixElement) in matrices.enumerated() {
                    transforms[matrixIndex] = try corpseMatrix(matrixElement)
                }
            }

            let minimum: OniLevelVector3
            let maximum: OniLevelVector3
            if let box = child(element, "BoundingBox") {
                minimum = try vector3(text(box, "Min"), default: [], field: "Corpse BoundingBox Min")
                maximum = try vector3(text(box, "Max"), default: [], field: "Corpse BoundingBox Max")
            } else {
                let x = transforms[0][9], y = transforms[0][10], z = transforms[0][11]
                minimum = OniLevelVector3(x: x - 10, y: y - 5, z: z - 10)
                maximum = OniLevelVector3(x: x + 10, y: y + 5, z: z + 10)
            }
            return OniLevelCorpse(
                isFixed: isFixed, isUsed: isUsed, fileName: sourceURL.lastPathComponent,
                characterClass: characterClass, transforms: transforms,
                boundingBoxMinimum: minimum, boundingBoxMaximum: maximum
            )
        }
    }

    private static func readImportedCorpse(_ url: URL) throws -> OniLevelCorpse {
        let data = try Data(contentsOf: url)
        let requiredSize = 128 + 4 + 19 * 48 + 24
        guard data.count >= requiredSize else {
            throw OniNativeXMLError.invalidDocument("imported corpse file is too short: \(url.path)")
        }
        let classBytes = data.prefix(128).prefix { $0 != 0 }
        guard let characterClass = String(data: classBytes, encoding: .utf8), !characterClass.isEmpty else {
            throw OniNativeXMLError.invalidDocument("imported corpse has no character class: \(url.path)")
        }
        var offset = 132
        var transforms: [[Float]] = []
        for _ in 0..<19 {
            transforms.append((0..<12).map { valueIndex in
                float32(data, offset + valueIndex * 4)
            })
            offset += 48
        }
        let minimum = OniLevelVector3(x: float32(data, offset), y: float32(data, offset + 4), z: float32(data, offset + 8))
        let maximum = OniLevelVector3(x: float32(data, offset + 12), y: float32(data, offset + 16), z: float32(data, offset + 20))
        return OniLevelCorpse(
            isFixed: true, isUsed: true, fileName: url.lastPathComponent,
            characterClass: characterClass, transforms: transforms,
            boundingBoxMinimum: minimum, boundingBoxMaximum: maximum
        )
    }

    private static func corpseMatrix(_ element: XMLElement) throws -> [Float] {
        let values = floats(element.stringValue ?? "")
        guard values.count == 12 else {
            throw OniNativeXMLError.invalidDocument("Corpse Transform requires 12 matrix numbers")
        }
        return values
    }

    private static func float32(_ data: Data, _ offset: Int) -> Float {
        let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

    private static func readCharacter(_ element: XMLElement) throws -> OniLevelScriptCharacter {
        let scripts = child(element, "Scripts")
        let scriptNames = ["Spawn", "Die", "Combat", "Alarm", "Hurt", "Defeated", "OutOfAmmo", "NoPath"]
        let orderedScripts = scriptNames.map { name in scripts.map { text($0, name) } ?? "" }
        return OniLevelScriptCharacter(
            name: text(element, "Name"),
            scriptID: try int16(text(element, "ScriptId"), field: "Character ScriptId"),
            flagID: try int16(text(element, "FlagId"), field: "Character FlagId"),
            flags: try enumValue(text(element, "Flags"), names: ["AI": 1, "AutoFreeze": 2, "Neutral": 4, "TurnGuard": 8], field: "Character Flags"),
            team: try enumValue(text(element, "Team"), names: [
                "Konoko": 0, "TCTF": 1, "Syndicate": 2, "Neutral": 3,
                "SecurityGuard": 4, "RogueKonoko": 5, "Switzerland": 6,
                "SyndicateAccessory": 7
            ], field: "Character Team"),
            className: text(element, "Class"),
            scripts: orderedScripts,
            weaponClassName: text(element, "Weapon"),
            ammo: try int16(text(element, "Ammo"), field: "Character Ammo")
        )
    }

    package static func readParticle(_ element: XMLElement) throws -> OniLevelEnvironmentParticle {
        let transformElement = child(element, "Transform")
        let transform = try matrix(transformElement)
        let scale = floats(text(element, "DecalScale"))
        guard scale.count == 2 else {
            throw OniNativeXMLError.invalidDocument("Particle DecalScale requires 2 numbers")
        }
        return OniLevelEnvironmentParticle(
            particleClass: text(element, "Class"),
            tag: text(element, "Tag"),
            transform: transform,
            decalScale: OniLevelVector2(x: scale[0], y: scale[1]),
            flags: try enumValue(text(element, "Flags"), names: ["NotInitiallyCreated": 2], field: "Particle Flags") & 2
        )
    }

    private static func readPhysicsObject(_ element: XMLElement, relativeTo baseURL: URL) throws -> [OniLevelPhysicsObject] {
        let importElement = child(element, "Import")
        let importText = importElement?.attribute(forName: "Path")?.stringValue
            ?? importElement?.attribute(forName: "Url")?.stringValue
            ?? importElement?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedURL: URL? = importText.flatMap { value in
            guard !value.isEmpty else { return nil }
            return value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL
                : baseURL.appendingPathComponent(value).standardizedFileURL
        }
        if let importedURL, !FileManager.default.fileExists(atPath: importedURL.path) {
            throw OniNativeXMLError.invalidDocument("Physics Import does not exist: \(importedURL.path)")
        }
        let sharedGeometryName = text(element, "Geometry")
        guard importedURL != nil || !sharedGeometryName.isEmpty else {
            throw OniNativeXMLError.invalidDocument("Physics Object requires <Geometry> or <Import>")
        }
        guard importedURL == nil || sharedGeometryName.isEmpty else {
            throw OniNativeXMLError.invalidDocument("Physics Object cannot combine <Geometry> and <Import>")
        }
        let position = try vector3(text(element, "Position"), default: [0, 0, 0], field: "Physics Position")
        let rotation = try vector3(text(element, "Rotation"), default: [0, 0, 0], field: "Physics Rotation")
        let scaleText = text(element, "Scale")
        guard scaleText.isEmpty || Float(scaleText) != nil else {
            throw OniNativeXMLError.invalidDocument("Physics Scale requires one number")
        }
        let scale = Float(scaleText) ?? 1
        let orientation = eulerQuaternion(x: rotation.x, y: rotation.y, z: rotation.z)
        let transform = transformMatrix(orientation: orientation, scale: scale, position: position)
        let particles = child(element, "Particles")?.elements(forName: "Particle") ?? []
        let attributeName = element.attribute(forName: "Name")?.stringValue ?? ""
        let explicitName = text(element, "Name")
        let defaultName = importedURL?.deletingPathExtension().lastPathComponent ?? sharedGeometryName
        let name = explicitName.isEmpty ? (attributeName.isEmpty ? defaultName : attributeName) : explicitName
        let geometryNames = if let importedURL {
            try OniWeaponXMLImporter.standaloneGeometryNames(from: importedURL, name: name)
        } else {
            [sharedGeometryName]
        }
        let animationClips = try importElement.map {
            try OniLevelBuilder.animationClips(in: $0, context: "Physics Import")
        } ?? []
        let geometryDetails = try importElement?.elements(forName: "Geometry").map { detail -> (String, Int32) in
            let detailName = detail.attribute(forName: "Name")?.stringValue ?? ""
            guard !detailName.isEmpty else {
                throw OniNativeXMLError.invalidDocument("Physics Import Geometry requires a Name attribute")
            }
            let detailScriptText = text(detail, "ScriptId")
            let detailScriptID = detailScriptText.isEmpty
                ? Int32(0) : try int32(detailScriptText, field: "Physics Geometry ScriptId")
            return (detailName, detailScriptID)
        } ?? []
        let selectedClip = animationClips.first(where: { $0.flags & 0x0008 != 0 }) ?? animationClips.first
        let importedAnimationName = selectedClip.map { $0.prefix + $0.name + $0.suffix } ?? ""
        let declaredPhysicsType = try enumValue32(text(element, "Physics"), names: [
            "None": 0, "Static": 1, "Linear": 2, "Animated": 3, "Newton": 4
        ], field: "Physics type")
        let physicsType = selectedClip.map { $0.flags & 0x0008 != 0 } == true ? UInt32(3) : declaredPhysicsType
        let scriptText = text(element, "ScriptId")
        let scriptID = scriptText.isEmpty ? Int32(-1) : try int32(scriptText, field: "Physics ScriptId")
        let objectFlags = try enumValue32(text(element, "Flags"), names: [
            "InUse": 0x200, "NoCollision": 0x400,
            "NoGravity": 0x800, "FaceCollision": 0x1000
        ], field: "Physics Flags") & ~0x200
        let objectParticles = try particles.map(readParticle)
        if let importedURL {
            let nodes = try importedPhysicsNodes(importedURL, generatedGeometryNames: geometryNames)
            if !nodes.isEmpty {
                return nodes.enumerated().map { index, node in
                    let clips: [OniLevelAnimationClip]
                    if index == 0 {
                        clips = animationClips
                    } else {
                        clips = animationClips.enumerated().map { clipIndex, clip in
                            OniLevelAnimationClip(
                                name: node.name, prefix: "",
                                suffix: clipIndex == 0 ? "" : String(format: "_%02d", clipIndex),
                                start: clip.start, end: clip.end, stop: clip.stop, flags: clip.flags
                            )
                        }
                    }
                    let active = clips.first(where: { $0.flags & 0x0008 != 0 }) ?? clips.first
                    var nodeScriptID = scriptID + Int32(index)
                    for (detailName, detailScriptID) in geometryDetails where node.name.hasSuffix(detailName) {
                        nodeScriptID = detailScriptID
                    }
                    return OniLevelPhysicsObject(
                        name: node.name, fileName: importedURL.lastPathComponent,
                        geometryNames: node.geometryNames, geometrySourceIndices: node.geometrySourceIndices,
                        importedGeometryURL: importedURL,
                        archiveGeometryURL: nil, archiveGeometryRootIndices: nil,
                        archiveGeometryTextureNames: nil,
                        geometryBuildName: name,
                        animationName: active.map { $0.prefix + $0.name + $0.suffix } ?? "",
                        animationClips: clips, animationNodeID: node.id,
                        particles: objectParticles, flags: objectFlags,
                        doorScriptID: 0,
                        physicsType: active.map { $0.flags & 0x0008 != 0 } == true ? 3 : declaredPhysicsType,
                        scriptID: nodeScriptID, position: position,
                        orientation: orientation, scale: scale, transform: transform
                    )
                }
            }
        }
        return [OniLevelPhysicsObject(
            name: name,
            fileName: importedURL?.lastPathComponent ?? URL(fileURLWithPath: sharedGeometryName).lastPathComponent,
            geometryNames: geometryNames,
            geometrySourceIndices: nil,
            importedGeometryURL: importedURL,
            archiveGeometryURL: nil,
            archiveGeometryRootIndices: nil,
            archiveGeometryTextureNames: nil,
            geometryBuildName: name,
            animationName: importedURL == nil ? text(element, "Animation") : importedAnimationName,
            animationClips: animationClips,
            animationNodeID: nil,
            particles: objectParticles,
            flags: objectFlags,
            doorScriptID: 0,
            physicsType: physicsType,
            scriptID: scriptID,
            position: position,
            orientation: orientation,
            scale: scale,
            transform: transform
        )]
    }

    private struct ImportedPhysicsNode {
        let id: String
        let name: String
        let geometryNames: [String]
        let geometrySourceIndices: [Int]
        let ancestorIDs: [String]
    }

    private static func importedPhysicsNodes(
        _ url: URL, generatedGeometryNames: [String]
    ) throws -> [ImportedPhysicsNode] {
        let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
        let geometryElements = try document.nodes(
            forXPath: "//*[local-name()='library_geometries']/*[local-name()='geometry'][*[local-name()='mesh']]"
        ).compactMap { $0 as? XMLElement }
        guard geometryElements.count == generatedGeometryNames.count else { return [] }
        var indicesByID: [String: Int] = [:]
        for (index, element) in geometryElements.enumerated() {
            if let id = element.attribute(forName: "id")?.stringValue { indicesByID[id] = index }
        }
        let sceneNodes = try document.nodes(
            forXPath: "//*[local-name()='visual_scene']//*[local-name()='node']"
        ).compactMap { $0 as? XMLElement }
        var usedNames = Set<String>()
        return sceneNodes.compactMap { node in
            let geometryIndices = (node.children ?? []).compactMap { child -> Int? in
                guard let element = child as? XMLElement,
                      (element.localName ?? element.name) == "instance_geometry",
                      let reference = element.attribute(forName: "url")?.stringValue else { return nil }
                let id = reference.hasPrefix("#") ? String(reference.dropFirst()) : reference
                return indicesByID[id]
            }
            guard !geometryIndices.isEmpty else { return nil }
            let id = node.attribute(forName: "id")?.stringValue ?? node.attribute(forName: "name")?.stringValue ?? ""
            guard !id.isEmpty else { return nil }
            let name = node.attribute(forName: "name")?.stringValue ?? id
            var ancestorIDs: [String] = []
            var ancestor: XMLElement? = node
            while let current = ancestor, (current.localName ?? current.name) == "node" {
                if let ancestorID = current.attribute(forName: "id")?.stringValue {
                    ancestorIDs.append(ancestorID)
                }
                ancestor = current.parent as? XMLElement
            }
            let geometryNames = geometryIndices.enumerated().map { localIndex, _ -> String in
                let stem = localIndex == 0 ? name : name + String(format: "_%02d", localIndex + 1)
                var candidate = stem
                var duplicate = 2
                while !usedNames.insert(candidate.lowercased()).inserted {
                    candidate = stem + String(format: "_%02d", duplicate)
                    duplicate += 1
                }
                return candidate
            }
            return ImportedPhysicsNode(
                id: id, name: name, geometryNames: geometryNames,
                geometrySourceIndices: geometryIndices,
                ancestorIDs: ancestorIDs.reversed()
            )
        }
    }

    private static func matrix(_ element: XMLElement?) throws -> [Float] {
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        guard let element else { return identity }
        let values = floats(element.stringValue ?? "")
        if values.isEmpty { return identity }
        guard values.count == 12 else {
            throw OniNativeXMLError.invalidDocument("Particle Transform requires 12 matrix numbers")
        }
        return values
    }

    private static func enumValue(_ value: String, names: [String: UInt16], field: String) throws -> UInt16 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("None") == .orderedSame { return 0 }
        let first = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? trimmed
        if let number = integer(first), number >= 0, number <= Int(UInt16.max) { return UInt16(number) }
        var result: UInt16 = 0
        let normalizedNames = Dictionary(uniqueKeysWithValues: names.map { ($0.key.lowercased(), $0.value) })
        for token in trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
            let name = token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard let flag = normalizedNames[name.lowercased()] else {
                throw OniNativeXMLError.invalidDocument("unknown \(field) value '\(name)'")
            }
            result |= flag
        }
        return result
    }

    private static func enumValue32(_ value: String, names: [String: UInt32], field: String) throws -> UInt32 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("None") == .orderedSame { return 0 }
        let first = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? trimmed
        if let number = integer(first), number >= 0, UInt64(number) <= UInt64(UInt32.max) { return UInt32(number) }
        var result: UInt32 = 0
        let normalizedNames = Dictionary(uniqueKeysWithValues: names.map { ($0.key.lowercased(), $0.value) })
        for token in trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
            let name = token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard let flag = normalizedNames[name.lowercased()] else {
                throw OniNativeXMLError.invalidDocument("unknown \(field) value '\(name)'")
            }
            result |= flag
        }
        return result
    }

    private static func int16(_ value: String, field: String) throws -> Int16 {
        guard let number = integer(value), number >= Int(Int16.min), number <= Int(Int16.max) else {
            throw OniNativeXMLError.invalidDocument("\(field) requires a signed 16-bit integer")
        }
        return Int16(number)
    }

    private static func int32(_ value: String, field: String) throws -> Int32 {
        guard let number = integer(value), number >= Int(Int32.min), number <= Int(Int32.max) else {
            throw OniNativeXMLError.invalidDocument("\(field) requires a signed 32-bit integer")
        }
        return Int32(number)
    }

    private static func vector3(_ value: String, default defaultValues: [Float], field: String) throws -> OniLevelVector3 {
        let values = value.isEmpty ? defaultValues : floats(value)
        guard values.count == 3 else { throw OniNativeXMLError.invalidDocument("\(field) requires 3 numbers") }
        return OniLevelVector3(x: values[0], y: values[1], z: values[2])
    }

    private static func eulerQuaternion(x: Float, y: Float, z: Float) -> [Float] {
        func axis(_ x: Float, _ y: Float, _ z: Float, degrees: Float) -> [Float] {
            let half = degrees * .pi / 360
            return [x * sin(half), y * sin(half), z * sin(half), cos(half)]
        }
        func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
            [
                a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
                -a[0] * b[2] + a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
                a[0] * b[1] - a[1] * b[0] + a[2] * b[3] + a[3] * b[2],
                -a[0] * b[0] - a[1] * b[1] - a[2] * b[2] + a[3] * b[3]
            ]
        }
        return multiply(multiply(axis(1, 0, 0, degrees: x), axis(0, 1, 0, degrees: y)), axis(0, 0, 1, degrees: z))
    }

    private static func transformMatrix(orientation q: [Float], scale: Float, position: OniLevelVector3) -> [Float] {
        let x = q[0], y = q[1], z = q[2], w = q[3]
        return [
            (1 - 2 * (y * y + z * z)) * scale,
            (2 * (x * y + z * w)) * scale,
            (2 * (z * x - y * w)) * scale,
            (2 * (x * y - z * w)) * scale,
            (1 - 2 * (z * z + x * x)) * scale,
            (2 * (y * z + x * w)) * scale,
            (2 * (z * x + y * w)) * scale,
            (2 * (y * z - x * w)) * scale,
            (1 - 2 * (y * y + x * x)) * scale,
            position.x, position.y, position.z
        ]
    }

    private static func integer(_ value: String) -> Int? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? ""
        if token.lowercased().hasPrefix("0x") { return Int(token.dropFirst(2), radix: 16) }
        return Int(token)
    }

    private static func floats(_ value: String) -> [Float] {
        value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Float($0) }
    }

    private static func child(_ element: XMLElement, _ name: String) -> XMLElement? {
        element.elements(forName: name).first
    }

    private static func text(_ element: XMLElement, _ name: String) -> String {
        child(element, name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

package enum OniLevelPhysicsDependencyBuilder {
    package static func resolveSharedGeometry(
        objects: [OniLevelPhysicsObject], sharedDirectory: URL
    ) throws -> [OniLevelPhysicsObject] {
        let files = try FileManager.default.contentsOfDirectory(
            at: sharedDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let shared = Dictionary(files.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return try objects.map { object in
            guard object.importedGeometryURL == nil, object.archiveGeometryURL == nil else { return object }
            var resolved: [String] = []
            for rawName in object.geometryNames {
                let stem = URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
                let geometryName = normalizedName(stem, tag: "M3GM")
                if shared[("M3GM" + geometryName + ".oni").lowercased()] != nil {
                    resolved.append(geometryName)
                    continue
                }
                let arrayName = normalizedName(stem, tag: "OFGA")
                guard let arrayURL = shared[("OFGA" + arrayName + ".oni").lowercased()] else {
                    resolved.append(geometryName)
                    continue
                }
                let members = try ofgaGeometryNames(in: arrayURL)
                guard !members.isEmpty else {
                    throw OniNativeXMLError.invalidDocument(
                        "shared physics geometry array has no visible M3GM members: \(arrayURL.lastPathComponent)"
                    )
                }
                resolved.append(contentsOf: members)
            }
            return object.replacingGeometryNames(resolved)
        }
    }

    package static func copy(
        objects: [OniLevelPhysicsObject],
        sharedDirectory: URL,
        outputDirectory: URL
    ) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: sharedDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let shared = Dictionary(files.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var requests: [(tag: String, name: String)] = []
        var outputURLs: [URL] = []
        var generatedGeometryNamesByImport: [String: Set<String>] = [:]
        for object in objects {
            if let sourceURL = object.archiveGeometryURL,
               let rootIndices = object.archiveGeometryRootIndices {
                guard rootIndices.count == object.geometryNames.count else {
                    throw OniNativeXMLError.invalidDocument("archived physics geometry metadata is inconsistent")
                }
                let source = try OniDatFile.load(from: sourceURL)
                let textureNames = object.archiveGeometryTextureNames
                    ?? Array(repeating: "", count: rootIndices.count)
                guard textureNames.count == rootIndices.count else {
                    throw OniNativeXMLError.invalidDocument("archived physics texture metadata is inconsistent")
                }
                for index in rootIndices.indices {
                    let rootIndex = rootIndices[index]
                    let rawName = object.geometryNames[index]
                    let name = normalizedName(rawName, tag: "M3GM")
                    let destination = outputDirectory.appendingPathComponent("M3GM\(name).oni")
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        let data = try OniDatUnpacker.standaloneData(
                            from: source, rootIndex: rootIndex, rootName: "M3GM" + name,
                            rootTextureName: textureNames[index]
                        )
                        try data.write(to: destination, options: .atomic)
                    }
                    outputURLs.append(destination)
                    if let textureName = try linkedTextureName(in: destination), !textureName.isEmpty {
                        requests.append(("TXMP", normalizedName(textureName, tag: "TXMP")))
                    }
                }
            } else if let sourceURL = object.importedGeometryURL {
                let importKey = sourceURL.standardizedFileURL.path + "\0" + object.geometryBuildName
                if let generatedNames = generatedGeometryNamesByImport[importKey] {
                    guard Set(object.geometryNames).isSubset(of: generatedNames) else {
                        throw OniNativeXMLError.invalidDocument("imported physics geometry names changed while building \(sourceURL.lastPathComponent)")
                    }
                } else {
                    let matchingObjects = objects.filter {
                        $0.importedGeometryURL?.standardizedFileURL.path == sourceURL.standardizedFileURL.path
                            && $0.geometryBuildName == object.geometryBuildName
                    }
                    var namedSourceIndices: [(index: Int, name: String)] = []
                    var hasSourceIndices = true
                    for matchingObject in matchingObjects {
                        guard let indices = matchingObject.geometrySourceIndices,
                              indices.count == matchingObject.geometryNames.count else {
                            hasSourceIndices = false
                            break
                        }
                        for (index, name) in zip(indices, matchingObject.geometryNames) {
                            namedSourceIndices.append((index, name))
                        }
                    }
                    let archives = if hasSourceIndices {
                        try OniWeaponXMLImporter.buildStandaloneGeometries(
                            from: sourceURL, namedSourceIndices: namedSourceIndices
                        )
                    } else {
                        try OniWeaponXMLImporter.buildStandaloneGeometries(
                            from: sourceURL, name: object.geometryBuildName
                        )
                    }
                    let generatedNames = Set(archives.map {
                        normalizedName($0.fileName, tag: "M3GM").replacingOccurrences(of: ".oni", with: "")
                    })
                    guard Set(object.geometryNames).isSubset(of: generatedNames) else {
                        throw OniNativeXMLError.invalidDocument("imported physics geometry names changed while building \(sourceURL.lastPathComponent)")
                    }
                    generatedGeometryNamesByImport[importKey] = generatedNames
                    for archive in archives {
                        let destination = outputDirectory.appendingPathComponent(archive.fileName)
                        try archive.archiveData.write(to: destination, options: .atomic)
                        outputURLs.append(destination)
                        if let textureName = try linkedTextureName(in: destination), !textureName.isEmpty {
                            requests.append(("TXMP", normalizedName(textureName, tag: "TXMP")))
                        }
                    }
                }
            } else {
                requests += object.geometryNames.map { ("M3GM", normalizedName($0, tag: "M3GM")) }
            }
            if !object.animationName.isEmpty && object.animationClips.isEmpty {
                requests.append(("OBAN", normalizedName(object.animationName, tag: "OBAN")))
            }
        }

        var handled = Set<String>()
        var index = 0
        while index < requests.count {
            let request = requests[index]
            index += 1
            let fileName = request.tag + request.name + ".oni"
            let key = fileName.lowercased()
            guard handled.insert(key).inserted else { continue }
            if request.tag == "TXMP" {
                let existing = try FileManager.default.contentsOfDirectory(
                    at: outputDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).first { $0.lastPathComponent.lowercased() == key }
                if let existing {
                    outputURLs.append(existing)
                    continue
                }
            }
            guard let source = shared[key] else {
                throw OniNativeXMLError.invalidDocument("shared physics dependency was not found: \(fileName)")
            }
            let destination = outputDirectory.appendingPathComponent(source.lastPathComponent)
            if request.tag == "OBAN", FileManager.default.fileExists(atPath: destination.path) {
                outputURLs.append(destination)
                continue
            }
            if request.tag == "M3GM" || request.tag == "OBAN" {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } else if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            outputURLs.append(destination)

            if request.tag == "M3GM", let textureName = try linkedTextureName(in: source), !textureName.isEmpty {
                requests.append(("TXMP", normalizedName(textureName, tag: "TXMP")))
            }
        }
        return outputURLs
    }

    private static func linkedTextureName(in url: URL) throws -> String? {
        let file = try OniDatFile.load(from: url)
        guard let geometry = file.instances.first(where: { $0.templateTag == "M3GM" && $0.descriptorFlags & 2 == 0 }),
              geometry.dataOffset + 32 <= file.data.count else { return nil }
        let value = u32(file.data, geometry.dataOffset + 28)
        guard value & 0xff == 1 else { return nil }
        let index = Int(value >> 8)
        guard file.instances.indices.contains(index), file.instances[index].templateTag == "TXMP" else { return nil }
        return file.instances[index].fullName
    }

    private static func ofgaGeometryNames(in url: URL) throws -> [String] {
        let file = try OniDatFile.load(from: url)
        guard let root = file.instances.first(where: {
            $0.templateTag == "OFGA" && $0.descriptorFlags & 2 == 0
        }), root.dataOffset + 24 <= file.data.count else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) does not contain OFGA geometry")
        }
        let count = Int(u32(file.data, root.dataOffset + 20))
        guard count <= 65_536, root.dataOffset + 24 + count * 12 <= file.data.count else {
            throw OniDatError.outOfBounds("OFGA geometry array")
        }
        var result: [String] = []
        for index in 0..<count {
            let offset = root.dataOffset + 24 + index * 12
            let flags = u32(file.data, offset)
            guard flags & 0x0000_2000 == 0 else { continue }
            let value = u32(file.data, offset + 4)
            let targetIndex = Int(value >> 8)
            guard value & 0xff == 1, file.instances.indices.contains(targetIndex),
                  file.instances[targetIndex].templateTag == "M3GM",
                  !file.instances[targetIndex].fullName.isEmpty else {
                throw OniNativeXMLError.invalidDocument("OFGA geometry has an invalid M3GM reference")
            }
            result.append(normalizedName(file.instances[targetIndex].fullName, tag: "M3GM"))
        }
        return result
    }

    private static func normalizedName(_ name: String, tag: String) -> String {
        name.lowercased().hasPrefix(tag.lowercased()) ? String(name.dropFirst(tag.count)) : name
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
