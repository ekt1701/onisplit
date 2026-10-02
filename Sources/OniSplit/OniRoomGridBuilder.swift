import Foundation

package struct OniRoomGridBuildResult {
    package let grids: [OniRoomGrid]
    package let oversizedRoomIndices: [Int]
}

package enum OniRoomGridBuilder {
    private struct Flags: OptionSet {
        let rawValue: UInt32
        static let stairs = Flags(rawValue: 0x0000_0010)
        static let noCollision = Flags(rawValue: 0x0000_0800)
        static let invisible = Flags(rawValue: 0x0000_2000)
        static let noObjectCollision = Flags(rawValue: 0x0000_4000)
        static let noCharacterCollision = Flags(rawValue: 0x0000_8000)
        static let noOcclusion = Flags(rawValue: 0x0001_0000)
        static let danger = Flags(rawValue: 0x0002_0000)
        static let gridIgnore = Flags(rawValue: 0x0040_0000)
        static let impassable = Flags(rawValue: 0x1000_0000)
    }

    private struct Polygon {
        let points: [OniLevelVector3]
        let normal: OniLevelVector3
        let minimum: OniLevelVector3
        let maximum: OniLevelVector3
        var flags: Flags
    }

    package static func build(topology: OniRoomTopology, environment: [OniColladaGeometryDocument]) -> OniRoomGridBuildResult {
        var polygons: [Polygon] = []
        for document in environment {
            for instance in document.instances {
                for source in instance.polygons {
                    guard source.positions.count >= 3, let normal = normal(source.positions) else { continue }
                    let bounds = bounds(source.positions)
                    polygons.append(Polygon(
                        points: source.positions,
                        normal: normal,
                        minimum: bounds.minimum,
                        maximum: bounds.maximum,
                        flags: flags(for: source.materialSymbol).union(Flags(rawValue: source.additionalFlags))
                    ))
                }
            }
        }
        processStairsCollision(&polygons)

        var grids: [OniRoomGrid] = []
        var oversized: [Int] = []
        for room in topology.rooms {
            let rasterizer = OniRoomGridRasterizer(room: room)
            rasterizer.clear(.danger)
            let testMinimum = OniLevelVector3(x: room.minimum.x - 9, y: room.minimum.y - 6, z: room.minimum.z - 9)
            let testMaximum = OniLevelVector3(x: room.maximum.x + 9, y: room.maximum.y - 6, z: room.maximum.z + 9)
            var candidates = polygons.filter {
                !$0.flags.contains(.noCollision)
                    && !$0.flags.contains(.noCharacterCollision)
                    && intersects($0.minimum, $0.maximum, testMinimum, testMaximum)
            }
            let danger = polygons.filter {
                $0.flags.contains(.danger) && intersects($0.minimum, $0.maximum, testMinimum, testMaximum)
            }

            for polygon in candidates where polygon.normal.y > 0.5 {
                rasterizer.drawFloor(polygon.points)
            }

            if room.floor.normal.y >= 0.999 {
                let floorMaximumY = room.floor.maximum.y
                let floorD = -dot(room.floor.normal, room.floor.points[0])
                let lowerPlane = (normal: room.floor.normal, d: floorD - 4)
                let upperPlane = (
                    normal: OniLevelVector3(x: -room.floor.normal.x, y: -room.floor.normal.y, z: -room.floor.normal.z),
                    d: -(floorD - 20)
                )

                for index in candidates.indices {
                    let polygon = candidates[index]
                    if polygon.flags.intersection([.stairs, .noCharacterCollision, .impassable]).isEmpty,
                       abs(polygon.normal.y) < 0.00001,
                       polygon.maximum.y - polygon.minimum.y <= 4,
                       abs(polygon.maximum.y - floorMaximumY) <= 4 {
                        candidates[index].flags.insert(.noCharacterCollision)
                        continue
                    }
                    let flags = candidates[index].flags
                    if !flags.intersection([.stairs, .gridIgnore, .noCollision, .noCharacterCollision]).isEmpty { continue }
                    guard let aboveFloor = clip(candidates[index].points, to: lowerPlane),
                          let belowCeiling = clip(aboveFloor, to: upperPlane) else { continue }
                    if abs(candidates[index].normal.y) <= 0.1 {
                        rasterizer.drawWall(belowCeiling)
                    } else {
                        rasterizer.drawImpassable(belowCeiling)
                    }
                }

                for polygon in danger { rasterizer.drawDanger(polygon.points) }
                rasterizer.addBorders()
            }
            let grid = rasterizer.grid()
            grids.append(grid)
            if grid.xTiles * grid.zTiles > 256 * 256 { oversized.append(room.index) }
        }
        return OniRoomGridBuildResult(grids: grids, oversizedRoomIndices: oversized)
    }

    private static func processStairsCollision(_ polygons: inout [Polygon]) {
        let stairIndices = polygons.indices.filter {
            polygons[$0].flags.contains(.stairs) && polygons[$0].points.count == 4
        }
        for stairIndex in stairIndices {
            let stair = polygons[stairIndex]
            let floorPoints = stair.points.map {
                OniLevelVector3(x: $0.x, y: $0.y + 0.1, z: $0.z)
            }
            let ceilingPoints = stair.points.map {
                OniLevelVector3(x: $0.x, y: $0.y + 7.5, z: $0.z)
            }
            guard let floorNormal = normal(floorPoints), let ceilingNormal = normal(ceilingPoints) else { continue }
            let floorPlane = (normal: floorNormal, d: -dot(floorNormal, floorPoints[0]))
            let ceilingPlane = (normal: ceilingNormal, d: -dot(ceilingNormal, ceilingPoints[0]))
            let volumeBounds = bounds(floorPoints + ceilingPoints)

            for polygonIndex in polygons.indices where polygonIndex != stairIndex {
                if !polygons[polygonIndex].flags.intersection([.noCollision, .noCharacterCollision]).isEmpty { continue }
                let polygon = polygons[polygonIndex]
                guard intersects(polygon.minimum, polygon.maximum, volumeBounds.minimum, volumeBounds.maximum),
                      let aboveFloor = clip(polygon.points, to: floorPlane),
                      clip(aboveFloor, to: ceilingPlane) == nil else { continue }
                polygons[polygonIndex].flags.insert(.noCharacterCollision)
            }
        }
    }

    private static func flags(for materialName: String) -> Flags {
        let name = materialName.lowercased()
        switch name {
        case "_marker_door", "_marker_ghost":
            return [.noCollision]
        case "_marker_stairs":
            return [.stairs, .invisible, .noObjectCollision]
        case "_marker_danger":
            return [.danger, .invisible, .noCollision, .noOcclusion]
        case "_marker_barrier":
            return [.invisible, .noObjectCollision]
        case "_marker_impassable":
            return [.invisible]
        case "_marker_blackness", "_marker_floor":
            return [.noCollision]
        default:
            return name.hasPrefix("lmap_") ? [.noCollision, .noOcclusion] : []
        }
    }

    private static func clip(
        _ points: [OniLevelVector3],
        to plane: (normal: OniLevelVector3, d: Float)
    ) -> [OniLevelVector3]? {
        let epsilon: Float = 0.00001
        let distances = points.map { dot(plane.normal, $0) + plane.d }
        if distances.allSatisfy({ $0 <= epsilon }) { return nil }
        if distances.allSatisfy({ $0 >= -epsilon }) { return points }
        var result: [OniLevelVector3] = []
        for index in points.indices {
            let nextIndex = (index + 1) % points.count
            let current = points[index], next = points[nextIndex]
            let currentDistance = distances[index], nextDistance = distances[nextIndex]
            if currentDistance >= -epsilon { result.append(current) }
            if (currentDistance > epsilon && nextDistance < -epsilon)
                || (currentDistance < -epsilon && nextDistance > epsilon) {
                let amount = currentDistance / (currentDistance - nextDistance)
                result.append(OniLevelVector3(
                    x: current.x + (next.x - current.x) * amount,
                    y: current.y + (next.y - current.y) * amount,
                    z: current.z + (next.z - current.z) * amount
                ))
            }
        }
        return result.count >= 3 ? result : nil
    }

    private static func intersects(
        _ minimum0: OniLevelVector3, _ maximum0: OniLevelVector3,
        _ minimum1: OniLevelVector3, _ maximum1: OniLevelVector3
    ) -> Bool {
        minimum0.x <= maximum1.x && maximum0.x >= minimum1.x
            && minimum0.y <= maximum1.y && maximum0.y >= minimum1.y
            && minimum0.z <= maximum1.z && maximum0.z >= minimum1.z
    }

    private static func normal(_ points: [OniLevelVector3]) -> OniLevelVector3? {
        let a = OniLevelVector3(x: points[1].x - points[0].x, y: points[1].y - points[0].y, z: points[1].z - points[0].z)
        let b = OniLevelVector3(x: points[2].x - points[0].x, y: points[2].y - points[0].y, z: points[2].z - points[0].z)
        let value = OniLevelVector3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
        let length = sqrt(dot(value, value))
        guard length >= 0.01 else { return nil }
        return OniLevelVector3(x: value.x / length, y: value.y / length, z: value.z / length)
    }

    private static func bounds(_ points: [OniLevelVector3]) -> (minimum: OniLevelVector3, maximum: OniLevelVector3) {
        (
            OniLevelVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0),
            OniLevelVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        )
    }

    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }
}
