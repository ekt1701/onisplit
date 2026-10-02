import Foundation

package struct OniLevelVector2: Hashable {
    package let x: Float
    package let y: Float
}

package struct OniLevelVector3: Hashable {
    package let x: Float
    package let y: Float
    package let z: Float
}

package struct OniColladaPolygon {
    package let positions: [OniLevelVector3]
    package let normals: [OniLevelVector3]
    package let textureCoordinates: [OniLevelVector2]
    package let materialSymbol: String
    package let additionalFlags: UInt32
    package let objectID: UInt32
    package let scriptID: Int32

    package init(
        positions: [OniLevelVector3],
        normals: [OniLevelVector3],
        textureCoordinates: [OniLevelVector2],
        materialSymbol: String,
        additionalFlags: UInt32 = 0,
        objectID: UInt32 = .max,
        scriptID: Int32 = 0
    ) {
        self.positions = positions
        self.normals = normals
        self.textureCoordinates = textureCoordinates
        self.materialSymbol = materialSymbol
        self.additionalFlags = additionalFlags
        self.objectID = objectID
        self.scriptID = scriptID
    }
}

package struct OniColladaGeometry {
    package let id: String
    package let name: String
    package let polygons: [OniColladaPolygon]
}

package struct OniColladaGeometryInstance {
    package let nodeName: String
    package let nodeID: String
    package let ancestorIDs: [String]
    package let geometryID: String
    package let materialNames: [String: String]
    package let polygons: [OniColladaPolygon]

    package init(
        nodeName: String, nodeID: String = "", ancestorIDs: [String] = [],
        geometryID: String, materialNames: [String: String], polygons: [OniColladaPolygon]
    ) {
        self.nodeName = nodeName
        self.nodeID = nodeID.isEmpty ? nodeName : nodeID
        self.ancestorIDs = ancestorIDs.isEmpty ? [self.nodeID] : ancestorIDs
        self.geometryID = geometryID
        self.materialNames = materialNames
        self.polygons = polygons
    }
}

package struct OniColladaGeometryDocument {
    package let sourceURL: URL
    package let unitScale: Float
    package let upAxis: String
    package let geometries: [String: OniColladaGeometry]
    package let instances: [OniColladaGeometryInstance]
    package let transparentMaterialNames: Set<String>

    package init(
        sourceURL: URL,
        unitScale: Float,
        upAxis: String,
        geometries: [String: OniColladaGeometry],
        instances: [OniColladaGeometryInstance],
        transparentMaterialNames: Set<String> = []
    ) {
        self.sourceURL = sourceURL
        self.unitScale = unitScale
        self.upAxis = upAxis
        self.geometries = geometries
        self.instances = instances
        self.transparentMaterialNames = transparentMaterialNames
    }
}

