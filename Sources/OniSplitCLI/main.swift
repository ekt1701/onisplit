import Foundation
import AppKit
import OniSplit

@main
struct OniSplitCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("onisplit: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        switch command {
        case "help", "--help", "-h", "-help":
            printHelp()
        case "version", "--version", "-version":
            print("onisplit native 0.9.3")
        case "info":
            guard arguments.count == 2 else { throw CLIError.usage("info requires one DAT file") }
            try printInfo(URL(fileURLWithPath: arguments[1]))
        case "list":
            try printList(Array(arguments.dropFirst()))
        case "-list":
            guard arguments.count == 2 else { throw CLIError.usage("-list requires one DAT or ONI file") }
            try printLegacyList(URL(fileURLWithPath: arguments[1]))
        case "show":
            guard arguments.count == 3 else { throw CLIError.usage("show requires a DAT file and instance index or name") }
            try printInstance(URL(fileURLWithPath: arguments[1]), selector: arguments[2])
        case "extract-textures":
            try extractTextures(Array(arguments.dropFirst()), legacyFormat: nil)
        case "extract-sounds":
            try extractSounds(Array(arguments.dropFirst()), legacyFormat: nil)
        case "to-xml":
            try convertOniToXML(Array(arguments.dropFirst()), legacy: false)
        case "from-xml":
            try convertXMLToOni(Array(arguments.dropFirst()), legacy: false)
        case "-import:sep":
            try importSeparatedLevel(Array(arguments.dropFirst()))
        case "-create:level":
            try createLevel(Array(arguments.dropFirst()), legacy: true)
        case "create:level":
            try createLevel(Array(arguments.dropFirst()), legacy: false)
        case "create-level":
            try createLevel(Array(arguments.dropFirst()), legacy: false)
        case "-room:extract":
            try extractRooms(Array(arguments.dropFirst()))
        case let value where value == "-export" || value.hasPrefix("-export:"):
            try exportLevel(Array(arguments.dropFirst()), command: command)
        case "-extract:xml":
            try convertOniToXML(Array(arguments.dropFirst()), legacy: true)
        case "-create", "create":
            try convertXMLToOni(Array(arguments.dropFirst()), legacy: true)
        case "-extract:png", "-extract:jpg", "-extract:bmp", "-extract:tif", "-extract:tga":
            let format = String(command.dropFirst("-extract:".count))
            try extractTextures(Array(arguments.dropFirst()), legacyFormat: format)
        case "-extract:wav", "-extract:aif":
            let format = String(command.dropFirst("-extract:".count))
            try extractSounds(Array(arguments.dropFirst()), legacyFormat: format)
        case "-extract:dae":
            try extractDae(Array(arguments.dropFirst()))
        default:
            throw CLIError.usage("unknown command '\(command)'")
        }
    }

    private static func extractRooms(_ arguments: [String]) throws {
        var outputPath: String?
        var reportPath: String?
        var inputPaths: [String] = []
        var connectRooms = false
        for value in arguments {
            if value.hasPrefix("-out:") {
                guard outputPath == nil else { throw CLIError.usage("-room:extract accepts one -out:<file> option") }
                let path = String(value.dropFirst("-out:".count))
                guard !path.isEmpty else { throw CLIError.usage("-out: requires an output file") }
                outputPath = path
            } else if value == "--connect" || value == "-connect" {
                connectRooms = true
            } else if value.hasPrefix("--report:") {
                guard reportPath == nil else { throw CLIError.usage("-room:extract accepts one --report:<file> option") }
                let path = String(value.dropFirst("--report:".count))
                guard !path.isEmpty else { throw CLIError.usage("--report: requires an output file") }
                reportPath = path
            } else if value.hasPrefix("-") {
                throw CLIError.usage("unknown option '\(value)'")
            } else {
                inputPaths.append(value)
            }
        }
        guard let outputPath, !inputPaths.isEmpty else {
            throw CLIError.usage("-room:extract requires -out:<rooms.dae> and at least one model.dae")
        }
        let inputs = inputPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for input in inputs where !FileManager.default.fileExists(atPath: input.path) {
            throw CLIError.usage("input model does not exist: \(input.path)")
        }
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        let result = try OniRoomExtractor.extract(from: inputs, to: output, connectRooms: connectRooms)
        print("onisplit: selected \(result.selectedFloorCount) floor polygons from \(result.sourcePolygonCount) source polygons")
        print("onisplit: wrote \(result.outputPolygonCount) room floors (\(result.mergedQuadCount) triangle pairs merged)")
        if result.approximatedRampCount > 0 {
            print("onisplit: converted \(result.approximatedRampCount) multi-corner ramps to four-corner BNV floors")
        }
        if result.recoveredReversedRampCount > 0 {
            print("onisplit: recovered \(result.recoveredReversedRampCount) reversed walkable ramp faces")
        }
        if result.mergedResidualTriangleCount > 0 {
            print("onisplit: merged \(result.mergedResidualTriangleCount) residual triangle floor fragments")
        }
        if result.discardedNonQuadFloorCount > 0 {
            print("onisplit: discarded \(result.discardedNonQuadFloorCount) floor fragments that could not form valid quads")
        }
        if connectRooms {
            print("onisplit: consolidated \(result.consolidatedFloorCount) additional coplanar floor fragments")
            print("onisplit: discarded \(result.discardedIsolatedFloorCount) small isolated floor surfaces")
            print("onisplit: wrote \(result.generatedGhostCount) validated ghost portals (\(result.rejectedGhostCount) candidates rejected)")
            print("onisplit: suppressed \(result.blockedGhostCount) fully obstructed shared boundaries")
        }
        print(output.path)
        if let reportPath {
            let report = URL(fileURLWithPath: reportPath).standardizedFileURL
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try OniRoomExtractor.reportData(for: output, result: result).write(to: report, options: .atomic)
            print(report.path)
        }
    }

    private static func exportLevel(_ arguments: [String], command: String) throws {
        guard arguments.count == 2 else {
            throw CLIError.usage("\(command) requires an output directory and one DAT file")
        }
        let prefixes: [String]
        if let separator = command.firstIndex(of: ":") {
            let prefix = String(command[command.index(after: separator)...])
            prefixes = prefix.isEmpty ? [] : [prefix]
        } else {
            prefixes = []
        }
        let output = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
        let source = try OniDatFile.load(from: URL(fileURLWithPath: arguments[1]).standardizedFileURL)
        let result = try OniDatUnpacker.export(file: source, to: output, namePrefixes: prefixes)
        print("onisplit: exported \(result.fileCount) ONI file(s)")
        print(output.path)
    }

    private static func importSeparatedLevel(_ arguments: [String]) throws {
        guard arguments.count >= 2 else { throw CLIError.usage("-import:sep requires at least one input directory and an output DAT file") }
        let output = URL(fileURLWithPath: arguments.last!).standardizedFileURL
        let directories = arguments.dropLast().map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        for directory in directories {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError.usage("input directory does not exist: \(directory.path)")
            }
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let packed = try OniDatPacker.pack(directories: directories, outputURL: output)
        let base = output.deletingPathExtension()
        try packed.dat.write(to: base.appendingPathExtension("dat"), options: .atomic)
        try packed.raw.write(to: base.appendingPathExtension("raw"), options: .atomic)
        try packed.sep.write(to: base.appendingPathExtension("sep"), options: .atomic)
        print("onisplit: packed \(packed.instanceCount) instances")
        print(base.appendingPathExtension("dat").path)
        print(base.appendingPathExtension("raw").path)
        print(base.appendingPathExtension("sep").path)
    }

    private static func createLevel(_ arguments: [String], legacy: Bool) throws {
        var outputPath: String?
        var sourcePath: String?
        var overwrite = false
        var debug = false
        var index = 0
        if legacy {
            guard arguments.count >= 2 else {
                throw CLIError.usage("-create:level requires an output directory and one level-definition XML file")
            }
            outputPath = arguments[0]
            for value in arguments.dropFirst() {
                if value == "--overwrite" { overwrite = true }
                else if value == "-debug" { debug = true }
                else if value.hasPrefix("-") { throw CLIError.usage("unknown option '\(value)'") }
                else if sourcePath == nil { sourcePath = value }
                else { throw CLIError.usage("-create:level accepts one level-definition XML file") }
            }
        } else {
            while index < arguments.count {
                switch arguments[index] {
                case "--output", "-o":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--output requires a directory") }
                    outputPath = arguments[index]
                case "--overwrite": overwrite = true
                case "--debug": debug = true
                case let value where value.hasPrefix("-"):
                    throw CLIError.usage("unknown option '\(value)'")
                case let value:
                    guard sourcePath == nil else { throw CLIError.usage("create-level accepts one level-definition XML file") }
                    sourcePath = value
                }
                index += 1
            }
        }
        guard let outputPath, let sourcePath else {
            throw CLIError.usage(legacy
                ? "-create:level requires an output directory and one level-definition XML file"
                : "create-level requires --output and one level-definition XML file")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.usage("level definition does not exist: \(sourceURL.path)")
        }
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CLIError.usage("output path is not a directory: \(outputURL.path)") }
            let contents = try FileManager.default.contentsOfDirectory(atPath: outputURL.path)
            if !contents.isEmpty && !overwrite {
                throw CLIError.usage("output directory is not empty; use --overwrite to replace matching outputs")
            }
        } else {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        }

        let result = try OniLevelBuilder.buildLevel(
            from: sourceURL, outputDirectory: outputURL, debug: debug
        )
        print("onisplit: created level '\(result.definition.name)'")
        print("onisplit: \(result.outputURLs.count) ONI files, \(result.objectCount) objects, \(result.furnitureCount) furniture objects, \(result.consoleCount) console objects")
        if result.triggerCount > 0 || result.turretCount > 0 {
            print("onisplit: \(result.triggerCount) trigger gunk objects, \(result.turretCount) turret gunk objects")
        }
        print("onisplit: \(result.environmentPolygonCount) environment polygons, \(result.roomCount) rooms, \(result.objectQuadMapCount) object maps")
        print("onisplit: imported \(result.importedTextureCount) textures, copied \(result.copiedTextureCount) shared textures")
        print("onisplit: \(result.physicsObjectCount) physics objects, \(result.scriptCharacterCount) script characters, \(result.environmentParticleCount) environment particles, \(result.corpseCount) corpses")
        if result.physicsDependencyCount > 0 {
            print("onisplit: copied \(result.physicsDependencyCount) shared physics dependencies")
        }
        if result.physicsAnimationCount > 0 {
            print("onisplit: imported \(result.physicsAnimationCount) physics animations")
        }
        if result.filmCount > 0 {
            print("onisplit: imported \(result.filmCount) films")
        }
        if result.cameraAnimationCount > 0 {
            print("onisplit: imported \(result.cameraAnimationCount) camera animations")
        }
        for url in result.outputURLs { print(url.path) }
    }

    private static func printInfo(_ url: URL) throws {
        let file = try OniDatFile.load(from: url)
        let header = file.header
        print("File: \(url.path)")
        print("Version: \(header.versionBytes)")
        print(String(format: "Template checksum: 0x%016llx", header.checksum))
        print("Instances: \(header.instanceCount)")
        print("Named instances: \(header.nameCount)")
        print("Templates: \(header.templateCount)")
        print("Data: offset \(header.dataBlockOffset), \(header.dataBlockLength) bytes")
        print("Names: offset \(header.nameBlockOffset), \(header.nameBlockLength) bytes")
        print("Companions: raw=\(file.rawData == nil ? "missing" : "present"), sep=\(file.sepData == nil ? "missing" : "present")")
        print("")
        print("Template counts:")
        for (tag, count) in file.templateCounts {
            print("  \(padded(tag, to: 4)) \(String(format: "%8d", count))")
        }
    }

    private static func printList(_ arguments: [String]) throws {
        var tag: String?
        var namesOnly = false
        var path: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--tag":
                index += 1
                guard index < arguments.count else { throw CLIError.usage("--tag requires a four-character tag") }
                tag = arguments[index]
            case "--names-only":
                namesOnly = true
            case let value where value.hasPrefix("-"):
                throw CLIError.usage("unknown option '\(value)'")
            case let value:
                guard path == nil else { throw CLIError.usage("list accepts one DAT file") }
                path = value
            }
            index += 1
        }

        guard let path else { throw CLIError.usage("list requires one DAT file") }
        if let tag, tag.count != 4 { throw CLIError.usage("--tag must be exactly four characters") }

        let file = try OniDatFile.load(from: URL(fileURLWithPath: path))
        let matches = file.instances.filter { instance in
            (tag == nil || instance.templateTag == tag) && (!namesOnly || !instance.fullName.isEmpty)
        }

        for instance in matches {
            let id = String(format: "%6d", instance.id)
            let size = String(format: "%8d", instance.dataSize)
            let flags = String(format: "0x%08x", instance.descriptorFlags)
            print("\(id)  \(padded(instance.templateTag, to: 4))  \(size)  \(flags)  \(instance.displayName)")
        }
        FileHandle.standardError.write(Data("\(matches.count) instance(s)\n".utf8))
    }

    private static func printLegacyList(_ url: URL) throws {
        let file = try OniDatFile.load(from: url)
        for instance in file.instances where !instance.fullName.isEmpty {
            print(instance.fullName)
        }
    }

    private static func extractTextures(_ arguments: [String], legacyFormat: String?) throws {
        var format = legacyFormat ?? "png"
        var outputPath: String?
        var inputPaths: [String] = []
        var overwrite = false
        var namePrefix: String?
        var limit: Int?

        if legacyFormat != nil {
            guard arguments.count >= 2 else {
                throw CLIError.usage("-extract:\(format) requires an output directory and at least one DAT or ONI file")
            }
            outputPath = arguments[0]
            inputPaths = Array(arguments.dropFirst())
        } else {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--output", "-o":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--output requires a directory") }
                    outputPath = arguments[index]
                case "--format":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--format requires png, jpg, bmp, tif, or tga") }
                    format = arguments[index].lowercased()
                case "--overwrite":
                    overwrite = true
                case "--name-prefix":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--name-prefix requires text") }
                    namePrefix = arguments[index]
                case "--limit":
                    index += 1
                    guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                        throw CLIError.usage("--limit requires a positive number")
                    }
                    limit = value
                case let value where value.hasPrefix("-"):
                    throw CLIError.usage("unknown option '\(value)'")
                case let value:
                    inputPaths.append(value)
                }
                index += 1
            }
        }

        guard ["png", "jpg", "bmp", "tif", "tga"].contains(format) else {
            throw CLIError.usage("texture format '\(format)' is not supported yet")
        }
        guard let outputPath, !inputPaths.isEmpty else {
            throw CLIError.usage("extract-textures requires --output and at least one DAT or ONI file")
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        var written = 0
        var skipped = 0
        var failed = 0
        var processed = 0
        var usedNames = Set<String>()

        outer: for inputPath in inputPaths {
            let file = try OniDatFile.load(from: URL(fileURLWithPath: inputPath))
            for instance in file.instances where instance.templateTag == "TXMP" && instance.dataSize >= 156 {
                if let namePrefix, !instance.displayName.hasPrefix(namePrefix) { continue }
                if let limit, processed >= limit { break outer }
                processed += 1
                guard let preview = file.texturePreview(for: instance) else {
                    failed += 1
                    FileHandle.standardError.write(Data("onisplit: could not decode \(instance.fullName): unknown texture format\n".utf8))
                    continue
                }
                guard let image = preview.image else {
                    failed += 1
                    FileHandle.standardError.write(Data("onisplit: could not decode \(instance.fullName): \(preview.error ?? "unknown texture error")\n".utf8))
                    continue
                }

                var baseName = encodedFileName(instance.fullName.isEmpty ? "TXMPunnamed_\(instance.id)" : instance.fullName)
                var collision = 2
                while usedNames.contains(baseName.lowercased()) {
                    baseName = encodedFileName(instance.fullName) + "_\(collision)"
                    collision += 1
                }
                usedNames.insert(baseName.lowercased())
                let destination = outputURL.appendingPathComponent(baseName).appendingPathExtension(format)
                if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
                    skipped += 1
                    continue
                }
                guard let data = imageData(image, preview: preview, format: format) else {
                    failed += 1
                    FileHandle.standardError.write(Data("onisplit: could not encode \(instance.fullName) as \(format)\n".utf8))
                    continue
                }
                try data.write(to: destination, options: .atomic)
                written += 1
                print(destination.path)
            }
        }

        FileHandle.standardError.write(Data("onisplit: wrote \(written), skipped \(skipped), failed \(failed) texture(s)\n".utf8))
        if failed > 0 { throw CLIError.operation("one or more textures could not be extracted") }
    }

    private static func imageData(_ image: NSImage, preview: OniTexturePreview, format: String) -> Data? {
        if format == "tga", let rgba = preview.rgba {
            return tgaData(width: preview.info.width, height: preview.info.height, rgba: rgba)
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        switch format {
        case "png": return bitmap.representation(using: .png, properties: [:])
        case "jpg": return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        case "bmp": return bitmap.representation(using: .bmp, properties: [:])
        case "tif": return bitmap.representation(using: .tiff, properties: [:])
        default: return nil
        }
    }

    private static func tgaData(width: Int, height: Int, rgba: Data) -> Data? {
        guard width > 0, height > 0, width <= Int(UInt16.max), height <= Int(UInt16.max),
              rgba.count == width * height * 4 else { return nil }
        var output = Data(repeating: 0, count: 18)
        output[2] = 2
        output[12] = UInt8(width & 0xff)
        output[13] = UInt8((width >> 8) & 0xff)
        output[14] = UInt8(height & 0xff)
        output[15] = UInt8((height >> 8) & 0xff)
        output[16] = 32
        output[17] = 0x28
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            output.append(rgba[pixel + 2])
            output.append(rgba[pixel + 1])
            output.append(rgba[pixel])
            output.append(rgba[pixel + 3])
        }
        return output
    }

    private static func extractSounds(_ arguments: [String], legacyFormat: String?) throws {
        var format = legacyFormat ?? "wav"
        var outputPath: String?
        var inputPaths: [String] = []
        var overwrite = false
        var namePrefix: String?
        var limit: Int?

        if legacyFormat != nil {
            guard arguments.count >= 2 else {
                throw CLIError.usage("-extract:\(format) requires an output directory and at least one DAT or ONI file")
            }
            outputPath = arguments[0]
            inputPaths = Array(arguments.dropFirst())
        } else {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--output", "-o":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--output requires a directory") }
                    outputPath = arguments[index]
                case "--format":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--format requires wav or aif") }
                    format = arguments[index].lowercased()
                case "--overwrite": overwrite = true
                case "--name-prefix":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--name-prefix requires text") }
                    namePrefix = arguments[index]
                case "--limit":
                    index += 1
                    guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                        throw CLIError.usage("--limit requires a positive number")
                    }
                    limit = value
                case let value where value.hasPrefix("-"):
                    throw CLIError.usage("unknown option '\(value)'")
                case let value: inputPaths.append(value)
                }
                index += 1
            }
        }

        guard ["wav", "aif"].contains(format) else { throw CLIError.usage("sound format '\(format)' is not supported") }
        guard let outputPath, !inputPaths.isEmpty else {
            throw CLIError.usage("extract-sounds requires --output and at least one DAT or ONI file")
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        var written = 0, skipped = 0, failed = 0, processed = 0
        var usedNames = Set<String>()

        outer: for inputPath in inputPaths {
            let file = try OniDatFile.load(from: URL(fileURLWithPath: inputPath))
            for instance in file.instances where instance.templateTag == "SNDD" {
                if let namePrefix, !instance.displayName.hasPrefix(namePrefix) { continue }
                if let limit, processed >= limit { break outer }
                processed += 1
                do {
                    guard let sound = try file.soundResource(for: instance) else { continue }
                    var sourceName = instance.fullName.isEmpty ? "SNDDunnamed_\(instance.id)" : instance.fullName
                    for suffix in [".aif", ".aiff", ".wav"] where sourceName.lowercased().hasSuffix(suffix) {
                        sourceName.removeLast(suffix.count)
                        break
                    }
                    let encoded = encodedFileName(sourceName)
                    var baseName = encoded
                    var collision = 2
                    while usedNames.contains(baseName.lowercased()) {
                        baseName = encoded + "_\(collision)"
                        collision += 1
                    }
                    usedNames.insert(baseName.lowercased())
                    let destination = outputURL.appendingPathComponent(baseName).appendingPathExtension(format)
                    if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
                        skipped += 1
                        continue
                    }
                    let encodedSound: Data
                    if format == "aif" {
                        guard sound.isIMA4 else { throw CLIError.operation("AIF export requires a Mac IMA4 sound") }
                        encodedSound = aifData(sound)
                    } else {
                        encodedSound = try wavData(sound)
                    }
                    try encodedSound.write(to: destination, options: .atomic)
                    written += 1
                    print(destination.path)
                } catch {
                    failed += 1
                    FileHandle.standardError.write(Data("onisplit: could not extract \(instance.fullName): \(error.localizedDescription)\n".utf8))
                }
            }
        }
        FileHandle.standardError.write(Data("onisplit: wrote \(written), skipped \(skipped), failed \(failed) sound(s)\n".utf8))
        if failed > 0 { throw CLIError.operation("one or more sounds could not be extracted") }
    }

    private static func extractDae(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.usage("-extract:dae requires an output directory and at least one DAT or ONI file")
        }
        let outputURL = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
        var inputPaths: [String] = []
        var noAnimation = false
        for argument in arguments.dropFirst() {
            if argument == "-noanim" {
                noAnimation = true
            } else if argument.hasPrefix("-") {
                throw CLIError.usage("unknown option '\(argument)'")
            } else {
                inputPaths.append(argument)
            }
        }
        guard !inputPaths.isEmpty else {
            throw CLIError.usage("-extract:dae requires at least one DAT or ONI file")
        }
        var written = 0
        var failed = 0
        for input in inputPaths {
            do {
                let file = try OniDatFile.load(from: URL(fileURLWithPath: input).standardizedFileURL)
                let result = try OniDaeExporter.export(file: file, to: outputURL, noAnimation: noAnimation)
                written += result.fileCount
                for url in result.outputURLs { print(url.path) }
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("onisplit: could not extract geometry from \(input): \(error.localizedDescription)\n".utf8))
            }
        }
        FileHandle.standardError.write(Data("onisplit: wrote \(written) Collada file(s), failed \(failed) input file(s)\n".utf8))
        if failed > 0 { throw CLIError.operation("one or more geometry files could not be extracted") }
    }

    private static func conversionArguments(_ arguments: [String], legacy: Bool, command: String) throws -> (URL, [String], Bool, Bool) {
        var outputPath: String?
        var inputs: [String] = []
        var overwrite = false
        var lossless = false
        if legacy {
            guard arguments.count >= 2 else { throw CLIError.usage("\(command) requires an output directory and at least one input file") }
            outputPath = arguments[0]
            inputs = Array(arguments.dropFirst())
        } else {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--output", "-o":
                    index += 1
                    guard index < arguments.count else { throw CLIError.usage("--output requires a directory") }
                    outputPath = arguments[index]
                case "--overwrite": overwrite = true
                case "--lossless", "--native-archive": lossless = true
                case "--semantic-only": lossless = false
                case let value where value.hasPrefix("-"): throw CLIError.usage("unknown option '\(value)'")
                case let value: inputs.append(value)
                }
                index += 1
            }
        }
        guard let outputPath, !inputs.isEmpty else {
            throw CLIError.usage("\(command) requires --output and at least one input file")
        }
        return (URL(fileURLWithPath: outputPath, isDirectory: true), inputs, overwrite, lossless)
    }

    private static func convertOniToXML(_ arguments: [String], legacy: Bool) throws {
        let (outputURL, inputs, overwrite, lossless) = try conversionArguments(arguments, legacy: legacy, command: legacy ? "-extract:xml" : "to-xml")
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        var written = 0, skipped = 0, failed = 0
        for input in inputs {
            do {
                let inputURL = URL(fileURLWithPath: input)
                let file = try OniDatFile.load(from: inputURL)
                let destination = outputURL.appendingPathComponent(inputURL.lastPathComponent).appendingPathExtension("xml")
                if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
                    skipped += 1
                    continue
                }
                let xml: Data
                if lossless {
                    xml = OniNativeXMLArchive.export(file: file)
                } else if OniTextureXMLExporter.supports(file: file) {
                    let exported = try OniTextureXMLExporter.export(file: file)
                    let imageDestinations = exported.images.map { outputURL.appendingPathComponent($0.fileName) }
                    if !overwrite && imageDestinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        skipped += 1
                        continue
                    }
                    for (image, imageDestination) in zip(exported.images, imageDestinations) {
                        try image.data.write(to: imageDestination, options: .atomic)
                    }
                    xml = exported.xml
                } else if OniWeaponXMLExporter.supports(file: file) {
                    let exported = try OniWeaponXMLExporter.export(file: file)
                    let fileDestinations = exported.files.map { outputURL.appendingPathComponent($0.fileName) }
                    if !overwrite && fileDestinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        skipped += 1
                        continue
                    }
                    for (artifact, artifactDestination) in zip(exported.files, fileDestinations) {
                        try artifact.data.write(to: artifactDestination, options: .atomic)
                    }
                    xml = exported.xml
                } else if OniCharacterXMLExporter.supports(file: file) {
                    xml = try OniCharacterXMLExporter.export(file: file)
                } else {
                    do {
                        xml = try OniNativeXMLArchive.semanticExport(file: file)
                    } catch {
                        xml = OniNativeXMLArchive.export(file: file)
                        FileHandle.standardError.write(Data("onisplit: \(inputURL.lastPathComponent) does not have semantic XML support yet; wrote lossless XML instead\n".utf8))
                    }
                }
                try xml.write(to: destination, options: .atomic)
                written += 1
                print(destination.path)
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("onisplit: could not convert \(input): \(error.localizedDescription)\n".utf8))
            }
        }
        FileHandle.standardError.write(Data("onisplit: wrote \(written), skipped \(skipped), failed \(failed) XML file(s)\n".utf8))
        if failed > 0 { throw CLIError.operation("one or more ONI files could not be converted to XML") }
    }

    private static func convertXMLToOni(_ arguments: [String], legacy: Bool) throws {
        let (outputURL, inputs, overwrite, _) = try conversionArguments(arguments, legacy: legacy, command: legacy ? "-create" : "from-xml")
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        var written = 0, skipped = 0, failed = 0
        for input in inputs {
            do {
                let inputURL = URL(fileURLWithPath: input)
                let archive = try OniNativeXMLArchive.load(
                    from: Data(contentsOf: inputURL),
                    sourceFileName: inputURL.lastPathComponent,
                    resourceBaseURL: inputURL.deletingLastPathComponent()
                )
                let destination = outputURL.appendingPathComponent(archive.fileName)
                if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
                    skipped += 1
                    continue
                }
                let validationURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("onisplit-validate-\(UUID().uuidString)")
                    .appendingPathExtension("oni")
                defer { try? FileManager.default.removeItem(at: validationURL) }
                try archive.archiveData.write(to: validationURL, options: .atomic)
                _ = try OniDatFile.load(from: validationURL)
                try archive.archiveData.write(to: destination, options: .atomic)
                written += 1
                print(destination.path)
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("onisplit: could not convert \(input): \(error.localizedDescription)\n".utf8))
            }
        }
        FileHandle.standardError.write(Data("onisplit: wrote \(written), skipped \(skipped), failed \(failed) ONI file(s)\n".utf8))
        if failed > 0 { throw CLIError.operation("one or more XML files could not be converted to ONI") }
    }

    private static func aifData(_ sound: OniSoundResource) -> Data {
        var output = Data()
        output.appendASCII("FORM")
        output.appendBE(UInt32(50 + sound.data.count))
        output.appendASCII("AIFC")
        output.appendASCII("COMM")
        output.appendBE(UInt32(22))
        output.appendBE(UInt16(sound.channels))
        output.appendBE(UInt32(sound.data.count / (sound.channels * 34)))
        output.appendBE(UInt16(16))
        output.append(contentsOf: [0x40, 0x0d, 0xac, 0x44, 0, 0, 0, 0, 0, 0])
        output.appendASCII("ima4")
        output.appendASCII("SSND")
        output.appendBE(UInt32(8 + sound.data.count))
        output.appendBE(UInt32(0))
        output.appendBE(UInt32(0))
        output.append(sound.data)
        return output
    }

    private static func wavData(_ sound: OniSoundResource) throws -> Data {
        let payload: Data
        let formatCode: UInt16
        let bits: Int
        let blockAlign: Int
        let averageRate: Int
        var extra = Data()
        var sampleCount = sound.sampleCount

        if sound.isIMA4 {
            payload = try decodeIMA4(sound.data, channels: sound.channels)
            formatCode = 1
            bits = 16
            blockAlign = 2 * sound.channels
            averageRate = sound.sampleRate * blockAlign
            sampleCount = payload.count / blockAlign
        } else {
            payload = sound.data
            formatCode = sound.isPCM ? 1 : 2
            bits = sound.bitsPerSample
            blockAlign = sound.blockAlignment
            averageRate = sound.averageBytesPerSecond
            if !sound.isPCM {
                extra.appendLE(UInt16(sound.samplesPerBlock))
                extra.appendLE(UInt16(sound.coefficients.count))
                for pair in sound.coefficients {
                    extra.appendLE(UInt16(bitPattern: pair.0))
                    extra.appendLE(UInt16(bitPattern: pair.1))
                }
            }
        }

        var format = Data()
        format.appendLE(formatCode)
        format.appendLE(UInt16(sound.channels))
        format.appendLE(UInt32(sound.sampleRate))
        format.appendLE(UInt32(averageRate))
        format.appendLE(UInt16(blockAlign))
        format.appendLE(UInt16(bits))
        if !extra.isEmpty {
            format.appendLE(UInt16(extra.count))
            format.append(extra)
        }

        var output = Data()
        let factSize = formatCode == 2 ? 12 : 0
        output.appendASCII("RIFF")
        output.appendLE(UInt32(4 + 8 + format.count + factSize + 8 + payload.count + payload.count % 2))
        output.appendASCII("WAVE")
        output.appendASCII("fmt ")
        output.appendLE(UInt32(format.count))
        output.append(format)
        if formatCode == 2 {
            output.appendASCII("fact")
            output.appendLE(UInt32(4))
            output.appendLE(UInt32(sampleCount))
        }
        output.appendASCII("data")
        output.appendLE(UInt32(payload.count))
        output.append(payload)
        if payload.count % 2 != 0 { output.append(0) }
        return output
    }

    private static func decodeIMA4(_ input: Data, channels: Int) throws -> Data {
        let blockSize = 34 * channels
        guard (channels == 1 || channels == 2), input.count % blockSize == 0 else {
            throw CLIError.operation("IMA4 audio contains an incomplete block")
        }
        let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
        let stepTable = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
        func decodeChannel(_ start: Int, predictor initialPredictor: inout Int, stepIndex initialIndex: inout Int) -> [Int16] {
            let high = Int(input[start])
            let low = Int(input[start + 1])
            var headerPredictor = (high << 8) | (low & 0x80)
            if headerPredictor > 32767 { headerPredictor -= 65536 }
            var stepIndex = min(low & 0x7f, 88)
            var predictor = headerPredictor
            var samples: [Int16] = []
            samples.reserveCapacity(64)
            for byteOffset in 2..<34 {
                let byte = Int(input[start + byteOffset])
                for nibble in [byte & 0xf, byte >> 4] {
                    let step = stepTable[stepIndex]
                    var difference = step >> 3
                    if nibble & 4 != 0 { difference += step }
                    if nibble & 2 != 0 { difference += step >> 1 }
                    if nibble & 1 != 0 { difference += step >> 2 }
                    predictor += nibble & 8 != 0 ? -difference : difference
                    predictor = min(max(predictor, -32768), 32767)
                    stepIndex = min(max(stepIndex + indexTable[nibble], 0), 88)
                    samples.append(Int16(predictor))
                }
            }
            initialPredictor = predictor
            initialIndex = stepIndex
            return samples
        }

        var output = Data()
        var predictors = [Int](repeating: 0, count: channels)
        var indices = [Int](repeating: 0, count: channels)
        for block in 0..<(input.count / blockSize) {
            var channelSamples = [[Int16]]()
            for channel in 0..<channels {
                channelSamples.append(decodeChannel(block * blockSize + channel * 34, predictor: &predictors[channel], stepIndex: &indices[channel]))
            }
            for sample in 0..<64 {
                for channel in 0..<channels { output.appendLE(UInt16(bitPattern: channelSamples[channel][sample])) }
            }
        }
        return output
    }

    private static func encodedFileName(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar.value == 0 || scalar == ":" {
                result += String(format: "%%%02X", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func printInstance(_ url: URL, selector: String) throws {
        let file = try OniDatFile.load(from: url)
        let instance: OniDatInstance?
        if let index = Int(selector), file.instances.indices.contains(index) {
            instance = file.instances[index]
        } else {
            instance = file.instances.first { $0.fullName == selector || $0.displayName == selector }
        }
        guard let instance else { throw CLIError.usage("instance '\(selector)' was not found") }

        print("Index: \(instance.id)")
        print("Template: \(instance.templateTag)")
        print("Name: \(instance.displayName)")
        print("Data offset: \(String(format: "0x%08X", instance.dataOffset))")
        print("Data size: \(instance.dataSize) bytes")
        print("Descriptor flags: \(String(format: "0x%08X", instance.descriptorFlags))")
        if let metadata = file.structuredMetadata(for: instance) {
            print("")
            print(metadata.templateName + ":")
            for field in metadata.fields {
                print("  \(padded(field.name + ":", to: 22)) \(field.value)")
            }
        }
    }

    private static func printHelp() {
        print("""
        Native OniSplit for macOS

        Usage:
          onisplit info <file.dat>
          onisplit list [--tag TAG] [--names-only] <file.dat>
          onisplit show <file.dat> <index-or-name>
          onisplit extract-textures --output <directory> [--format png|jpg|bmp|tif|tga]
                                    [--name-prefix TEXT] [--overwrite] <files...>
          onisplit extract-sounds --output <directory> [--format wav|aif]
                                  [--name-prefix TEXT] [--overwrite] <files...>
          onisplit to-xml --output <directory> [--lossless] [--overwrite] <files.oni...>
          onisplit from-xml --output <directory> [--overwrite] <files.xml...>
          onisplit create:level --output <directory> [--overwrite] [--debug] <level-definition.xml>
          onisplit create-level --output <directory> [--overwrite] [--debug] <level-definition.xml>
          onisplit version

        Original OniSplit-compatible forms:
          onisplit -list <file.dat>
          onisplit -export <directory> <file.dat>
          onisplit -export:PREFIX <directory> <file.dat>
          onisplit -import:sep <directory> [additional-directories...] <file.dat>
          onisplit -create:level <directory> <level-definition.xml> [--overwrite] [-debug]
          onisplit -room:extract -out:<rooms.dae> [--connect] [--report:<report.json>] <model1.dae> [model2.dae...]
          onisplit -extract:png <directory> <files...>
          onisplit -extract:tga|-extract:jpg|-extract:bmp|-extract:tif <directory> <files...>
          onisplit -extract:wav|-extract:aif <directory> <files...>
          onisplit -extract:dae <directory> [-noanim] <files...>
                                                             (M3GM, ONCC, TRBS, and AKEV)
          onisplit -extract:xml <directory> <files.oni...>
          onisplit -create <directory> <files.xml...>
          onisplit -version | -help

        Readable, editable semantic XML is the default. --lossless embeds the
        complete native archive. --semantic-only remains accepted as an alias
        for the default behavior.
        """)
    }

    private static func padded(_ value: String, to width: Int) -> String {
        if value.count >= width { return value }
        return value + String(repeating: " ", count: width - value.count)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) { append(contentsOf: value.utf8) }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .usage(let detail):
            return "\(detail). Run 'onisplit help' for usage."
        case .operation(let detail):
            return detail
        }
    }
}
