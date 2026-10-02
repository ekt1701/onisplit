import Foundation

package struct OniLevelAnimationClip {
    package let name: String
    package let prefix: String
    package let suffix: String
    package let start: Int
    package let end: Int?
    package let stop: Int
    package let flags: UInt32
}

package struct OniLevelCameraImport {
    package let sourceURL: URL
    package let clips: [OniLevelAnimationClip]
}

package struct OniLevelEnvironmentNodeProperties {
    package let scriptID: Int32
    package let gunkFlags: UInt32
    package let physicsType: UInt32?
    package let objectFlags: UInt32
    package let animationClips: [OniLevelAnimationClip]
    package let particles: [OniLevelEnvironmentParticle]

    package var hasPhysics: Bool {
        physicsType != nil || objectFlags != 0 || !animationClips.isEmpty || !particles.isEmpty
    }
}

package struct OniLevelTextureOption {
    package let name: String
    package let width: Int?
    package let height: Int?
    package let format: String?
    package let flags: String
    package let gunkFlags: UInt32
    package let environmentMap: String?
    package let speed: Int
    package let imageURLs: [URL]
}

package struct OniLevelTextureSettings {
    package let options: [String: OniLevelTextureOption]
    package let defaultFormat: String
    package let defaultAlphaFormat: String
    package let maximumSize: Int
}

package struct OniLevelDefinition {
    package let sourceURL: URL
    package let name: String
    package let sharedDirectory: URL
    package let environmentModels: [URL]
    package let environmentNodeProperties: [String: [String: OniLevelEnvironmentNodeProperties]]
    package let textureSettings: OniLevelTextureSettings
    package let roomModels: [URL]
    package let skyName: String
    package let objectFiles: [URL]
    package let filmFiles: [URL]
    package let cameras: [OniLevelCameraImport]
}

package struct OniLevelObjectBuildResult {
    package let definition: OniLevelDefinition
    package let outputURLs: [URL]
    package let objectCount: Int
    package let runtime: OniLevelRuntimeContent
}

package struct OniLevelBuildResult {
    package let definition: OniLevelDefinition
    package let outputURLs: [URL]
    package let objectCount: Int
    package let furnitureCount: Int
    package let consoleCount: Int
    package let triggerCount: Int
    package let turretCount: Int
    package let environmentPolygonCount: Int
    package let roomCount: Int
    package let objectQuadMapCount: Int
    package let importedTextureCount: Int
    package let copiedTextureCount: Int
    package let scriptCharacterCount: Int
    package let environmentParticleCount: Int
    package let physicsObjectCount: Int
    package let physicsDependencyCount: Int
    package let corpseCount: Int
    package let filmCount: Int
    package let cameraAnimationCount: Int
    package let physicsAnimationCount: Int
}

package struct OniColladaSummary {
    package let sourceURL: URL
    package let unitMeters: Double
    package let upAxis: String
    package let geometryCount: Int
    package let nodeCount: Int
    package let materialCount: Int
    package let imageCount: Int
    package let triangleCount: Int
    package let polygonCount: Int
}