package enum OniColladaGeometryReader {
    private struct Source {
        let values: [Float]
        let stride: Int

        func vector2(_ index: Int) throws -> OniLevelVector2 {
            let offset = index * stride
            guard offset >= 0, offset + 1 < values.count else { throw OniDatError.outOfBounds("Collada vector2 source") }
            return OniLevelVector2(x: values[offset], y: values[offset + 1])
        }

        func vector3(_ index: Int) throws -> OniLevelVector3 {
            let offset = index * stride
            guard offset >= 0, offset + 2 < values.count else { throw OniDatError.outOfBounds("Collada vector3 source") }
            return OniLevelVector3(x: values[offset], y: values[offset + 1], z: values[offset + 2])
        }
    }

    private struct Input {
        let semantic: String
        let sourceID: String
        let offset: Int
    }

    package static func read(_ sourceURL: URL) throws -> OniColladaGeometryDocument {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: Data(contentsOf: sourceURL), options: [.nodePreserveAll])
        } catch {
            throw OniNativeXMLError.invalidDocument("Collada file \(sourceURL.lastPathComponent): \(error.localizedDescription)")
        }
        guard document.rootElement()?.localName == "COLLADA" || document.rootElement()?.name == "COLLADA" else {
            throw OniNativeXMLError.invalidDocument("\(sourceURL.lastPathComponent) is not a COLLADA document")
        }
        let unitNode = try document.nodes(forXPath: "//*[local-name()='unit']").first as? XMLElement
        let meter = Float(unitNode?.attribute(forName: "meter")?.stringValue ?? "1") ?? 1
        let unitScale = 10 * meter
        let upAxis = try document.nodes(forXPath: "//*[local-name()='up_axis']").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Y_UP"
        let geometryNodes = try document.nodes(forXPath: "//*[local-name()='library_geometries']/*[local-name()='geometry']").compactMap { $0 as? XMLElement }
        var rawGeometries: [String: OniColladaGeometry] = [:]
        var geometries: [String: OniColladaGeometry] = [:]
        for node in geometryNodes {
            let raw = try readGeometry(node, unitScale: 1, upAxis: "Y_UP")
            guard !raw.id.isEmpty else { throw OniNativeXMLError.invalidDocument("Collada geometry has no id") }
            rawGeometries[raw.id] = raw
            geometries[raw.id] = converted(raw, unitScale: unitScale, upAxis: upAxis)
        }
        let materialNames = try readMaterialNames(document)
        let transparentMaterialNames = try readTransparentMaterialNames(document, materialNames: materialNames)
        let instances = try readSceneInstances(document, geometries: rawGeometries, materialNames: materialNames, unitScale: unitScale, upAxis: upAxis)
        return OniColladaGeometryDocument(
            sourceURL: sourceURL,
            unitScale: unitScale,
            upAxis: upAxis,
            geometries: geometries,
            instances: instances,
            transparentMaterialNames: transparentMaterialNames
        )
    }

    private static func readTransparentMaterialNames(_ document: XMLDocument, materialNames: [String: String]) throws -> Set<String> {
        var transparentEffects = Set<String>()
        let effects = try document.nodes(forXPath: "//*[local-name()='library_effects']/*[local-name()='effect']").compactMap { $0 as? XMLElement }
        for effect in effects {
            let diffuse = try effect.nodes(forXPath: ".//*[local-name()='diffuse']/*[local-name()='texture']/@texture").first?.stringValue
            let transparent = try effect.nodes(forXPath: ".//*[local-name()='transparent']/*[local-name()='texture']/@texture").first?.stringValue
            if let diffuse, diffuse == transparent, let id = effect.attribute(forName: "id")?.stringValue {
                transparentEffects.insert(id)
            }
        }
        var names = Set<String>()
        let materials = try document.nodes(forXPath: "//*[local-name()='library_materials']/*[local-name()='material']").compactMap { $0 as? XMLElement }
        for material in materials {
            guard let id = material.attribute(forName: "id")?.stringValue,
                  let target = try material.nodes(forXPath: "./*[local-name()='instance_effect']/@url").first?.stringValue else { continue }
            let effectID = target.hasPrefix("#") ? String(target.dropFirst()) : target
            if transparentEffects.contains(effectID) { names.insert(materialNames[id] ?? id) }
        }
        return names
    }

    private static func converted(_ geometry: OniColladaGeometry, unitScale: Float, upAxis: String) -> OniColladaGeometry {
        OniColladaGeometry(
            id: geometry.id,
            name: geometry.name,
            polygons: geometry.polygons.map { polygon in
                OniColladaPolygon(
                    positions: polygon.positions.map { convertPosition($0, scale: unitScale, upAxis: upAxis) },
                    normals: polygon.normals.map { convertNormal($0, upAxis: upAxis) },
                    textureCoordinates: polygon.textureCoordinates,
                    materialSymbol: polygon.materialSymbol,
                    additionalFlags: polygon.additionalFlags,
                    objectID: polygon.objectID,
                    scriptID: polygon.scriptID
                )
            }
        )
    }

    private static func readMaterialNames(_ document: XMLDocument) throws -> [String: String] {
        var imageNames: [String: String] = [:]
        let images = try document.nodes(forXPath: "//*[local-name()='library_images']/*[local-name()='image']")
            .compactMap { $0 as? XMLElement }
        for image in images {
            guard let id = image.attribute(forName: "id")?.stringValue,
                  let source = try image.nodes(forXPath: "./*[local-name()='init_from']").first?.stringValue,
                  !source.isEmpty else { continue }
            let path = (source.removingPercentEncoding ?? source).replacingOccurrences(of: "\\", with: "/")
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if !name.isEmpty { imageNames[id] = name }
        }

        var effectNames: [String: String] = [:]
        let effects = try document.nodes(forXPath: "//*[local-name()='library_effects']/*[local-name()='effect']")
            .compactMap { $0 as? XMLElement }
        for effect in effects {
            guard let effectID = effect.attribute(forName: "id")?.stringValue,
                  let texture = try effect.nodes(forXPath: ".//*[local-name()='diffuse']/*[local-name()='texture']").first as? XMLElement,
                  let samplerID = texture.attribute(forName: "texture")?.stringValue else { continue }
            let parameters = try effect.nodes(forXPath: ".//*[local-name()='newparam']").compactMap { $0 as? XMLElement }
            guard let sampler = parameters.first(where: { $0.attribute(forName: "sid")?.stringValue == samplerID }),
                  let surfaceID = try sampler.nodes(forXPath: "./*[local-name()='sampler2D']/*[local-name()='source']").first?.stringValue,
                  let surface = parameters.first(where: { $0.attribute(forName: "sid")?.stringValue == surfaceID }),
                  let imageID = try surface.nodes(forXPath: "./*[local-name()='surface']/*[local-name()='init_from']").first?.stringValue,
                  let name = imageNames[imageID] else { continue }
            effectNames[effectID] = name
        }

        let nodes = try document.nodes(forXPath: "//*[local-name()='library_materials']/*[local-name()='material']").compactMap { $0 as? XMLElement }
        return Dictionary(uniqueKeysWithValues: nodes.compactMap { element in
            guard let id = element.attribute(forName: "id")?.stringValue else { return nil }
            let target = try? element.nodes(forXPath: "./*[local-name()='instance_effect']/@url").first?.stringValue
            let effectID = target.map(reference)
            return (id, effectID.flatMap { effectNames[$0] } ?? "notfoundtex")
        })
    }

    private static func readSceneInstances(
        _ document: XMLDocument,
        geometries: [String: OniColladaGeometry],
        materialNames: [String: String],
        unitScale: Float,
        upAxis: String
    ) throws -> [OniColladaGeometryInstance] {
        let selectedID = try document.nodes(forXPath: "//*[local-name()='scene']/*[local-name()='instance_visual_scene']")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "url")?.stringValue }
            .map(reference)
            .first
        let scenes = try document.nodes(forXPath: "//*[local-name()='library_visual_scenes']/*[local-name()='visual_scene']").compactMap { $0 as? XMLElement }
        guard let scene = scenes.first(where: { selectedID == nil || $0.attribute(forName: "id")?.stringValue == selectedID }) else { return [] }
        let sceneID = scene.attribute(forName: "id")?.stringValue ?? ""
        var result: [OniColladaGeometryInstance] = []
        for node in children(scene, named: "node") {
            try readSceneNode(
                node,
                parentTransform: .identity,
                ancestorIDs: sceneID.isEmpty ? [] : [sceneID],
                geometries: geometries,
                materialNames: materialNames,
                unitScale: unitScale,
                upAxis: upAxis,
                result: &result
            )
        }
        return result
    }

    private static func readSceneNode(
        _ node: XMLElement,
        parentTransform: Matrix4,
        ancestorIDs: [String],
        geometries: [String: OniColladaGeometry],
        materialNames: [String: String],
        unitScale: Float,
        upAxis: String,
        result: inout [OniColladaGeometryInstance]
    ) throws {
        let localTransform = try nodeTransform(node)
        let worldTransform = localTransform * parentTransform
        let nodeID = node.attribute(forName: "id")?.stringValue
            ?? node.attribute(forName: "name")?.stringValue ?? ""
        let nodeName = node.attribute(forName: "name")?.stringValue ?? nodeID
        let nodeAncestry = ancestorIDs + [nodeID]
        for element in children(node, named: "instance_geometry") {
            guard let target = element.attribute(forName: "url")?.stringValue.map(reference), let geometry = geometries[target] else { continue }
            var bindings: [String: String] = [:]
            for binding in descendants(element, named: "instance_material") {
                guard let symbol = binding.attribute(forName: "symbol")?.stringValue,
                      let targetID = binding.attribute(forName: "target")?.stringValue.map(reference) else { continue }
                bindings[symbol] = materialNames[targetID] ?? "notfoundtex"
            }
            let transformed = geometry.polygons.map { polygon in
                OniColladaPolygon(
                    positions: polygon.positions.map {
                        convertPosition(worldTransform.transformPoint($0), scale: unitScale, upAxis: upAxis)
                    },
                    normals: polygon.normals.map {
                        convertNormal(worldTransform.transformNormal($0).normalized, upAxis: upAxis)
                    },
                    textureCoordinates: polygon.textureCoordinates,
                    materialSymbol: bindings[polygon.materialSymbol] ?? "notfoundtex",
                    additionalFlags: polygon.additionalFlags,
                    objectID: polygon.objectID,
                    scriptID: polygon.scriptID
                )
            }
            result.append(OniColladaGeometryInstance(
                nodeName: nodeName, nodeID: nodeID, ancestorIDs: nodeAncestry,
                geometryID: target, materialNames: bindings, polygons: transformed
            ))
        }
        for child in children(node, named: "node") {
            try readSceneNode(
                child, parentTransform: worldTransform, ancestorIDs: nodeAncestry,
                geometries: geometries, materialNames: materialNames,
                unitScale: unitScale, upAxis: upAxis, result: &result
            )
        }
    }

    private static func nodeTransform(_ node: XMLElement) throws -> Matrix4 {
        var transforms: [Matrix4] = []
        for element in childElements(node) {
            let values = floats(element.stringValue)
            switch localName(element) {
            case "matrix":
                guard values.count == 16 else { throw OniNativeXMLError.invalidDocument("Collada matrix must have 16 values") }
                transforms.append(Matrix4(colladaValues: values))
            case "translate":
                guard values.count == 3 else { throw OniNativeXMLError.invalidDocument("Collada translate must have 3 values") }
                transforms.append(.translation(values[0], values[1], values[2]))
            case "scale":
                guard values.count == 3 else { throw OniNativeXMLError.invalidDocument("Collada scale must have 3 values") }
                transforms.append(.scale(values[0], values[1], values[2]))
            case "rotate":
                guard values.count == 4 else { throw OniNativeXMLError.invalidDocument("Collada rotate must have 4 values") }
                transforms.append(.rotation(axis: OniLevelVector3(x: values[0], y: values[1], z: values[2]), degrees: values[3]))
            default:
                continue
            }
        }
        return transforms.reversed().reduce(.identity) { $0 * $1 }
    }

    private static func readGeometry(_ geometry: XMLElement, unitScale: Float, upAxis: String) throws -> OniColladaGeometry {
        guard let mesh = children(geometry, named: "mesh").first else {
            throw OniNativeXMLError.invalidDocument("Collada geometry is missing mesh")
        }
        var sources: [String: Source] = [:]
        for sourceElement in children(mesh, named: "source") {
            guard let id = sourceElement.attribute(forName: "id")?.stringValue,
                  let array = children(sourceElement, named: "float_array").first else { continue }
            let values = floats(array.stringValue)
            let accessor = descendants(sourceElement, named: "accessor").first
            let stride = Int(accessor?.attribute(forName: "stride")?.stringValue ?? "1") ?? 1
            guard stride > 0 else { throw OniNativeXMLError.invalidDocument("Collada source \(id) has invalid stride") }
            sources[id] = Source(values: values, stride: stride)
        }

        var vertices: [String: [String: String]] = [:]
        for element in children(mesh, named: "vertices") {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            var bindings: [String: String] = [:]
            for input in children(element, named: "input") {
                guard let semantic = input.attribute(forName: "semantic")?.stringValue,
                      let source = input.attribute(forName: "source")?.stringValue else { continue }
                bindings[semantic] = reference(source)
            }
            vertices[id] = bindings
        }

        var polygons: [OniColladaPolygon] = []
        for primitive in childElements(mesh) where ["triangles", "polylist", "polygons"].contains(localName(primitive)) {
            polygons += try readPrimitive(primitive, sources: sources, vertices: vertices, unitScale: unitScale, upAxis: upAxis)
        }
        return OniColladaGeometry(
            id: geometry.attribute(forName: "id")?.stringValue ?? "",
            name: geometry.attribute(forName: "name")?.stringValue ?? geometry.attribute(forName: "id")?.stringValue ?? "",
            polygons: polygons
        )
    }

    private static func readPrimitive(
        _ primitive: XMLElement,
        sources: [String: Source],
        vertices: [String: [String: String]],
        unitScale: Float,
        upAxis: String
    ) throws -> [OniColladaPolygon] {
        let inputs = children(primitive, named: "input").compactMap { element -> Input? in
            guard let semantic = element.attribute(forName: "semantic")?.stringValue,
                  let source = element.attribute(forName: "source")?.stringValue else { return nil }
            return Input(semantic: semantic, sourceID: reference(source), offset: Int(element.attribute(forName: "offset")?.stringValue ?? "0") ?? 0)
        }
        let indexStride = max(1, (inputs.map(\.offset).max() ?? 0) + 1)
        let vertexCounts: [Int]
        switch localName(primitive) {
        case "triangles":
            vertexCounts = Array(repeating: 3, count: Int(primitive.attribute(forName: "count")?.stringValue ?? "0") ?? 0)
        case "polylist":
            vertexCounts = integers(children(primitive, named: "vcount").first?.stringValue)
        default:
            vertexCounts = children(primitive, named: "p").map { integers($0.stringValue).count / indexStride }
        }
        let packedIndices = children(primitive, named: "p").flatMap { integers($0.stringValue) }
        let material = primitive.attribute(forName: "material")?.stringValue ?? ""
        var result: [OniColladaPolygon] = []
        var vertexBase = 0
        for vertexCount in vertexCounts {
            guard vertexCount >= 0, (vertexBase + vertexCount) * indexStride <= packedIndices.count else {
                throw OniNativeXMLError.invalidDocument("Collada primitive index count does not match vcount")
            }
            var positionValues: [OniLevelVector3] = []
            var normalValues: [OniLevelVector3] = []
            var textureValues: [OniLevelVector2] = []
            for vertex in 0..<vertexCount {
                let base = (vertexBase + vertex) * indexStride
                for input in inputs {
                    let index = packedIndices[base + input.offset]
                    if input.semantic == "VERTEX" {
                        let bindings = vertices[input.sourceID] ?? [:]
                        if let sourceID = bindings["POSITION"], let source = sources[sourceID] {
                            positionValues.append(convertPosition(try source.vector3(index), scale: unitScale, upAxis: upAxis))
                        }
                        if let sourceID = bindings["NORMAL"], let source = sources[sourceID] {
                            normalValues.append(convertNormal(try source.vector3(index), upAxis: upAxis))
                        }
                    } else if input.semantic == "POSITION", let source = sources[input.sourceID] {
                        positionValues.append(convertPosition(try source.vector3(index), scale: unitScale, upAxis: upAxis))
                    } else if input.semantic == "NORMAL", let source = sources[input.sourceID] {
                        normalValues.append(convertNormal(try source.vector3(index), upAxis: upAxis))
                    } else if input.semantic == "TEXCOORD", let source = sources[input.sourceID] {
                        textureValues.append(try source.vector2(index))
                    }
                }
            }
            result.append(OniColladaPolygon(positions: positionValues, normals: normalValues, textureCoordinates: textureValues, materialSymbol: material))
            vertexBase += vertexCount
        }
        return result
    }

    private static func convertPosition(_ value: OniLevelVector3, scale: Float, upAxis: String) -> OniLevelVector3 {
        if upAxis == "Z_UP" { return OniLevelVector3(x: value.x * scale, y: value.z * scale, z: -value.y * scale) }
        return OniLevelVector3(x: value.x * scale, y: value.y * scale, z: value.z * scale)
    }

    private static func convertNormal(_ value: OniLevelVector3, upAxis: String) -> OniLevelVector3 {
        if upAxis == "Z_UP" { return OniLevelVector3(x: value.x, y: value.z, z: -value.y) }
        return value
    }

    private static func floats(_ text: String?) -> [Float] {
        text?.split(whereSeparator: \Character.isWhitespace).compactMap { Float($0) } ?? []
    }

    private static func integers(_ text: String?) -> [Int] {
        text?.split(whereSeparator: \Character.isWhitespace).compactMap { Int($0) } ?? []
    }

    private static func reference(_ value: String) -> String { value.hasPrefix("#") ? String(value.dropFirst()) : value }
    private static func localName(_ element: XMLElement) -> String { element.localName ?? element.name ?? "" }
    private static func childElements(_ element: XMLElement) -> [XMLElement] { element.children?.compactMap { $0 as? XMLElement } ?? [] }
    private static func children(_ element: XMLElement, named name: String) -> [XMLElement] { childElements(element).filter { localName($0) == name } }
    private static func descendants(_ element: XMLElement, named name: String) -> [XMLElement] {
        childElements(element).flatMap { child -> [XMLElement] in
            (localName(child) == name ? [child] : []) + descendants(child, named: name)
        }
    }
}

