import Foundation

package struct OniGunkGeometryBuildResult {
    package let documents: [OniColladaGeometryDocument]
    package let furnitureCount: Int
    package let consoleCount: Int
    package let triggerCount: Int
    package let turretCount: Int
    package let geometryPartCount: Int
    package let polygonCount: Int
    package let textureNames: [String]
    package let doorPhysicsObjects: [OniLevelPhysicsObject]
    package let furnitureParticles: [OniLevelEnvironmentParticle]
}

package enum OniGunkGeometryBuilder {
    private static let furnitureFlags: UInt32 = 0x0001_0000 | 0x0100_0000
    private static let supportedObjectNames: Set<String> = [
        "CHAR", "Character", "CONS", "Console", "DOOR", "Door", "FLAG", "Flag",
        "FURN", "Furniture", "NEUT", "Neutral", "PART", "Particle", "PATR", "Patrol",
        "PWRU", "PowerUp", "SNDG", "Sound", "TRIG", "Trigger", "TRGV", "TriggerVolume",
        "TURR", "Turret", "WEAP", "Weapon"
    ]

    private struct Placement {
        let objectID: Int
        let className: String
        let position: OniLevelVector3
        let rotation: OniLevelVector3
        let particleTag: String
    }

    private struct DoorPlacement {
        let objectID: Int
        let scriptID: Int32
        let flags: UInt16
        let className: String
        let position: OniLevelVector3
        let rotation: OniLevelVector3
        let textures: [String]
    }

    private struct ConsolePlacement {
        let objectID: Int
        let className: String
        let position: OniLevelVector3
        let rotation: OniLevelVector3
    }

    private struct GenericPlacement {
        let objectID: Int
        let className: String
        let position: OniLevelVector3
        let rotation: OniLevelVector3
    }

    private struct DoorClass {
        let url: URL
        let file: OniDatFile
        let nodes: [(flags: UInt32, rootIndex: Int)]
        let animationScale: OniLevelVector3
    }

    private struct Mesh {
        let name: String
        let points: [OniLevelVector3]
        let normals: [OniLevelVector3]
        let textureCoordinates: [OniLevelVector2]
        let triangles: [[Int]]
        let textureName: String
        let transparent: Bool
    }

    package static func build(from definition: OniLevelDefinition) throws -> OniGunkGeometryBuildResult {
        let sharedFiles = try sharedFileMap(definition.sharedDirectory)
        let placements = try readFurniturePlacements(definition.objectFiles, sharedFiles: sharedFiles)
        let doorPlacements = try readDoorPlacements(definition.objectFiles)
        let consolePlacements = try readConsolePlacements(definition.objectFiles)
        let triggerPlacements = try readGenericPlacements(
            definition.objectFiles, names: Set(["TRIG", "Trigger"]), templateTag: "TRIG"
        )
        let turretPlacements = try readGenericPlacements(
            definition.objectFiles, names: Set(["TURR", "Turret"]), templateTag: "TURR"
        )
        var documents: [OniColladaGeometryDocument] = []
        var partCount = 0
        var polygonCount = 0
        var textureNames: [String] = []
        var knownTextureNames = Set<String>()
        var doorPhysicsObjects: [OniLevelPhysicsObject] = []
        var furnitureParticles: [OniLevelEnvironmentParticle] = []

        for placement in placements {
            guard let ofgaURL = sharedFiles["ofga\(placement.className).oni".lowercased()] else {
                throw OniNativeXMLError.invalidDocument("furniture class OFGA\(placement.className).oni was not found in SharedPath")
            }
            let nodes: [(flags: UInt32, name: String)]
            do { nodes = try readOFGA(ofgaURL) }
            catch { throw OniNativeXMLError.invalidDocument("could not read \(ofgaURL.lastPathComponent): \(error.localizedDescription)") }
            var instances: [OniColladaGeometryInstance] = []
            var transparentNames = Set<String>()
            for (nodeIndex, node) in nodes.enumerated() {
                guard let m3gmURL = sharedFiles["\(node.name).oni".lowercased()] else {
                    throw OniNativeXMLError.invalidDocument("furniture geometry \(node.name).oni was not found in SharedPath")
                }
                let mesh: Mesh
                do { mesh = try readM3GM(m3gmURL, sharedFiles: sharedFiles) }
                catch { throw OniNativeXMLError.invalidDocument("could not read \(m3gmURL.lastPathComponent): \(error.localizedDescription)") }
                if knownTextureNames.insert(mesh.textureName.lowercased()).inserted {
                    textureNames.append(mesh.textureName)
                }
                let combinedFlags = node.flags | furnitureFlags
                let encodedObjectID = UInt32(5 << 24 | placement.objectID)
                let polygons = quadify(mesh).map { indices in
                    OniColladaPolygon(
                        positions: indices.map { transform(mesh.points[$0], placement: placement, isNormal: false) },
                        normals: indices.map { index in
                            guard mesh.normals.indices.contains(index) else { return OniLevelVector3(x: 0, y: 1, z: 0) }
                            return transform(mesh.normals[index], placement: placement, isNormal: true)
                        },
                        textureCoordinates: indices.map { index in
                            mesh.textureCoordinates.indices.contains(index) ? mesh.textureCoordinates[index] : OniLevelVector2(x: 0, y: 0)
                        },
                        materialSymbol: mesh.textureName,
                        additionalFlags: combinedFlags | (mesh.transparent ? 0x0001_0280 : 0),
                        objectID: encodedObjectID
                    )
                }
                let nodeName = "FURN_\(placement.objectID)_\(nodeIndex)_\(placement.className)"
                instances.append(OniColladaGeometryInstance(
                    nodeName: nodeName,
                    geometryID: mesh.name,
                    materialNames: [mesh.textureName: mesh.textureName],
                    polygons: polygons
                ))
                if mesh.transparent { transparentNames.insert(mesh.textureName) }
                partCount += 1
                polygonCount += polygons.count
            }
            documents.append(OniColladaGeometryDocument(
                sourceURL: ofgaURL,
                unitScale: 1,
                upAxis: "Y_UP",
                geometries: [:],
                instances: instances,
                transparentMaterialNames: transparentNames
            ))
            let placementTransform = placementMatrix(position: placement.position, rotation: placement.rotation)
            furnitureParticles += try readOFGAParticles(ofgaURL).map { particle in
                OniLevelEnvironmentParticle(
                    particleClass: particle.particleClass,
                    tag: placement.particleTag + "_" + particle.tag,
                    transform: multiply(particle.transform, placementTransform),
                    decalScale: particle.decalScale, flags: particle.flags
                )
            }
        }

        for placement in consolePlacements {
            guard let classURL = sharedFiles["cons\(placement.className).oni".lowercased()] else {
                throw OniNativeXMLError.invalidDocument("console class CONS\(placement.className).oni was not found in SharedPath")
            }
            let file = try OniDatFile.load(from: classURL)
            guard let root = file.instances.first(where: {
                $0.templateTag == "CONS" && $0.descriptorFlags & 2 == 0
            }) else {
                throw OniNativeXMLError.invalidDocument("\(classURL.lastPathComponent) does not contain a CONS class")
            }
            let geometry = try link(file, at: root.dataOffset + 28, tag: "OFGA")
            let nodes = try readOFGA(file, root: geometry)
            let objectTransform = placementMatrix(position: placement.position, rotation: placement.rotation)
            var instances: [OniColladaGeometryInstance] = []
            var transparentNames = Set<String>()
            for (part, node) in nodes.enumerated() {
                let mesh = try readM3GM(file, root: file.instances[node.rootIndex], sharedFiles: sharedFiles)
                if knownTextureNames.insert(mesh.textureName.lowercased()).inserted {
                    textureNames.append(mesh.textureName)
                }
                let polygons = quadify(mesh).map { indices in
                    OniColladaPolygon(
                        positions: indices.map { transform(mesh.points[$0], by: objectTransform, isNormal: false) },
                        normals: indices.map { index in
                            guard mesh.normals.indices.contains(index) else { return OniLevelVector3(x: 0, y: 1, z: 0) }
                            return transform(mesh.normals[index], by: objectTransform, isNormal: true)
                        },
                        textureCoordinates: indices.map { index in
                            mesh.textureCoordinates.indices.contains(index) ? mesh.textureCoordinates[index] : OniLevelVector2(x: 0, y: 0)
                        },
                        materialSymbol: mesh.textureName,
                        additionalFlags: node.flags | 0x0001_0000 | (mesh.transparent ? 0x0001_0280 : 0),
                        objectID: UInt32(15 << 24 | placement.objectID)
                    )
                }
                instances.append(OniColladaGeometryInstance(
                    nodeName: "CONS_\(placement.objectID)_\(part)_\(placement.className)",
                    geometryID: mesh.name, materialNames: [mesh.textureName: mesh.textureName],
                    polygons: polygons
                ))
                if mesh.transparent { transparentNames.insert(mesh.textureName) }
                partCount += 1
                polygonCount += polygons.count
            }
            documents.append(OniColladaGeometryDocument(
                sourceURL: classURL, unitScale: 1, upAxis: "Y_UP", geometries: [:],
                instances: instances, transparentMaterialNames: transparentNames
            ))
        }


        let genericGroups: [(
            placements: [GenericPlacement], tag: String, geometryOffset: Int,
            flagsOffset: Int, objectType: Int
        )] = [
            (triggerPlacements, "TRIG", 16, 24, 13),
            (turretPlacements, "TURR", 88, 96, 14)
        ]
        for group in genericGroups {
            for placement in group.placements {
                guard let classURL = sharedFiles["\(group.tag)\(placement.className).oni".lowercased()] else {
                    throw OniNativeXMLError.invalidDocument(
                        "\(group.tag) class \(group.tag)\(placement.className).oni was not found in SharedPath"
                    )
                }
                let file = try OniDatFile.load(from: classURL)
                guard let root = file.instances.first(where: {
                    $0.templateTag == group.tag && $0.descriptorFlags & 2 == 0
                }) else {
                    throw OniNativeXMLError.invalidDocument(
                        "\(classURL.lastPathComponent) does not contain a \(group.tag) class"
                    )
                }
                let geometry = try link(
                    file, at: root.dataOffset + group.geometryOffset, tag: "M3GM"
                )
                let classFlags = try u32(
                    file.data, root.dataOffset + group.flagsOffset,
                    context: "\(group.tag) gunk flags"
                )
                let mesh = try readM3GM(file, root: geometry, sharedFiles: sharedFiles)
                if knownTextureNames.insert(mesh.textureName.lowercased()).inserted {
                    textureNames.append(mesh.textureName)
                }
                let objectTransform = placementMatrix(
                    position: placement.position, rotation: placement.rotation
                )
                let polygons = quadify(mesh).map { indices in
                    OniColladaPolygon(
                        positions: indices.map {
                            transform(mesh.points[$0], by: objectTransform, isNormal: false)
                        },
                        normals: indices.map { index in
                            guard mesh.normals.indices.contains(index) else {
                                return OniLevelVector3(x: 0, y: 1, z: 0)
                            }
                            return transform(mesh.normals[index], by: objectTransform, isNormal: true)
                        },
                        textureCoordinates: indices.map { index in
                            mesh.textureCoordinates.indices.contains(index)
                                ? mesh.textureCoordinates[index] : OniLevelVector2(x: 0, y: 0)
                        },
                        materialSymbol: mesh.textureName,
                        additionalFlags: classFlags | 0x0001_0000
                            | (mesh.transparent ? 0x0001_0280 : 0),
                        objectID: UInt32(group.objectType << 24 | placement.objectID)
                    )
                }
                let instance = OniColladaGeometryInstance(
                    nodeName: "\(group.tag)_\(placement.objectID)_\(placement.className)",
                    geometryID: mesh.name,
                    materialNames: [mesh.textureName: mesh.textureName], polygons: polygons
                )
                documents.append(OniColladaGeometryDocument(
                    sourceURL: classURL, unitScale: 1, upAxis: "Y_UP", geometries: [:],
                    instances: [instance],
                    transparentMaterialNames: mesh.transparent ? [mesh.textureName] : []
                ))
                partCount += 1
                polygonCount += polygons.count
            }
        }

        for placement in doorPlacements {
            guard let classURL = sharedFiles["door\(placement.className).oni".lowercased()] else {
                throw OniNativeXMLError.invalidDocument("door class DOOR\(placement.className).oni was not found in SharedPath")
            }
            let doorClass = try readDoorClass(classURL, sharedFiles: sharedFiles)
            let meshes = try doorClass.nodes.map { node in
                try readM3GM(doorClass.file, root: doorClass.file.instances[node.rootIndex], sharedFiles: sharedFiles)
            }
            let geometryTransform = multiply(
                scaleMatrix(doorClass.animationScale), rotationX(-Float.pi / 2)
            )
            let transformedPoints = meshes.flatMap(\.points).map { transform($0, by: geometryTransform, isNormal: false) }
            let minY = min(0, transformedPoints.map(\.y).min() ?? 0)
            let minX = min(0, transformedPoints.map(\.x).min() ?? 0)
            let maxX = max(0, transformedPoints.map(\.x).max() ?? 0)
            var placementMatrix = placementMatrix(position: placement.position, rotation: placement.rotation)
            placementMatrix[10] -= minY
            let sideCount = placement.flags & 0x0080 == 0 ? 1 : 2
            let xOffset = sideCount == 1 ? Float(0) : (maxX - minX) / 2

            for side in 0..<sideCount {
                let sidePlacement = multiply(
                    translationMatrix(side == 0 ? xOffset : -xOffset, 0, 0), placementMatrix
                )
                let isMirroredSide = (placement.flags & 0x0100 != 0) == (side == 0)
                let origin = isMirroredSide
                    ? multiply(multiply(rotationY(.pi), geometryTransform), sidePlacement)
                    : multiply(geometryTransform, sidePlacement)
                let gunkTransform = isMirroredSide
                    ? multiply(multiply(geometryTransform, rotationY(.pi)), sidePlacement)
                    : origin
                let scriptID = placement.scriptID | Int32(side << 12)
                let textureOverride = placement.textures.indices.contains(side) ? placement.textures[side] : ""
                var instances: [OniColladaGeometryInstance] = []
                var geometryNames: [String] = []
                var rootIndices: [Int] = []
                var physicsTextureNames: [String] = []
                for (part, pair) in zip(doorClass.nodes.indices, zip(doorClass.nodes, meshes)) {
                    let (node, mesh) = pair
                    let textureName = textureOverride.isEmpty ? mesh.textureName : textureOverride
                    if knownTextureNames.insert(textureName.lowercased()).inserted { textureNames.append(textureName) }
                    let polygons = quadify(mesh).map { indices in
                        OniColladaPolygon(
                            positions: indices.map { transform(mesh.points[$0], by: gunkTransform, isNormal: false) },
                            normals: indices.map { index in
                                guard mesh.normals.indices.contains(index) else { return OniLevelVector3(x: 0, y: 1, z: 0) }
                                return transform(mesh.normals[index], by: gunkTransform, isNormal: true)
                            },
                            textureCoordinates: indices.map { index in
                                mesh.textureCoordinates.indices.contains(index) ? mesh.textureCoordinates[index] : OniLevelVector2(x: 0, y: 0)
                            },
                            materialSymbol: textureName,
                            additionalFlags: node.flags | 0x0080_0800 | (mesh.transparent ? 0x0001_0280 : 0),
                            objectID: UInt32(3 << 24 | placement.objectID)
                        )
                    }
                    let geometryName = "door_\(placement.objectID)_\(side)_\(part)"
                    geometryNames.append(geometryName)
                    rootIndices.append(node.rootIndex)
                    physicsTextureNames.append(textureName)
                    instances.append(OniColladaGeometryInstance(
                        nodeName: "DOOR_\(placement.objectID)_\(side)_\(part)", geometryID: mesh.name,
                        materialNames: [textureName: textureName], polygons: polygons
                    ))
                    partCount += 1
                    polygonCount += polygons.count
                }
                documents.append(OniColladaGeometryDocument(
                    sourceURL: classURL, unitScale: 1, upAxis: "Y_UP", geometries: [:],
                    instances: instances, transparentMaterialNames: []
                ))
                doorPhysicsObjects.append(OniLevelPhysicsObject(
                    name: "door_\(scriptID)", fileName: "", geometryNames: geometryNames,
                    geometrySourceIndices: nil, importedGeometryURL: nil,
                    archiveGeometryURL: classURL, archiveGeometryRootIndices: rootIndices,
                    archiveGeometryTextureNames: physicsTextureNames,
                    geometryBuildName: "", animationName: "", animationClips: [],
                    animationNodeID: nil, particles: [], flags: 0x1000,
                    doorScriptID: scriptID, physicsType: 0, scriptID: 65_535,
                    position: OniLevelVector3(x: 0, y: 0, z: 0), orientation: [0, 0, 0, 1],
                    scale: 1, transform: origin
                ))
            }
        }
        return OniGunkGeometryBuildResult(
            documents: documents,
            furnitureCount: placements.count,
            consoleCount: consolePlacements.count,
            triggerCount: triggerPlacements.count,
            turretCount: turretPlacements.count,
            geometryPartCount: partCount,
            polygonCount: polygonCount,
            textureNames: textureNames, doorPhysicsObjects: doorPhysicsObjects,
            furnitureParticles: furnitureParticles
        )
    }

    private static func readFurniturePlacements(_ urls: [URL], sharedFiles: [String: URL]) throws -> [Placement] {
        var result: [Placement] = []
        var nextObjectID = 1
        for url in urls {
            let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
            guard let root = document.rootElement(), root.name == "Oni" else {
                throw OniNativeXMLError.invalidDocument("object file \(url.lastPathComponent) must contain <Oni>")
            }
            guard let objects = root.elements(forName: "Objects").first else { continue }
            for object in objects.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard supportedObjectNames.contains(object.name ?? "") else { continue }
                guard object.name == "FURN" || object.name == "Furniture" else {
                    nextObjectID += 1
                    continue
                }
                guard
                      let header = object.elements(forName: "Header").first,
                      let osd = object.elements(forName: "OSD").first else { continue }
                let className = normalizedFurnitureClass(text(osd, "Class"))
                guard !className.isEmpty else { continue }
                guard sharedFiles["ofga\(className).oni".lowercased()] != nil else { continue }
                result.append(Placement(
                    objectID: nextObjectID,
                    className: className,
                    position: try vector3(text(header, "Position"), field: "FURN Position"),
                    rotation: try vector3(text(header, "Rotation"), field: "FURN Rotation"),
                    particleTag: text(osd, "Particle")
                ))
                nextObjectID += 1
            }
        }
        return result
    }

    private static func readDoorPlacements(_ urls: [URL]) throws -> [DoorPlacement] {
        var result: [DoorPlacement] = []
        var nextObjectID = 1
        for url in urls {
            let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
            guard let root = document.rootElement(), root.name == "Oni" else {
                throw OniNativeXMLError.invalidDocument("object file \(url.lastPathComponent) must contain <Oni>")
            }
            guard let objects = root.elements(forName: "Objects").first else { continue }
            for object in objects.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard supportedObjectNames.contains(object.name ?? "") else { continue }
                defer { nextObjectID += 1 }
                guard object.name == "DOOR" || object.name == "Door",
                      let header = object.elements(forName: "Header").first,
                      let osd = object.elements(forName: "OSD").first else { continue }
                var className = text(osd, "Class")
                className = URL(fileURLWithPath: className).deletingPathExtension().lastPathComponent
                if className.lowercased().hasPrefix("door") { className = String(className.dropFirst(4)) }
                guard !className.isEmpty else { continue }
                let texture1 = text(osd, "Texture1").isEmpty ? text(osd, "Texture") : text(osd, "Texture1")
                result.append(DoorPlacement(
                    objectID: nextObjectID,
                    scriptID: Int32(integerToken(text(osd, "DoorId")) ?? 0),
                    flags: UInt16(truncatingIfNeeded: doorFlags(text(osd, "Flags"))),
                    className: className,
                    position: try vector3(text(header, "Position"), field: "DOOR Position"),
                    rotation: try vector3(text(header, "Rotation"), field: "DOOR Rotation"),
                    textures: [texture1, text(osd, "Texture2")]
                ))
            }
        }
        return result
    }

    private static func readConsolePlacements(_ urls: [URL]) throws -> [ConsolePlacement] {
        var result: [ConsolePlacement] = []
        var nextObjectID = 1
        for url in urls {
            let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
            guard let root = document.rootElement(), root.name == "Oni" else {
                throw OniNativeXMLError.invalidDocument("object file \(url.lastPathComponent) must contain <Oni>")
            }
            guard let objects = root.elements(forName: "Objects").first else { continue }
            for object in objects.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard supportedObjectNames.contains(object.name ?? "") else { continue }
                defer { nextObjectID += 1 }
                guard object.name == "CONS" || object.name == "Console",
                      let header = object.elements(forName: "Header").first,
                      let osd = object.elements(forName: "OSD").first else { continue }
                var className = text(osd, "Class")
                className = URL(fileURLWithPath: className).deletingPathExtension().lastPathComponent
                if className.hasPrefix("CONS") { className = String(className.dropFirst(4)) }
                guard !className.isEmpty else { continue }
                result.append(ConsolePlacement(
                    objectID: nextObjectID, className: className,
                    position: try vector3(text(header, "Position"), field: "CONS Position"),
                    rotation: try vector3(text(header, "Rotation"), field: "CONS Rotation")
                ))
            }
        }
        return result
    }

    private static func readGenericPlacements(
        _ urls: [URL], names: Set<String>, templateTag: String
    ) throws -> [GenericPlacement] {
        var result: [GenericPlacement] = []
        var nextObjectID = 1
        for url in urls {
            let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
            guard let root = document.rootElement(), root.name == "Oni" else {
                throw OniNativeXMLError.invalidDocument("object file \(url.lastPathComponent) must contain <Oni>")
            }
            guard let objects = root.elements(forName: "Objects").first else { continue }
            for object in objects.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard supportedObjectNames.contains(object.name ?? "") else { continue }
                defer { nextObjectID += 1 }
                guard names.contains(object.name ?? ""),
                      let header = object.elements(forName: "Header").first,
                      let osd = object.elements(forName: "OSD").first else { continue }
                var className = URL(fileURLWithPath: text(osd, "Class"))
                    .deletingPathExtension().lastPathComponent
                if className.hasPrefix(templateTag) {
                    className = String(className.dropFirst(templateTag.count))
                }
                guard !className.isEmpty else { continue }
                result.append(GenericPlacement(
                    objectID: nextObjectID, className: className,
                    position: try vector3(text(header, "Position"), field: "\(templateTag) Position"),
                    rotation: try vector3(text(header, "Rotation"), field: "\(templateTag) Rotation")
                ))
            }
        }
        return result
    }

    private static func readDoorClass(_ url: URL, sharedFiles: [String: URL]) throws -> DoorClass {
        let file = try OniDatFile.load(from: url)
        guard let root = file.instances.first(where: { $0.templateTag == "DOOR" && $0.descriptorFlags & 2 == 0 }) else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) does not contain a DOOR class")
        }
        let geometry = try link(file, at: root.dataOffset, tag: "OFGA")
        let nodes = try readOFGA(file, root: geometry).map { ($0.flags, $0.rootIndex) }
        let animation = try link(file, at: root.dataOffset + 8, tag: "OBAN")
        let animationURL = sharedFiles[(animation.fullName + ".oni").lowercased()]
        let animationFile: OniDatFile
        if let animationURL { animationFile = try OniDatFile.load(from: animationURL) }
        else { animationFile = file }
        guard let animationRoot = animationFile.instances.first(where: {
            $0.templateTag == "OBAN" && $0.descriptorFlags & 2 == 0
        }) else {
            throw OniNativeXMLError.invalidDocument("door animation \(animation.fullName) was not found in SharedPath")
        }
        let offset = animationRoot.dataOffset + 64
        let row0 = try vector(animationFile.data, offset, context: "door animation scale")
        let row1 = try vector(animationFile.data, offset + 12, context: "door animation scale")
        let row2 = try vector(animationFile.data, offset + 24, context: "door animation scale")
        return DoorClass(
            url: url, file: file, nodes: nodes,
            animationScale: OniLevelVector3(x: length(row0), y: length(row1), z: length(row2))
        )
    }

    private static func normalizedFurnitureClass(_ value: String) -> String {
        var name = value
        if value.lowercased().hasSuffix(".oni") {
            name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        }
        if name.lowercased().hasPrefix("ofga") { name = String(name.dropFirst(4)) }
        return name
    }

    private static func sharedFileMap(_ directory: URL) throws -> [String: URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Dictionary(urls.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func readOFGA(_ url: URL) throws -> [(flags: UInt32, name: String)] {
        let file = try OniDatFile.load(from: url)
        guard let root = file.instances.first(where: { $0.templateTag == "OFGA" && $0.descriptorFlags & 2 == 0 }) else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) does not contain OFGA geometry")
        }
        let count = try integer(file.data, root.dataOffset + 20, context: "OFGA geometry count")
        guard count >= 0, count <= 65_536 else { throw OniDatError.outOfBounds("OFGA geometry count") }
        var nodes: [(UInt32, String)] = []
        for index in 0..<count {
            let offset = root.dataOffset + 24 + index * 12
            let flags = try u32(file.data, offset, context: "OFGA flags")
            let target = try link(file, at: offset + 4, tag: "M3GM")
            guard !target.fullName.isEmpty else {
                throw OniNativeXMLError.invalidDocument("OFGA geometry has an unnamed M3GM reference")
            }
            nodes.append((flags, target.fullName))
        }
        return nodes
    }

    private static func readOFGAParticles(_ url: URL) throws -> [OniLevelEnvironmentParticle] {
        let file = try OniDatFile.load(from: url)
        guard let root = file.instances.first(where: {
            $0.templateTag == "OFGA" && $0.descriptorFlags & 2 == 0
        }) else { return [] }
        let value = try u32(file.data, root.dataOffset + 16, context: "OFGA particle link")
        guard value != 0 else { return [] }
        let particleIndex = Int(value >> 8)
        guard file.instances.indices.contains(particleIndex),
              file.instances[particleIndex].templateTag == "ENVP" else {
            throw OniNativeXMLError.invalidDocument("OFGA particle link does not point to ENVP")
        }
        let envp = file.instances[particleIndex]
        guard envp.dataOffset + 24 <= file.data.count else {
            throw OniDatError.outOfBounds("OFGA ENVP header")
        }
        let count = Int(try u16(file.data, envp.dataOffset + 22, context: "OFGA ENVP count"))
        return try (0..<count).map { index in
            let offset = envp.dataOffset + 24 + index * 208
            guard offset + 208 <= file.data.count else { throw OniDatError.outOfBounds("OFGA ENVP particle") }
            let transform = try (0..<12).map { component in
                Float(bitPattern: try u32(
                    file.data, offset + 112 + component * 4, context: "OFGA ENVP transform"
                ))
            }
            return OniLevelEnvironmentParticle(
                particleClass: fixedString(file.data, offset: offset, length: 64),
                tag: fixedString(file.data, offset: offset + 64, length: 48),
                transform: transform,
                decalScale: OniLevelVector2(
                    x: Float(bitPattern: try u32(file.data, offset + 160, context: "OFGA ENVP decal scale")),
                    y: Float(bitPattern: try u32(file.data, offset + 164, context: "OFGA ENVP decal scale"))
                ),
                flags: try u16(file.data, offset + 168, context: "OFGA ENVP flags")
            )
        }
    }

    private static func readOFGA(
        _ file: OniDatFile, root: OniDatInstance
    ) throws -> [(flags: UInt32, rootIndex: Int)] {
        let count = try integer(file.data, root.dataOffset + 20, context: "OFGA geometry count")
        guard count >= 0, count <= 65_536 else { throw OniDatError.outOfBounds("OFGA geometry count") }
        return try (0..<count).map { index in
            let offset = root.dataOffset + 24 + index * 12
            let flags = try u32(file.data, offset, context: "OFGA flags")
            let target = try link(file, at: offset + 4, tag: "M3GM")
            return (flags, target.id)
        }
    }

    private static func readM3GM(_ url: URL, sharedFiles: [String: URL]) throws -> Mesh {
        let file = try OniDatFile.load(from: url)
        guard let root = file.instances.first(where: { $0.templateTag == "M3GM" && $0.descriptorFlags & 2 == 0 }) else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) does not contain M3GM geometry")
        }
        return try readM3GM(file, root: root, sharedFiles: sharedFiles)
    }

    private static func readM3GM(
        _ file: OniDatFile, root: OniDatInstance, sharedFiles: [String: URL]
    ) throws -> Mesh {
        let pointsInstance = try link(file, at: root.dataOffset + 4, tag: "PNTA")
        let normalsInstance = try link(file, at: root.dataOffset + 8, tag: "VCRA")
        let faceNormalsInstance = try link(file, at: root.dataOffset + 12, tag: "VCRA")
        let textureInstance = try link(file, at: root.dataOffset + 16, tag: "TXCA")
        let stripsInstance = try link(file, at: root.dataOffset + 20, tag: "IDXA")
        let faceIndicesInstance = try link(file, at: root.dataOffset + 24, tag: "IDXA")
        let textureLink = try u32(file.data, root.dataOffset + 28, context: "M3GM texture link")
        let textureName: String
        if textureLink == 0 {
            textureName = "NONE"
        } else {
            let index = Int(textureLink >> 8)
            guard file.instances.indices.contains(index), file.instances[index].templateTag == "TXMP" else {
                throw OniNativeXMLError.invalidDocument("M3GM texture link is invalid")
            }
            let fullName = file.instances[index].fullName
            textureName = fullName.hasPrefix("TXMP") ? String(fullName.dropFirst(4)) : fullName
        }

        let points = try vectors3(file, pointsInstance, header: 52, context: "PNTA")
        let normals = try vectors3(file, normalsInstance, header: 20, context: "vertex VCRA")
        let faceNormals = try vectors3(file, faceNormalsInstance, header: 20, context: "face VCRA")
        let textureCoordinates = try vectors2(file, textureInstance, header: 20, context: "TXCA")
        let strips = try indices(file, stripsInstance, header: 20, context: "strip IDXA")
        let faceIndices = try indices(file, faceIndicesInstance, header: 20, context: "face IDXA")
        let triangles = try triangleList(points: points, strips: strips, faceNormals: faceNormals, faceIndices: faceIndices)
        let transparent = try isTransparentTexture(textureName, sharedFiles: sharedFiles)
        return Mesh(
            name: root.fullName,
            points: points,
            normals: normals,
            textureCoordinates: textureCoordinates,
            triangles: triangles,
            textureName: textureName.isEmpty ? "NONE" : textureName,
            transparent: transparent
        )
    }

    private static func triangleList(
        points: [OniLevelVector3], strips: [Int32], faceNormals: [OniLevelVector3], faceIndices: [Int32]
    ) throws -> [[Int]] {
        var triangles: [[Int]] = []
        var face = [0, 0, 0]
        var faceIndex = 0
        var order = 0
        var index = 0
        while index < strips.count {
            if strips[index] < 0 {
                face[0] = Int(UInt32(bitPattern: strips[index]) & 0x7fff_ffff)
                index += 1
                guard index < strips.count else { throw OniDatError.outOfBounds("M3GM triangle strip") }
                face[1] = Int(strips[index])
                index += 1
                order = 0
                guard index < strips.count else { throw OniDatError.outOfBounds("M3GM triangle strip") }
            } else {
                face[order] = face[2]
                order ^= 1
            }
            face[2] = Int(strips[index])
            guard face.allSatisfy(points.indices.contains), faceIndices.indices.contains(faceIndex) else {
                throw OniDatError.outOfBounds("M3GM triangle index")
            }
            let normalIndex = Int(faceIndices[faceIndex])
            guard faceNormals.indices.contains(normalIndex) else { throw OniDatError.outOfBounds("M3GM face normal index") }
            let calculated = normalized(cross(subtract(points[face[1]], points[face[0]]), subtract(points[face[2]], points[face[0]])))
            let expected = normalized(faceNormals[normalIndex])
            triangles.append(dot(expected, calculated) < 0 ? [face[2], face[1], face[0]] : face)
            faceIndex += 1
            index += 1
        }
        return triangles
    }

    private static func quadify(_ mesh: Mesh) -> [[Int]] {
        struct Edge { let face: Int; let edge: Int; let p0: Int; let p1: Int }
        let normals = mesh.triangles.map { triangle in
            normalized(cross(subtract(mesh.points[triangle[1]], mesh.points[triangle[0]]), subtract(mesh.points[triangle[2]], mesh.points[triangle[0]])))
        }
        var usage: [Int: [Int]] = [:]
        for (faceIndex, triangle) in mesh.triangles.enumerated() {
            for point in triangle { usage[point, default: []].append(faceIndex) }
        }
        var consumed = Array(repeating: false, count: mesh.triangles.count)
        var replacements: [Int: [Int]] = [:]
        for faceIndex in mesh.triangles.indices where !consumed[faceIndex] {
            let triangle = mesh.triangles[faceIndex]
            var candidates: [(length: Float, first: Edge, second: Edge)] = []
            for edgeIndex in 0..<3 {
                let edge = Edge(face: faceIndex, edge: edgeIndex, p0: triangle[edgeIndex], p1: triangle[(edgeIndex + 1) % 3])
                let adjacentFaces = intersection(usage[edge.p0] ?? [], usage[edge.p1] ?? [])
                for adjacentFace in adjacentFaces where adjacentFace != faceIndex && !consumed[adjacentFace] {
                    guard vectorDistance(normals[adjacentFace], normals[faceIndex]) <= 0.01 else { continue }
                    let adjacent = mesh.triangles[adjacentFace]
                    for adjacentEdgeIndex in 0..<3 where adjacent[adjacentEdgeIndex] == edge.p1 && adjacent[(adjacentEdgeIndex + 1) % 3] == edge.p0 {
                        let second = Edge(face: adjacentFace, edge: adjacentEdgeIndex, p0: edge.p1, p1: edge.p0)
                        let d = subtract(mesh.points[edge.p0], mesh.points[edge.p1])
                        candidates.append((dot(d, d), edge, second))
                    }
                }
            }
            guard let candidate = candidates.enumerated().min(by: {
                $0.element.length == $1.element.length ? $0.offset < $1.offset : $0.element.length < $1.element.length
            })?.element else { continue }
            let first = mesh.triangles[candidate.first.face]
            let second = mesh.triangles[candidate.second.face]
            let firstOther = (0..<3).first { $0 != candidate.first.edge && $0 != (candidate.first.edge + 1) % 3 }!
            let secondOther = (0..<3).first { $0 != candidate.second.edge && $0 != (candidate.second.edge + 1) % 3 }!
            replacements[faceIndex] = [first[(candidate.first.edge + 1) % 3], first[firstOther], first[candidate.first.edge], second[secondOther]]
            consumed[faceIndex] = true
            consumed[candidate.second.face] = true
        }
        var result: [[Int]] = []
        for index in mesh.triangles.indices {
            if let replacement = replacements[index] { result.append(replacement) }
            else if !consumed[index] { result.append(mesh.triangles[index]) }
        }
        return result
    }

    private static func isTransparentTexture(_ name: String, sharedFiles: [String: URL]) throws -> Bool {
        guard !name.isEmpty, name != "NONE",
              let url = sharedFiles["txmp\(name).oni".lowercased()] else { return false }
        let file = try OniDatFile.load(from: url)
        guard let texture = file.instances.first(where: { $0.templateTag == "TXMP" && $0.descriptorFlags & 2 == 0 }),
              texture.dataOffset + 0x8c <= file.data.count else { return false }
        let format = try u32(file.data, texture.dataOffset + 0x88, context: "TXMP format")
        return format == 0 || format == 2 || format == 7
    }

    private static func vectors3(_ file: OniDatFile, _ instance: OniDatInstance, header: Int, context: String) throws -> [OniLevelVector3] {
        let count = try integer(file.data, instance.dataOffset + header, context: context + " count")
        guard count >= 0, instance.dataOffset + header + 4 + count * 12 <= file.data.count else { throw OniDatError.outOfBounds(context) }
        return try (0..<count).map { index in
            let offset = instance.dataOffset + header + 4 + index * 12
            return OniLevelVector3(
                x: Float(bitPattern: try u32(file.data, offset, context: context)),
                y: Float(bitPattern: try u32(file.data, offset + 4, context: context)),
                z: Float(bitPattern: try u32(file.data, offset + 8, context: context))
            )
        }
    }

    private static func vectors2(_ file: OniDatFile, _ instance: OniDatInstance, header: Int, context: String) throws -> [OniLevelVector2] {
        let count = try integer(file.data, instance.dataOffset + header, context: context + " count")
        guard count >= 0, instance.dataOffset + header + 4 + count * 8 <= file.data.count else { throw OniDatError.outOfBounds(context) }
        return try (0..<count).map { index in
            let offset = instance.dataOffset + header + 4 + index * 8
            return OniLevelVector2(
                x: Float(bitPattern: try u32(file.data, offset, context: context)),
                y: Float(bitPattern: try u32(file.data, offset + 4, context: context))
            )
        }
    }

    private static func indices(_ file: OniDatFile, _ instance: OniDatInstance, header: Int, context: String) throws -> [Int32] {
        let count = try integer(file.data, instance.dataOffset + header, context: context + " count")
        guard count >= 0, instance.dataOffset + header + 4 + count * 4 <= file.data.count else { throw OniDatError.outOfBounds(context) }
        return try (0..<count).map { index in
            Int32(bitPattern: try u32(file.data, instance.dataOffset + header + 4 + index * 4, context: context))
        }
    }

    private static func link(_ file: OniDatFile, at offset: Int, tag: String) throws -> OniDatInstance {
        let value = try u32(file.data, offset, context: tag + " link")
        let index = Int(value >> 8)
        guard value != 0, file.instances.indices.contains(index), file.instances[index].templateTag == tag else {
            throw OniNativeXMLError.invalidDocument("geometry link does not point to \(tag)")
        }
        return file.instances[index]
    }

    private static func transform(_ value: OniLevelVector3, placement: Placement, isNormal: Bool) -> OniLevelVector3 {
        let radiansPerDegree = Float(3.141593) / Float(180)
        let x = placement.rotation.x * radiansPerDegree
        let y = placement.rotation.y * radiansPerDegree
        let z = placement.rotation.z * radiansPerDegree
        let cx = Float(Foundation.cos(Double(x))), sx = Float(Foundation.sin(Double(x)))
        let cy = Float(Foundation.cos(Double(y))), sy = Float(Foundation.sin(Double(y)))
        let cz = Float(Foundation.cos(Double(z))), sz = Float(Foundation.sin(Double(z)))
        var result = value
        result = OniLevelVector3(x: result.x, y: result.y * cx - result.z * sx, z: result.y * sx + result.z * cx)
        result = OniLevelVector3(x: result.x * cy + result.z * sy, y: result.y, z: -result.x * sy + result.z * cy)
        result = OniLevelVector3(x: result.x * cz - result.y * sz, y: result.x * sz + result.y * cz, z: result.z)
        if !isNormal {
            result = OniLevelVector3(x: result.x + placement.position.x, y: result.y + placement.position.y, z: result.z + placement.position.z)
        }
        return result
    }

    private static func text(_ parent: XMLElement, _ name: String) -> String {
        parent.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func vector3(_ value: String, field: String) throws -> OniLevelVector3 {
        let parts = value.split(whereSeparator: \Character.isWhitespace).compactMap { Float($0) }
        guard parts.count == 3 else { throw OniNativeXMLError.invalidDocument("\(field) must contain three numbers") }
        return OniLevelVector3(x: parts[0], y: parts[1], z: parts[2])
    }

    private static func integerToken(_ value: String) -> Int? {
        let token = value.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? ""
        if token.lowercased().hasPrefix("0x") { return Int(token.dropFirst(2), radix: 16) }
        return Int(token)
    }

    private static func doorFlags(_ value: String) -> UInt32 {
        if let number = integerToken(value) { return UInt32(truncatingIfNeeded: number) }
        let names: [String: UInt32] = [
            "initiallocked": 0x01, "indoorframe": 0x04, "manual": 0x10,
            "doubledoor": 0x80, "mirror": 0x100, "oneway": 0x200,
            "reverse": 0x400, "jammed": 0x800, "initialopen": 0x1000
        ]
        return value.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" })
            .reduce(0) { $0 | (names[$1.lowercased()] ?? 0) }
    }

    private static func vector(_ data: Data, _ offset: Int, context: String) throws -> OniLevelVector3 {
        OniLevelVector3(
            x: Float(bitPattern: try u32(data, offset, context: context)),
            y: Float(bitPattern: try u32(data, offset + 4, context: context)),
            z: Float(bitPattern: try u32(data, offset + 8, context: context))
        )
    }

    private static func length(_ value: OniLevelVector3) -> Float {
        sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    }

    private static func identityMatrix() -> [Float] {
        [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
    }

    private static func scaleMatrix(_ value: OniLevelVector3) -> [Float] {
        [value.x, 0, 0, 0, value.y, 0, 0, 0, value.z, 0, 0, 0]
    }

    private static func translationMatrix(_ x: Float, _ y: Float, _ z: Float) -> [Float] {
        [1, 0, 0, 0, 1, 0, 0, 0, 1, x, y, z]
    }

    private static func rotationX(_ angle: Float) -> [Float] {
        let c = cos(angle), s = sin(angle)
        return [1, 0, 0, 0, c, s, 0, -s, c, 0, 0, 0]
    }

    private static func rotationY(_ angle: Float) -> [Float] {
        let c = cos(angle), s = sin(angle)
        return [c, 0, -s, 0, 1, 0, s, 0, c, 0, 0, 0]
    }

    private static func rotationZ(_ angle: Float) -> [Float] {
        let c = cos(angle), s = sin(angle)
        return [c, s, 0, -s, c, 0, 0, 0, 1, 0, 0, 0]
    }

    private static func placementMatrix(position: OniLevelVector3, rotation: OniLevelVector3) -> [Float] {
        let d = Float.pi / 180
        return multiply(
            multiply(multiply(rotationX(rotation.x * d), rotationY(rotation.y * d)), rotationZ(rotation.z * d)),
            translationMatrix(position.x, position.y, position.z)
        )
    }

    private static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == 12 && b.count == 12)
        var r = identityMatrix()
        for row in 0..<3 {
            for column in 0..<3 {
                let a0 = a[row * 3]
                let a1 = a[row * 3 + 1]
                let a2 = a[row * 3 + 2]
                r[row * 3 + column] = a0 * b[column]
                    + a1 * b[3 + column] + a2 * b[6 + column]
            }
        }
        for column in 0..<3 {
            r[9 + column] = a[9] * b[column] + a[10] * b[3 + column]
                + a[11] * b[6 + column] + b[9 + column]
        }
        return r
    }

    private static func transform(_ value: OniLevelVector3, by matrix: [Float], isNormal: Bool) -> OniLevelVector3 {
        var result = OniLevelVector3(
            x: value.x * matrix[0] + value.y * matrix[3] + value.z * matrix[6],
            y: value.x * matrix[1] + value.y * matrix[4] + value.z * matrix[7],
            z: value.x * matrix[2] + value.y * matrix[5] + value.z * matrix[8]
        )
        if !isNormal {
            result = OniLevelVector3(x: result.x + matrix[9], y: result.y + matrix[10], z: result.z + matrix[11])
        }
        return isNormal ? normalized(result) : result
    }

    private static func integer(_ data: Data, _ offset: Int, context: String) throws -> Int {
        Int(try u32(data, offset, context: context))
    }

    private static func u32(_ data: Data, _ offset: Int, context: String) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw OniDatError.outOfBounds(context) }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func u16(_ data: Data, _ offset: Int, context: String) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw OniDatError.outOfBounds(context) }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func fixedString(_ data: Data, offset: Int, length: Int) -> String {
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func intersection(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        let right = Set(rhs)
        return lhs.filter(right.contains)
    }

    private static func subtract(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func cross(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.y * rhs.z - lhs.z * rhs.y, y: lhs.z * rhs.x - lhs.x * rhs.z, z: lhs.x * rhs.y - lhs.y * rhs.x)
    }

    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func normalized(_ value: OniLevelVector3) -> OniLevelVector3 {
        let length = sqrt(dot(value, value))
        guard length > .leastNonzeroMagnitude else { return value }
        return OniLevelVector3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func vectorDistance(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        let value = subtract(lhs, rhs)
        return sqrt(dot(value, value))
    }
}
