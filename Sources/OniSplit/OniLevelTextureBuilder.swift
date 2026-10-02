import Foundation

package struct OniLevelTextureBuildResult {
    package let outputURLs: [URL]
    package let importedCount: Int
    package let copiedCount: Int
}

package enum OniLevelTextureBuilder {
    private struct SourceTexture {
        let name: String
        let imageURLs: [URL]
        let transparent: Bool
    }

    private static let standardSharedTextures = [
        "NONE", "_marker_barrier", "_marker_blackness", "_marker_danger",
        "_marker_door", "_marker_ghost", "_marker_impassable", "_marker_stairs",
        "notfoundtex"
    ]

    package static func build(
        definition: OniLevelDefinition,
        geometry: OniAkiraGeometry,
        additionalSharedTextureNames: [String] = [],
        additionalModelURLs: [URL] = [],
        outputDirectory: URL
    ) throws -> OniLevelTextureBuildResult {
        var sources: [String: SourceTexture] = [:]
        var sourceOrder: [String] = []
        for modelURL in definition.environmentModels + additionalModelURLs {
            for source in try readSources(modelURL) {
                let key = normalizedTextureName(source.name)
                if sources[key] == nil { sourceOrder.append(key); sources[key] = source }
            }
        }
        for (key, option) in definition.textureSettings.options where !option.imageURLs.isEmpty {
            if sources[key] == nil { sourceOrder.append(key) }
            sources[key] = SourceTexture(
                name: option.name, imageURLs: option.imageURLs,
                transparent: isAlphaFormat(option.format)
            )
        }

        var outputURLs: [URL] = []
        var writtenNames = Set<String>()
        var importedCount = 0
        for key in sourceOrder {
            guard let source = sources[key] else { continue }
            let option = definition.textureSettings.options[normalizedTextureName(source.name)]
            let outputName = source.name.lowercased().hasPrefix("txmp") ? source.name : "TXMP" + source.name
            let destination = outputDirectory.appendingPathComponent(outputName + ".oni")
            let texture = XMLElement(name: "Texture")
            let flags = ["HasMipMaps", option?.flags ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            texture.addChild(XMLElement(name: "Flags", stringValue: flags))
            let format = option?.format ?? (source.transparent
                ? definition.textureSettings.defaultAlphaFormat
                : definition.textureSettings.defaultFormat)
            texture.addChild(XMLElement(name: "Format", stringValue: format))
            let dimensions = try OniTextureXMLImporter.imageDimensions(at: source.imageURLs[0])
            var width = option?.width ?? dimensions.width
            var height = option?.height ?? dimensions.height
            guard width <= dimensions.width, height <= dimensions.height else {
                throw OniNativeXMLError.invalidDocument("Texture \(source.name) cannot be upscaled")
            }
            let maximum = definition.textureSettings.maximumSize
            if width > maximum || height > maximum {
                if width > height {
                    height = maximum * height / width
                    width = maximum
                } else {
                    width = maximum * width / height
                    height = maximum
                }
            }
            width = floorPowerOfTwo(width)
            height = floorPowerOfTwo(height)
            texture.addChild(XMLElement(name: "Width", stringValue: String(width)))
            texture.addChild(XMLElement(name: "Height", stringValue: String(height)))
            if let environmentMap = option?.environmentMap {
                texture.addChild(XMLElement(name: "EnvMap", stringValue: environmentMap))
            }
            if let option, option.speed != 1 {
                texture.addChild(XMLElement(name: "Speed", stringValue: String(option.speed)))
            }
            for imageURL in source.imageURLs {
                texture.addChild(XMLElement(name: "Image", stringValue: imageURL.path))
            }
            let archive = try OniTextureXMLImporter.build(
                texture: texture,
                sourceFileName: destination.lastPathComponent + ".xml",
                resourceBaseURL: source.imageURLs[0].deletingLastPathComponent()
            )
            try archive.archiveData.write(to: destination, options: .atomic)
            outputURLs.append(destination)
            writtenNames.insert(outputName.lowercased())
            importedCount += 1
        }

        let sharedFiles = try FileManager.default.contentsOfDirectory(
            at: definition.sharedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let sharedMap = Dictionary(sharedFiles.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let requested = geometry.materials + additionalSharedTextureNames + standardSharedTextures
        var copiedCount = 0
        let textureWorkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "onisplit-textures-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: textureWorkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: textureWorkDirectory) }
        for material in requested {
            let fullName = material.lowercased().hasPrefix("txmp") ? material : "TXMP" + material
            let key = (fullName + ".oni").lowercased()
            guard !writtenNames.contains(fullName.lowercased()), let source = sharedMap[key] else { continue }
            let destination = outputDirectory.appendingPathComponent(source.lastPathComponent)
            let sourceFile = try OniDatFile.load(from: source)
            let mainTexture = sourceFile.instances.first {
                $0.templateTag == "TXMP" && $0.descriptorFlags & 2 == 0 && !$0.fullName.isEmpty
            }
            let hasMipMaps = mainTexture.map {
                $0.dataSize >= 132 && readUInt32(sourceFile.data, $0.dataOffset + 128) & 1 != 0
            } ?? true
            if hasMipMaps {
                try FileManager.default.copyItemReplacingExisting(at: source, to: destination)
                copiedCount += 1
            } else {
                let exported = try OniTextureXMLExporter.export(file: sourceFile)
                for image in exported.images {
                    try image.data.write(
                        to: textureWorkDirectory.appendingPathComponent(image.fileName), options: .atomic
                    )
                }
                let document = try XMLDocument(data: exported.xml, options: [.nodePreserveAll])
                guard let texture = document.rootElement()?.elements(forName: "Texture").first else {
                    throw OniNativeXMLError.invalidDocument("could not rebuild shared texture \(source.lastPathComponent)")
                }
                if let flags = texture.elements(forName: "Flags").first {
                    let old = flags.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    flags.stringValue = ["HasMipMaps", old].filter { !$0.isEmpty }.joined(separator: " ")
                } else {
                    texture.addChild(XMLElement(name: "Flags", stringValue: "HasMipMaps"))
                }
                let rebuilt = try OniTextureXMLImporter.build(
                    texture: texture, sourceFileName: source.lastPathComponent + ".xml",
                    resourceBaseURL: textureWorkDirectory
                )
                try rebuilt.archiveData.write(to: destination, options: .atomic)
                importedCount += 1
            }
            outputURLs.append(destination)
            writtenNames.insert(fullName.lowercased())
        }
        return OniLevelTextureBuildResult(outputURLs: outputURLs, importedCount: importedCount, copiedCount: copiedCount)
    }

    private static func readSources(_ sourceURL: URL) throws -> [SourceTexture] {
        let document = try XMLDocument(data: Data(contentsOf: sourceURL), options: [.nodePreserveAll])
        let images = try document.nodes(forXPath: "//*[local-name()='library_images']/*[local-name()='image']")
            .compactMap { $0 as? XMLElement }
        var imagePaths: [String: URL] = [:]
        for image in images {
            guard let id = image.attribute(forName: "id")?.stringValue,
                  let path = try image.nodes(forXPath: "./*[local-name()='init_from']").first?.stringValue,
                  !path.isEmpty else { continue }
            imagePaths[id] = resolveImage(path, relativeTo: sourceURL.deletingLastPathComponent())
        }

        var effectImages: [String: (imageID: String, transparent: Bool)] = [:]
        let effects = try document.nodes(forXPath: "//*[local-name()='library_effects']/*[local-name()='effect']")
            .compactMap { $0 as? XMLElement }
        for effect in effects {
            guard let effectID = effect.attribute(forName: "id")?.stringValue,
                  let diffuseTexture = try effect.nodes(forXPath: ".//*[local-name()='diffuse']/*[local-name()='texture']").first as? XMLElement,
                  let samplerID = diffuseTexture.attribute(forName: "texture")?.stringValue else { continue }
            let parameters = try effect.nodes(forXPath: ".//*[local-name()='newparam']").compactMap { $0 as? XMLElement }
            guard let sampler = parameters.first(where: { $0.attribute(forName: "sid")?.stringValue == samplerID }),
                  let surfaceID = try sampler.nodes(forXPath: "./*[local-name()='sampler2D']/*[local-name()='source']").first?.stringValue,
                  let surface = parameters.first(where: { $0.attribute(forName: "sid")?.stringValue == surfaceID }),
                  let imageID = try surface.nodes(forXPath: "./*[local-name()='surface']/*[local-name()='init_from']").first?.stringValue else { continue }
            let transparentSampler = try effect.nodes(forXPath: ".//*[local-name()='transparent']/*[local-name()='texture']/@texture").first?.stringValue
            effectImages[effectID] = (imageID, transparentSampler == samplerID)
        }

        var result: [SourceTexture] = []
        let materials = try document.nodes(forXPath: "//*[local-name()='library_materials']/*[local-name()='material']")
            .compactMap { $0 as? XMLElement }
        for material in materials {
            guard let effectTarget = try material.nodes(forXPath: "./*[local-name()='instance_effect']/@url").first?.stringValue else { continue }
            let effectID = effectTarget.hasPrefix("#") ? String(effectTarget.dropFirst()) : effectTarget
            guard let source = effectImages[effectID], let imageURL = imagePaths[source.imageID],
                  FileManager.default.fileExists(atPath: imageURL.path) else { continue }
            let rawName = imageURL.deletingPathExtension().lastPathComponent
            let name = rawName.isEmpty ? (material.attribute(forName: "name")?.stringValue ?? "unnamed") : rawName
            result.append(SourceTexture(name: name, imageURLs: [imageURL], transparent: source.transparent))
        }
        return result
    }

    private static func normalizedTextureName(_ name: String) -> String {
        let value = name.lowercased().hasPrefix("txmp") ? String(name.dropFirst(4)) : name
        return value.lowercased()
    }

    private static func isAlphaFormat(_ format: String?) -> Bool {
        switch format?.uppercased() {
        case "BGRA4444", "BGRA5551", "RGBA": true
        default: false
        }
    }

    private static func floorPowerOfTwo(_ value: Int) -> Int {
        guard value > 2 else { return value }
        var result = 1
        while result <= value / 2 { result *= 2 }
        return result
    }

    private static func resolveImage(_ value: String, relativeTo base: URL) -> URL {
        if value.hasPrefix("file://"), let url = URL(string: value) { return url.standardizedFileURL }
        let decoded = value.removingPercentEncoding ?? value
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded).standardizedFileURL }
        return base.appendingPathComponent(decoded).standardizedFileURL
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

private extension FileManager {
    func copyItemReplacingExisting(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) { try removeItem(at: destination) }
        try copyItem(at: source, to: destination)
    }
}
