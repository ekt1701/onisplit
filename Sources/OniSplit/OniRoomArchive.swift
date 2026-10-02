import Foundation

package struct OniRoomBSPNode {
    package let planeIndex: Int
    package let backChildIndex: Int
    package let frontChildIndex: Int
}

package struct OniRoomArchiveNode {
    package let roomIndex: Int
    package let bspTreeIndex: Int
    package let firstSide: Int
    package let lastSide: Int
    package let grid: OniRoomGrid
    package let compressedGrid: Data
    package let minimum: OniLevelVector3
    package let maximum: OniLevelVector3
    package let flags: UInt32
    package let floorPlane: OniAkiraPlane
    package let height: Float
}

package struct OniRoomArchiveSide {
    package let firstAdjacency: Int
    package let lastAdjacency: Int
}

package struct OniRoomArchiveAdjacency {
    package let adjacentRoomIndex: Int
    package let ghostPolygonIndex: Int
}

package struct OniRoomArchive {
    package let nodes: [OniRoomArchiveNode]
    package let sides: [OniRoomArchiveSide]
    package let bspNodes: [OniRoomBSPNode]
    package let adjacencies: [OniRoomArchiveAdjacency]

    package var rawGridParts: [Data] { nodes.map(\.compressedGrid) }

    package func akvaPayload(rawOffsets: [UInt32]) -> Data {
        precondition(rawOffsets.count == nodes.count)
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(nodes.count))
        for (index, node) in nodes.enumerated() {
            append(&data, Int32(node.bspTreeIndex))
            append(&data, Int32(node.roomIndex))
            append(&data, Int32(node.firstSide))
            append(&data, Int32(node.lastSide))
            append(&data, Int32(-1))
            append(&data, Int32(-1))
            append(&data, UInt32(0))
            append(&data, UInt32(node.grid.xTiles))
            append(&data, UInt32(node.grid.zTiles))
            append(&data, rawOffsets[index])
            append(&data, UInt32(node.compressedGrid.count))
            append(&data, OniRoomGrid.tileSize)
            append(&data, node.minimum)
            append(&data, node.maximum)
            append(&data, Int16(OniRoomGrid.xOrigin))
            append(&data, Int16(OniRoomGrid.zOrigin))
            append(&data, UInt32(node.roomIndex))
            data.append(Data(repeating: 0, count: 12))
            append(&data, node.flags)
            append(&data, node.floorPlane.normal)
            append(&data, node.floorPlane.d)
            append(&data, node.height)
        }
        return data
    }

    package var akbaPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(sides.count))
        for side in sides {
            append(&data, UInt32(0))
            append(&data, UInt32(side.firstAdjacency))
            append(&data, UInt32(side.lastAdjacency))
            data.append(Data(repeating: 0, count: 16))
        }
        return data
    }

    package var akbpPayload: Data {
        var data = Data(repeating: 0, count: 22)
        append(&data, UInt16(bspNodes.count))
        for node in bspNodes {
            append(&data, Int32(node.planeIndex))
            append(&data, Int32(node.backChildIndex))
            append(&data, Int32(node.frontChildIndex))
        }
        return data
    }

    package var akaaPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(adjacencies.count))
        for adjacency in adjacencies {
            append(&data, UInt32(adjacency.adjacentRoomIndex))
            append(&data, UInt32(adjacency.ghostPolygonIndex))
            append(&data, UInt32(0))
        }
        return data
    }

    private func append(_ data: inout Data, _ value: OniLevelVector3) {
        append(&data, value.x); append(&data, value.y); append(&data, value.z)
    }

    private func append(_ data: inout Data, _ value: Float) { append(&data, value.bitPattern) }
    private func append(_ data: inout Data, _ value: Int16) { append(&data, UInt16(bitPattern: value)) }
    private func append(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
    }
    private func append(_ data: inout Data, _ value: Int32) { append(&data, UInt32(bitPattern: value)) }
    private func append(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8((value >> 24) & 0xff))
    }
}