private extension OniLevelVector3 {
    var normalized: OniLevelVector3 {
        let length = sqrt(x * x + y * y + z * z)
        guard length > Float.leastNonzeroMagnitude else { return self }
        return OniLevelVector3(x: x / length, y: y / length, z: z / length)
    }
}

private struct Matrix4 {
    let m: [Float]

    static let identity = Matrix4(m: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    init(m: [Float]) { self.m = m }

    init(colladaValues v: [Float]) {
        m = [
            v[0], v[4], v[8], v[12],
            v[1], v[5], v[9], v[13],
            v[2], v[6], v[10], v[14],
            v[3], v[7], v[11], v[15],
        ]
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> Matrix4 {
        Matrix4(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1])
    }

    static func scale(_ x: Float, _ y: Float, _ z: Float) -> Matrix4 {
        Matrix4(m: [x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1])
    }

    static func rotation(axis: OniLevelVector3, degrees: Float) -> Matrix4 {
        let a = axis.normalized
        let radians = degrees * .pi / 180
        let s = sin(radians), c = cos(radians), d = 1 - c
        return Matrix4(m: [
            a.x * a.x + c * (1 - a.x * a.x), a.x * a.y * d + s * a.z, a.x * a.z * d - s * a.y, 0,
            a.x * a.y * d - s * a.z, a.y * a.y + c * (1 - a.y * a.y), a.y * a.z * d + s * a.x, 0,
            a.x * a.z * d + s * a.y, a.y * a.z * d - s * a.x, a.z * a.z + c * (1 - a.z * a.z), 0,
            0, 0, 0, 1,
        ])
    }

    func transformPoint(_ v: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(
            x: v.x * m[0] + v.y * m[4] + v.z * m[8] + m[12],
            y: v.x * m[1] + v.y * m[5] + v.z * m[9] + m[13],
            z: v.x * m[2] + v.y * m[6] + v.z * m[10] + m[14]
        )
    }

    func transformNormal(_ v: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(
            x: v.x * m[0] + v.y * m[4] + v.z * m[8],
            y: v.x * m[1] + v.y * m[5] + v.z * m[9],
            z: v.x * m[2] + v.y * m[6] + v.z * m[10]
        )
    }

    static func * (lhs: Matrix4, rhs: Matrix4) -> Matrix4 {
        var values = Array(repeating: Float.zero, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                var value: Float = 0
                for index in 0..<4 {
                    value += lhs.m[row * 4 + index] * rhs.m[index * 4 + column]
                }
                values[row * 4 + column] = value
            }
        }
        return Matrix4(m: values)
    }
}
