import Foundation

package struct OniAkiraPlane: Hashable {
    package let normal: OniLevelVector3
    package let d: Float
}

package struct OniAkiraPolygon {
    package let pointIndices: [Int]
    package let textureCoordinateIndices: [Int]
    package let planeIndex: Int
    package let materialIndex: Int
    package let objectName: String
    package let fileName: String
    package var flags: UInt32
    package let objectID: UInt32
    package let scriptID: Int32
    package let minimum: OniLevelVector3
    package let maximum: OniLevelVector3
}

package struct OniAkiraGeometry {
    package let points: [OniLevelVector3]
    package let textureCoordinates: [OniLevelVector2]
    package let planes: [OniAkiraPlane]
    package let materials: [String]
    package let polygons: [OniAkiraPolygon]
    package let ignoredDegeneratePolygonCount: Int
    package let ignoredUnsupportedPolygonCount: Int

    package var pointArrayPayload: Data {
        var data = Data(repeating: 0, count: 12)
        let minimum = OniLevelVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0)
        let maximum = OniLevelVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        append(&data, minimum)
        append(&data, maximum)
        let divisor = Float(max(points.count, 1))
        let center = OniLevelVector3(
            x: points.reduce(0) { $0 + $1.x } / divisor,
            y: points.reduce(0) { $0 + $1.y } / divisor,
            z: points.reduce(0) { $0 + $1.z } / divisor
        )
        append(&data, center)
        append(&data, sqrt(points.map { point in
            let x = point.x - center.x, y = point.y - center.y, z = point.z - center.z
            return x * x + y * y + z * z
        }.max() ?? 0))
        append(&data, UInt32(points.count))
        for point in points { append(&data, point) }
        return data
    }

    package var planeArrayPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(planes.count))
        for plane in planes { append(&data, plane.normal); append(&data, plane.d) }
        return data
    }

    package var textureCoordinateArrayPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(textureCoordinates.count))
        for value in textureCoordinates { append(&data, value.x); append(&data, value.y) }
        data.append(Data(repeating: 0, count: 480))
        return data
    }

    package var polygonGeometryPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(polygons.count))
        for polygon in polygons {
            let points = paddedFour(polygon.pointIndices)
            let textureCoordinates = paddedFour(polygon.textureCoordinateIndices)
            for index in points { append(&data, UInt32(index)) }
            for index in textureCoordinates { append(&data, UInt32(index)) }
            for _ in 0..<4 { append(&data, UInt32(0xffcf_cfcf)) }
            append(&data, polygon.flags)
            append(&data, polygon.objectID)
        }
        return data
    }

    package var polygonMaterialPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(polygons.count))
        for polygon in polygons { append(&data, UInt32(polygon.materialIndex)) }
        return data
    }

    package var polygonCollisionPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(polygons.count))
        for polygon in polygons {
            append(&data, UInt32(polygon.planeIndex))
            append(&data, polygon.minimum)
            append(&data, polygon.maximum)
        }
        return data
    }

    package func textureMapPayload(instanceIDs: [UInt32]) -> Data {
        precondition(instanceIDs.count == materials.count)
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(instanceIDs.count))
        for instanceID in instanceIDs { append(&data, instanceID) }
        return data
    }

    package var scriptPolygonIndexPayload: Data {
        indexArrayPayload(scriptEntries.map { UInt32($0.polygonIndex) })
    }

    package var scriptIDPayload: Data {
        indexArrayPayload(scriptEntries.map { UInt32(bitPattern: $0.scriptID) })
    }

    private var scriptEntries: [(scriptID: Int32, polygonIndex: Int)] {
        polygons.enumerated().compactMap { index, polygon in
            polygon.scriptID == 0 ? nil : (polygon.scriptID, index)
        }.sorted { first, second in
            first.scriptID == second.scriptID ? first.polygonIndex < second.polygonIndex : first.scriptID < second.scriptID
        }
    }

    private func indexArrayPayload(_ values: [UInt32]) -> Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(values.count))
        for value in values { append(&data, value) }
        return data
    }

    private func paddedFour(_ values: [Int]) -> [Int] {
        guard values.count == 3 else { return Array(values.prefix(4)) }
        return values + [values[2]]
    }

    private func append(_ data: inout Data, _ value: OniLevelVector3) {
        append(&data, value.x); append(&data, value.y); append(&data, value.z)
    }

    private func append(_ data: inout Data, _ value: Float) { append(&data, value.bitPattern) }
    private func append(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8((value >> 24) & 0xff))
    }
}