package enum OniLevelBuilder {
    private static let objectTables: [(tag: String, name: String, aliases: Set<String>)] = [
        ("CHAR", "Character", ["CHAR", "Character"]), ("CONS", "Console", ["CONS", "Console"]),
        ("DOOR", "Door", ["DOOR", "Door"]), ("FLAG", "Flag", ["FLAG", "Flag"]),
        ("FURN", "Furniture", ["FURN", "Furniture"]), ("NEUT", "Neutral", ["NEUT", "Neutral"]),
        ("PART", "Particle", ["PART", "Particle"]), ("PATR", "Patrol Path", ["PATR", "Patrol"]),
        ("PWRU", "PowerUp", ["PWRU", "PowerUp"]), ("SNDG", "Sound", ["SNDG", "Sound"]),
        ("TRIG", "Trigger", ["TRIG", "Trigger"]), ("TRGV", "Trigger Volume", ["TRGV", "TriggerVolume"]),
        ("TURR", "Turret", ["TURR", "Turret"]), ("WEAP", "Weapon", ["WEAP", "Weapon"])
    ]

    package static func parse(_ sourceURL: URL) throws -> OniLevelDefinition {
        let data = try Data(contentsOf: sourceURL)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodePreserveAll])
        } catch {
            throw OniNativeXMLError.invalidDocument("level definition: \(error.localizedDescription)")
        }
        guard let oni = document.rootElement(), oni.name == "Oni",
              let level = oni.elements(forName: "Level").first else {
            throw OniNativeXMLError.invalidDocument("level definition must contain <Oni><Level>")
        }

        let base = sourceURL.deletingLastPathComponent()
        let requestedName = level.attribute(forName: "Name")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = requestedName?.isEmpty == false ? requestedName! : sourceURL.deletingPathExtension().lastPathComponent
        let sharedText = level.attribute(forName: "SharedPath")?.stringValue ?? "classes"
        let sharedDirectory = resolve(sharedText, relativeTo: base, directory: true)

        guard let environment = level.elements(forName: "Environment").first,
              let model = environment.elements(forName: "Model").first,
              let rooms = environment.elements(forName: "Rooms").first else {
            throw OniNativeXMLError.invalidDocument("level definition requires Environment, Model, and Rooms")
        }
        let modelImports = try environmentImports(in: model, relativeTo: base)
        let environmentModels = modelImports.map(\.url)
        let environmentNodeProperties = Dictionary(uniqueKeysWithValues: modelImports.map {
            ($0.url.standardizedFileURL.path, $0.nodeProperties)
        })
        let roomModels = imports(in: rooms, relativeTo: base)
        let textureSettings = try levelTextureSettings(environment: environment, model: model, relativeTo: base)
        guard !environmentModels.isEmpty else {
            throw OniNativeXMLError.invalidDocument("level Model does not contain an Import")
        }
        guard !roomModels.isEmpty else {
            throw OniNativeXMLError.invalidDocument("level Rooms does not contain an Import")
        }

        let skyName = level.elements(forName: "Sky").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !skyName.isEmpty else { throw OniNativeXMLError.invalidDocument("level definition requires Sky") }
        let objectFiles = level.elements(forName: "Objects").first.map { imports(in: $0, relativeTo: base) } ?? []
        let filmFiles = level.elements(forName: "Films").first.map { imports(in: $0, relativeTo: base) } ?? []
        let modelCameras = try cameraImports(in: model, relativeTo: base)
        let sectionCameras = try level.elements(forName: "Cameras").first.map {
            try cameraImports(in: $0, relativeTo: base)
        } ?? []
        let cameras = modelCameras + sectionCameras

        for url in environmentModels + roomModels + objectFiles + filmFiles + cameras.map(\.sourceURL) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw OniNativeXMLError.invalidDocument("referenced file does not exist: \(url.path)")
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sharedDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OniNativeXMLError.invalidDocument("SharedPath does not exist: \(sharedDirectory.path)")
        }

        return OniLevelDefinition(
            sourceURL: sourceURL, name: name, sharedDirectory: sharedDirectory,
            environmentModels: environmentModels, environmentNodeProperties: environmentNodeProperties,
            textureSettings: textureSettings,
            roomModels: roomModels,
            skyName: skyName, objectFiles: objectFiles, filmFiles: filmFiles, cameras: cameras
        )
    }

    package static func buildObjectTables(from sourceURL: URL, outputDirectory: URL) throws -> OniLevelObjectBuildResult {
        let definition = try parse(sourceURL)
        var runtime = try OniLevelRuntimeReader.read(definition.objectFiles)
        runtime.physicsObjects += try OniLevelRuntimeReader.readEnvironmentPhysics(
            models: definition.environmentModels,
            propertiesByModel: definition.environmentNodeProperties
        )
        var records: [(tag: String, element: XMLElement)] = []
        var nextObjectID = 1
        for objectURL in definition.objectFiles {
            let document: XMLDocument
            do {
                document = try XMLDocument(data: Data(contentsOf: objectURL), options: [.nodePreserveAll])
            } catch {
                throw OniNativeXMLError.invalidDocument("object file \(objectURL.lastPathComponent): \(error.localizedDescription)")
            }
            guard let root = document.rootElement(), root.name == "Oni" else {
                throw OniNativeXMLError.invalidDocument("object file \(objectURL.lastPathComponent) must contain <Oni>")
            }
            guard let objects = root.elements(forName: "Objects").first else { continue }
            for sourceRecord in objects.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                guard let table = objectTables.first(where: { $0.aliases.contains(sourceRecord.name ?? "") }) else { continue }
                if table.tag == "FURN", !furnitureClassExists(
                    sourceRecord, sourceDirectory: objectURL.deletingLastPathComponent(), sharedDirectory: definition.sharedDirectory
                ) { continue }
                let record = sourceRecord.copy() as! XMLElement
                normalizeLegacyRecord(record, originalName: sourceRecord.name ?? "")
                record.name = table.tag
                if let id = record.attribute(forName: "Id") { id.stringValue = String(nextObjectID) }
                else { record.addAttribute(XMLNode.attribute(withName: "Id", stringValue: String(nextObjectID)) as! XMLNode) }
                normalizeLegacyClassPath(in: record, tag: table.tag)
                records.append((table.tag, record))
                nextObjectID += 1
            }
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var outputURLs: [URL] = []
        for table in objectTables {
            let fileName = "BINACJBO\(table.name).oni"
            let root = XMLElement(name: "Oni")
            let document = XMLDocument(rootElement: root)
            document.version = "1.0"
            document.characterEncoding = "utf-8"
            let objects = XMLElement(name: "Objects")
            objects.addAttribute(XMLNode.attribute(withName: "source", stringValue: fileName) as! XMLNode)
            root.addChild(objects)
            for record in records where record.tag == table.tag {
                objects.addChild(record.element.copy() as! XMLNode)
            }
            let archive: OniNativeXMLArchive
            do {
                archive = try OniNativeXMLArchive.load(
                    from: document.xmlData(options: [.nodePrettyPrint]),
                    sourceFileName: fileName + ".xml",
                    resourceBaseURL: sourceURL.deletingLastPathComponent()
                )
            } catch {
                throw OniNativeXMLError.invalidDocument("\(table.name) object table: \(error)")
            }
            let outputURL = outputDirectory.appendingPathComponent(fileName)
            try archive.archiveData.write(to: outputURL, options: .atomic)
            outputURLs.append(outputURL)
        }
        return OniLevelObjectBuildResult(
            definition: definition, outputURLs: outputURLs,
            objectCount: records.count, runtime: runtime
        )
    }

    private static func normalizeLegacyClassPath(in record: XMLElement, tag: String) {
        guard ["CONS", "DOOR", "FURN", "TRIG", "TURR"].contains(tag),
              let value = record.elements(forName: "OSD").first?.elements(forName: "Class").first,
              let original = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              original.lowercased().hasSuffix(".oni") else { return }
        var name = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let prefix = tag == "FURN" ? "OFGA" : tag
        if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        value.stringValue = name
    }

    private static func normalizeLegacyRecord(_ record: XMLElement, originalName: String) {
        guard originalName == "Particle",
              let flags = record.elements(forName: "OSD").first?.elements(forName: "Flags").first else { return }
        let text = flags.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let number = Int(text) { flags.stringValue = String(number & 0x0002) }
        else if text.caseInsensitiveCompare("NotInitiallyCreated") == .orderedSame { flags.stringValue = "2" }
        else if text.isEmpty || text.caseInsensitiveCompare("None") == .orderedSame { flags.stringValue = "0" }
    }

    private static func furnitureClassExists(
        _ record: XMLElement, sourceDirectory: URL, sharedDirectory: URL
    ) -> Bool {
        guard let value = record.elements(forName: "OSD").first?.elements(forName: "Class").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        let manager = FileManager.default
        if value.lowercased().hasSuffix(".oni") {
            if manager.fileExists(atPath: sourceDirectory.appendingPathComponent(value).standardizedFileURL.path)
                || manager.fileExists(atPath: sharedDirectory.appendingPathComponent(value).standardizedFileURL.path) { return true }
        }
        var name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        if name.lowercased().hasPrefix("ofga") { name = String(name.dropFirst(4)) }
        let wanted = ("OFGA" + name + ".oni").lowercased()
        let files = (try? manager.contentsOfDirectory(at: sharedDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.lastPathComponent.lowercased() == wanted }
    }

    package static func buildLevel(
        from sourceURL: URL, outputDirectory: URL, debug: Bool = false
    ) throws -> OniLevelBuildResult {
        let objects = try buildObjectTables(from: sourceURL, outputDirectory: outputDirectory)
        let definition = objects.definition
        let environment = try definition.environmentModels.map { url in
            let document = try OniColladaGeometryReader.read(url)
            return applyingEnvironmentNodeProperties(
                definition.environmentNodeProperties[url.standardizedFileURL.path] ?? [:], to: document
            )
        }
        let roomDocuments = try definition.roomModels.map(OniColladaGeometryReader.read)
        let roomGeometry = OniRoomGeometryBuilder.build(from: roomDocuments)
        let topology = OniRoomTopologyBuilder.build(from: roomGeometry)
        guard !topology.rooms.isEmpty else {
            throw OniNativeXMLError.invalidDocument("level does not contain any valid rooms")
        }
        let furniture = try OniGunkGeometryBuilder.build(from: definition)
        let runtimePhysicsObjects = try OniLevelPhysicsDependencyBuilder.resolveSharedGeometry(
            objects: objects.runtime.physicsObjects + furniture.doorPhysicsObjects,
            sharedDirectory: definition.sharedDirectory
        )
        let environmentParticles = objects.runtime.particles + furniture.furnitureParticles
        let completeEnvironment = (environment + furniture.documents).map {
            applyingTextureOptions(definition.textureSettings.options, to: $0)
        }
        let grids = OniRoomGridBuilder.build(topology: topology, environment: completeEnvironment)
        guard grids.oversizedRoomIndices.isEmpty else {
            let values = grids.oversizedRoomIndices.map(String.init).joined(separator: ", ")
            throw OniNativeXMLError.invalidDocument("room grids exceed Oni's 256x256 limit: \(values)")
        }
        let akev = OniAKEVBuilder.build(
            name: definition.name,
            environment: completeEnvironment,
            roomGeometry: roomGeometry,
            topology: topology,
            grids: grids.grids,
            debug: debug
        )
        let akevURL = outputDirectory.appendingPathComponent(akev.fileName)
        try akev.archiveData.write(to: akevURL, options: .atomic)
        let physicsAnimations = try OniLevelCameraBuilder.buildPhysics(
            objects: runtimePhysicsObjects, outputDirectory: outputDirectory,
            sharedDirectory: definition.sharedDirectory
        )
        let physicsObjects = physicsAnimations.objects
        let onlv = try OniONLVBuilder.build(
            name: definition.name,
            skyName: definition.skyName,
            geometry: akev.geometry,
            physicsObjects: physicsObjects,
            characters: objects.runtime.characters,
            particles: environmentParticles,
            corpses: objects.runtime.corpses
        )
        let onlvURL = outputDirectory.appendingPathComponent(onlv.fileName)
        try onlv.archiveData.write(to: onlvURL, options: .atomic)
        let textures = try OniLevelTextureBuilder.build(
            definition: definition,
            geometry: akev.geometry,
            additionalSharedTextureNames: furniture.textureNames,
            additionalModelURLs: physicsObjects.compactMap(\.importedGeometryURL),
            outputDirectory: outputDirectory
        )
        let physicsDependencies = try OniLevelPhysicsDependencyBuilder.copy(
            objects: physicsObjects,
            sharedDirectory: definition.sharedDirectory,
            outputDirectory: outputDirectory
        )
        let films = try OniLevelFilmBuilder.build(imports: definition.filmFiles, outputDirectory: outputDirectory)
        let cameras = try OniLevelCameraBuilder.build(imports: definition.cameras, outputDirectory: outputDirectory)
        var allOutputs = objects.outputURLs
        allOutputs += [akevURL, onlvURL]
        allOutputs += textures.outputURLs
        allOutputs += physicsAnimations.outputURLs
        allOutputs += physicsDependencies
        allOutputs += films.outputURLs
        allOutputs += cameras.outputURLs
        var seenOutputs = Set<String>()
        let uniqueOutputs = allOutputs.filter { seenOutputs.insert($0.standardizedFileURL.path).inserted }
        return OniLevelBuildResult(
            definition: definition,
            outputURLs: uniqueOutputs,
            objectCount: objects.objectCount,
            furnitureCount: furniture.furnitureCount,
            consoleCount: furniture.consoleCount,
            triggerCount: furniture.triggerCount,
            turretCount: furniture.turretCount,
            environmentPolygonCount: akev.geometry.polygons.count,
            roomCount: topology.rooms.count,
            objectQuadMapCount: onlv.objectQuadMapCount,
            importedTextureCount: textures.importedCount,
            copiedTextureCount: textures.copiedCount,
            scriptCharacterCount: objects.runtime.characters.count,
            environmentParticleCount: environmentParticles.count,
            physicsObjectCount: physicsObjects.count,
            physicsDependencyCount: physicsDependencies.count,
            corpseCount: objects.runtime.corpses.count,
            filmCount: films.filmCount,
            cameraAnimationCount: cameras.animationCount,
            physicsAnimationCount: physicsAnimations.animationCount
        )
    }

    package static func inspectCollada(_ sourceURL: URL) throws -> OniColladaSummary {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: Data(contentsOf: sourceURL), options: [.nodePreserveAll])
        } catch {
            throw OniNativeXMLError.invalidDocument("Collada file \(sourceURL.lastPathComponent): \(error.localizedDescription)")
        }
        guard document.rootElement()?.localName == "COLLADA" || document.rootElement()?.name == "COLLADA" else {
            throw OniNativeXMLError.invalidDocument("\(sourceURL.lastPathComponent) is not a COLLADA document")
        }
        func nodes(_ name: String) throws -> [XMLNode] {
            try document.nodes(forXPath: "//*[local-name()='\(name)']")
        }
        func count(_ name: String) throws -> Int { try nodes(name).count }
        func attribute(_ node: XMLNode?, _ name: String) -> String? {
            (node as? XMLElement)?.attribute(forName: name)?.stringValue
        }
        func summedCount(_ name: String) throws -> Int {
            try nodes(name).reduce(0) { $0 + (Int(attribute($1, "count") ?? "") ?? 0) }
        }
        let unit = try nodes("unit").first
        let axis = try nodes("up_axis").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Y_UP"
        return OniColladaSummary(
            sourceURL: sourceURL,
            unitMeters: Double(attribute(unit, "meter") ?? "1") ?? 1,
            upAxis: axis,
            geometryCount: try count("geometry"),
            nodeCount: try count("node"),
            materialCount: try count("material"),
            imageCount: try count("image"),
            triangleCount: try summedCount("triangles"),
            polygonCount: try summedCount("polylist")
        )
    }

    private static func imports(in parent: XMLElement, relativeTo base: URL) -> [URL] {
        parent.elements(forName: "Import").compactMap { element in
            let text = element.attribute(forName: "Path")?.stringValue ?? element.stringValue
            guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return resolve(value, relativeTo: base, directory: false)
        }
    }

    private struct MutableTextureOption {
        var name: String
        var width: Int?
        var height: Int?
        var format: String?
        var flags = ""
        var gunkFlags: UInt32 = 0
        var environmentMap: String?
        var speed = 1
        var imageURLs: [URL] = []

        var value: OniLevelTextureOption {
            OniLevelTextureOption(
                name: name, width: width, height: height, format: format,
                flags: flags, gunkFlags: gunkFlags, environmentMap: environmentMap,
                speed: speed, imageURLs: imageURLs
            )
        }
    }

    private struct MutableTextureSettings {
        var options: [String: MutableTextureOption] = [:]
        var defaultFormat = "BGR"
        var defaultAlphaFormat = "RGBA"
        var maximumSize = 512
    }

    private static func levelTextureSettings(
        environment: XMLElement, model: XMLElement, relativeTo base: URL
    ) throws -> OniLevelTextureSettings {
        var settings = MutableTextureSettings()
        for texture in model.elements(forName: "Texture") {
            try readTextureOption(texture, relativeTo: base, settings: &settings)
        }
        if let textures = environment.elements(forName: "Textures").first {
            try readTextureContainer(textures, relativeTo: base, settings: &settings)
        }
        return OniLevelTextureSettings(
            options: settings.options.mapValues(\.value),
            defaultFormat: settings.defaultFormat,
            defaultAlphaFormat: settings.defaultAlphaFormat,
            maximumSize: settings.maximumSize
        )
    }

    private static func readTextureContainer(
        _ container: XMLElement, relativeTo base: URL, settings: inout MutableTextureSettings
    ) throws {
        if let value = container.attribute(forName: "Format")?.stringValue, !value.isEmpty {
            settings.defaultFormat = value
        }
        if let value = container.attribute(forName: "AlphaFormat")?.stringValue, !value.isEmpty {
            settings.defaultAlphaFormat = value
        }
        if let value = container.attribute(forName: "MaxSize")?.stringValue, !value.isEmpty {
            guard let size = Int(value), size > 0 else {
                throw OniNativeXMLError.invalidDocument("Textures MaxSize requires a positive integer")
            }
            settings.maximumSize = size
        }
        for element in container.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch element.name {
            case "Texture":
                try readTextureOption(element, relativeTo: base, settings: &settings)
            case "Import":
                let path = element.attribute(forName: "Path")?.stringValue
                    ?? element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                guard !path.isEmpty else {
                    throw OniNativeXMLError.invalidDocument("Textures Import requires a path")
                }
                let url = resolve(path, relativeTo: base, directory: false)
                let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
                guard let root = document.rootElement(), root.name == "Oni",
                      let imported = root.elements(forName: "Textures").first else {
                    throw OniNativeXMLError.invalidDocument("texture settings file must contain <Oni><Textures>")
                }
                try readTextureContainer(
                    imported, relativeTo: url.deletingLastPathComponent(), settings: &settings
                )
            default:
                continue
            }
        }
    }

    private static func readTextureOption(
        _ element: XMLElement, relativeTo base: URL, settings: inout MutableTextureSettings
    ) throws {
        let name = element.attribute(forName: "Name")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw OniNativeXMLError.invalidDocument("Texture requires a Name") }
        let key = normalizedTextureName(name)
        var option = settings.options[key] ?? MutableTextureOption(name: name)
        option.name = name
        func text(_ childName: String) -> String? {
            element.elements(forName: childName).first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func dimension(_ childName: String) throws -> Int? {
            guard let value = text(childName), !value.isEmpty else { return nil }
            guard let result = Int(value), result > 0 else {
                throw OniNativeXMLError.invalidDocument("Texture \(childName) requires a positive integer")
            }
            return result
        }
        if let width = try dimension("Width") { option.width = width }
        if let height = try dimension("Height") { option.height = height }
        if let format = text("Format"), !format.isEmpty { option.format = format }
        if let flags = text("Flags") { option.flags = flags }
        if let flags = text("GunkFlags") { option.gunkFlags = try environmentGunkFlags(flags) }
        if let environmentMap = text("EnvMap") { option.environmentMap = environmentMap.isEmpty ? nil : environmentMap }
        if let speedText = text("Speed"), !speedText.isEmpty {
            guard let speed = Int(speedText), Int16(exactly: speed) != nil else {
                throw OniNativeXMLError.invalidDocument("Texture Speed requires a signed 16-bit integer")
            }
            option.speed = speed
        }
        option.imageURLs = element.elements(forName: "Image").compactMap { image in
            guard let value = image.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return resolve(value, relativeTo: base, directory: false)
        }
        settings.options[key] = option
    }

    private static func normalizedTextureName(_ name: String) -> String {
        let value = name.lowercased().hasPrefix("txmp") ? String(name.dropFirst(4)) : name
        return value.lowercased()
    }

    private static func environmentImports(
        in parent: XMLElement, relativeTo base: URL
    ) throws -> [(url: URL, nodeProperties: [String: OniLevelEnvironmentNodeProperties])] {
        let elements = parent.children?.compactMap { $0 as? XMLElement }.filter {
            $0.name == "Import" || $0.name == "Scene"
        } ?? []
        return try elements.compactMap { element in
            let rawPath = element.attribute(forName: "Path")?.stringValue ?? element.stringValue
            guard let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            let sourceURL = resolve(path, relativeTo: base, directory: false)
            var properties: [String: OniLevelEnvironmentNodeProperties] = [:]
            let rootScriptText = element.elements(forName: "ScriptId").first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            guard let rootScriptID = Int32(rootScriptText) else {
                throw OniNativeXMLError.invalidDocument("Environment Import ScriptId requires a signed 32-bit integer")
            }
            let rootGunkFlags = try environmentGunkFlags(
                element.elements(forName: "GunkFlags").first?.stringValue ?? ""
            )
            if rootScriptID != 0 || rootGunkFlags != 0,
               let sceneID = try colladaSceneID(sourceURL) {
                properties[sceneID] = OniLevelEnvironmentNodeProperties(
                    scriptID: rootScriptID, gunkFlags: rootGunkFlags,
                    physicsType: nil, objectFlags: 0, animationClips: [], particles: []
                )
            }
            for node in element.elements(forName: "Node") {
                let id = node.attribute(forName: "Id")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !id.isEmpty else { throw OniNativeXMLError.invalidDocument("Environment Node requires an Id") }
                let scriptText = node.elements(forName: "ScriptId").first?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? String(rootScriptID)
                guard let scriptID = Int32(scriptText) else {
                    throw OniNativeXMLError.invalidDocument("Environment Node ScriptId requires a signed 32-bit integer")
                }
                let nodeGunkFlags = try environmentGunkFlags(
                    node.elements(forName: "GunkFlags").first?.stringValue ?? ""
                )
                let physicsType = try node.elements(forName: "Physics").first.map { element -> UInt32 in
                    try environmentEnumValue(
                        element.stringValue ?? "", names: [
                            "None": 0, "Static": 1, "Linear": 2, "Animated": 3, "Newton": 4
                        ], field: "Environment Node Physics"
                    )
                }
                let objectFlags = try node.elements(forName: "ObjectFlags").first.map { element in
                    try environmentEnumValue(
                        element.stringValue ?? "", names: [
                            "InUse": 0x200, "NoCollision": 0x400,
                            "NoGravity": 0x800, "FaceCollision": 0x1000
                        ], field: "Environment Node ObjectFlags"
                    ) & ~0x200
                } ?? 0
                let clips = try animationClips(in: node, context: "Environment Node")
                let particles = try node.elements(forName: "Particles").first.map { container in
                    try container.elements(forName: "Particle").map(OniLevelRuntimeReader.readParticle)
                } ?? []
                properties[id] = OniLevelEnvironmentNodeProperties(
                    scriptID: scriptID, gunkFlags: rootGunkFlags | nodeGunkFlags,
                    physicsType: physicsType, objectFlags: objectFlags,
                    animationClips: clips, particles: particles
                )
            }
            return (sourceURL, properties)
        }
    }

    private static func colladaSceneID(_ sourceURL: URL) throws -> String? {
        let document = try XMLDocument(data: Data(contentsOf: sourceURL), options: [.nodePreserveAll])
        let selected = try document.nodes(
            forXPath: "//*[local-name()='scene']/*[local-name()='instance_visual_scene']/@url"
        ).first?.stringValue
        if let selected, !selected.isEmpty {
            return selected.hasPrefix("#") ? String(selected.dropFirst()) : selected
        }
        return try document.nodes(
            forXPath: "//*[local-name()='library_visual_scenes']/*[local-name()='visual_scene']/@id"
        ).first?.stringValue
    }

    private static func environmentGunkFlags(_ value: String) throws -> UInt32 {
        let names: [String: UInt32] = [
            "DoorFrame": 0x0000_0001, "Ghost": 0x0000_0002, "StairsUp": 0x0000_0004,
            "StairsDown": 0x0000_0008, "Stairs": 0x0000_0010, "Transparent": 0x0000_0080,
            "TwoSided": 0x0000_0200, "NoCollision": 0x0000_0800, "Invisible": 0x0000_2000,
            "NoObjectCollision": 0x0000_4000, "NoCharacterCollision": 0x0000_8000,
            "NoOcclusion": 0x0001_0000, "Danger": 0x0002_0000, "GridIgnore": 0x0040_0000,
            "NoDecals": 0x0080_0000, "Furniture": 0x0100_0000,
            "SoundTransparent": 0x0800_0000, "Impassable": 0x1000_0000
        ]
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.caseInsensitiveCompare("None") == .orderedSame { return 0 }
        if text.lowercased().hasPrefix("0x"), let number = UInt32(text.dropFirst(2), radix: 16) { return number }
        if let number = UInt32(text) { return number }
        let normalized = Dictionary(uniqueKeysWithValues: names.map { ($0.key.lowercased(), $0.value) })
        var result: UInt32 = 0
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
            guard let flag = normalized[String(token).lowercased()] else {
                throw OniNativeXMLError.invalidDocument("unknown Environment GunkFlags value '\(token)'")
            }
            result |= flag
        }
        return result
    }

    private static func environmentEnumValue(
        _ value: String, names: [String: UInt32], field: String
    ) throws -> UInt32 {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.caseInsensitiveCompare("None") == .orderedSame { return 0 }
        if text.lowercased().hasPrefix("0x"), let number = UInt32(text.dropFirst(2), radix: 16) { return number }
        if let number = UInt32(text) { return number }
        let normalized = Dictionary(uniqueKeysWithValues: names.map { ($0.key.lowercased(), $0.value) })
        var result: UInt32 = 0
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
            guard let flag = normalized[String(token).lowercased()] else {
                throw OniNativeXMLError.invalidDocument("unknown \(field) value '\(token)'")
            }
            result |= flag
        }
        return result
    }

    package static func applyingEnvironmentNodeProperties(
        _ properties: [String: OniLevelEnvironmentNodeProperties],
        to document: OniColladaGeometryDocument
    ) -> OniColladaGeometryDocument {
        guard !properties.isEmpty else { return document }
        let instances = document.instances.compactMap { instance -> OniColladaGeometryInstance? in
            let inheritedProperties = instance.ancestorIDs.compactMap { properties[$0] }
            if inheritedProperties.contains(where: \.hasPhysics) { return nil }
            guard let values = inheritedProperties.last else { return instance }
            return OniColladaGeometryInstance(
                nodeName: instance.nodeName, nodeID: instance.nodeID,
                ancestorIDs: instance.ancestorIDs, geometryID: instance.geometryID,
                materialNames: instance.materialNames,
                polygons: instance.polygons.map { polygon in
                    OniColladaPolygon(
                        positions: polygon.positions, normals: polygon.normals,
                        textureCoordinates: polygon.textureCoordinates,
                        materialSymbol: polygon.materialSymbol,
                        additionalFlags: polygon.additionalFlags | values.gunkFlags,
                        objectID: polygon.objectID, scriptID: values.scriptID
                    )
                }
            )
        }
        return OniColladaGeometryDocument(
            sourceURL: document.sourceURL, unitScale: document.unitScale, upAxis: document.upAxis,
            geometries: document.geometries, instances: instances,
            transparentMaterialNames: document.transparentMaterialNames
        )
    }

    package static func applyingTextureOptions(
        _ options: [String: OniLevelTextureOption], to document: OniColladaGeometryDocument
    ) -> OniColladaGeometryDocument {
        guard !options.isEmpty else { return document }
        let instances = document.instances.map { instance in
            OniColladaGeometryInstance(
                nodeName: instance.nodeName, nodeID: instance.nodeID,
                ancestorIDs: instance.ancestorIDs, geometryID: instance.geometryID,
                materialNames: instance.materialNames,
                polygons: instance.polygons.map { polygon in
                    let key = normalizedTextureName(polygon.materialSymbol)
                    guard let option = options[key] else { return polygon }
                    let alphaFlags: UInt32
                    switch option.format?.uppercased() {
                    case "BGRA4444", "BGRA5551", "RGBA":
                        alphaFlags = 0x0000_0080 | 0x0000_0200 | 0x0001_0000
                    default:
                        alphaFlags = 0
                    }
                    return OniColladaPolygon(
                        positions: polygon.positions, normals: polygon.normals,
                        textureCoordinates: polygon.textureCoordinates,
                        materialSymbol: polygon.materialSymbol,
                        additionalFlags: polygon.additionalFlags | option.gunkFlags | alphaFlags,
                        objectID: polygon.objectID, scriptID: polygon.scriptID
                    )
                }
            )
        }
        return OniColladaGeometryDocument(
            sourceURL: document.sourceURL, unitScale: document.unitScale, upAxis: document.upAxis,
            geometries: document.geometries, instances: instances,
            transparentMaterialNames: document.transparentMaterialNames
        )
    }

    private static func cameraImports(in parent: XMLElement, relativeTo base: URL) throws -> [OniLevelCameraImport] {
        try parent.elements(forName: "Camera").map { camera in
            let path = camera.attribute(forName: "Path")?.stringValue ?? camera.attribute(forName: "Url")?.stringValue ?? ""
            guard !path.isEmpty else { throw OniNativeXMLError.invalidDocument("Camera requires a Path attribute") }
            let clips = try animationClips(in: camera, context: "Camera")
            guard !clips.isEmpty else { throw OniNativeXMLError.invalidDocument("Camera requires at least one Animation") }
            return OniLevelCameraImport(sourceURL: resolve(path, relativeTo: base, directory: false), clips: clips)
        }
    }

    package static func animationClips(in parent: XMLElement, context: String) throws -> [OniLevelAnimationClip] {
        try parent.elements(forName: "Animation").map { animation in
            let name = animation.attribute(forName: "Name")?.stringValue ?? ""
            guard !name.isEmpty else { throw OniNativeXMLError.invalidDocument("\(context) Animation requires a Name") }
            func value(_ childName: String) -> String {
                animation.elements(forName: childName).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            func integer(_ childName: String, default defaultValue: Int) throws -> Int {
                let text = value(childName)
                guard !text.isEmpty else { return defaultValue }
                guard let result = Int(text) else {
                    throw OniNativeXMLError.invalidDocument("\(context) Animation \(childName) requires an integer")
                }
                return result
            }
            let flagNames: [String: UInt32] = ["Loop": 1, "PingPong": 2, "RandomStart": 4, "AutoStart": 8, "Local": 16]
            var flags: UInt32 = 0
            for token in value("Flags").split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
                guard let flag = flagNames[String(token)] else {
                    throw OniNativeXMLError.invalidDocument("unknown \(context) Animation flag '\(token)'")
                }
                flags |= flag
            }
            let endText = value("End")
            return OniLevelAnimationClip(
                name: name, prefix: value("Prefix"), suffix: value("Suffix"),
                start: try integer("Start", default: 0), end: endText.isEmpty ? nil : try integer("End", default: 0),
                stop: try integer("Stop", default: 0), flags: flags
            )
        }
    }

    private static func resolve(_ path: String, relativeTo base: URL, directory: Bool) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: directory).standardizedFileURL }
        return base.appendingPathComponent(path, isDirectory: directory).standardizedFileURL
    }
}
