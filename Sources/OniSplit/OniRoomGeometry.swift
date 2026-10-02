import Foundation

package enum OniRoomSurfaceKind: String {
    case floor
    case ghost
}

package struct OniRoomSurface {
    package let kind: OniRoomSurfaceKind
    package let nodeName: String
    package let points: [OniLevelVector3]
    package let normal: OniLevelVector3
    package let minimum: OniLevelVector3
    package let maximum: OniLevelVector3
}

package struct OniRoomGeometry {
    package let floors: [OniRoomSurface]
    package let ghosts: [OniRoomSurface]
    package let discardedSurfaceCount: Int
}

package enum OniRoomConnectionKind: String {
    case ghost
    case stairsUp
    case stairsDown
}

package struct OniRoomConnection {
    package let ghostIndex: Int
    package let room0: Int
    package let room1: Int
    package let kind: OniRoomConnectionKind
}

package struct OniRoom {
    package let index: Int
    package let floor: OniRoomSurface
    package let height: Float
    package let minimum: OniLevelVector3
    package let maximum: OniLevelVector3
    package let adjacentRoomIndices: [Int]
}

package struct OniRoomTopology {
    package let rooms: [OniRoom]
    package let connections: [OniRoomConnection]
    package let ignoredGhostCount: Int
}

package enum OniRoomGeometryBuilder {
    package static func build(from documents: [OniColladaGeometryDocument]) -> OniRoomGeometry {
        var floors: [OniRoomSurface] = []
        var ghosts: [OniRoomSurface] = []
        var discarded = 0
        for document in documents {
            for instance in document.instances {
                for polygon in instance.polygons {
                    let points = simplify(polygon.positions)
                    guard points.count >= 3, let normal = normal(points) else {
                        discarded += 1
                        continue
                    }
                    let bounds = boundingBox(points)
                    if abs(normal.y) < 0.0001 {
                        guard bounds.maximum.y - bounds.minimum.y >= 1, points.count == 4 else {
                            discarded += 1
                            continue
                        }
                        ghosts.append(OniRoomSurface(kind: .ghost, nodeName: instance.nodeName, points: points, normal: normal, minimum: bounds.minimum, maximum: bounds.maximum))
                    } else if abs(normal.y) >= 0.3420201 {
                        floors.append(OniRoomSurface(kind: .floor, nodeName: instance.nodeName, points: points, normal: normal, minimum: bounds.minimum, maximum: bounds.maximum))
                    } else {
                        discarded += 1
                    }
                }
            }
        }
        return OniRoomGeometry(floors: floors, ghosts: ghosts, discardedSurfaceCount: discarded)
    }

    private static func simplify(_ points: [OniLevelVector3]) -> [OniLevelVector3] {
        guard points.count >= 3 else { return points }
        var result: [OniLevelVector3] = []
        for index in points.indices {
            let previous = points[index == points.startIndex ? points.index(before: points.endIndex) : points.index(before: index)]
            let current = points[index]
            let next = points[points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)]
            if current == previous { continue }
            let incoming = subtract(current, previous)
            let outgoing = subtract(next, current)
            if lengthSquared(cross(outgoing, incoming)) < 0.000001 { continue }
            result.append(current)
        }
        return result
    }

    private static func normal(_ points: [OniLevelVector3]) -> OniLevelVector3? {
        let value = cross(subtract(points[1], points[0]), subtract(points[2], points[0]))
        let length = sqrt(lengthSquared(value))
        guard length >= 0.01 else { return nil }
        return OniLevelVector3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func boundingBox(_ points: [OniLevelVector3]) -> (minimum: OniLevelVector3, maximum: OniLevelVector3) {
        (
            OniLevelVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0),
            OniLevelVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        )
    }

    private static func subtract(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func cross(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.y * rhs.z - lhs.z * rhs.y, y: lhs.z * rhs.x - lhs.x * rhs.z, z: lhs.x * rhs.y - lhs.y * rhs.x)
    }

    private static func lengthSquared(_ value: OniLevelVector3) -> Float { value.x * value.x + value.y * value.y + value.z * value.z }
}