package enum OniAkiraGeometryBuilder {
    package static func build(from documents: [OniColladaGeometryDocument]) -> OniAkiraGeometry {
        var points: [OniLevelVector3] = []
        var pointMap: [OniLevelVector3: Int] = [:]
        var textureCoordinates: [OniLevelVector2] = []
        var textureMap: [OniLevelVector2: Int] = [:]
        var planes: [OniAkiraPlane] = []
        var planeMap: [OniAkiraPlane: Int] = [:]
        var materials: [String] = []
        var materialMap: [String: Int] = [:]
        var polygons: [OniAkiraPolygon] = []
        var degenerateCount = 0
        var unsupportedCount = 0

        func add<T: Hashable>(_ value: T, to values: inout [T], map: inout [T: Int]) -> Int {
            if let index = map[value] { return index }
            let index = values.count
            values.append(value)
            map[value] = index
            return index
        }

        for document in documents {
            for instance in document.instances {
                for polygon in instance.polygons {
                    guard polygon.positions.count == 3 || polygon.positions.count == 4 else {
                        unsupportedCount += 1
                        continue
                    }
                    guard let plane = plane(for: polygon.positions) else {
                        degenerateCount += 1
                        continue
                    }
                    let pointIndices = polygon.positions.map { add($0, to: &points, map: &pointMap) }
                    let uvValues: [OniLevelVector2]
                    if polygon.textureCoordinates.count == polygon.positions.count {
                        uvValues = polygon.textureCoordinates
                    } else {
                        uvValues = Array(repeating: OniLevelVector2(x: 0, y: 0), count: polygon.positions.count)
                    }
                    let uvIndices = uvValues.map { add($0, to: &textureCoordinates, map: &textureMap) }
                    let planeIndex = add(plane, to: &planes, map: &planeMap)
                    let materialName = polygon.materialSymbol.isEmpty ? "NONE" : polygon.materialSymbol
                    let materialIndex = add(materialName, to: &materials, map: &materialMap)
                    let bounds = boundingBox(polygon.positions)
                    let transparencyFlags: UInt32 = document.transparentMaterialNames.contains(materialName) ? 0x0001_0280 : 0
                    polygons.append(OniAkiraPolygon(
                        pointIndices: pointIndices,
                        textureCoordinateIndices: uvIndices,
                        planeIndex: planeIndex,
                        materialIndex: materialIndex,
                        objectName: instance.nodeName,
                        fileName: document.sourceURL.lastPathComponent,
                        flags: flags(for: polygon.positions, plane: plane)
                            | polygon.additionalFlags | transparencyFlags | materialFlags(for: materialName),
                        objectID: polygon.objectID,
                        scriptID: polygon.scriptID,
                        minimum: bounds.0,
                        maximum: bounds.1
                    ))
                }
            }
        }
        return OniAkiraGeometry(
            points: points,
            textureCoordinates: textureCoordinates,
            planes: planes,
            materials: materials,
            polygons: polygons,
            ignoredDegeneratePolygonCount: degenerateCount,
            ignoredUnsupportedPolygonCount: unsupportedCount
        )
    }

    private static func plane(for points: [OniLevelVector3]) -> OniAkiraPlane? {
        let a = subtract(points[1], points[0])
        let b = subtract(points[2], points[0])
        var normal = cross(a, b)
        let lengthSquared = dot(normal, normal)
        guard lengthSquared >= 0.0001 else { return nil }
        let inverseLength = 1 / sqrt(lengthSquared)
        normal = OniLevelVector3(x: normal.x * inverseLength, y: normal.y * inverseLength, z: normal.z * inverseLength)

        let minimum = OniLevelVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0)
        let maximum = OniLevelVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        if abs(maximum.x - minimum.x) < 0.0001 {
            normal = OniLevelVector3(x: normal.x < 0 ? -1 : 1, y: 0, z: 0)
        } else if abs(maximum.y - minimum.y) < 0.0001 {
            normal = OniLevelVector3(x: 0, y: normal.y < 0 ? -1 : 1, z: 0)
        } else if abs(maximum.z - minimum.z) < 0.0001 {
            normal = OniLevelVector3(x: 0, y: 0, z: normal.z < 0 ? -1 : 1)
        } else {
            normal = OniLevelVector3(
                x: (normal.x * 10_000).rounded() / 10_000,
                y: (normal.y * 10_000).rounded() / 10_000,
                z: (normal.z * 10_000).rounded() / 10_000
            )
        }
        return OniAkiraPlane(normal: normal, d: -dot(normal, points[0]))
    }

    private static func boundingBox(_ points: [OniLevelVector3]) -> (OniLevelVector3, OniLevelVector3) {
        (
            OniLevelVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0),
            OniLevelVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        )
    }

    private static func flags(for points: [OniLevelVector3], plane: OniAkiraPlane) -> UInt32 {
        let xy = projectedArea(points) { OniLevelVector2(x: $0.x, y: $0.y) }
        let xz = projectedArea(points) { OniLevelVector2(x: $0.x, y: $0.z) }
        let yz = projectedArea(points) { OniLevelVector2(x: $0.z, y: $0.y) }
        let projection: UInt32
        if xy > yz { projection = xy > xz ? 1 : 2 }
        else { projection = yz > xz ? 3 : 2 }
        let orientation: UInt32 = abs(plane.normal.y) < 0.3420201 ? 0x0010_0000 : 0x0008_0000
        let triangle: UInt32 = points.count == 3 ? 0x0000_0040 : 0
        return (projection << 25) | orientation | triangle
    }

    private static func materialFlags(for materialName: String) -> UInt32 {
        switch materialName.lowercased() {
        case "_marker_door": return 0x0000_0a81
        case "_marker_ghost": return 0x0000_0a82
        case "_marker_stairs": return 0x0000_6210
        case "_marker_danger": return 0x0003_2800
        case "_marker_barrier": return 0x0000_6000
        case "_marker_impassable": return 0x0000_2000
        case "_marker_blackness": return 0x0000_0a00
        case "_marker_floor": return 0x0000_0800
        default: return materialName.lowercased().hasPrefix("lmap_") ? 0x0801_0800 : 0
        }
    }

    private static func projectedArea(_ points: [OniLevelVector3], project: (OniLevelVector3) -> OniLevelVector2) -> Float {
        let values = points.map(project)
        var area: Float = 0
        for index in values.indices {
            let next = values[(index + 1) % values.count]
            area += values[index].x * next.y - values[index].y * next.x
        }
        return abs(area * 0.5)
    }

    private static func subtract(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func cross(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }
}
