import Foundation

package struct OniDaeExportResult {
    package let fileCount: Int
    package let outputURLs: [URL]
}

package enum OniDaeExporter {
    private struct Scene {
        let suffix: String
        let meshes: [Mesh]
    }

    private struct Mesh {
        let id: String
        let nodeName: String
        let positions: [OniLevelVector3]
        let normals: [OniLevelVector3]
        let textureCoordinates: [OniLevelVector2]
        let triangles: [Int]
        let textureIndex: Int?
        let translation: OniLevelVector3?
        let rotation: OniLevelVector3?
        let children: [Mesh]
    }

    private struct ResolvedInstance {
        let file: OniDatFile
        let instance: OniDatInstance
    }

    private static let bodyPartNames = [
        "pelvis", "left_thigh", "left_calf", "left_foot", "right_thigh", "right_calf",
        "right_foot", "mid", "chest", "neck", "head", "left_shoulder", "left_biceps",
        "left_wrist", "left_handfist", "right_shoulder", "right_biceps", "right_wrist",
        "right_handfist"
    ]

    // Matches the static character pose used by original OniSplit's -noanim option.
    private static let defaultBodyPose = [
        OniLevelVector3(x: 0, y: 90, z: 90),
        OniLevelVector3(x: 0, y: 180, z: 0), .init(x: 0, y: 0, z: 0), .init(x: 0, y: 0, z: 0),
        OniLevelVector3(x: 0, y: 180, z: 0), .init(x: 0, y: 0, z: 0), .init(x: 0, y: 0, z: 0),
        .init(x: 0, y: 0, z: 0), .init(x: 0, y: 0, z: 0), .init(x: 0, y: 0, z: 0),
        .init(x: 0, y: 0, z: 0), OniLevelVector3(x: 90, y: 90, z: 90),
        .init(x: 0, y: 0, z: 0), .init(x: 0, y: 0, z: 0), OniLevelVector3(x: -90, y: 0, z: 0),
        OniLevelVector3(x: -90, y: -90, z: 90), .init(x: 0, y: 0, z: 0),
        .init(x: 0, y: 0, z: 0), OniLevelVector3(x: 90, y: 0, z: 0)
    ]

    private static let objectTypeNames = [
        "", "char", "patr", "door", "flag", "furn", "", "", "part", "pwru",
        "sndg", "trgv", "weap", "trig", "turr", "cons", "cmbt", "mele", "neut"
    ]

    package static func export(
        file: OniDatFile, to outputDirectory: URL, overwrite: Bool = true, noAnimation: Bool = false
    ) throws -> OniDaeExportResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let roots = file.instances.filter {
            ($0.templateTag == "M3GM" || $0.templateTag == "ONCC" || $0.templateTag == "TRBS" || $0.templateTag == "AKEV") &&
            $0.descriptorFlags & 1 == 0 && $0.descriptorFlags & 2 == 0 && !$0.fullName.isEmpty
        }
        var outputs: [URL] = []
        var usedNames = Set<String>()
        for root in roots {
            do {
                let baseName = uniqueFileName(safeFileName(root.fullName), used: &usedNames)
                let scenes: [Scene]
                if root.templateTag == "M3GM" {
                    scenes = [Scene(suffix: "", meshes: [try readMesh(file, index: root.id, id: "mesh", nodeName: root.fullName)])]
                } else if root.templateTag == "ONCC" {
                    scenes = [Scene(suffix: "", meshes: [try readCharacter(file, index: root.id, noAnimation: noAnimation)])]
                } else if root.templateTag == "TRBS" {
                    scenes = [Scene(suffix: "", meshes: [try readBodySet(
                        file, instance: root, noAnimation: noAnimation, textureIndices: nil, textureOwner: file
                    )])]
                } else {
                    scenes = try readEnvironment(file, index: root.id)
                }
                for scene in scenes where !scene.meshes.isEmpty {
                    let destination = outputDirectory.appendingPathComponent(baseName + scene.suffix).appendingPathExtension("dae")
                    if !overwrite && FileManager.default.fileExists(atPath: destination.path) { continue }
                    let data = try colladaData(file: file, name: root.fullName + scene.suffix, meshes: scene.meshes, outputDirectory: outputDirectory)
                    try data.write(to: destination, options: .atomic)
                    outputs.append(destination)
                }
            } catch let error as OniDatError {
                throw error.withContext("while exporting \(root.fullName)")
            }
        }
        return OniDaeExportResult(fileCount: outputs.count, outputURLs: outputs)
    }

    private struct EnvironmentPolygon {
        let pointIndices: [Int]
        let textureCoordinateIndices: [Int]
        let normal: OniLevelVector3
        let materialIndex: Int
        let flags: UInt32
        let objectID: UInt32
        var scriptID: Int32
    }

    private static func readEnvironment(_ file: OniDatFile, index: Int) throws -> [Scene] {
        let akev = try instance(file, index, tag: "AKEV")
        guard let pointsArray = try link(file, at: akev.dataOffset, expected: "PNTA"),
              let planesArray = try link(file, at: akev.dataOffset + 4, expected: "PLEA"),
              let texCoordsArray = try link(file, at: akev.dataOffset + 8, expected: "TXCA"),
              let polygonArray = try link(file, at: akev.dataOffset + 12, expected: "AGQG"),
              let materialArray = try link(file, at: akev.dataOffset + 16, expected: "AGQR"),
              let collisionArray = try link(file, at: akev.dataOffset + 20, expected: "AGQC"),
              let textureMap = try link(file, at: akev.dataOffset + 28, expected: "TXMA") else {
            throw OniDatError.invalidHeader("\(akev.fullName) has incomplete environment geometry")
        }
        let points = try vector3Array(file, pointsArray, countOffset: 52)
        let textureCoordinates = try vector2Array(file, texCoordsArray, countOffset: 20)
        let planeCount = Int(try u32(file.data, planesArray.dataOffset + 20))
        let planes = try (0..<planeCount).map { plane -> OniLevelVector3 in
            try vector3(file.data, planesArray.dataOffset + 24 + plane * 16)
        }
        let polygonCount = Int(try u32(file.data, polygonArray.dataOffset + 20))
        guard Int(try u32(file.data, materialArray.dataOffset + 20)) >= polygonCount,
              Int(try u32(file.data, collisionArray.dataOffset + 20)) >= polygonCount else {
            throw OniDatError.invalidHeader("\(akev.fullName) has mismatched environment polygon arrays")
        }
        var polygons: [EnvironmentPolygon] = []
        polygons.reserveCapacity(polygonCount)
        for polygon in 0..<polygonCount {
            let geometryOffset = polygonArray.dataOffset + 24 + polygon * 56
            let flags = try u32(file.data, geometryOffset + 48)
            let vertexCount = flags & 0x40 == 0 ? 4 : 3
            let pointIndices = try (0..<vertexCount).map { Int(try u32(file.data, geometryOffset + $0 * 4)) }
            let texCoordIndices = try (0..<vertexCount).map { Int(try u32(file.data, geometryOffset + 16 + $0 * 4)) }
            let encodedPlane = try u32(file.data, collisionArray.dataOffset + 24 + polygon * 28)
            let planeIndex = Int(encodedPlane & 0x7fff_ffff)
            guard planeIndex < planes.count,
                  pointIndices.allSatisfy(points.indices.contains),
                  texCoordIndices.allSatisfy(textureCoordinates.indices.contains) else {
                throw OniDatError.outOfBounds("environment polygon \(polygon)")
            }
            let plane = planes[planeIndex]
            let normal = encodedPlane & 0x8000_0000 == 0 ? plane : OniLevelVector3(x: -plane.x, y: -plane.y, z: -plane.z)
            polygons.append(EnvironmentPolygon(
                pointIndices: pointIndices, textureCoordinateIndices: texCoordIndices, normal: normal,
                materialIndex: Int(try u32(file.data, materialArray.dataOffset + 24 + polygon * 4) & 0xffff),
                flags: flags, objectID: try u32(file.data, geometryOffset + 52), scriptID: 0
            ))
        }
        if let scriptPolygons = try link(file, at: akev.dataOffset + 40, expected: "IDXA"),
           let scriptIDs = try link(file, at: akev.dataOffset + 44, expected: "IDXA") {
            let polygonIndices = try int32Array(file, scriptPolygons, countOffset: 20)
            let identifiers = try int32Array(file, scriptIDs, countOffset: 20)
            for pair in zip(polygonIndices, identifiers) where polygons.indices.contains(Int(pair.0)) {
                polygons[Int(pair.0)].scriptID = pair.1
            }
        }
        let textureCount = Int(try u32(file.data, textureMap.dataOffset + 20))
        let textures = try (0..<textureCount).map { try linkIndex(file, at: textureMap.dataOffset + 24 + $0 * 4) }

        enum Category: Hashable {
            case environment, markers, object(String), script(Int32)
        }
        var categories: [Category: [EnvironmentPolygon]] = [:]
        for polygon in polygons {
            // Adjacency polygons belong to the BNV/room export, not the visible environment.
            if polygon.flags & 0x0e != 0 { continue }
            let materialName: String = {
                guard textures.indices.contains(polygon.materialIndex), let texture = textures[polygon.materialIndex] else { return "" }
                return file.instances[texture].displayName.lowercased()
            }()
            let category: Category
            if polygon.scriptID != 0 {
                category = .script(polygon.scriptID)
            } else if polygon.objectID != .max {
                let objectType = Int((polygon.objectID >> 24) & 0xff)
                let typeName = objectTypeNames.indices.contains(objectType) && !objectTypeNames[objectType].isEmpty
                    ? objectTypeNames[objectType] : "object_\(objectType)"
                category = .object(typeName)
            } else if materialName.hasPrefix("_marker_") {
                category = .markers
            } else {
                category = .environment
            }
            categories[category, default: []].append(polygon)
        }

        func scene(_ category: Category, suffix: String) -> Scene? {
            guard let values = categories[category], !values.isEmpty else { return nil }
            return Scene(suffix: suffix, meshes: environmentMeshes(
                values, points: points, textureCoordinates: textureCoordinates, textures: textures, idPrefix: xmlID(suffix.isEmpty ? "env" : suffix)
            ))
        }
        var scenes: [Scene] = []
        if let value = scene(.environment, suffix: "_env") { scenes.append(value) }
        if let value = scene(.markers, suffix: "_env_markers") { scenes.append(value) }
        let objectNames = Set(categories.keys.compactMap { if case .object(let name) = $0 { name } else { nil } }).sorted()
        for name in objectNames { if let value = scene(.object(name), suffix: "_\(name)") { scenes.append(value) } }
        let scriptIDs = Set(categories.keys.compactMap { if case .script(let id) = $0 { id } else { nil } }).sorted()
        for id in scriptIDs { if let value = scene(.script(id), suffix: "_script_\(id)") { scenes.append(value) } }
        return scenes
    }

    private static func environmentMeshes(
        _ polygons: [EnvironmentPolygon], points: [OniLevelVector3], textureCoordinates: [OniLevelVector2],
        textures: [Int?], idPrefix: String
    ) -> [Mesh] {
        Dictionary(grouping: polygons, by: \.materialIndex).sorted { $0.key < $1.key }.enumerated().map { meshNumber, entry in
            var positions: [OniLevelVector3] = [], normals: [OniLevelVector3] = [], texCoords: [OniLevelVector2] = [], triangles: [Int] = []
            for polygon in entry.value {
                let base = positions.count
                positions += polygon.pointIndices.map { points[$0] }
                normals += Array(repeating: polygon.normal, count: polygon.pointIndices.count)
                texCoords += polygon.textureCoordinateIndices.map { textureCoordinates[$0] }
                triangles += [base, base + 1, base + 2]
                if polygon.pointIndices.count == 4 { triangles += [base, base + 2, base + 3] }
            }
            return Mesh(
                id: "\(idPrefix)_mesh_\(meshNumber)", nodeName: "material_\(entry.key)", positions: positions,
                normals: normals, textureCoordinates: texCoords, triangles: triangles,
                textureIndex: textures.indices.contains(entry.key) ? textures[entry.key] : nil,
                translation: nil, rotation: nil, children: []
            )
        }
    }

    private static func readCharacter(_ file: OniDatFile, index: Int, noAnimation: Bool) throws -> Mesh {
        let oncc = try instance(file, index, tag: "ONCC")
        let bodySet = try resolvedLink(file, at: oncc.dataOffset + 0xC34, expected: "TRBS")
        guard let bodySet else { throw OniDatError.invalidHeader("\(oncc.fullName) has no body set") }
        let textureIndices: [Int?]?
        if let textureArray = try link(file, at: oncc.dataOffset + 0xC38, expected: "TRMA"), textureArray.dataSize >= 24 {
            let textureCount = Int(try u16(file.data, textureArray.dataOffset + 22))
            textureIndices = try (0..<textureCount).map {
                try linkIndex(file, at: textureArray.dataOffset + 24 + $0 * 4)
            }
        } else {
            textureIndices = nil
        }
        return try readBodySet(
            bodySet.file, instance: bodySet.instance, noAnimation: noAnimation,
            textureIndices: textureIndices, textureOwner: file
        )
    }

    private static func readBodySet(
        _ file: OniDatFile, instance bodySet: OniDatInstance, noAnimation: Bool,
        textureIndices: [Int?]?, textureOwner: OniDatFile
    ) throws -> Mesh {
        let bodies = try (0..<5).compactMap { try resolvedLink(file, at: bodySet.dataOffset + $0 * 4, expected: "TRCM") }
        guard let body = bodies.last else { throw OniDatError.invalidHeader("\(bodySet.fullName) has an empty body set") }
        return try readBody(
            body, noAnimation: noAnimation, textureIndices: textureIndices, textureOwner: textureOwner
        )
    }

    private static func readBody(
        _ body: ResolvedInstance, noAnimation: Bool, textureIndices: [Int?]?, textureOwner: OniDatFile
    ) throws -> Mesh {
        let file = body.file
        let trcm = body.instance
        guard let geometryArray = try resolvedLink(file, at: trcm.dataOffset + 84, expected: "TRGA"),
              let translationArray = try resolvedLink(file, at: trcm.dataOffset + 88, expected: "TRTA"),
              let hierarchyArray = try resolvedLink(file, at: trcm.dataOffset + 92, expected: "TRIA") else {
            throw OniDatError.invalidHeader("\(trcm.fullName) has an incomplete body graph")
        }
        let count = Int(try u16(geometryArray.file.data, geometryArray.instance.dataOffset + 22))
        guard count > 0, count <= bodyPartNames.count,
              Int(try u16(translationArray.file.data, translationArray.instance.dataOffset + 22)) >= count,
              Int(try u16(hierarchyArray.file.data, hierarchyArray.instance.dataOffset + 22)) >= count else {
            throw OniDatError.invalidHeader("\(trcm.fullName) has invalid body arrays")
        }
        let geometries = try (0..<count).map { part -> ResolvedInstance in
            guard let value = try resolvedLink(
                geometryArray.file, at: geometryArray.instance.dataOffset + 24 + part * 4, expected: "M3GM"
            ) else {
                throw OniDatError.invalidHeader("\(trcm.fullName) has a missing body geometry")
            }
            return value
        }
        let translations = try (0..<count).map {
            try vector3(translationArray.file.data, translationArray.instance.dataOffset + 24 + $0 * 12)
        }
        let firstChildren = (0..<count).map {
            Int(hierarchyArray.file.data[hierarchyArray.instance.dataOffset + 24 + $0 * 4 + 1])
        }
        let siblings = (0..<count).map {
            Int(hierarchyArray.file.data[hierarchyArray.instance.dataOffset + 24 + $0 * 4 + 2])
        }

        func build(_ part: Int, ancestry: Set<Int>) throws -> Mesh {
            guard part >= 0, part < count, !ancestry.contains(part) else {
                throw OniDatError.invalidHeader("\(trcm.fullName) has an invalid body hierarchy")
            }
            var children: [Mesh] = []
            var child = firstChildren[part]
            var seen = Set<Int>()
            while child != 0 {
                guard child < count, seen.insert(child).inserted else {
                    throw OniDatError.invalidHeader("\(trcm.fullName) has an invalid child chain")
                }
                children.append(try build(child, ancestry: ancestry.union([part])))
                child = siblings[child]
            }
            let name = bodyPartNames[part]
            let source = try readMesh(geometries[part], id: "mesh_\(part)", nodeName: name)
            let characterTexture = textureIndices.flatMap { $0.indices.contains(part) ? $0[part] : nil } ?? nil
            let geometryTexture = geometries[part].file.url.standardizedFileURL == textureOwner.url.standardizedFileURL
                ? source.textureIndex : nil
            return Mesh(
                id: source.id, nodeName: source.nodeName, positions: source.positions, normals: source.normals,
                textureCoordinates: source.textureCoordinates, triangles: source.triangles,
                textureIndex: characterTexture ?? geometryTexture, translation: translations[part],
                rotation: noAnimation ? defaultBodyPose[part] : nil, children: children
            )
        }
        return try build(0, ancestry: [])
    }

    private static func readMesh(_ file: OniDatFile, index: Int, id: String, nodeName: String) throws -> Mesh {
        try readMesh(.init(file: file, instance: try instance(file, index, tag: "M3GM")), id: id, nodeName: nodeName)
    }

    private static func readMesh(_ source: ResolvedInstance, id: String, nodeName: String) throws -> Mesh {
        let file = source.file
        let m3gm = source.instance
        guard let points = try resolvedLink(file, at: m3gm.dataOffset + 4, expected: "PNTA"),
              let vertexNormals = try resolvedLink(file, at: m3gm.dataOffset + 8, expected: "VCRA"),
              let faceNormals = try resolvedLink(file, at: m3gm.dataOffset + 12, expected: "VCRA"),
              let textureCoordinates = try resolvedLink(file, at: m3gm.dataOffset + 16, expected: "TXCA"),
              let strips = try resolvedLink(file, at: m3gm.dataOffset + 20, expected: "IDXA"),
              let faceNormalIndices = try resolvedLink(file, at: m3gm.dataOffset + 24, expected: "IDXA") else {
            throw OniDatError.invalidHeader("\(m3gm.fullName) has incomplete geometry arrays")
        }
        let positionValues = try vector3Array(points.file, points.instance, countOffset: 52)
        let normalValues = try vector3Array(vertexNormals.file, vertexNormals.instance, countOffset: 20)
        let faceNormalValues = try vector3Array(faceNormals.file, faceNormals.instance, countOffset: 20)
        let texCoordValues = try vector2Array(textureCoordinates.file, textureCoordinates.instance, countOffset: 20)
        let stripValues = try int32Array(strips.file, strips.instance, countOffset: 20)
        let faceValues = try int32Array(faceNormalIndices.file, faceNormalIndices.instance, countOffset: 20)
        let triangles = try triangleList(points: positionValues, strips: stripValues, faceNormals: faceNormalValues, faceIndices: faceValues)
        guard triangles.allSatisfy({ $0 >= 0 && $0 < positionValues.count && $0 < normalValues.count && $0 < texCoordValues.count }) else {
            throw OniDatError.outOfBounds("triangle vertex in \(m3gm.fullName)")
        }
        let textureIndex = try linkIndex(file, at: m3gm.dataOffset + 28)
        return Mesh(
            id: id, nodeName: nodeName, positions: positionValues, normals: normalValues,
            textureCoordinates: texCoordValues, triangles: triangles, textureIndex: textureIndex,
            translation: nil, rotation: nil, children: []
        )
    }

    private static func triangleList(
        points: [OniLevelVector3], strips: [Int32], faceNormals: [OniLevelVector3], faceIndices: [Int32]
    ) throws -> [Int] {
        var result: [Int] = []
        var face = [0, 0, 0]
        var faceIndex = 0
        var order = 0
        var index = 0
        while index < strips.count {
            let value = strips[index]
            if value < 0 {
                guard index + 1 < strips.count else { throw OniDatError.invalidHeader("truncated triangle strip") }
                face[0] = Int(UInt32(bitPattern: value) & 0x7fff_ffff)
                index += 1
                face[1] = Int(strips[index])
                index += 1
                order = 0
            } else {
                face[order] = face[2]
                order ^= 1
            }
            guard index < strips.count else { throw OniDatError.invalidHeader("truncated triangle strip") }
            face[2] = Int(strips[index])
            guard face.allSatisfy({ points.indices.contains($0) }), faceIndex < faceIndices.count,
                  faceNormals.indices.contains(Int(faceIndices[faceIndex])) else {
                throw OniDatError.outOfBounds("triangle strip geometry")
            }
            let a = points[face[0]], b = points[face[1]], c = points[face[2]]
            let geometric = normalized(cross(subtract(b, a), subtract(c, a)))
            let declared = normalized(faceNormals[Int(faceIndices[faceIndex])])
            result += dot(declared, geometric) < 0 ? [face[2], face[1], face[0]] : [face[0], face[1], face[2]]
            faceIndex += 1
            index += 1
        }
        return result
    }

    private static func colladaData(file: OniDatFile, name: String, meshes: [Mesh], outputDirectory: URL) throws -> Data {
        let document = XMLDocument()
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        let root = XMLElement(name: "COLLADA")
        root.addAttribute(attribute("xmlns", "http://www.collada.org/2005/11/COLLADASchema"))
        root.addAttribute(attribute("version", "1.4.1"))
        document.setRootElement(root)
        let asset = XMLElement(name: "asset")
        let unit = XMLElement(name: "unit")
        unit.addAttribute(attribute("name", "decimeter")); unit.addAttribute(attribute("meter", "0.1"))
        asset.addChild(unit); asset.addChild(element("up_axis", "Y_UP")); root.addChild(asset)

        let flatMeshes = flatten(meshes)
        let textureIndices = Set(flatMeshes.compactMap(\.textureIndex)).filter { file.instances.indices.contains($0) && file.instances[$0].templateTag == "TXMP" }
        var textureIDs: [Int: String] = [:]
        if !textureIndices.isEmpty {
            let images = XMLElement(name: "library_images"), effects = XMLElement(name: "library_effects"), materials = XMLElement(name: "library_materials")
            let imagesDirectory = outputDirectory.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            for textureIndex in textureIndices.sorted() {
                let texture = file.instances[textureIndex]
                guard let (textureFile, textureInstance) = try resolvedTexture(file: file, instance: texture),
                      let preview = textureFile.texturePreview(for: textureInstance), let rgba = preview.rgba else {
                    continue
                }
                let id = xmlID(texture.displayName.isEmpty ? "texture_\(textureIndex)" : texture.displayName)
                textureIDs[textureIndex] = id
                let fileName = safeFileName(texture.displayName.isEmpty ? "texture_\(textureIndex)" : texture.displayName) + ".tga"
                try tgaData(width: preview.info.width, height: preview.info.height, rgba: rgba).write(
                    to: imagesDirectory.appendingPathComponent(fileName), options: .atomic
                )
                let image = XMLElement(name: "image"); image.addAttribute(attribute("id", "\(id)-image")); image.addAttribute(attribute("name", id))
                image.addChild(element("init_from", "./images/\(fileName)")); images.addChild(image)
                let effect = XMLElement(name: "effect"); effect.addAttribute(attribute("id", "\(id)-effect"))
                let profile = XMLElement(name: "profile_COMMON")
                let surface = XMLElement(name: "newparam"); surface.addAttribute(attribute("sid", "surface"))
                let surfaceValue = XMLElement(name: "surface"); surfaceValue.addAttribute(attribute("type", "2D")); surfaceValue.addChild(element("init_from", "\(id)-image")); surface.addChild(surfaceValue)
                let sampler = XMLElement(name: "newparam"); sampler.addAttribute(attribute("sid", "sampler")); let samplerValue = XMLElement(name: "sampler2D"); samplerValue.addChild(element("source", "surface")); sampler.addChild(samplerValue)
                let technique = XMLElement(name: "technique"); technique.addAttribute(attribute("sid", "common")); let phong = XMLElement(name: "phong"), diffuse = XMLElement(name: "diffuse"), textureNode = XMLElement(name: "texture")
                textureNode.addAttribute(attribute("texture", "sampler")); textureNode.addAttribute(attribute("texcoord", "diffuse_TEXCOORD")); diffuse.addChild(textureNode); phong.addChild(diffuse); technique.addChild(phong)
                profile.addChild(surface); profile.addChild(sampler); profile.addChild(technique); effect.addChild(profile); effects.addChild(effect)
                let material = XMLElement(name: "material"); material.addAttribute(attribute("id", "\(id)-material")); material.addAttribute(attribute("name", id)); let instanceEffect = XMLElement(name: "instance_effect"); instanceEffect.addAttribute(attribute("url", "#\(id)-effect")); material.addChild(instanceEffect); materials.addChild(material)
            }
            root.addChild(images); root.addChild(effects); root.addChild(materials)
        }

        let geometries = XMLElement(name: "library_geometries")
        for mesh in flatMeshes { geometries.addChild(geometryElement(mesh)) }
        root.addChild(geometries)
        let scenes = XMLElement(name: "library_visual_scenes"), visualScene = XMLElement(name: "visual_scene")
        visualScene.addAttribute(attribute("id", "scene")); visualScene.addAttribute(attribute("name", name))
        for mesh in meshes { visualScene.addChild(nodeElement(mesh, textureIDs: textureIDs)) }
        scenes.addChild(visualScene); root.addChild(scenes)
        let scene = XMLElement(name: "scene"), instanceScene = XMLElement(name: "instance_visual_scene")
        instanceScene.addAttribute(attribute("url", "#scene")); scene.addChild(instanceScene); root.addChild(scene)
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func geometryElement(_ meshValue: Mesh) -> XMLElement {
        let geometry = XMLElement(name: "geometry"); geometry.addAttribute(attribute("id", meshValue.id)); geometry.addAttribute(attribute("name", meshValue.nodeName))
        let mesh = XMLElement(name: "mesh")
        mesh.addChild(sourceElement(id: "\(meshValue.id)-positions", values: meshValue.positions.flatMap { [$0.x, $0.y, $0.z] }, stride: 3, names: ["X", "Y", "Z"]))
        mesh.addChild(sourceElement(id: "\(meshValue.id)-normals", values: meshValue.normals.flatMap { [$0.x, $0.y, $0.z] }, stride: 3, names: ["X", "Y", "Z"]))
        mesh.addChild(sourceElement(id: "\(meshValue.id)-texcoords", values: meshValue.textureCoordinates.flatMap { [$0.x, 1 - $0.y] }, stride: 2, names: ["S", "T"]))
        let vertices = XMLElement(name: "vertices"); vertices.addAttribute(attribute("id", "\(meshValue.id)-vertices")); let vertexInput = XMLElement(name: "input"); vertexInput.addAttribute(attribute("semantic", "POSITION")); vertexInput.addAttribute(attribute("source", "#\(meshValue.id)-positions")); vertices.addChild(vertexInput); mesh.addChild(vertices)
        let triangles = XMLElement(name: "triangles"); triangles.addAttribute(attribute("count", String(meshValue.triangles.count / 3))); triangles.addAttribute(attribute("material", "default"))
        for (semantic, source, offset, set) in [("VERTEX", "#\(meshValue.id)-vertices", "0", nil), ("NORMAL", "#\(meshValue.id)-normals", "1", nil), ("TEXCOORD", "#\(meshValue.id)-texcoords", "2", "0")] {
            let input = XMLElement(name: "input"); input.addAttribute(attribute("semantic", semantic)); input.addAttribute(attribute("source", source)); input.addAttribute(attribute("offset", offset)); if let set { input.addAttribute(attribute("set", set)) }; triangles.addChild(input)
        }
        triangles.addChild(element("p", meshValue.triangles.flatMap { [$0, $0, $0] }.map(String.init).joined(separator: " ")))
        mesh.addChild(triangles); geometry.addChild(mesh); return geometry
    }

    private static func sourceElement(id: String, values: [Float], stride: Int, names: [String]) -> XMLElement {
        let source = XMLElement(name: "source"); source.addAttribute(attribute("id", id)); let array = element("float_array", values.map(format).joined(separator: " ")); array.addAttribute(attribute("id", "\(id)-array")); array.addAttribute(attribute("count", String(values.count))); source.addChild(array)
        let common = XMLElement(name: "technique_common"), accessor = XMLElement(name: "accessor"); accessor.addAttribute(attribute("source", "#\(id)-array")); accessor.addAttribute(attribute("count", String(values.count / stride))); accessor.addAttribute(attribute("stride", String(stride)))
        for name in names { let parameter = XMLElement(name: "param"); parameter.addAttribute(attribute("name", name)); parameter.addAttribute(attribute("type", "float")); accessor.addChild(parameter) }
        common.addChild(accessor); source.addChild(common); return source
    }

    private static func nodeElement(_ mesh: Mesh, textureIDs: [Int: String]) -> XMLElement {
        let node = XMLElement(name: "node"); node.addAttribute(attribute("id", xmlID(mesh.nodeName))); node.addAttribute(attribute("name", mesh.nodeName))
        if let value = mesh.translation { node.addChild(element("translate", "\(format(value.x)) \(format(value.y)) \(format(value.z))")) }
        if let value = mesh.rotation {
            for (sid, axis, angle) in [("rotX", "1 0 0", value.x), ("rotY", "0 1 0", value.y), ("rotZ", "0 0 1", value.z)] {
                let rotate = element("rotate", "\(axis) \(format(angle))")
                rotate.addAttribute(attribute("sid", sid))
                node.addChild(rotate)
            }
        }
        let instance = XMLElement(name: "instance_geometry"); instance.addAttribute(attribute("url", "#\(mesh.id)"))
        if let textureIndex = mesh.textureIndex, let textureID = textureIDs[textureIndex] {
            let bind = XMLElement(name: "bind_material"), common = XMLElement(name: "technique_common"), material = XMLElement(name: "instance_material")
            material.addAttribute(attribute("symbol", "default")); material.addAttribute(attribute("target", "#\(textureID)-material")); common.addChild(material); bind.addChild(common); instance.addChild(bind)
        }
        node.addChild(instance); for child in mesh.children { node.addChild(nodeElement(child, textureIDs: textureIDs)) }; return node
    }

    private static func flatten(_ meshes: [Mesh]) -> [Mesh] { meshes.flatMap { [$0] + flatten($0.children) } }
    private static func resolvedTexture(file: OniDatFile, instance: OniDatInstance) throws -> (OniDatFile, OniDatInstance)? {
        if instance.dataSize >= 156 { return (file, instance) }
        let expected = (instance.fullName.isEmpty ? "TXMP" + instance.displayName : instance.fullName).lowercased()
        let directory = file.url.deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "oni" && $0.deletingPathExtension().lastPathComponent.lowercased() == expected }
        guard let candidate = candidates.first else { return nil }
        let textureFile = try OniDatFile.load(from: candidate)
        guard let texture = textureFile.instances.first(where: {
            $0.templateTag == "TXMP" && $0.descriptorFlags & 2 == 0 && $0.dataSize >= 156
        }) else { return nil }
        return (textureFile, texture)
    }
    private static func instance(_ file: OniDatFile, _ index: Int, tag: String) throws -> OniDatInstance {
        guard file.instances.indices.contains(index), file.instances[index].templateTag == tag else { throw OniDatError.outOfBounds("\(tag) instance") }
        return file.instances[index]
    }
    private static func link(_ file: OniDatFile, at offset: Int, expected: String) throws -> OniDatInstance? {
        guard let index = try linkIndex(file, at: offset) else { return nil }
        return try instance(file, index, tag: expected)
    }
    private static func resolvedLink(_ file: OniDatFile, at offset: Int, expected: String) throws -> ResolvedInstance? {
        guard let linked = try link(file, at: offset, expected: expected) else { return nil }
        if linked.dataSize > 0 { return .init(file: file, instance: linked) }
        let expectedName = linked.fullName.lowercased()
        let directory = file.url.deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension.lowercased() == "oni" &&
            $0.deletingPathExtension().lastPathComponent.lowercased() == expectedName
        }
        guard let candidate = candidates.first else {
            throw OniDatError.invalidHeader("referenced \(expected) file was not found: \(linked.fullName).oni")
        }
        let external = try OniDatFile.load(from: candidate)
        guard let concrete = external.instances.first(where: {
            $0.templateTag == expected && $0.descriptorFlags & 2 == 0 && $0.dataSize > 0 &&
            ($0.fullName.lowercased() == expectedName || $0.displayName.lowercased() == linked.displayName.lowercased())
        }) else {
            throw OniDatError.invalidHeader("\(candidate.lastPathComponent) does not contain \(linked.fullName)")
        }
        return .init(file: external, instance: concrete)
    }
    private static func linkIndex(_ file: OniDatFile, at offset: Int) throws -> Int? {
        let value = try u32(file.data, offset); if value == 0 { return nil }; let index = Int(value >> 8)
        guard file.instances.indices.contains(index) else { throw OniDatError.outOfBounds("instance link") }; return index
    }
    private static func vector3Array(_ file: OniDatFile, _ instance: OniDatInstance, countOffset: Int) throws -> [OniLevelVector3] {
        let count = Int(try u32(file.data, instance.dataOffset + countOffset)); return try (0..<count).map { try vector3(file.data, instance.dataOffset + countOffset + 4 + $0 * 12) }
    }
    private static func vector2Array(_ file: OniDatFile, _ instance: OniDatInstance, countOffset: Int) throws -> [OniLevelVector2] {
        let count = Int(try u32(file.data, instance.dataOffset + countOffset)); return try (0..<count).map { let at = instance.dataOffset + countOffset + 4 + $0 * 8; return OniLevelVector2(x: try f32(file.data, at), y: try f32(file.data, at + 4)) }
    }
    private static func int32Array(_ file: OniDatFile, _ instance: OniDatInstance, countOffset: Int) throws -> [Int32] {
        let count = Int(try u32(file.data, instance.dataOffset + countOffset)); return try (0..<count).map { Int32(bitPattern: try u32(file.data, instance.dataOffset + countOffset + 4 + $0 * 4)) }
    }
    private static func vector3(_ data: Data, _ offset: Int) throws -> OniLevelVector3 { OniLevelVector3(x: try f32(data, offset), y: try f32(data, offset + 4), z: try f32(data, offset + 8)) }
    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 { try BinaryReader(data: data).u16(at: offset) }
    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 { try BinaryReader(data: data).u32(at: offset) }
    private static func f32(_ data: Data, _ offset: Int) throws -> Float { Float(bitPattern: try u32(data, offset)) }
    private static func subtract(_ a: OniLevelVector3, _ b: OniLevelVector3) -> OniLevelVector3 { .init(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func cross(_ a: OniLevelVector3, _ b: OniLevelVector3) -> OniLevelVector3 { .init(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
    private static func dot(_ a: OniLevelVector3, _ b: OniLevelVector3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func normalized(_ value: OniLevelVector3) -> OniLevelVector3 { let length = sqrt(dot(value, value)); return length > 0 ? .init(x: value.x / length, y: value.y / length, z: value.z / length) : value }
    private static func attribute(_ name: String, _ value: String) -> XMLNode { XMLNode.attribute(withName: name, stringValue: value) as! XMLNode }
    private static func element(_ name: String, _ text: String) -> XMLElement { let value = XMLElement(name: name); value.stringValue = text; return value }
    private static func format(_ value: Float) -> String { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    private static func xmlID(_ value: String) -> String { let clean = value.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }; return clean.first?.isNumber == true ? "_" + String(clean) : String(clean) }
    private static func safeFileName(_ value: String) -> String { value.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "_") }
    private static func uniqueFileName(_ value: String, used: inout Set<String>) -> String { var result = value, suffix = 2; while !used.insert(result.lowercased()).inserted { result = "\(value)_\(suffix)"; suffix += 1 }; return result }
    private static func tgaData(width: Int, height: Int, rgba: Data) -> Data { var result = Data(repeating: 0, count: 18); result[2] = 2; result[12] = UInt8(width & 0xff); result[13] = UInt8((width >> 8) & 0xff); result[14] = UInt8(height & 0xff); result[15] = UInt8((height >> 8) & 0xff); result[16] = 32; result[17] = 0x28; for pixel in stride(from: 0, to: rgba.count, by: 4) { result.append(rgba[pixel + 2]); result.append(rgba[pixel + 1]); result.append(rgba[pixel]); result.append(rgba[pixel + 3]) }; return result }
}
