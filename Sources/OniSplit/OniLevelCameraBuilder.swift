import Foundation

package struct OniLevelCameraBuildResult {
    package let outputURLs: [URL]
    package let animationCount: Int
}

package struct OniLevelPhysicsAnimationBuildResult {
    package let outputURLs: [URL]
    package let animationCount: Int
    package let objects: [OniLevelPhysicsObject]
}

package enum OniLevelCameraBuilder {
    private struct Source { let floats: [Float]; let names: [String]; let stride: Int }
    private struct Sampler { let input: Source; let output: Source; let interpolation: Source? }
    private struct Channel { let sampler: Sampler; let target: String }
    private struct Frame { let scale: OniLevelVector3; let rotation: [Float]; let translation: OniLevelVector3; let time: Int }
    private struct BuiltClip { let name: String; let url: URL; let firstFrame: Frame }

    package static func build(imports: [OniLevelCameraImport], outputDirectory: URL) throws -> OniLevelCameraBuildResult {
        var outputs: [URL] = []
        for item in imports { outputs += try build(item, outputDirectory: outputDirectory).map(\.url) }
        return OniLevelCameraBuildResult(outputURLs: outputs, animationCount: outputs.count)
    }

    package static func buildPhysics(
        objects: [OniLevelPhysicsObject], outputDirectory: URL,
        sharedDirectory: URL? = nil
    ) throws -> OniLevelPhysicsAnimationBuildResult {
        var outputs: [URL] = []
        var adjustedObjects: [OniLevelPhysicsObject] = []
        let sharedFiles: [String: URL]
        if let sharedDirectory {
            let urls = try FileManager.default.contentsOfDirectory(
                at: sharedDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            sharedFiles = Dictionary(urls.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            sharedFiles = [:]
        }
        for object in objects {
            if object.importedGeometryURL == nil, object.animationClips.isEmpty,
               !object.animationName.isEmpty, !sharedFiles.isEmpty {
                let name = normalizedAnimationName(object.animationName)
                let fileName = "OBAN\(name).oni"
                guard let sourceURL = sharedFiles[fileName.lowercased()] else {
                    throw OniNativeXMLError.invalidDocument("shared physics animation was not found: \(fileName)")
                }
                let built = try buildSharedPhysicsAnimation(
                    sourceURL: sourceURL, name: name, object: object,
                    outputDirectory: outputDirectory
                )
                outputs.append(built.url)
                adjustedObjects.append(object.applyingAnimationStart(
                    scale: built.firstFrame.scale.x,
                    orientation: built.firstFrame.rotation,
                    position: built.firstFrame.translation,
                    physicsType: built.flags & 0x0008 != 0 ? 3 : nil
                ))
                continue
            }
            guard let sourceURL = object.importedGeometryURL, !object.animationClips.isEmpty else {
                adjustedObjects.append(object)
                continue
            }
            let built = try build(
                sourceURL: sourceURL, clips: object.animationClips,
                outputDirectory: outputDirectory, preferredNodeID: object.animationNodeID,
                requiresSingleAnimatedNode: false,
                setupOrientation: object.orientation, setupPosition: object.position
            )
            outputs += built.map(\.url)
            if let selected = built.first(where: { $0.name == object.animationName }) ?? built.first {
                adjustedObjects.append(object.applyingAnimationStart(
                    scale: selected.firstFrame.scale.x,
                    orientation: selected.firstFrame.rotation,
                    position: selected.firstFrame.translation
                ))
            } else {
                adjustedObjects.append(object)
            }
        }
        return OniLevelPhysicsAnimationBuildResult(
            outputURLs: outputs, animationCount: outputs.count, objects: adjustedObjects
        )
    }

    private static func buildSharedPhysicsAnimation(
        sourceURL: URL, name: String, object: OniLevelPhysicsObject, outputDirectory: URL
    ) throws -> (url: URL, firstFrame: Frame, flags: UInt32) {
        let file = try OniDatFile.load(from: sourceURL)
        guard let animation = file.instances.first(where: {
            $0.templateTag == "OBAN" && $0.descriptorFlags & 2 == 0
        }) else {
            throw OniNativeXMLError.invalidDocument("\(sourceURL.lastPathComponent) does not contain an OBAN animation")
        }
        let base = animation.dataOffset
        guard animation.dataSize >= 120 else {
            throw OniNativeXMLError.invalidDocument("\(sourceURL.lastPathComponent) has a truncated OBAN animation")
        }
        let flags = readUInt32(file.data, base + 12)
        let scale = OniLevelVector3(
            x: vectorLength(file.data, base + 64),
            y: vectorLength(file.data, base + 76),
            z: vectorLength(file.data, base + 88)
        )
        let length = Int(readUInt16(file.data, base + 114))
        let stop = Int(Int16(bitPattern: readUInt16(file.data, base + 116)))
        let keyCount = Int(readUInt16(file.data, base + 118))
        guard keyCount > 0, base + 120 + keyCount * 32 <= file.data.count else {
            throw OniNativeXMLError.invalidDocument("\(sourceURL.lastPathComponent) has invalid OBAN key frames")
        }
        var frames: [Frame] = []
        frames.reserveCapacity(keyCount)
        for index in 0..<keyCount {
            let offset = base + 120 + index * 32
            var rotation = (0..<4).map { readFloat(file.data, offset + $0 * 4) }
            var translation = OniLevelVector3(
                x: readFloat(file.data, offset + 16),
                y: readFloat(file.data, offset + 20),
                z: readFloat(file.data, offset + 24)
            )
            if flags & 0x0010 != 0 {
                rotation = multiply(object.orientation, rotation)
                translation = OniLevelVector3(
                    x: translation.x + object.position.x,
                    y: translation.y + object.position.y,
                    z: translation.z + object.position.z
                )
            }
            frames.append(Frame(
                scale: scale, rotation: rotation, translation: translation,
                time: Int(readUInt32(file.data, offset + 28))
            ))
        }
        let payload = try obanPayload(name: name, flags: flags, length: length, stop: stop, frames: frames)
        let archive = OniStandaloneArchiveBuilder.build(
            instances: [.init(tag: "OBAN", name: "OBAN" + name, payload: payload)], embeddedRaw: Data()
        )
        let output = outputDirectory.appendingPathComponent("OBAN\(name).oni")
        try archive.write(to: output, options: .atomic)
        return (output, frames[0], flags)
    }

    private static func build(_ item: OniLevelCameraImport, outputDirectory: URL) throws -> [BuiltClip] {
        try build(
            sourceURL: item.sourceURL, clips: item.clips,
            outputDirectory: outputDirectory, preferredNodeID: nil,
            requiresSingleAnimatedNode: true,
            setupOrientation: nil, setupPosition: nil
        )
    }

    private static func build(
        sourceURL: URL, clips: [OniLevelAnimationClip], outputDirectory: URL,
        preferredNodeID: String?, requiresSingleAnimatedNode: Bool,
        setupOrientation: [Float]?, setupPosition: OniLevelVector3?
    ) throws -> [BuiltClip] {
        let document = try XMLDocument(data: Data(contentsOf: sourceURL), options: [.nodePreserveAll])
        guard document.rootElement()?.localName == "COLLADA" || document.rootElement()?.name == "COLLADA" else {
            throw OniNativeXMLError.invalidDocument("animation file is not COLLADA: \(sourceURL.lastPathComponent)")
        }
        let meterNode = try document.nodes(forXPath: "//*[local-name()='unit']").first as? XMLElement
        let unitScale = 10 * (Float(meterNode?.attribute(forName: "meter")?.stringValue ?? "0.1") ?? 0.1)
        let upAxis = try document.nodes(forXPath: "//*[local-name()='up_axis']").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Y_UP"

        var sources: [String: Source] = [:]
        for element in try document.nodes(forXPath: "//*[local-name()='library_animations']//*[local-name()='source']").compactMap({ $0 as? XMLElement }) {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            let accessor = descendants(element, "accessor").first
            let stride = max(1, Int(accessor?.attribute(forName: "stride")?.stringValue ?? "1") ?? 1)
            let floatValues = children(element, "float_array").first?.stringValue?.split(whereSeparator: \Character.isWhitespace).compactMap { Float($0) } ?? []
            let nameValues = children(element, "Name_array").first?.stringValue?.split(whereSeparator: \Character.isWhitespace).map(String.init) ?? []
            sources[id] = Source(floats: floatValues, names: nameValues, stride: stride)
        }
        var samplers: [String: Sampler] = [:]
        for element in try document.nodes(forXPath: "//*[local-name()='library_animations']//*[local-name()='sampler']").compactMap({ $0 as? XMLElement }) {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            var links: [String: Source] = [:]
            for input in children(element, "input") {
                guard let semantic = input.attribute(forName: "semantic")?.stringValue,
                      let sourceID = input.attribute(forName: "source")?.stringValue.map(reference),
                      let source = sources[sourceID] else { continue }
                links[semantic] = source
            }
            guard let input = links["INPUT"], let output = links["OUTPUT"] else { continue }
            samplers[id] = Sampler(input: input, output: output, interpolation: links["INTERPOLATION"])
        }
        let channels: [Channel] = try document.nodes(forXPath: "//*[local-name()='library_animations']//*[local-name()='channel']").compactMap { node in
            guard let element = node as? XMLElement,
                  let sourceID = element.attribute(forName: "source")?.stringValue.map(reference),
                  let sampler = samplers[sourceID], let target = element.attribute(forName: "target")?.stringValue else { return nil }
            return Channel(sampler: sampler, target: target)
        }
        guard !channels.isEmpty else { throw OniNativeXMLError.invalidDocument("COLLADA has no animation channels: \(sourceURL.lastPathComponent)") }
        let nodeIDs = Set(channels.compactMap { $0.target.split(separator: "/").first.map(String.init) })
        let nodeID: String
        if let preferredNodeID {
            nodeID = preferredNodeID
        } else if !requiresSingleAnimatedNode, let first = channels.first?.target.split(separator: "/").first {
            nodeID = String(first)
        } else {
            guard nodeIDs.count == 1, let only = nodeIDs.first else {
                throw OniNativeXMLError.invalidDocument("camera COLLADA must animate exactly one node: \(sourceURL.lastPathComponent)")
            }
            nodeID = only
        }
        let nodes = try document.nodes(forXPath: "//*[local-name()='visual_scene']//*[local-name()='node']").compactMap { $0 as? XMLElement }
        guard let node = nodes.first(where: { $0.attribute(forName: "id")?.stringValue == nodeID }) else {
            throw OniNativeXMLError.invalidDocument("animation node '\(nodeID)' was not found")
        }
        let nodeChain = ancestorNodeChain(endingAt: node)
        let chainIDs = Set(nodeChain.compactMap { $0.attribute(forName: "id")?.stringValue })
        let chainChannels = channels.filter { channel in
            guard let targetID = channel.target.split(separator: "/").first else { return false }
            return chainIDs.contains(String(targetID))
        }
        let supportedTargets = Set(["translate.X", "translate.Y", "translate.Z", "rotX.ANGLE", "rotY.ANGLE", "rotZ.ANGLE"])
        for channel in chainChannels {
            let targetID = channel.target.split(separator: "/").first.map(String.init) ?? ""
            let property = String(channel.target.dropFirst(targetID.count + 1))
            guard supportedTargets.contains(property) else {
                throw OniNativeXMLError.invalidDocument("unsupported COLLADA animation target '\(property)'")
            }
        }
        let lastTime = chainChannels.compactMap { $0.sampler.input.floats.last }.max() ?? 0
        let totalFrames = max(1, Int((lastTime * 60).rounded()) + 1)
        let allFrames = try (0..<totalFrames).map { frame in
            try worldFrame(
                nodeChain: nodeChain, channels: chainChannels,
                frame: frame, unitScale: unitScale, upAxis: upAxis
            )
        }

        var outputs: [BuiltClip] = []
        for clip in clips {
            let end = min(clip.end ?? (allFrames.count - 1), allFrames.count - 1)
            guard clip.start >= 0, clip.start <= end else {
                throw OniNativeXMLError.invalidDocument("camera animation '\(clip.name)' has an invalid frame range")
            }
            let frames = allFrames[clip.start...end].enumerated().map { offset, frame in
                var rotation = frame.rotation
                var translation = frame.translation
                if clip.flags & 0x0010 != 0,
                   let setupOrientation, let setupPosition, setupOrientation.count == 4 {
                    rotation = multiply(setupOrientation, rotation)
                    translation = OniLevelVector3(
                        x: translation.x + setupPosition.x,
                        y: translation.y + setupPosition.y,
                        z: translation.z + setupPosition.z
                    )
                }
                return Frame(
                    scale: frame.scale, rotation: rotation,
                    translation: translation, time: offset
                )
            }
            let name = clip.prefix + clip.name + clip.suffix
            let payload = try obanPayload(name: name, flags: clip.flags, length: end - clip.start + 1, stop: clip.stop, frames: frames)
            let archive = OniStandaloneArchiveBuilder.build(
                instances: [.init(tag: "OBAN", name: "OBAN" + name, payload: payload)], embeddedRaw: Data()
            )
            let output = outputDirectory.appendingPathComponent("OBAN\(name).oni")
            try archive.write(to: output, options: .atomic)
            outputs.append(BuiltClip(name: name, url: output, firstFrame: frames[frames.startIndex]))
        }
        return outputs
    }

    private static func ancestorNodeChain(endingAt node: XMLElement) -> [XMLElement] {
        var chain: [XMLElement] = []
        var current: XMLElement? = node
        while let element = current, (element.localName ?? element.name) == "node" {
            chain.append(element)
            current = element.parent as? XMLElement
        }
        return chain.reversed()
    }

    private static func worldFrame(
        nodeChain: [XMLElement], channels: [Channel], frame: Int,
        unitScale: Float, upAxis: String
    ) throws -> Frame {
        var world = Frame(
            scale: OniLevelVector3(x: 1, y: 1, z: 1), rotation: [0, 0, 0, 1],
            translation: OniLevelVector3(x: 0, y: 0, z: 0), time: frame
        )
        for node in nodeChain {
            let nodeID = node.attribute(forName: "id")?.stringValue ?? ""
            let localChannels = channels.filter { $0.target.hasPrefix(nodeID + "/") }
            let local = try makeFrame(
                node: node, channels: localChannels, frame: frame,
                unitScale: unitScale, upAxis: upAxis
            )
            let scaledTranslation = OniLevelVector3(
                x: local.translation.x * world.scale.x,
                y: local.translation.y * world.scale.y,
                z: local.translation.z * world.scale.z
            )
            let rotatedTranslation = rotate(scaledTranslation, by: world.rotation)
            world = Frame(
                scale: OniLevelVector3(
                    x: world.scale.x * local.scale.x,
                    y: world.scale.y * local.scale.y,
                    z: world.scale.z * local.scale.z
                ),
                rotation: multiply(world.rotation, local.rotation),
                translation: OniLevelVector3(
                    x: world.translation.x + rotatedTranslation.x,
                    y: world.translation.y + rotatedTranslation.y,
                    z: world.translation.z + rotatedTranslation.z
                ),
                time: frame
            )
        }
        return world
    }

    private static func makeFrame(
        node: XMLElement, channels: [Channel], frame: Int, unitScale: Float, upAxis: String
    ) throws -> Frame {
        var values: [String: Float] = [:]
        var rotations: [(sid: String, axis: OniLevelVector3)] = []
        var scale = OniLevelVector3(x: 1, y: 1, z: 1)
        for element in childElements(node) {
            let name = element.localName ?? element.name ?? ""
            let numbers = element.stringValue?.split(whereSeparator: \Character.isWhitespace).compactMap { Float($0) } ?? []
            let sid = element.attribute(forName: "sid")?.stringValue ?? name
            if name == "translate", numbers.count == 3 {
                values[sid + ".X"] = numbers[0]; values[sid + ".Y"] = numbers[1]; values[sid + ".Z"] = numbers[2]
            } else if name == "rotate", numbers.count == 4 {
                rotations.append((sid, OniLevelVector3(x: numbers[0], y: numbers[1], z: numbers[2])))
                values[sid + ".ANGLE"] = numbers[3]
            } else if name == "scale", numbers.count == 3 {
                scale = OniLevelVector3(x: numbers[0], y: numbers[1], z: numbers[2])
            }
        }
        for channel in channels {
            let property = String(channel.target.split(separator: "/", maxSplits: 1)[1])
            values[property] = try sample(channel.sampler, frame: frame)
        }
        var translation = OniLevelVector3(
            x: (values["translate.X"] ?? 0) * unitScale,
            y: (values["translate.Y"] ?? 0) * unitScale,
            z: (values["translate.Z"] ?? 0) * unitScale
        )
        if upAxis == "Z_UP" { translation = OniLevelVector3(x: translation.x, y: translation.z, z: -translation.y) }
        var rotation: [Float] = [0, 0, 0, 1]
        for item in rotations {
            var axis = item.axis
            if upAxis == "Z_UP" { axis = OniLevelVector3(x: axis.x, y: axis.z, z: -axis.y) }
            rotation = multiply(rotation, axisQuaternion(axis, degrees: values[item.sid + ".ANGLE"] ?? 0))
        }
        return Frame(scale: scale, rotation: rotation, translation: translation, time: frame)
    }

    private static func sample(_ sampler: Sampler, frame: Int) throws -> Float {
        let times = sampler.input.floats
        let output = sampler.output.floats
        let stride = sampler.output.stride
        guard !times.isEmpty, output.count >= times.count * stride else { return 0 }
        let time = Float(frame) / 60
        if time <= times[0] { return output[0] }
        if time >= times[times.count - 1] { return output[(times.count - 1) * stride] }
        guard let upper = times.firstIndex(where: { $0 >= time }), upper > 0 else { return output[0] }
        if times[upper] == time { return output[upper * stride] }
        let interpolation = sampler.interpolation?.names.indices.contains(upper - 1) == true ? sampler.interpolation!.names[upper - 1] : "LINEAR"
        guard interpolation == "LINEAR" else { throw OniNativeXMLError.invalidDocument("unsupported camera interpolation '\(interpolation)'") }
        let factor = (time - times[upper - 1]) / (times[upper] - times[upper - 1])
        let lowerValue = output[(upper - 1) * stride], upperValue = output[upper * stride]
        return lowerValue + factor * (upperValue - lowerValue)
    }

    private static func obanPayload(name: String, flags: UInt32, length: Int, stop: Int, frames: [Frame]) throws -> Data {
        guard !name.isEmpty, length <= Int(UInt16.max), frames.count <= Int(UInt16.max),
              stop >= Int(Int16.min), stop <= Int(Int16.max), let first = frames.first else {
            throw OniNativeXMLError.invalidDocument("camera animation values exceed OBAN limits")
        }
        var data = Data(repeating: 0, count: 12)
        append(&data, flags)
        for value in transformMatrix(first) { append(&data, value) }
        for value in [first.scale.x, 0, 0, 0, first.scale.y, 0, 0, 0, first.scale.z, 0, 0, 0] as [Float] { append(&data, value) }
        append(&data, UInt16(1)); append(&data, UInt16(length)); append(&data, Int16(stop)); append(&data, UInt16(frames.count))
        for frame in frames {
            for value in frame.rotation { append(&data, value) }
            append(&data, frame.translation.x); append(&data, frame.translation.y); append(&data, frame.translation.z)
            append(&data, UInt32(frame.time))
        }
        return data
    }

    private static func transformMatrix(_ frame: Frame) -> [Float] {
        let q = frame.rotation, x=q[0], y=q[1], z=q[2], w=q[3], sx=frame.scale.x, sy=frame.scale.y, sz=frame.scale.z
        return [(1-2*(y*y+z*z))*sx,(2*(x*y+z*w))*sx,(2*(z*x-y*w))*sx,
                (2*(x*y-z*w))*sy,(1-2*(z*z+x*x))*sy,(2*(y*z+x*w))*sy,
                (2*(z*x+y*w))*sz,(2*(y*z-x*w))*sz,(1-2*(y*y+x*x))*sz,
                frame.translation.x,frame.translation.y,frame.translation.z]
    }
    private static func axisQuaternion(_ axis: OniLevelVector3, degrees: Float) -> [Float] { let h=degrees * .pi / 360; return [axis.x*sin(h),axis.y*sin(h),axis.z*sin(h),cos(h)] }
    private static func multiply(_ a: [Float], _ b: [Float]) -> [Float] { [a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0],-a[0]*b[2]+a[1]*b[3]+a[2]*b[0]+a[3]*b[1],a[0]*b[1]-a[1]*b[0]+a[2]*b[3]+a[3]*b[2],-a[0]*b[0]-a[1]*b[1]-a[2]*b[2]+a[3]*b[3]] }
    private static func rotate(_ vector: OniLevelVector3, by q: [Float]) -> OniLevelVector3 {
        let u = OniLevelVector3(x: q[0], y: q[1], z: q[2])
        let dotUV = u.x * vector.x + u.y * vector.y + u.z * vector.z
        let dotUU = u.x * u.x + u.y * u.y + u.z * u.z
        let cross = OniLevelVector3(
            x: u.y * vector.z - u.z * vector.y,
            y: u.z * vector.x - u.x * vector.z,
            z: u.x * vector.y - u.y * vector.x
        )
        return OniLevelVector3(
            x: 2 * dotUV * u.x + (q[3] * q[3] - dotUU) * vector.x + 2 * q[3] * cross.x,
            y: 2 * dotUV * u.y + (q[3] * q[3] - dotUU) * vector.y + 2 * q[3] * cross.y,
            z: 2 * dotUV * u.z + (q[3] * q[3] - dotUU) * vector.z + 2 * q[3] * cross.z
        )
    }
    private static func normalizedAnimationName(_ name: String) -> String {
        name.lowercased().hasPrefix("oban") ? String(name.dropFirst(4)) : name
    }
    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static func readFloat(_ data: Data, _ offset: Int) -> Float {
        Float(bitPattern: readUInt32(data, offset))
    }
    private static func vectorLength(_ data: Data, _ offset: Int) -> Float {
        let x = readFloat(data, offset), y = readFloat(data, offset + 4), z = readFloat(data, offset + 8)
        return sqrt(x * x + y * y + z * z)
    }
    private static func reference(_ value: String) -> String { value.hasPrefix("#") ? String(value.dropFirst()) : value }
    private static func childElements(_ element: XMLElement) -> [XMLElement] { element.children?.compactMap { $0 as? XMLElement } ?? [] }
    private static func children(_ element: XMLElement, _ name: String) -> [XMLElement] { childElements(element).filter { ($0.localName ?? $0.name) == name } }
    private static func descendants(_ element: XMLElement, _ name: String) -> [XMLElement] { childElements(element).flatMap { (($0.localName ?? $0.name) == name ? [$0] : []) + descendants($0, name) } }
    private static func append(_ data: inout Data, _ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff)) }
    private static func append(_ data: inout Data, _ value: Int16) { append(&data, UInt16(bitPattern: value)) }
    private static func append(_ data: inout Data, _ value: UInt32) { for shift in stride(from:0,to:32,by:8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
    private static func append(_ data: inout Data, _ value: Float) { append(&data, value.bitPattern) }
}
