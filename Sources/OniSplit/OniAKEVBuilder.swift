import Foundation

package struct OniAKEVBuildResult {
    package let fileName: String
    package let archiveData: Data
    package let geometry: OniAkiraGeometry
    package let rooms: OniRoomArchive
    package let spatialOctree: OniSpatialOctree
    package let transparencyBSP: OniTransparencyBSP
}

package enum OniAKEVBuilder {
    package static func build(
        name: String,
        environment: [OniColladaGeometryDocument],
        roomGeometry: OniRoomGeometry,
        topology: OniRoomTopology,
        grids: [OniRoomGrid],
        debug: Bool = false
    ) -> OniAKEVBuildResult {
        let environmentGeometry = OniAkiraGeometryBuilder.build(from: environment)
        let ghostDocument = OniColladaGeometryDocument(
            sourceURL: URL(fileURLWithPath: "generated-room-ghosts.dae"),
            unitScale: 1,
            upAxis: "Y_UP",
            geometries: [:],
            instances: roomGeometry.ghosts.enumerated().map { index, ghost in
                OniColladaGeometryInstance(
                    nodeName: "ghost_\(index)",
                    geometryID: "ghost_\(index)",
                    materialNames: ["_marker_ghost": "_marker_ghost"],
                    polygons: [OniColladaPolygon(
                        positions: ghost.points,
                        normals: Array(repeating: ghost.normal, count: ghost.points.count),
                        textureCoordinates: Array(repeating: OniLevelVector2(x: 0, y: 0), count: ghost.points.count),
                        materialSymbol: "_marker_ghost",
                        additionalFlags: 0x0000_0a82
                    )]
                )
            }
        )
        var geometry = OniAkiraGeometryBuilder.build(from: environment + [ghostDocument])
        var polygons = geometry.polygons
        for connection in topology.connections {
            let polygonIndex = environmentGeometry.polygons.count + connection.ghostIndex
            guard polygons.indices.contains(polygonIndex) else { continue }
            polygons[polygonIndex].flags &= ~UInt32(0x0000_000e)
            switch connection.kind {
            case .ghost:
                polygons[polygonIndex].flags |= 0x0000_0002
            case .stairsUp:
                polygons[polygonIndex].flags |= 0x0000_0004
            case .stairsDown:
                polygons[polygonIndex].flags |= 0x0000_0008
            }
        }
        geometry = OniAkiraGeometry(
            points: geometry.points,
            textureCoordinates: geometry.textureCoordinates,
            planes: geometry.planes,
            materials: geometry.materials,
            polygons: polygons,
            ignoredDegeneratePolygonCount: geometry.ignoredDegeneratePolygonCount,
            ignoredUnsupportedPolygonCount: geometry.ignoredUnsupportedPolygonCount
        )
        var planes = geometry.planes
        var planeIndices = Dictionary(uniqueKeysWithValues: planes.enumerated().map { ($0.element, $0.offset) })
        let ghostPolygonIndices = topology.connections.map { environmentGeometry.polygons.count + $0.ghostIndex }
        let rooms = OniRoomArchiveBuilder.build(
            topology: topology,
            grids: grids,
            ghostPolygonIndices: ghostPolygonIndices
        ) { plane in
            if let index = planeIndices[plane] { return index }
            let index = planes.count
            planes.append(plane)
            planeIndices[plane] = index
            return index
        }
        geometry = OniAkiraGeometry(
            points: geometry.points,
            textureCoordinates: geometry.textureCoordinates,
            planes: planes,
            materials: geometry.materials,
            polygons: geometry.polygons,
            ignoredDegeneratePolygonCount: geometry.ignoredDegeneratePolygonCount,
            ignoredUnsupportedPolygonCount: geometry.ignoredUnsupportedPolygonCount
        )

        var raw = Data(repeating: 0, count: 32)
        let debugPayload = agdbPayload(geometry: geometry, raw: &raw, enabled: debug)
        var rawOffsets: [UInt32] = []
        for part in rooms.rawGridParts {
            pad32(&raw)
            rawOffsets.append(UInt32(raw.count))
            raw.append(part)
        }
        let spatialOctree = OniSpatialOctreeBuilder.build(
            geometry: geometry,
            polygonCount: debug ? geometry.polygons.count : environmentGeometry.polygons.count,
            topology: topology
        )
        let transparentMaterialNames = environment.reduce(into: Set<String>()) { result, document in
            result.formUnion(document.transparentMaterialNames)
        }
        let transparencyBSP = OniTransparencyBSPBuilder.build(
            geometry: geometry,
            transparentMaterialNames: transparentMaterialNames,
            polygonCount: debug ? geometry.polygons.count : environmentGeometry.polygons.count
        )

        let coreCount = 23
        let textureStart = coreCount
        let pointer: (Int) -> UInt32 = { UInt32($0 << 8) | 1 }
        let boundingPoints = geometry.points + roomGeometry.floors.flatMap(\.points)
        var definitions: [OniStandaloneInstanceDefinition] = []
        definitions.append(.init(tag: "AKEV", name: "AKEV" + name, payload: akevPayload(pointer: pointer, points: boundingPoints)))
        definitions.append(.init(tag: "PNTA", payload: geometry.pointArrayPayload))
        definitions.append(.init(tag: "PLEA", payload: geometry.planeArrayPayload))
        definitions.append(.init(tag: "TXCA", payload: geometry.textureCoordinateArrayPayload))
        definitions.append(.init(tag: "AGQG", payload: geometry.polygonGeometryPayload))
        definitions.append(.init(tag: "AGQR", payload: geometry.polygonMaterialPayload))
        definitions.append(.init(tag: "AGQC", payload: geometry.polygonCollisionPayload))
        definitions.append(.init(tag: "AGDB", payload: debugPayload))
        definitions.append(.init(tag: "TXMA", payload: geometry.textureMapPayload(instanceIDs: geometry.materials.indices.map { pointer(textureStart + $0) })))
        definitions.append(.init(tag: "AKVA", payload: rooms.akvaPayload(rawOffsets: rawOffsets)))
        definitions.append(.init(tag: "AKBA", payload: rooms.akbaPayload))
        definitions.append(.init(tag: "IDXA", payload: geometry.scriptPolygonIndexPayload))
        definitions.append(.init(tag: "IDXA", payload: geometry.scriptIDPayload))
        definitions.append(.init(tag: "AKBP", payload: rooms.akbpPayload))
        definitions.append(.init(tag: "ABNA", payload: transparencyBSP.abnaPayload))
        definitions.append(.init(tag: "AKOT", payload: pointerPayload([18, 19, 20, 21, 22], pointer: pointer)))
        definitions.append(.init(tag: "AKAA", payload: rooms.akaaPayload))
        definitions.append(.init(tag: "AKDA", payload: emptyLongArray()))
        definitions.append(.init(tag: "OTIT", payload: spatialOctree.otitPayload))
        definitions.append(.init(tag: "OTLF", payload: spatialOctree.otlfPayload))
        definitions.append(.init(tag: "QTNA", payload: spatialOctree.qtnaPayload))
        definitions.append(.init(tag: "IDXA", payload: spatialOctree.polygonIndexPayload))
        definitions.append(.init(tag: "IDXA", payload: spatialOctree.roomIndexPayload))
        for material in geometry.materials {
            definitions.append(.init(tag: "TXMP", name: "TXMP" + material))
        }

        return OniAKEVBuildResult(
            fileName: "AKEV\(name).oni",
            archiveData: OniStandaloneArchiveBuilder.build(instances: definitions, embeddedRaw: raw),
            geometry: geometry,
            rooms: rooms,
            spatialOctree: spatialOctree,
            transparencyBSP: transparencyBSP
        )
    }

    private static func akevPayload(pointer: (Int) -> UInt32, points: [OniLevelVector3]) -> Data {
        var data = Data()
        for index in 1...17 { append(&data, pointer(index)) }
        let minimum = OniLevelVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0)
        let maximum = OniLevelVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        append(&data, minimum); append(&data, maximum)
        data.append(Data(repeating: 0, count: 24))
        append(&data, Float(12))
        return data
    }

    private static func pointerPayload(_ indices: [Int], pointer: (Int) -> UInt32) -> Data {
        var data = Data()
        for index in indices { append(&data, pointer(index)) }
        return data
    }

    private static func emptyLongArray() -> Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(0))
        return data
    }

    private static func agdbPayload(geometry: OniAkiraGeometry, raw: inout Data, enabled: Bool) -> Data {
        guard enabled else { return emptyLongArray() }
        var objectOffsets: [String: UInt32] = [:]
        var fileOffsets: [String: UInt32] = [:]
        var payload = Data(repeating: 0, count: 20)
        append(&payload, UInt32(geometry.polygons.count))

        func rawStringOffset(_ value: String, offsets: inout [String: UInt32]) -> UInt32 {
            let name = value.isEmpty ? "(none)" : value
            if let offset = offsets[name] { return offset }
            pad32(&raw)
            let offset = UInt32(raw.count)
            raw.append(Data(name.utf8))
            raw.append(0)
            offsets[name] = offset
            return offset
        }

        for polygon in geometry.polygons {
            append(&payload, rawStringOffset(polygon.objectName, offsets: &objectOffsets))
            append(&payload, rawStringOffset(polygon.fileName, offsets: &fileOffsets))
        }
        return payload
    }

    private static func pad32(_ data: inout Data) {
        let count = (data.count + 31) & ~31
        if data.count < count { data.append(Data(repeating: 0, count: count - data.count)) }
    }
    private static func append(_ data: inout Data, _ value: OniLevelVector3) {
        append(&data, value.x); append(&data, value.y); append(&data, value.z)
    }
    private static func append(_ data: inout Data, _ value: Float) { append(&data, value.bitPattern) }
    private static func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
}
