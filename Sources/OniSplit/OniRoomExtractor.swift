import Foundation

package struct OniRoomExtractionResult {
    package let sourcePolygonCount: Int
    package let selectedFloorCount: Int
    package let mergedQuadCount: Int
    package let approximatedRampCount: Int
    package let recoveredReversedRampCount: Int
    package let mergedResidualTriangleCount: Int
    package let discardedNonQuadFloorCount: Int
    package let consolidatedFloorCount: Int
    package let discardedIsolatedFloorCount: Int
    package let outputPolygonCount: Int
    package let generatedGhostCount: Int
    package let rejectedGhostCount: Int
    package let blockedGhostCount: Int
}

package enum OniRoomExtractor {
    private struct BlockingPolygon {
        let points: [OniLevelVector3]
        let normal: OniLevelVector3
        let planeDistance: Float
        let minimum: OniLevelVector3
        let maximum: OniLevelVector3
    }

    private static let minimumFloorNormalY: Float = 0.3420201
    private static let pointTolerance: Float = 0.01
    private static let planeTolerance: Float = 0.0001
    private static let minimumIsolatedFloorArea: Float = 64
    private static let minimumQuadCornerAngle: Float = .pi / 12
    private static let minimumOppositeEdgeBalance: Float = 0.05
    private static let minimumRampQuadCoverage: Float = 0.9

    package static func extract(
        from sourceURLs: [URL], to outputURL: URL, connectRooms: Bool = false
    ) throws -> OniRoomExtractionResult {
        guard !sourceURLs.isEmpty else {
            throw OniNativeXMLError.invalidDocument("room extraction requires at least one COLLADA model")
        }

        let documents = try sourceURLs.map(OniColladaGeometryReader.read)
        let sourcePolygons = documents.flatMap(\.instances).flatMap(\.polygons)
        var selected: [[OniLevelVector3]] = []
        var reversedRampCandidates: [[OniLevelVector3]] = []
        for polygon in sourcePolygons {
            let points = removeRepeatedClosingPoint(polygon.positions)
            guard points.count >= 3, let normal = polygonNormal(points) else { continue }
            if normal.y >= minimumFloorNormalY {
                selected.append(points)
            } else if normal.y <= -minimumFloorNormalY, normal.y > -0.999 {
                let upward = orientedUpward(removeCollinearPoints(points))
                if upward.count == 4, quadQuality(upward) != nil {
                    reversedRampCandidates.append(upward)
                }
            }
        }
        let recoveredReversedRamps = reversedRampCandidates.filter {
            !hasMatchingUpwardRamp($0, in: selected)
        }
        let recoveredRampKeys = Set(recoveredReversedRamps.map(floorSignature))
        selected.append(contentsOf: recoveredReversedRamps)
        let rawQuadrangulated = quadrangulate(selected)
        var approximatedRampCount = 0
        let quadrangulated = rawQuadrangulated.map {
            orientedUpward(removeCollinearPoints($0))
        }.map { polygon in
            guard let approximation = rampQuadApproximation(polygon) else { return polygon }
            approximatedRampCount += 1
            return approximation
        }
        let triangleFree = eliminateTriangles(quadrangulated)
        var floors = connectRooms ? consolidate(triangleFree.polygons) : triangleFree.polygons
        let consolidatedFloorCount = triangleFree.polygons.count - floors.count
        let blockingPolygons = connectRooms ? blockingPolygons(from: sourcePolygons) : []
        var discardedIsolatedFloorCount = 0
        if connectRooms {
            let preliminary = validatedGhosts(
                between: floors, blockingPolygons: blockingPolygons,
                priorityRampKeys: recoveredRampKeys
            )
            let retained = floors.enumerated().compactMap { index, floor -> [OniLevelVector3]? in
                let connected = preliminary.connectedRoomIndices.contains(index)
                let largeEnough = abs(signedAreaXZ(floor)) >= minimumIsolatedFloorArea
                return connected || largeEnough ? floor : nil
            }
            discardedIsolatedFloorCount = floors.count - retained.count
            floors = retained
        }
        let connectionResult = connectRooms
            ? validatedGhosts(
                between: floors, blockingPolygons: blockingPolygons,
                priorityRampKeys: recoveredRampKeys
            )
            : (ghosts: [], rejectedCount: 0, blockedCount: 0, connectedRoomIndices: [])
        guard floors.allSatisfy({ $0.count == 4 && quadQuality($0) != nil }) else {
            throw OniNativeXMLError.invalidDocument(
                "room extraction produced a non-quadrilateral BNV floor"
            )
        }

        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try colladaData(floors: floors, ghosts: connectionResult.ghosts).write(to: outputURL, options: .atomic)

        return OniRoomExtractionResult(
            sourcePolygonCount: sourcePolygons.count,
            selectedFloorCount: selected.count,
            mergedQuadCount: selected.count - rawQuadrangulated.count,
            approximatedRampCount: approximatedRampCount,
            recoveredReversedRampCount: recoveredReversedRamps.count,
            mergedResidualTriangleCount: triangleFree.mergedCount,
            discardedNonQuadFloorCount: triangleFree.discardedCount,
            consolidatedFloorCount: consolidatedFloorCount,
            discardedIsolatedFloorCount: discardedIsolatedFloorCount,
            outputPolygonCount: floors.count,
            generatedGhostCount: connectionResult.ghosts.count,
            rejectedGhostCount: connectionResult.rejectedCount,
            blockedGhostCount: connectionResult.blockedCount
        )
    }

    package static func reportData(
        for extractionURL: URL, result: OniRoomExtractionResult
    ) throws -> Data {
        let document = try OniColladaGeometryReader.read(extractionURL)
        let geometry = OniRoomGeometryBuilder.build(from: [document])
        let topology = OniRoomTopologyBuilder.build(from: geometry)
        let rooms: [[String: Any]] = topology.rooms.map { room in
            [
                "index": room.index,
                "name": room.floor.nodeName,
                "vertexCount": room.floor.points.count,
                "projectedArea": Double(abs(signedAreaXZ(room.floor.points))),
                "minimum": vectorArray(room.minimum),
                "maximum": vectorArray(room.maximum),
                "height": Double(room.height),
                "adjacentRooms": room.adjacentRoomIndices,
                "isolated": room.adjacentRoomIndices.isEmpty
            ]
        }
        let portals: [[String: Any]] = topology.connections.map { connection in
            let ghost = geometry.ghosts[connection.ghostIndex]
            let minimumY = ghost.points.map(\.y).min() ?? 0
            let bottom = ghost.points.filter { abs($0.y - minimumY) <= 0.1 }
            let width: Float
            if bottom.count == 2 { width = sqrt(lengthSquared(subtract(bottom[1], bottom[0]))) }
            else { width = 0 }
            return [
                "index": connection.ghostIndex,
                "name": ghost.nodeName,
                "room0": connection.room0,
                "room1": connection.room1,
                "kind": connection.kind.rawValue,
                "width": Double(width),
                "height": Double(ghost.maximum.y - ghost.minimum.y),
                "points": ghost.points.map(vectorArray)
            ]
        }
        let report: [String: Any] = [
            "source": extractionURL.path,
            "summary": [
                "sourcePolygonCount": result.sourcePolygonCount,
                "selectedFloorCount": result.selectedFloorCount,
                "trianglePairMergeCount": result.mergedQuadCount,
                "approximatedRampCount": result.approximatedRampCount,
                "recoveredReversedRampCount": result.recoveredReversedRampCount,
                "residualTriangleMergeCount": result.mergedResidualTriangleCount,
                "discardedNonQuadFloorCount": result.discardedNonQuadFloorCount,
                "coplanarMergeCount": result.consolidatedFloorCount,
                "discardedIsolatedFloorCount": result.discardedIsolatedFloorCount,
                "roomCount": topology.rooms.count,
                "portalCount": topology.connections.count,
                "isolatedRoomCount": topology.rooms.filter { $0.adjacentRoomIndices.isEmpty }.count,
                "rejectedPortalCount": result.rejectedGhostCount,
                "blockedBoundaryCount": result.blockedGhostCount
            ],
            "rooms": rooms,
            "portals": portals
        ]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }

    private static func vectorArray(_ value: OniLevelVector3) -> [Double] {
        [Double(value.x), Double(value.y), Double(value.z)]
    }

    private static func consolidate(_ input: [[OniLevelVector3]]) -> [[OniLevelVector3]] {
        var polygons = input
        var didMerge = true
        while didMerge {
            didMerge = false
            mergeSearch: for firstIndex in polygons.indices {
                for secondIndex in polygons.indices where secondIndex > firstIndex {
                    guard let merged = convexMergedPolygon(polygons[firstIndex], polygons[secondIndex]),
                          merged.count == 4, quadQuality(merged) != nil else { continue }
                    polygons[firstIndex] = orientedUpward(merged)
                    polygons.remove(at: secondIndex)
                    didMerge = true
                    break mergeSearch
                }
            }
        }
        return polygons
    }

    private static func eliminateTriangles(
        _ input: [[OniLevelVector3]]
    ) -> (polygons: [[OniLevelVector3]], mergedCount: Int, discardedCount: Int) {
        var polygons = input
        var mergedCount = 0

        while true {
            var candidates: [(triangle: Int, neighbor: Int, points: [OniLevelVector3])] = []
            for triangleIndex in polygons.indices where polygons[triangleIndex].count == 3 {
                for neighborIndex in polygons.indices where neighborIndex != triangleIndex {
                    guard let merged = convexMergedPolygon(
                        polygons[triangleIndex], polygons[neighborIndex]
                    ), merged.count == 4, quadQuality(merged) != nil else { continue }
                    candidates.append((triangleIndex, neighborIndex, orientedUpward(merged)))
                }
            }
            guard !candidates.isEmpty else { break }

            let triangleDegrees = Dictionary(grouping: candidates, by: \.triangle)
                .mapValues(\.count)
            let best = candidates.min {
                let firstDegree = triangleDegrees[$0.triangle] ?? Int.max
                let secondDegree = triangleDegrees[$1.triangle] ?? Int.max
                if firstDegree != secondDegree { return firstDegree < secondDegree }
                if $0.points.count != $1.points.count { return $0.points.count < $1.points.count }
                if $0.triangle != $1.triangle { return $0.triangle < $1.triangle }
                return $0.neighbor < $1.neighbor
            }!

            let retainedIndex = min(best.triangle, best.neighbor)
            let removedIndex = max(best.triangle, best.neighbor)
            polygons[retainedIndex] = best.points
            polygons.remove(at: removedIndex)
            mergedCount += 1
        }

        let discardedCount = polygons.count(where: { $0.count != 4 || quadQuality($0) == nil })
        polygons.removeAll(where: { $0.count != 4 || quadQuality($0) == nil })
        return (polygons, mergedCount, discardedCount)
    }

    private static func quadQuality(_ points: [OniLevelVector3]) -> Float? {
        guard points.count == 4, removeCollinearPoints(points).count == 4,
              isConvexXZ(points) else { return nil }

        var edgeLengths: [Float] = []
        var minimumAngle = Float.greatestFiniteMagnitude
        for index in points.indices {
            let previous = points[(index + 3) % 4]
            let current = points[index]
            let next = points[(index + 1) % 4]
            let incomingX = previous.x - current.x
            let incomingZ = previous.z - current.z
            let outgoingX = next.x - current.x
            let outgoingZ = next.z - current.z
            let incomingLength = sqrt(incomingX * incomingX + incomingZ * incomingZ)
            let outgoingLength = sqrt(outgoingX * outgoingX + outgoingZ * outgoingZ)
            guard incomingLength > pointTolerance, outgoingLength > pointTolerance else { return nil }
            let cosine = max(-1, min(1,
                (incomingX * outgoingX + incomingZ * outgoingZ)
                    / (incomingLength * outgoingLength)
            ))
            minimumAngle = min(minimumAngle, acos(cosine))
            edgeLengths.append(outgoingLength)
        }
        guard minimumAngle >= minimumQuadCornerAngle else { return nil }

        let firstBalance = min(edgeLengths[0], edgeLengths[2])
            / max(edgeLengths[0], edgeLengths[2])
        let secondBalance = min(edgeLengths[1], edgeLengths[3])
            / max(edgeLengths[1], edgeLengths[3])
        let oppositeEdgeBalance = min(firstBalance, secondBalance)
        guard oppositeEdgeBalance >= minimumOppositeEdgeBalance else { return nil }
        return oppositeEdgeBalance * sin(minimumAngle)
    }

    private static func rampQuadApproximation(
        _ points: [OniLevelVector3]
    ) -> [OniLevelVector3]? {
        guard points.count > 4, isConvexXZ(points),
              let normal = roomSurfaceNormal(points),
              normal.y >= minimumFloorNormalY, normal.y < 0.999 else { return nil }
        let sourceArea = abs(signedAreaXZ(points))
        guard sourceArea > 0 else { return nil }

        var best: (points: [OniLevelVector3], area: Float)?
        for first in 0..<(points.count - 3) {
            for second in (first + 1)..<(points.count - 2) {
                for third in (second + 1)..<(points.count - 1) {
                    for fourth in (third + 1)..<points.count {
                        let candidate = orientedUpward([
                            points[first], points[second], points[third], points[fourth]
                        ])
                        guard quadQuality(candidate) != nil else { continue }
                        let area = abs(signedAreaXZ(candidate))
                        guard area <= sourceArea * 1.0001,
                              area >= sourceArea * minimumRampQuadCoverage else { continue }
                        if best == nil || area > best!.area {
                            best = (candidate, area)
                        }
                    }
                }
            }
        }
        return best?.points
    }

    private static func hasMatchingUpwardRamp(
        _ candidate: [OniLevelVector3], in upwardFloors: [[OniLevelVector3]]
    ) -> Bool {
        guard let candidateNormal = roomSurfaceNormal(candidate) else { return false }
        let candidateMinimumX = candidate.map(\.x).min() ?? 0
        let candidateMaximumX = candidate.map(\.x).max() ?? 0
        let candidateMinimumZ = candidate.map(\.z).min() ?? 0
        let candidateMaximumZ = candidate.map(\.z).max() ?? 0
        let candidateArea = max(
            pointTolerance,
            (candidateMaximumX - candidateMinimumX) * (candidateMaximumZ - candidateMinimumZ)
        )

        for floor in upwardFloors {
            guard let normal = roomSurfaceNormal(floor), normal.y < 0.999,
                  dot(candidateNormal, normal) >= 0.98 else { continue }
            let minimumX = floor.map(\.x).min() ?? 0
            let maximumX = floor.map(\.x).max() ?? 0
            let minimumZ = floor.map(\.z).min() ?? 0
            let maximumZ = floor.map(\.z).max() ?? 0
            let overlapX = max(0, min(candidateMaximumX, maximumX) - max(candidateMinimumX, minimumX))
            let overlapZ = max(0, min(candidateMaximumZ, maximumZ) - max(candidateMinimumZ, minimumZ))
            if overlapX * overlapZ >= candidateArea * 0.8 { return true }
        }
        return false
    }

    private static func floorSignature(_ points: [OniLevelVector3]) -> String {
        points.map { point in
            "\(Int((point.x / pointTolerance).rounded())),\(Int((point.y / pointTolerance).rounded())),\(Int((point.z / pointTolerance).rounded()))"
        }.sorted().joined(separator: "|")
    }

    private static func convexMergedPolygon(
        _ first: [OniLevelVector3], _ originalSecond: [OniLevelVector3]
    ) -> [OniLevelVector3]? {
        guard let firstNormal = roomSurfaceNormal(first), let originalSecondNormal = roomSurfaceNormal(originalSecond),
              dot(firstNormal, originalSecondNormal) >= 1 - planeTolerance,
              abs(planeDistance(first, normal: firstNormal) - planeDistance(originalSecond, normal: firstNormal)) <= planeTolerance else {
            return nil
        }

        let expandedFirst = insertingEdgeVertices(into: first, from: originalSecond)
        let expandedOriginalSecond = insertingEdgeVertices(into: originalSecond, from: first)

        for shouldReverse in [false, true] {
            let second = shouldReverse ? Array(expandedOriginalSecond.reversed()) : expandedOriginalSecond
            for firstEdge in expandedFirst.indices {
                let firstEnd = (firstEdge + 1) % expandedFirst.count
                for secondEdge in second.indices {
                    let secondEnd = (secondEdge + 1) % second.count
                    guard approximatelyEqual(expandedFirst[firstEdge], second[secondEnd]),
                          approximatelyEqual(expandedFirst[firstEnd], second[secondEdge]) else { continue }

                    var merged: [OniLevelVector3] = []
                    for offset in 0..<expandedFirst.count {
                        merged.append(expandedFirst[(firstEnd + offset) % expandedFirst.count])
                    }
                    if second.count > 2 {
                        for offset in 2..<second.count {
                            merged.append(second[(secondEdge + offset) % second.count])
                        }
                    }
                    merged = removeCollinearPoints(merged)
                    let sourceArea = abs(signedAreaXZ(first)) + abs(signedAreaXZ(second))
                    let mergedArea = abs(signedAreaXZ(merged))
                    let areaTolerance = max(0.01, sourceArea * 0.0001)
                    guard merged.count >= 4,
                          !hasRepeatedVertex(merged),
                          abs(sourceArea - mergedArea) <= areaTolerance,
                          isConvexXZ(merged),
                          let normal = roomSurfaceNormal(merged),
                          abs(normal.y) >= minimumFloorNormalY else { continue }
                    return merged
                }
            }
        }
        return nil
    }

    private static func insertingEdgeVertices(
        into polygon: [OniLevelVector3], from other: [OniLevelVector3]
    ) -> [OniLevelVector3] {
        var result: [OniLevelVector3] = []
        for edge in polygon.indices {
            let start = polygon[edge]
            let end = polygon[(edge + 1) % polygon.count]
            result.append(start)
            let insertions = other.compactMap { point -> (t: Float, point: OniLevelVector3)? in
                guard !approximatelyEqual(point, start), !approximatelyEqual(point, end),
                      let t = interiorSegmentParameter(point, start: start, end: end) else { return nil }
                return (t, point)
            }.sorted { $0.t < $1.t }
            for insertion in insertions where !result.contains(where: { approximatelyEqual($0, insertion.point) }) {
                result.append(insertion.point)
            }
        }
        return result
    }

    private static func interiorSegmentParameter(
        _ point: OniLevelVector3, start: OniLevelVector3, end: OniLevelVector3
    ) -> Float? {
        let segment = subtract(end, start)
        let segmentLengthSquared = lengthSquared(segment)
        guard segmentLengthSquared > pointTolerance * pointTolerance else { return nil }
        let offset = subtract(point, start)
        let t = dot(offset, segment) / segmentLengthSquared
        guard t > 0.00001, t < 0.99999 else { return nil }
        let closest = OniLevelVector3(
            x: start.x + segment.x * t,
            y: start.y + segment.y * t,
            z: start.z + segment.z * t
        )
        return lengthSquared(subtract(point, closest)) <= pointTolerance * pointTolerance ? t : nil
    }

    private static func removeCollinearPoints(_ points: [OniLevelVector3]) -> [OniLevelVector3] {
        guard points.count >= 3 else { return points }
        var result: [OniLevelVector3] = []
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            if approximatelyEqual(previous, current) { continue }
            let incoming = subtract(current, previous)
            let outgoing = subtract(next, current)
            if lengthSquared(cross(incoming, outgoing)) <= 0.000001 { continue }
            result.append(current)
        }
        return result
    }

    private static func hasRepeatedVertex(_ points: [OniLevelVector3]) -> Bool {
        for first in points.indices {
            for second in points.indices where second > first {
                if approximatelyEqual(points[first], points[second]) { return true }
            }
        }
        return false
    }

    private static func signedAreaXZ(_ points: [OniLevelVector3]) -> Float {
        guard points.count >= 3 else { return 0 }
        var twiceArea: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            twiceArea += current.x * next.z - next.x * current.z
        }
        return twiceArea * 0.5
    }

    private static func isConvexXZ(_ points: [OniLevelVector3]) -> Bool {
        var sign: Float = 0
        for index in points.indices {
            let first = points[index]
            let second = points[(index + 1) % points.count]
            let third = points[(index + 2) % points.count]
            let turn = (second.z - first.z) * (third.x - second.x)
                - (second.x - first.x) * (third.z - second.z)
            if abs(turn) <= 0.0001 { continue }
            if sign == 0 { sign = turn }
            else if sign * turn < 0 { return false }
        }
        return sign != 0
    }

    private static func blockingPolygons(from polygons: [OniColladaPolygon]) -> [BlockingPolygon] {
        polygons.compactMap { polygon in
            let points = removeRepeatedClosingPoint(polygon.positions)
            guard points.count >= 3, let normal = polygonNormal(points),
                  abs(normal.y) < minimumFloorNormalY else { return nil }
            return BlockingPolygon(
                points: points,
                normal: normal,
                planeDistance: dot(normal, points[0]),
                minimum: OniLevelVector3(
                    x: points.map(\.x).min() ?? 0,
                    y: points.map(\.y).min() ?? 0,
                    z: points.map(\.z).min() ?? 0
                ),
                maximum: OniLevelVector3(
                    x: points.map(\.x).max() ?? 0,
                    y: points.map(\.y).max() ?? 0,
                    z: points.map(\.z).max() ?? 0
                )
            )
        }
    }

    private static func validatedGhosts(
        between floors: [[OniLevelVector3]], blockingPolygons: [BlockingPolygon],
        priorityRampKeys: Set<String>
    ) -> (
        ghosts: [[OniLevelVector3]], rejectedCount: Int, blockedCount: Int,
        connectedRoomIndices: Set<Int>
    ) {
        var candidates: [[OniLevelVector3]] = []
        var blockedCount = 0
        var edgeKeys = Set<String>()
        for floor in floors {
            guard priorityRampKeys.contains(floorSignature(floor)),
                  let normal = roomSurfaceNormal(floor), normal.y < 0.999 else { continue }
            for edge in floor.indices {
                let end = (edge + 1) % floor.count
                let a = floor[edge]
                let b = floor[end]
                guard abs(a.y - b.y) <= 0.1,
                      lengthSquared(subtract(b, a)) >= 1 else { continue }
                let key = edgeKey(a, b)
                guard edgeKeys.insert(key).inserted else { continue }
                let portals = openPortalQuads(
                    along: a, b, blockingPolygons: [],
                    openingSampleHeight: 4
                )
                if portals.isEmpty { blockedCount += 1 }
                candidates.append(contentsOf: portals)
            }
        }
        for firstIndex in floors.indices {
            for secondIndex in floors.indices where secondIndex > firstIndex {
                for firstEdge in floors[firstIndex].indices {
                    let firstEnd = (firstEdge + 1) % floors[firstIndex].count
                    let a = floors[firstIndex][firstEdge]
                    let b = floors[firstIndex][firstEnd]
                    guard abs(a.y - b.y) <= 0.1, lengthSquared(subtract(b, a)) >= 1 else { continue }
                    for secondEdge in floors[secondIndex].indices {
                        let secondEnd = (secondEdge + 1) % floors[secondIndex].count
                        let c = floors[secondIndex][secondEdge]
                        let d = floors[secondIndex][secondEnd]
                        guard let shared = sharedHorizontalSegment(a, b, c, d) else { continue }
                        let key = edgeKey(shared.start, shared.end)
                        guard edgeKeys.insert(key).inserted else { continue }
                        let portals = openPortalQuads(
                            along: shared.start, shared.end,
                            blockingPolygons: blockingPolygons
                        )
                        if portals.isEmpty { blockedCount += 1 }
                        candidates.append(contentsOf: portals)
                    }
                }
            }
        }

        let floorSurfaces = floors.enumerated().compactMap { index, points in
            surface(kind: .floor, name: "floor_\(index)", points: points)
        }
        let ghostSurfaces = candidates.enumerated().compactMap { index, points in
            surface(kind: .ghost, name: "ghost_\(index)", points: points)
        }
        let geometry = OniRoomGeometry(
            floors: floorSurfaces, ghosts: ghostSurfaces,
            discardedSurfaceCount: floors.count - floorSurfaces.count + candidates.count - ghostSurfaces.count
        )
        let topology = OniRoomTopologyBuilder.build(from: geometry)
        let acceptedIndices = Set(topology.connections.map(\.ghostIndex))
        let accepted = candidates.enumerated().compactMap { acceptedIndices.contains($0.offset) ? $0.element : nil }
        let connectedRooms = Set(topology.connections.flatMap { [$0.room0, $0.room1] })
        return (accepted, candidates.count - accepted.count, blockedCount, connectedRooms)
    }

    private static func sharedHorizontalSegment(
        _ firstStart: OniLevelVector3, _ firstEnd: OniLevelVector3,
        _ secondStart: OniLevelVector3, _ secondEnd: OniLevelVector3
    ) -> (start: OniLevelVector3, end: OniLevelVector3)? {
        guard abs(firstStart.y - firstEnd.y) <= 0.1,
              abs(secondStart.y - secondEnd.y) <= 0.1,
              abs(firstStart.y - secondStart.y) <= 0.1,
              abs(firstStart.y - secondEnd.y) <= 0.1 else { return nil }

        let dx = firstEnd.x - firstStart.x
        let dz = firstEnd.z - firstStart.z
        let lengthSquaredXZ = dx * dx + dz * dz
        guard lengthSquaredXZ >= 1 else { return nil }
        let lengthXZ = sqrt(lengthSquaredXZ)
        func lineDistance(_ point: OniLevelVector3) -> Float {
            abs(dx * (point.z - firstStart.z) - dz * (point.x - firstStart.x))
                / lengthXZ
        }
        guard lineDistance(secondStart) <= pointTolerance,
              lineDistance(secondEnd) <= pointTolerance else { return nil }

        func parameter(_ point: OniLevelVector3) -> Float {
            ((point.x - firstStart.x) * dx + (point.z - firstStart.z) * dz)
                / lengthSquaredXZ
        }
        let secondT0 = parameter(secondStart)
        let secondT1 = parameter(secondEnd)
        let overlapStart = max(0, min(secondT0, secondT1))
        let overlapEnd = min(1, max(secondT0, secondT1))
        guard overlapEnd > overlapStart,
              lengthXZ * (overlapEnd - overlapStart) >= 1 else { return nil }
        return (
            interpolate(firstStart, firstEnd, overlapStart),
            interpolate(firstStart, firstEnd, overlapEnd)
        )
    }

    private static func openPortalQuads(
        along start: OniLevelVector3, _ end: OniLevelVector3,
        blockingPolygons: [BlockingPolygon], openingSampleHeight: Float = 2
    ) -> [[OniLevelVector3]] {
        let edge = subtract(end, start)
        let edgeLength = sqrt(lengthSquared(edge))
        guard edgeLength >= 1 else { return [] }
        let sampleCount = min(512, max(1, Int(ceil(edgeLength / 2))))
        var open = Array(repeating: false, count: sampleCount)
        for sample in 0..<sampleCount {
            let t = (Float(sample) + 0.5) / Float(sampleCount)
            let point = add(
                interpolate(start, end, t),
                OniLevelVector3(x: 0, y: openingSampleHeight, z: 0)
            )
            open[sample] = !isBlocked(point, by: blockingPolygons)
        }

        var result: [[OniLevelVector3]] = []
        var index = 0
        while index < sampleCount {
            guard open[index] else { index += 1; continue }
            let runStart = index
            while index < sampleCount, open[index] { index += 1 }
            let runEnd = index
            let startT = Float(runStart) / Float(sampleCount)
            let endT = Float(runEnd) / Float(sampleCount)
            guard edgeLength * (endT - startT) >= 1 else { continue }
            let bottom0 = interpolate(start, end, startT)
            let bottom1 = interpolate(start, end, endT)
            let midpoint = interpolate(bottom0, bottom1, 0.5)
            var height: Float = 20
            let firstHeightStep = max(3, Int(ceil(openingSampleHeight)) + 1)
            for step in firstHeightStep...20 {
                let point = add(midpoint, OniLevelVector3(x: 0, y: Float(step), z: 0))
                if isBlocked(point, by: blockingPolygons) {
                    height = Float(step)
                    break
                }
            }
            let up = OniLevelVector3(x: 0, y: max(1, height), z: 0)
            result.append([bottom0, bottom1, add(bottom1, up), add(bottom0, up)])
        }
        return result
    }

    private static func isBlocked(
        _ point: OniLevelVector3, by polygons: [BlockingPolygon]
    ) -> Bool {
        for polygon in polygons {
            guard point.x >= polygon.minimum.x - 0.05, point.x <= polygon.maximum.x + 0.05,
                  point.y >= polygon.minimum.y - 0.05, point.y <= polygon.maximum.y + 0.05,
                  point.z >= polygon.minimum.z - 0.05, point.z <= polygon.maximum.z + 0.05,
                  abs(dot(polygon.normal, point) - polygon.planeDistance) <= 0.05,
                  containsProjected(point, polygon: polygon) else { continue }
            return true
        }
        return false
    }

    private static func containsProjected(
        _ point: OniLevelVector3, polygon: BlockingPolygon
    ) -> Bool {
        let nx = abs(polygon.normal.x), ny = abs(polygon.normal.y), nz = abs(polygon.normal.z)
        func project(_ value: OniLevelVector3) -> OniLevelVector2 {
            if nx >= ny, nx >= nz { return OniLevelVector2(x: value.y, y: value.z) }
            if ny >= nz { return OniLevelVector2(x: value.x, y: value.z) }
            return OniLevelVector2(x: value.x, y: value.y)
        }
        let target = project(point)
        let points = polygon.points.map(project)
        var inside = false
        var previous = points.last!
        for current in points {
            if pointOnSegment2D(target, previous, current) { return true }
            if (current.y > target.y) != (previous.y > target.y) {
                let crossingX = (previous.x - current.x) * (target.y - current.y)
                    / (previous.y - current.y) + current.x
                if target.x < crossingX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func pointOnSegment2D(
        _ point: OniLevelVector2, _ start: OniLevelVector2, _ end: OniLevelVector2
    ) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        let px = point.x - start.x, py = point.y - start.y
        let crossValue = dx * py - dy * px
        guard abs(crossValue) <= 0.05 * max(1, sqrt(dx * dx + dy * dy)) else { return false }
        let projection = px * dx + py * dy
        return projection >= -0.05 && projection <= dx * dx + dy * dy + 0.05
    }

    private static func interpolate(
        _ start: OniLevelVector3, _ end: OniLevelVector3, _ t: Float
    ) -> OniLevelVector3 {
        OniLevelVector3(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t,
            z: start.z + (end.z - start.z) * t
        )
    }

    private static func surface(
        kind: OniRoomSurfaceKind, name: String, points: [OniLevelVector3]
    ) -> OniRoomSurface? {
        guard let normal = roomSurfaceNormal(points) else { return nil }
        let minimum = OniLevelVector3(
            x: points.map(\.x).min() ?? 0,
            y: points.map(\.y).min() ?? 0,
            z: points.map(\.z).min() ?? 0
        )
        let maximum = OniLevelVector3(
            x: points.map(\.x).max() ?? 0,
            y: points.map(\.y).max() ?? 0,
            z: points.map(\.z).max() ?? 0
        )
        return OniRoomSurface(
            kind: kind, nodeName: name, points: points, normal: normal,
            minimum: minimum, maximum: maximum
        )
    }

    private static func edgeKey(_ first: OniLevelVector3, _ second: OniLevelVector3) -> String {
        func pointKey(_ point: OniLevelVector3) -> String {
            "\(Int((point.x / pointTolerance).rounded())),\(Int((point.y / pointTolerance).rounded())),\(Int((point.z / pointTolerance).rounded()))"
        }
        let firstKey = pointKey(first), secondKey = pointKey(second)
        return firstKey < secondKey ? "\(firstKey)|\(secondKey)" : "\(secondKey)|\(firstKey)"
    }

    private static func quadrangulate(_ polygons: [[OniLevelVector3]]) -> [[OniLevelVector3]] {
        var replacements = Array<[OniLevelVector3]?>(repeating: nil, count: polygons.count)
        var consumed = Array(repeating: false, count: polygons.count)

        while true {
            var candidates: [(
                firstIndex: Int, secondIndex: Int,
                points: [OniLevelVector3], sharedLengthSquared: Float, quality: Float
            )] = []
            for firstIndex in polygons.indices
                where !consumed[firstIndex] && polygons[firstIndex].count == 3 {
                for secondIndex in polygons.indices
                    where secondIndex > firstIndex && !consumed[secondIndex]
                        && polygons[secondIndex].count == 3 {
                    guard let candidate = quadCandidate(
                        polygons[firstIndex], polygons[secondIndex]
                    ) else { continue }
                    candidates.append((
                        firstIndex, secondIndex,
                        candidate.points, candidate.sharedLengthSquared, candidate.quality
                    ))
                }
            }
            guard !candidates.isEmpty else { break }

            var degrees: [Int: Int] = [:]
            for candidate in candidates {
                degrees[candidate.firstIndex, default: 0] += 1
                degrees[candidate.secondIndex, default: 0] += 1
            }
            let best = candidates.min {
                let firstMinimumDegree = min(
                    degrees[$0.firstIndex] ?? Int.max,
                    degrees[$0.secondIndex] ?? Int.max
                )
                let secondMinimumDegree = min(
                    degrees[$1.firstIndex] ?? Int.max,
                    degrees[$1.secondIndex] ?? Int.max
                )
                if firstMinimumDegree != secondMinimumDegree {
                    return firstMinimumDegree < secondMinimumDegree
                }
                if abs($0.quality - $1.quality) >= Float.ulpOfOne {
                    return $0.quality > $1.quality
                }
                if abs($0.sharedLengthSquared - $1.sharedLengthSquared) >= Float.ulpOfOne {
                    return $0.sharedLengthSquared > $1.sharedLengthSquared
                }
                if $0.firstIndex != $1.firstIndex { return $0.firstIndex < $1.firstIndex }
                return $0.secondIndex < $1.secondIndex
            }!

            replacements[best.firstIndex] = best.points
            consumed[best.firstIndex] = true
            consumed[best.secondIndex] = true
        }

        var result: [[OniLevelVector3]] = []
        for index in polygons.indices {
            if let replacement = replacements[index] {
                result.append(replacement)
            } else if !consumed[index] {
                result.append(polygons[index])
            }
        }
        return result
    }

    private static func quadCandidate(
        _ first: [OniLevelVector3], _ second: [OniLevelVector3]
    ) -> (points: [OniLevelVector3], sharedLengthSquared: Float, quality: Float)? {
        guard let firstNormal = polygonNormal(first), let secondNormal = polygonNormal(second),
              dot(firstNormal, secondNormal) >= 1 - planeTolerance,
              abs(planeDistance(first, normal: firstNormal) - planeDistance(second, normal: firstNormal)) <= planeTolerance else {
            return nil
        }

        for firstEdge in first.indices {
            let firstEnd = (firstEdge + 1) % first.count
            for secondEdge in second.indices {
                let secondEnd = (secondEdge + 1) % second.count
                let sameDirection = approximatelyEqual(first[firstEdge], second[secondEdge])
                    && approximatelyEqual(first[firstEnd], second[secondEnd])
                let oppositeDirection = approximatelyEqual(first[firstEdge], second[secondEnd])
                    && approximatelyEqual(first[firstEnd], second[secondEdge])
                guard sameDirection || oppositeDirection else { continue }

                let firstOther = first.indices.first { $0 != firstEdge && $0 != firstEnd }!
                let secondOther = second.indices.first { $0 != secondEdge && $0 != secondEnd }!
                var points = removeCollinearPoints([
                    first[firstEnd], first[firstOther], first[firstEdge], second[secondOther]
                ])
                guard points.count >= 4 else { continue }
                if let mergedNormal = polygonNormal(points), dot(mergedNormal, firstNormal) < 0 {
                    points.reverse()
                }
                let sourceArea = abs(signedAreaXZ(first)) + abs(signedAreaXZ(second))
                let mergedArea = abs(signedAreaXZ(points))
                let areaTolerance = max(0.01, sourceArea * 0.0001)
                guard isConvexXZ(points), abs(sourceArea - mergedArea) <= areaTolerance,
                      let quality = quadQuality(points) else {
                    continue
                }
                let edge = subtract(first[firstEnd], first[firstEdge])
                return (points, lengthSquared(edge), quality)
            }
        }
        return nil
    }

    private static func colladaData(
        floors: [[OniLevelVector3]], ghosts: [[OniLevelVector3]]
    ) -> Data {
        let document = XMLDocument()
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        let root = XMLElement(name: "COLLADA")
        root.addAttribute(XMLNode.attribute(withName: "xmlns", stringValue: "http://www.collada.org/2005/11/COLLADASchema") as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "1.4.1") as! XMLNode)
        document.setRootElement(root)

        let asset = XMLElement(name: "asset")
        let unit = XMLElement(name: "unit")
        unit.addAttribute(XMLNode.attribute(withName: "name", stringValue: "decimeter") as! XMLNode)
        unit.addAttribute(XMLNode.attribute(withName: "meter", stringValue: "0.1") as! XMLNode)
        asset.addChild(unit)
        asset.addChild(element("up_axis", text: "Y_UP"))
        root.addChild(asset)

        let geometries = XMLElement(name: "library_geometries")
        let scenes = XMLElement(name: "library_visual_scenes")
        let visualScene = XMLElement(name: "visual_scene")
        visualScene.addAttribute(XMLNode.attribute(withName: "id", stringValue: "room_scene") as! XMLNode)
        visualScene.addAttribute(XMLNode.attribute(withName: "name", stringValue: "room_scene") as! XMLNode)

        let surfaces = floors.enumerated().map { (name: "floor_\($0.offset)", points: $0.element) }
            + ghosts.enumerated().map { (name: "ghost_\($0.offset)", points: $0.element) }
        for surface in surfaces {
            let name = surface.name
            let points = surface.points
            let geometryID = "\(name)_geo"
            let positionsID = "\(geometryID)_positions"
            let arrayID = "\(positionsID)_array"
            let verticesID = "\(geometryID)_vertices"

            let geometry = XMLElement(name: "geometry")
            geometry.addAttribute(XMLNode.attribute(withName: "id", stringValue: geometryID) as! XMLNode)
            geometry.addAttribute(XMLNode.attribute(withName: "name", stringValue: geometryID) as! XMLNode)
            let mesh = XMLElement(name: "mesh")
            let source = XMLElement(name: "source")
            source.addAttribute(XMLNode.attribute(withName: "id", stringValue: positionsID) as! XMLNode)
            let array = element("float_array", text: points.flatMap { [$0.x, $0.y, $0.z] }.map(format).joined(separator: " "))
            array.addAttribute(XMLNode.attribute(withName: "id", stringValue: arrayID) as! XMLNode)
            array.addAttribute(XMLNode.attribute(withName: "count", stringValue: String(points.count * 3)) as! XMLNode)
            source.addChild(array)
            let technique = XMLElement(name: "technique_common")
            let accessor = XMLElement(name: "accessor")
            accessor.addAttribute(XMLNode.attribute(withName: "source", stringValue: "#\(arrayID)") as! XMLNode)
            accessor.addAttribute(XMLNode.attribute(withName: "count", stringValue: String(points.count)) as! XMLNode)
            accessor.addAttribute(XMLNode.attribute(withName: "stride", stringValue: "3") as! XMLNode)
            for parameterName in ["X", "Y", "Z"] {
                let parameter = XMLElement(name: "param")
                parameter.addAttribute(XMLNode.attribute(withName: "name", stringValue: parameterName) as! XMLNode)
                parameter.addAttribute(XMLNode.attribute(withName: "type", stringValue: "float") as! XMLNode)
                accessor.addChild(parameter)
            }
            technique.addChild(accessor)
            source.addChild(technique)
            mesh.addChild(source)

            let vertices = XMLElement(name: "vertices")
            vertices.addAttribute(XMLNode.attribute(withName: "id", stringValue: verticesID) as! XMLNode)
            let vertexInput = XMLElement(name: "input")
            vertexInput.addAttribute(XMLNode.attribute(withName: "semantic", stringValue: "POSITION") as! XMLNode)
            vertexInput.addAttribute(XMLNode.attribute(withName: "source", stringValue: "#\(positionsID)") as! XMLNode)
            vertices.addChild(vertexInput)
            mesh.addChild(vertices)

            let polygon = XMLElement(name: "polygons")
            polygon.addAttribute(XMLNode.attribute(withName: "count", stringValue: "1") as! XMLNode)
            let polygonInput = XMLElement(name: "input")
            polygonInput.addAttribute(XMLNode.attribute(withName: "semantic", stringValue: "VERTEX") as! XMLNode)
            polygonInput.addAttribute(XMLNode.attribute(withName: "source", stringValue: "#\(verticesID)") as! XMLNode)
            polygonInput.addAttribute(XMLNode.attribute(withName: "offset", stringValue: "0") as! XMLNode)
            polygon.addChild(polygonInput)
            polygon.addChild(element("p", text: points.indices.map(String.init).joined(separator: " ")))
            mesh.addChild(polygon)
            geometry.addChild(mesh)
            geometries.addChild(geometry)

            let node = XMLElement(name: "node")
            node.addAttribute(XMLNode.attribute(withName: "id", stringValue: name) as! XMLNode)
            node.addAttribute(XMLNode.attribute(withName: "name", stringValue: name) as! XMLNode)
            let instance = XMLElement(name: "instance_geometry")
            instance.addAttribute(XMLNode.attribute(withName: "url", stringValue: "#\(geometryID)") as! XMLNode)
            node.addChild(instance)
            visualScene.addChild(node)
        }

        scenes.addChild(visualScene)
        root.addChild(geometries)
        root.addChild(scenes)
        let scene = XMLElement(name: "scene")
        let instanceScene = XMLElement(name: "instance_visual_scene")
        instanceScene.addAttribute(XMLNode.attribute(withName: "url", stringValue: "#room_scene") as! XMLNode)
        scene.addChild(instanceScene)
        root.addChild(scene)
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func element(_ name: String, text: String) -> XMLElement {
        let value = XMLElement(name: name)
        value.stringValue = text
        return value
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private static func removeRepeatedClosingPoint(_ points: [OniLevelVector3]) -> [OniLevelVector3] {
        guard points.count > 3, let first = points.first, let last = points.last,
              approximatelyEqual(first, last) else { return points }
        return Array(points.dropLast())
    }

    private static func orientedUpward(_ points: [OniLevelVector3]) -> [OniLevelVector3] {
        guard let normal = roomSurfaceNormal(points), normal.y < 0 else { return points }
        return Array(points.reversed())
    }

    // Match the simplification and first-three-points normal used when the
    // generated file is consumed as room geometry.
    private static func roomSurfaceNormal(_ points: [OniLevelVector3]) -> OniLevelVector3? {
        guard points.count >= 3 else { return nil }
        var simplified: [OniLevelVector3] = []
        for index in points.indices {
            let previous = points[index == points.startIndex ? points.index(before: points.endIndex) : points.index(before: index)]
            let current = points[index]
            let next = points[points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)]
            if approximatelyEqual(current, previous) { continue }
            let incoming = subtract(current, previous)
            let outgoing = subtract(next, current)
            if lengthSquared(cross(outgoing, incoming)) < 0.000001 { continue }
            simplified.append(current)
        }
        guard simplified.count >= 3 else { return nil }
        let value = cross(subtract(simplified[1], simplified[0]), subtract(simplified[2], simplified[0]))
        let magnitude = sqrt(lengthSquared(value))
        guard magnitude >= 0.01 else { return nil }
        return OniLevelVector3(x: value.x / magnitude, y: value.y / magnitude, z: value.z / magnitude)
    }

    private static func polygonNormal(_ points: [OniLevelVector3]) -> OniLevelVector3? {
        guard points.count >= 3 else { return nil }
        for index in 1..<(points.count - 1) {
            let value = cross(subtract(points[index], points[0]), subtract(points[index + 1], points[0]))
            let magnitude = sqrt(lengthSquared(value))
            if magnitude >= 0.01 {
                return OniLevelVector3(x: value.x / magnitude, y: value.y / magnitude, z: value.z / magnitude)
            }
        }
        return nil
    }

    private static func approximatelyEqual(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Bool {
        abs(lhs.x - rhs.x) <= pointTolerance
            && abs(lhs.y - rhs.y) <= pointTolerance
            && abs(lhs.z - rhs.z) <= pointTolerance
    }

    private static func planeDistance(_ points: [OniLevelVector3], normal: OniLevelVector3) -> Float {
        dot(normal, points[0])
    }

    private static func subtract(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func add(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 {
        OniLevelVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
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

    private static func lengthSquared(_ value: OniLevelVector3) -> Float {
        dot(value, value)
    }
}
