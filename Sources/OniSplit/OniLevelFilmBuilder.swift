import Foundation

package struct OniLevelFilmBuildResult {
    package let outputURLs: [URL]
    package let filmCount: Int
}

private struct OniLevelFilmFrame {
    let mouseX: Float
    let mouseY: Float
    let keys: UInt64
    let time: UInt32
}

private struct OniLevelFilm {
    let name: String
    let position: OniLevelVector3
    let facing: Float
    let desiredFacing: Float
    let headFacing: Float
    let headPitch: Float
    let frameCount: Int32
    let animations: [String]
    let frames: [OniLevelFilmFrame]
}

package enum OniLevelFilmBuilder {
    private static let keyValues: [String: UInt64] = [
        "None": 0, "Escape": 0x1, "Console": 0x2, "Pause": 0x4,
        "Cutscene1": 0x8, "Cutscene2": 0x10, "F4": 0x20, "F5": 0x40,
        "F6": 0x80, "F7": 0x100, "F8": 0x200, "StartRecord": 0x400,
        "StopRecord": 0x800, "PlayRecord": 0x1000, "F12": 0x2000,
        "LookMode": 0x8000, "Screenshot": 0x10000, "Forward": 0x200000,
        "Backward": 0x400000, "TurnLeft": 0x800000, "TurnRight": 0x1000000,
        "StepLeft": 0x2000000, "StepRight": 0x4000000, "Jump": 0x8000000,
        "Crouch": 0x10000000, "Punch": 0x20000000, "Kick": 0x40000000,
        "Block": 0x80000000, "Walk": 0x100000000, "Action": 0x200000000,
        "Hypo": 0x400000000, "Reload": 0x800000000, "Swap": 0x1000000000,
        "Drop": 0x2000000000, "Fire1": 0x4000000000, "Fire2": 0x8000000000,
        "Fire3": 0x10000000000
    ]

    package static func build(imports: [URL], outputDirectory: URL) throws -> OniLevelFilmBuildResult {
        var outputURLs: [URL] = []
        for sourceURL in imports {
            switch sourceURL.pathExtension.lowercased() {
            case "oni":
                let destination = outputDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }
                _ = try OniDatPacker.validate(OniDatFile.load(from: destination))
                outputURLs.append(destination)
            case "xml":
                let film = try readXML(sourceURL)
                outputURLs.append(try write(film, to: outputDirectory))
            case "dat":
                let film = try readBinary(sourceURL)
                outputURLs.append(try write(film, to: outputDirectory))
            default:
                throw OniNativeXMLError.invalidDocument("unsupported film file type: \(sourceURL.lastPathComponent)")
            }
        }
        return OniLevelFilmBuildResult(outputURLs: outputURLs, filmCount: imports.count)
    }

    private static func readXML(_ url: URL) throws -> OniLevelFilm {
        let document = try XMLDocument(data: Data(contentsOf: url), options: [.nodePreserveAll])
        guard let root = document.rootElement(), root.name == "Oni",
              let film = root.elements(forName: "FILM").first else {
            throw OniNativeXMLError.invalidDocument("film XML must contain <Oni><FILM>")
        }
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("FILM") { name = String(name.dropFirst(4)) }
        if let requested = film.attribute(forName: "Name")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            name = requested
        }
        let positionValues = floats(text(film, "Position"))
        guard positionValues.count == 3 else { throw OniNativeXMLError.invalidDocument("FILM Position requires 3 numbers") }
        let animationElements = child(film, "Animations")?.elements(forName: "Link") ?? []
        var animations = animationElements.map { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        while animations.count < 2 { animations.append("") }
        guard animations.count == 2 else { throw OniNativeXMLError.invalidDocument("FILM Animations requires exactly 2 Link elements") }
        let frameElements = child(film, "Frames")?.children?.compactMap { $0 as? XMLElement }.filter {
            ($0.localName ?? $0.name) == "Frame" || ($0.localName ?? $0.name) == "FILMFrame"
        } ?? []
        let frames = try frameElements.map(readFrame)
        return OniLevelFilm(
            name: name,
            position: OniLevelVector3(x: positionValues[0], y: positionValues[1], z: positionValues[2]),
            facing: try number(text(film, "Facing"), field: "FILM Facing"),
            desiredFacing: try number(text(film, "DesiredFacing"), field: "FILM DesiredFacing"),
            headFacing: try number(text(film, "HeadFacing"), field: "FILM HeadFacing"),
            headPitch: try number(text(film, "HeadPitch"), field: "FILM HeadPitch"),
            frameCount: try signed32(text(film, "FrameCount"), field: "FILM FrameCount"),
            animations: animations,
            frames: frames
        )
    }

    private static func readFrame(_ element: XMLElement) throws -> OniLevelFilmFrame {
        let elementName = element.localName ?? element.name
        let mouseValues: [Float]
        if elementName == "FILMFrame" {
            mouseValues = [
                try number(text(element, "MouseDeltaX"), field: "FILM MouseDeltaX"),
                try number(text(element, "MouseDeltaY"), field: "FILM MouseDeltaY")
            ]
        } else {
            mouseValues = floats(text(element, "MouseDelta"))
            guard mouseValues.isEmpty || mouseValues.count == 2 else {
                throw OniNativeXMLError.invalidDocument("FILM MouseDelta requires 2 numbers")
            }
        }
        let timeText = elementName == "FILMFrame" ? text(element, "Frame") : text(element, "Time")
        guard let time = unsigned32(timeText) else { throw OniNativeXMLError.invalidDocument("FILM frame time requires an unsigned integer") }
        return OniLevelFilmFrame(
            mouseX: mouseValues.first ?? 0, mouseY: mouseValues.dropFirst().first ?? 0,
            keys: try keys(text(element, "Keys")), time: time
        )
    }

    private static func readBinary(_ url: URL) throws -> OniLevelFilm {
        let data = try Data(contentsOf: url)
        guard data.count >= 320 else { throw OniNativeXMLError.invalidDocument("film binary is too short: \(url.lastPathComponent)") }
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("FILM") { name = String(name.dropFirst(4)) }
        let animations = [fixedString(data, 0, 128), fixedString(data, 128, 128)]
        let position = OniLevelVector3(x: f32(data, 256), y: f32(data, 260), z: f32(data, 264))
        let frameCount = i32(data, 284)
        let count = Int(u32(data, 316))
        guard count >= 0, 320 + count * 24 <= data.count else {
            throw OniNativeXMLError.invalidDocument("film binary frame array is truncated: \(url.lastPathComponent)")
        }
        let frames = (0..<count).map { index -> OniLevelFilmFrame in
            let offset = 320 + index * 24
            return OniLevelFilmFrame(
                mouseX: f32(data, offset), mouseY: f32(data, offset + 4),
                keys: u64(data, offset + 8), time: u32(data, offset + 16)
            )
        }
        return OniLevelFilm(
            name: name, position: position, facing: f32(data, 268), desiredFacing: f32(data, 272),
            headFacing: f32(data, 276), headPitch: f32(data, 280), frameCount: frameCount,
            animations: animations, frames: frames
        )
    }

    private static func write(_ film: OniLevelFilm, to directory: URL) throws -> URL {
        var definitions = [OniStandaloneInstanceDefinition(tag: "FILM", name: "FILM" + film.name)]
        var animationIndices: [Int?] = []
        var animationReferences: [String: Int] = [:]
        for animation in film.animations {
            if animation.isEmpty { animationIndices.append(nil) }
            else {
                let clean = animation.hasPrefix("TRAM") ? String(animation.dropFirst(4)) : animation
                if let existing = animationReferences[clean] {
                    animationIndices.append(existing)
                } else {
                    let index = definitions.count
                    animationReferences[clean] = index
                    animationIndices.append(index)
                    definitions.append(.init(tag: "TRAM", name: "TRAM" + clean))
                }
            }
        }
        var payload = Data()
        append(&payload, film.position.x); append(&payload, film.position.y); append(&payload, film.position.z)
        append(&payload, film.facing); append(&payload, film.desiredFacing)
        append(&payload, film.headFacing); append(&payload, film.headPitch)
        append(&payload, UInt32(bitPattern: film.frameCount))
        for index in animationIndices { append(&payload, index.map { UInt32($0 << 8) | 1 } ?? 0) }
        payload.append(Data(repeating: 0, count: 12))
        append(&payload, UInt32(film.frames.count))
        for frame in film.frames {
            append(&payload, frame.mouseX); append(&payload, frame.mouseY)
            append(&payload, frame.keys); append(&payload, frame.time); append(&payload, UInt32(0))
        }
        definitions[0] = .init(tag: "FILM", name: "FILM" + film.name, payload: payload)
        let output = directory.appendingPathComponent("FILM\(film.name).oni")
        try OniStandaloneArchiveBuilder.build(instances: definitions, embeddedRaw: Data()).write(to: output, options: .atomic)
        return output
    }

    private static func keys(_ value: String) throws -> UInt64 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let first = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? trimmed
        if let numeric = integer64(first) { return numeric }
        let normalized = Dictionary(uniqueKeysWithValues: keyValues.map { ($0.key.lowercased(), $0.value) })
        var result: UInt64 = 0
        for token in trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" }) {
            let name = token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard let flag = normalized[name.lowercased()] else {
                throw OniNativeXMLError.invalidDocument("unknown FILM Keys value '\(name)'")
            }
            result |= flag
        }
        return result
    }

    private static func number(_ value: String, field: String) throws -> Float {
        guard let result = Float(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OniNativeXMLError.invalidDocument("\(field) requires a number")
        }
        return result
    }

    private static func signed32(_ value: String, field: String) throws -> Int32 {
        guard let result = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OniNativeXMLError.invalidDocument("\(field) requires a signed integer")
        }
        return result
    }

    private static func unsigned32(_ value: String) -> UInt32? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("0x") { return UInt32(text.dropFirst(2), radix: 16) }
        return UInt32(text)
    }

    private static func integer64(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") { return UInt64(value.dropFirst(2), radix: 16) }
        return UInt64(value)
    }

    private static func floats(_ value: String) -> [Float] {
        value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Float($0) }
    }

    private static func child(_ element: XMLElement, _ name: String) -> XMLElement? { element.elements(forName: name).first }
    private static func text(_ element: XMLElement, _ name: String) -> String {
        child(element, name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func fixedString(_ data: Data, _ offset: Int, _ length: Int) -> String {
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static func i32(_ data: Data, _ offset: Int) -> Int32 { Int32(bitPattern: u32(data, offset)) }
    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }
    private static func f32(_ data: Data, _ offset: Int) -> Float { Float(bitPattern: u32(data, offset)) }
    private static func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
    private static func append(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }
    private static func append(_ data: inout Data, _ value: Float) { append(&data, value.bitPattern) }
}