package enum OniRoomTopologyBuilder {
    private struct WorkingRoom {
        let index: Int
        let floor: OniRoomSurface
        var adjacent: [Int] = []
        var ghostIndices: [Int] = []
    }

    private struct CandidatePair {
        let room0: WorkingRoom
        let room1: WorkingRoom
        let heightDelta: Float
        let volumeDelta: Float
    }

    package static func build(from geometry: OniRoomGeometry) -> OniRoomTopology {
        var rooms = geometry.floors.enumerated().map { WorkingRoom(index: $0.offset, floor: $0.element) }
        var connections: [OniRoomConnection] = []
        var ignored = 0

        for (ghostIndex, ghost) in geometry.ghosts.enumerated() {
            let minimumY = ghost.points.map(\.y).min() ?? 0
            let bottom = ghost.points.filter { abs($0.y - minimumY) <= 0.1 }
            guard bottom.count == 2 else { ignored += 1; continue }
            let midpoint = OniLevelVector3(
                x: (bottom[0].x + bottom[1].x) * 0.5,
                y: (bottom[0].y + bottom[1].y) * 0.5,
                z: (bottom[0].z + bottom[1].z) * 0.5
            )
            let p0 = OniLevelVector3(x: midpoint.x - ghost.normal.x, y: midpoint.y - ghost.normal.y + 2, z: midpoint.z - ghost.normal.z)
            let p1 = OniLevelVector3(x: midpoint.x + ghost.normal.x, y: midpoint.y + ghost.normal.y + 2, z: midpoint.z + ghost.normal.z)
            let rooms0 = rooms.filter { contains(p0, room: $0.floor, height: 20) }
            let rooms1 = rooms.filter { contains(p1, room: $0.floor, height: 20) }
            var pairs: [CandidatePair] = []
            for room0 in rooms0 {
                for room1 in rooms1 where room0.index != room1.index {
                    let heightDelta = planeDistance(room0.floor, p0) - planeDistance(room1.floor, p1)
                    let volumeDelta = volume(room0.floor, height: 20) - volume(room1.floor, height: 20)
                    pairs.append(CandidatePair(room0: room0, room1: room1, heightDelta: heightDelta, volumeDelta: volumeDelta))
                }
            }
            pairs.sort {
                let firstHasOneStair = ($0.room0.floor.normal.y < 0.999)
                    != ($0.room1.floor.normal.y < 0.999)
                let secondHasOneStair = ($1.room0.floor.normal.y < 0.999)
                    != ($1.room1.floor.normal.y < 0.999)
                if firstHasOneStair != secondHasOneStair {
                    return firstHasOneStair
                }
                return abs($0.heightDelta - $1.heightDelta) < 0.00001
                    ? $0.volumeDelta < $1.volumeDelta
                    : $0.heightDelta < $1.heightDelta
            }
            guard let pair = pairs.first else { ignored += 1; continue }
            let room0 = pair.room0.index, room1 = pair.room1.index
            let room0IsStairs = pair.room0.floor.normal.y < 0.999
            let room1IsStairs = pair.room1.floor.normal.y < 0.999
            let kind: OniRoomConnectionKind
            if room0IsStairs || room1IsStairs {
                let stairs = room0IsStairs ? pair.room0.floor : pair.room1.floor
                kind = ghost.minimum.y > stairs.maximum.y - 1 ? .stairsDown : .stairsUp
            } else {
                kind = .ghost
            }
            rooms[room0].adjacent.append(room1)
            rooms[room0].ghostIndices.append(ghostIndex)
            rooms[room1].adjacent.append(room0)
            rooms[room1].ghostIndices.append(ghostIndex)
            connections.append(OniRoomConnection(ghostIndex: ghostIndex, room0: room0, room1: room1, kind: kind))
        }

        let finalRooms = rooms.map { room -> OniRoom in
            let maximumFloorY = room.floor.points.map(\.y).max() ?? room.floor.maximum.y
            let maximumRoomY = room.ghostIndices.map { geometry.ghosts[$0].maximum.y }.max() ?? maximumFloorY + 20
            let height = (maximumRoomY - maximumFloorY) * room.floor.normal.y
            return OniRoom(
                index: room.index,
                floor: room.floor,
                height: height,
                minimum: room.floor.minimum,
                maximum: OniLevelVector3(x: room.floor.maximum.x, y: maximumRoomY, z: room.floor.maximum.z),
                adjacentRoomIndices: room.adjacent
            )
        }
        return OniRoomTopology(rooms: finalRooms, connections: connections, ignoredGhostCount: ignored)
    }

    private static func contains(_ point: OniLevelVector3, room: OniRoomSurface, height: Float) -> Bool {
        guard point.x >= room.minimum.x - 0.001, point.x <= room.maximum.x + 0.001,
              point.z >= room.minimum.z - 0.001, point.z <= room.maximum.z + 0.001 else { return false }
        let d = -dot(room.normal, room.points[0])
        guard abs(room.normal.y) > Float.leastNonzeroMagnitude else { return false }
        let floorY = (-d - room.normal.x * point.x - room.normal.z * point.z) / room.normal.y
        guard point.y >= floorY - 0.001, point.y <= floorY + height + 0.001 else { return false }
        var inside = false
        var previous = room.points.last!
        for current in room.points {
            if (current.z > point.z) != (previous.z > point.z) {
                let crossingX = (previous.x - current.x) * (point.z - current.z) / (previous.z - current.z) + current.x
                if point.x < crossingX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func planeDistance(_ floor: OniRoomSurface, _ point: OniLevelVector3) -> Float {
        dot(floor.normal, point) - dot(floor.normal, floor.points[0])
    }

    private static func volume(_ floor: OniRoomSurface, height: Float) -> Float {
        (floor.maximum.x - floor.minimum.x) * height * (floor.maximum.z - floor.minimum.z)
    }

    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }
}