package enum OniRoomArchiveBuilder {
    package static func build(
        topology: OniRoomTopology,
        grids: [OniRoomGrid],
        ghostPolygonIndices: [Int],
        planeIndex: (OniAkiraPlane) -> Int
    ) -> OniRoomArchive {
        precondition(grids.count == topology.rooms.count)
        precondition(ghostPolygonIndices.count == topology.connections.count)
        var nodes: [OniRoomArchiveNode] = []
        var sides: [OniRoomArchiveSide] = []
        var bspNodes: [OniRoomBSPNode] = []
        var adjacencies: [OniRoomArchiveAdjacency] = []

        for room in topology.rooms {
            let firstSide = sides.count
            let roomConnections = topology.connections.enumerated().filter {
                $0.element.room0 == room.index || $0.element.room1 == room.index
            }
            if !roomConnections.isEmpty {
                let firstAdjacency = adjacencies.count
                for (connectionIndex, connection) in roomConnections {
                    let adjacent = connection.room0 == room.index ? connection.room1 : connection.room0
                    adjacencies.append(OniRoomArchiveAdjacency(
                        adjacentRoomIndex: adjacent,
                        ghostPolygonIndex: ghostPolygonIndices[connectionIndex]
                    ))
                }
                sides.append(OniRoomArchiveSide(firstAdjacency: firstAdjacency, lastAdjacency: adjacencies.count))
            }

            let floorPlane = plane(room.floor)
            let roomBSPStart = bspNodes.count
            var orderedPlanes: [OniAkiraPlane] = []
            for index in room.floor.points.indices.reversed() {
                let p0 = room.floor.points[index]
                let p1 = room.floor.points[(index + 1) % room.floor.points.count]
                let p2 = OniLevelVector3(x: p1.x, y: p1.y + 1, z: p1.z)
                if let side = plane([p0, p1, p2]) { orderedPlanes.append(side) }
            }
            orderedPlanes.append(OniAkiraPlane(normal: floorPlane.normal, d: floorPlane.d - room.height))
            orderedPlanes.append(OniAkiraPlane(
                normal: OniLevelVector3(x: -floorPlane.normal.x, y: -floorPlane.normal.y, z: -floorPlane.normal.z),
                d: -floorPlane.d
            ))
            for index in orderedPlanes.indices {
                bspNodes.append(OniRoomBSPNode(
                    planeIndex: planeIndex(orderedPlanes[index]),
                    backChildIndex: index + 1 < orderedPlanes.count ? roomBSPStart + index + 1 : -1,
                    frontChildIndex: -1
                ))
            }

            let roomFlags: UInt32 = 0x04 | (room.floor.normal.y < 0.999 ? 0x01 : 0)
            let grid = grids[room.index]
            nodes.append(OniRoomArchiveNode(
                roomIndex: room.index,
                bspTreeIndex: roomBSPStart,
                firstSide: firstSide,
                lastSide: sides.count,
                grid: grid,
                compressedGrid: grid.compressed(),
                minimum: room.minimum,
                maximum: room.maximum,
                flags: roomFlags,
                floorPlane: floorPlane,
                height: room.height
            ))
        }
        return OniRoomArchive(nodes: nodes, sides: sides, bspNodes: bspNodes, adjacencies: adjacencies)
    }

    private static func plane(_ surface: OniRoomSurface) -> OniAkiraPlane {
        OniAkiraPlane(normal: surface.normal, d: -dot(surface.normal, surface.points[0]))
    }

    private static func plane(_ points: [OniLevelVector3]) -> OniAkiraPlane? {
        let a = subtract(points[1], points[0]), b = subtract(points[2], points[0])
        let cross = OniLevelVector3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
        let length = sqrt(dot(cross, cross))
        guard length >= 0.01 else { return nil }
        let normal = OniLevelVector3(x: cross.x / length, y: cross.y / length, z: cross.z / length)
        return OniAkiraPlane(normal: normal, d: -dot(normal, points[0]))
    }

    private static func subtract(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }
}
