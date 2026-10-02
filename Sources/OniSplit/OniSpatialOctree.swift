import Foundation

package struct OniSpatialOctree {
    package let interiorChildren: [Int32]
    package let leafAdjacency: [Int32]
    package let leafPackedBounds: [UInt32]
    package let leafPolygonRanges: [UInt32]
    package let leafRoomRanges: [UInt32]
    package let faceQuadtreeChildren: [Int32]
    package let polygonIndices: [UInt32]
    package let roomIndices: [UInt32]

    package var otitPayload: Data { longArray(interiorChildren.map { UInt32(bitPattern: $0) }, elementWidth: 8) }
    package var otlfPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(leafPackedBounds.count))
        for index in leafPackedBounds.indices {
            append(&data, leafPolygonRanges[index])
            for face in 0..<6 { append(&data, UInt32(bitPattern: leafAdjacency[index * 6 + face])) }
            append(&data, leafPackedBounds[index])
            append(&data, leafRoomRanges[index])
        }
        return data
    }
    package var qtnaPayload: Data { longArray(faceQuadtreeChildren.map { UInt32(bitPattern: $0) }, elementWidth: 4) }
    package var polygonIndexPayload: Data { longArray(polygonIndices, elementWidth: 1) }
    package var roomIndexPayload: Data { longArray(roomIndices, elementWidth: 1) }

    private func longArray(_ values: [UInt32], elementWidth: Int) -> Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(values.count / elementWidth))
        for value in values { append(&data, value) }
        return data
    }
    private func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
}

package enum OniSpatialOctreeBuilder {
    private struct Bounds {
        var minimum: OniLevelVector3
        var maximum: OniLevelVector3
        var center: OniLevelVector3 { scale(add(minimum, maximum), 0.5) }
        var size: Float { maximum.x - minimum.x }
    }

    private struct Polygon {
        let index: Int
        let points: [OniLevelVector3]
        let plane: OniAkiraPlane
        let bounds: Bounds
    }

    private final class Node {
        let bounds: Bounds
        var polygons: [Polygon]?
        var rooms: [OniRoom]?
        var children: [Node]?
        var adjacency = Array<Node?>(repeating: nil, count: 6)
        var index = 0

        init(bounds: Bounds, polygons: [Polygon], rooms: [OniRoom]) {
            self.bounds = bounds
            self.polygons = polygons
            self.rooms = rooms
        }

        var isLeaf: Bool { polygons != nil }
    }

    private final class QuadNode {
        let center: OniLevelVector3
        let size: Float
        let face: Int
        var nodes = Array<QuadNode?>(repeating: nil, count: 4)
        var leaves = Array<Node?>(repeating: nil, count: 4)
        var index = 0

        init(center: OniLevelVector3, size: Float, face: Int) {
            self.center = center; self.size = size; self.face = face
        }
    }

    private static let rootBounds = Bounds(
        minimum: OniLevelVector3(x: -4096, y: -4096, z: -4096),
        maximum: OniLevelVector3(x: 4096, y: 4096, z: 4096)
    )

    package static func build(geometry: OniAkiraGeometry, polygonCount: Int, topology: OniRoomTopology) -> OniSpatialOctree {
        let count = min(polygonCount, geometry.polygons.count)
        let polygons: [Polygon] = geometry.polygons.prefix(count).enumerated().compactMap { index, polygon in
            guard geometry.materials.indices.contains(polygon.materialIndex),
                  geometry.materials[polygon.materialIndex].lowercased() != "_marker_door" else { return nil }
            let points = polygon.pointIndices.compactMap { geometry.points.indices.contains($0) ? geometry.points[$0] : nil }
            guard points.count >= 3, geometry.planes.indices.contains(polygon.planeIndex) else { return nil }
            return Polygon(
                index: index,
                points: points,
                plane: geometry.planes[polygon.planeIndex],
                bounds: Bounds(minimum: polygon.minimum, maximum: polygon.maximum)
            )
        }
        let root = Node(bounds: rootBounds, polygons: polygons, rooms: topology.rooms)
        build(root)
        if root.children == nil { split(root) }

        var interior: [Node] = [], leaves: [Node] = []
        traverse(root) { node in
            if node.isLeaf { node.index = leaves.count; leaves.append(node) }
            else { node.index = interior.count; interior.append(node) }
        }

        let remap = [0, 4, 2, 6, 1, 5, 3, 7]
        var interiorChildren = Array(repeating: Int32(0), count: interior.count * 8)
        for node in interior {
            for sourceIndex in 0..<8 {
                let child = node.children![sourceIndex]
                let value = child.isLeaf ? Int32(child.index) | Int32.min : Int32(child.index)
                interiorChildren[node.index * 8 + remap[sourceIndex]] = value
            }
        }

        var polygonIndices: [UInt32] = [], roomIndices: [UInt32] = []
        var polygonRanges = Array(repeating: UInt32(0), count: leaves.count)
        var roomRanges = Array(repeating: UInt32(0), count: leaves.count)
        var packedBounds = Array(repeating: UInt32(0), count: leaves.count)
        for leaf in leaves {
            if let polygons = leaf.polygons, !polygons.isEmpty {
                polygonRanges[leaf.index] = UInt32(polygonIndices.count << 12) | UInt32(polygons.count & 0x0fff)
                polygonIndices.append(contentsOf: polygons.map { UInt32($0.index) })
            }
            if let rooms = leaf.rooms, !rooms.isEmpty {
                roomRanges[leaf.index] = UInt32(roomIndices.count << 8) | UInt32(rooms.count & 0xff)
                roomIndices.append(contentsOf: rooms.map { UInt32($0.index) })
            }
            packedBounds[leaf.index] = pack(leaf.bounds)
        }

        var leafAdjacency = Array(repeating: Int32(-1), count: leaves.count * 6)
        var quadChildren: [Int32] = []
        for leaf in leaves {
            refineAdjacency(leaf)
            for face in 0..<6 {
                let outputIndex = leaf.index * 6 + face
                guard let adjacent = leaf.adjacency[face] else { continue }
                if adjacent.isLeaf {
                    leafAdjacency[outputIndex] = Int32(adjacent.index) | Int32.min
                } else {
                    let base = quadChildren.count / 4
                    leafAdjacency[outputIndex] = Int32(base)
                    let root = QuadNode(center: move(leaf.bounds.center, face: face, delta: leaf.bounds.size * 0.5), size: leaf.bounds.size, face: face)
                    buildQuad(root, adjacent: adjacent)
                    var list: [QuadNode] = []
                    traverseQuad(root) { node in node.index = list.count; list.append(node) }
                    for node in list {
                        for child in 0..<4 {
                            if let nested = node.nodes[child] { quadChildren.append(Int32(base + nested.index)) }
                            else { quadChildren.append(Int32(node.leaves[child]!.index) | Int32.min) }
                        }
                    }
                }
            }
        }

        return OniSpatialOctree(
            interiorChildren: interiorChildren,
            leafAdjacency: leafAdjacency,
            leafPackedBounds: packedBounds,
            leafPolygonRanges: polygonRanges,
            leafRoomRanges: roomRanges,
            faceQuadtreeChildren: quadChildren,
            polygonIndices: polygonIndices,
            roomIndices: roomIndices
        )
    }

    private static func build(_ node: Node) {
        if (node.polygons?.count ?? 0) <= 19, (node.rooms?.count ?? 0) < 16 { return }
        if node.bounds.size <= 16 { return }
        split(node)
    }

    private static func split(_ node: Node) {
        let center = node.bounds.center
        var children: [Node] = []
        for position in 0..<8 {
            let bounds = Bounds(
                minimum: OniLevelVector3(
                    x: position & 4 == 0 ? node.bounds.minimum.x : center.x,
                    y: position & 2 == 0 ? node.bounds.minimum.y : center.y,
                    z: position & 1 == 0 ? node.bounds.minimum.z : center.z
                ),
                maximum: OniLevelVector3(
                    x: position & 4 == 0 ? center.x : node.bounds.maximum.x,
                    y: position & 2 == 0 ? center.y : node.bounds.maximum.y,
                    z: position & 1 == 0 ? center.z : node.bounds.maximum.z
                )
            )
            let polygons = (node.polygons ?? []).filter { intersects($0, bounds) }
            let rooms = (node.rooms ?? []).filter { intersects($0, bounds) }
            children.append(Node(bounds: bounds, polygons: polygons, rooms: rooms))
        }
        node.children = children
        node.polygons = nil; node.rooms = nil
        buildSimpleAdjacency(node)
        for child in children { build(child) }
    }

    private static func buildSimpleAdjacency(_ node: Node) {
        for position in 0..<8 {
            let child = node.children![position]
            for face in 0..<6 {
                let axis = axisForFace(face), bit = 1 << axis
                let positive = face & 1 == 1
                if positive, position & bit == 0 { child.adjacency[face] = node.children![position | bit] }
                else if !positive, position & bit != 0 { child.adjacency[face] = node.children![position & ~bit] }
                else { child.adjacency[face] = node.adjacency[face] }
            }
        }
    }

    private static func refineAdjacency(_ leaf: Node) {
        for face in 0..<6 {
            if let adjacent = leaf.adjacency[face], !adjacent.isLeaf, adjacent.bounds.size > leaf.bounds.size {
                leaf.adjacency[face] = findLargestOrEqual(adjacent, point: move(leaf.bounds.center, face: face, delta: leaf.bounds.size), size: leaf.bounds.size)
            }
        }
    }

    private static func findLargestOrEqual(_ start: Node, point: OniLevelVector3, size: Float) -> Node {
        var node = start
        while !node.isLeaf, node.bounds.size > size {
            let center = node.bounds.center
            let childIndex = (point.x < center.x ? 0 : 4) + (point.y < center.y ? 0 : 2) + (point.z < center.z ? 0 : 1)
            let child = node.children![childIndex]
            if child.bounds.size < size { break }
            node = child
        }
        return node
    }

    private static func buildQuad(_ node: QuadNode, adjacent: Node) {
        let childSize = node.size * 0.5
        for position in 0..<4 {
            let childCenter = quadChildCenter(node, position: position)
            let adjacentCenter = move(childCenter, face: node.face, delta: childSize * 0.5)
            let found = findLargestOrEqual(adjacent, point: adjacentCenter, size: childSize)
            if found.isLeaf { node.leaves[position] = found }
            else {
                let child = QuadNode(center: childCenter, size: childSize, face: node.face)
                buildQuad(child, adjacent: found)
                node.nodes[position] = child
            }
        }
    }

    private static func quadChildCenter(_ node: QuadNode, position: Int) -> OniLevelVector3 {
        let offset = node.size * 0.25
        let u: Float = position & 1 == 0 ? -offset : offset
        let v: Float = position & 2 == 0 ? -offset : offset
        let point = node.center
        switch axisForFace(node.face) {
        case 2: return OniLevelVector3(x: point.x, y: point.y + u, z: point.z + v)
        case 1: return OniLevelVector3(x: point.x + u, y: point.y, z: point.z + v)
        default: return OniLevelVector3(x: point.x + u, y: point.y + v, z: point.z)
        }
    }

    private static func move(_ point: OniLevelVector3, face: Int, delta initialDelta: Float) -> OniLevelVector3 {
        let delta = face & 1 == 0 ? -initialDelta : initialDelta
        switch axisForFace(face) {
        case 2: return OniLevelVector3(x: point.x + delta, y: point.y, z: point.z)
        case 1: return OniLevelVector3(x: point.x, y: point.y + delta, z: point.z)
        default: return OniLevelVector3(x: point.x, y: point.y, z: point.z + delta)
        }
    }

    private static func axisForFace(_ face: Int) -> Int { 2 - ((face & 6) >> 1) }

    private static func intersects(_ polygon: Polygon, _ box: Bounds) -> Bool {
        guard intersects(polygon.bounds, box), intersects(box, polygon.plane) else { return false }
        if triangleIntersectsBox(Array(polygon.points.prefix(3)), box) { return true }
        if polygon.points.count > 3 {
            return triangleIntersectsBox([polygon.points[2], polygon.points[3], polygon.points[0]], box)
        }
        return false
    }

    private static func triangleIntersectsBox(_ source: [OniLevelVector3], _ box: Bounds) -> Bool {
        let center = box.center
        let half = scale(subtract(box.maximum, box.minimum), 0.5)
        let triangle = source.map { subtract($0, center) }
        let edges = [subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[1]), subtract(triangle[0], triangle[2])]
        let tests = [(1,2,0,2), (2,0,0,2), (0,1,2,1), (1,2,0,2), (2,0,0,2), (0,1,0,1), (1,2,0,1), (2,0,0,1), (0,1,2,1)]
        for (index, test) in tests.enumerated() {
            let edge = edges[index / 3]
            if axisSeparates(edge, triangle, half, test.0, test.1, test.2, test.3) { return false }
        }
        return true
    }

    private static func axisSeparates(_ edge: OniLevelVector3, _ triangle: [OniLevelVector3], _ half: OniLevelVector3, _ a1: Int, _ a2: Int, _ p0: Int, _ p1: Int) -> Bool {
        let c0 = component(edge, a2) * component(triangle[p0], a1) - component(edge, a1) * component(triangle[p0], a2)
        let c1 = component(edge, a2) * component(triangle[p1], a1) - component(edge, a1) * component(triangle[p1], a2)
        let radius = abs(component(edge, a2)) * component(half, a1) + abs(component(edge, a1)) * component(half, a2)
        return c0 < c1 ? c0 > radius || c1 < -radius : c1 > radius || c0 < -radius
    }

    private static func intersects(_ room: OniRoom, _ box: Bounds) -> Bool {
        let roomBounds = Bounds(minimum: room.minimum, maximum: room.maximum)
        guard intersects(roomBounds, box) else { return false }
        var planes: [OniAkiraPlane] = []
        for index in room.floor.points.indices.reversed() {
            let p0 = room.floor.points[index], p1 = room.floor.points[(index + 1) % room.floor.points.count]
            if let side = makePlane([p0, p1, OniLevelVector3(x: p1.x, y: p1.y + 1, z: p1.z)]) { planes.append(side) }
        }
        let floor = OniAkiraPlane(normal: room.floor.normal, d: -dot(room.floor.normal, room.floor.points[0]))
        planes.append(OniAkiraPlane(normal: floor.normal, d: floor.d - room.height))
        planes.append(OniAkiraPlane(normal: scale(floor.normal, -1), d: -floor.d))
        var front = false
        for plane in planes {
            let relation = relation(box, plane)
            if relation == 0 { return true }
            front = relation > 0
            if front { return false }
        }
        return !front
    }

    private static func relation(_ box: Bounds, _ plane: OniAkiraPlane) -> Int {
        let minimum = OniLevelVector3(
            x: plane.normal.x >= 0 ? box.minimum.x : box.maximum.x,
            y: plane.normal.y >= 0 ? box.minimum.y : box.maximum.y,
            z: plane.normal.z >= 0 ? box.minimum.z : box.maximum.z
        )
        let maximum = OniLevelVector3(
            x: plane.normal.x >= 0 ? box.maximum.x : box.minimum.x,
            y: plane.normal.y >= 0 ? box.maximum.y : box.minimum.y,
            z: plane.normal.z >= 0 ? box.maximum.z : box.minimum.z
        )
        if dot(plane.normal, minimum) + plane.d > 0 { return 1 }
        if dot(plane.normal, maximum) + plane.d < 0 { return -1 }
        return 0
    }

    private static func intersects(_ lhs: Bounds, _ rhs: Bounds) -> Bool {
        lhs.maximum.x >= rhs.minimum.x && lhs.minimum.x <= rhs.maximum.x
            && lhs.maximum.y >= rhs.minimum.y && lhs.minimum.y <= rhs.maximum.y
            && lhs.maximum.z >= rhs.minimum.z && lhs.minimum.z <= rhs.maximum.z
    }

    private static func intersects(_ box: Bounds, _ plane: OniAkiraPlane) -> Bool {
        let positive = OniLevelVector3(
            x: plane.normal.x >= 0 ? box.maximum.x : box.minimum.x,
            y: plane.normal.y >= 0 ? box.maximum.y : box.minimum.y,
            z: plane.normal.z >= 0 ? box.maximum.z : box.minimum.z
        )
        let negative = OniLevelVector3(
            x: plane.normal.x >= 0 ? box.minimum.x : box.maximum.x,
            y: plane.normal.y >= 0 ? box.minimum.y : box.maximum.y,
            z: plane.normal.z >= 0 ? box.minimum.z : box.maximum.z
        )
        return dot(plane.normal, negative) <= -plane.d && dot(plane.normal, positive) >= -plane.d
    }

    private static func makePlane(_ points: [OniLevelVector3]) -> OniAkiraPlane? {
        let a = subtract(points[1], points[0]), b = subtract(points[2], points[0])
        let cross = OniLevelVector3(x: a.y*b.z-a.z*b.y, y: a.z*b.x-a.x*b.z, z: a.x*b.y-a.y*b.x)
        let length = sqrt(dot(cross, cross)); guard length >= 0.01 else { return nil }
        let normal = scale(cross, 1 / length)
        return OniAkiraPlane(normal: normal, d: -dot(normal, points[0]))
    }

    private static func pack(_ bounds: Bounds) -> UInt32 {
        let size = Int(log2(bounds.size)) - 4
        let x = Int(bounds.maximum.x + 4080), y = Int(bounds.maximum.y + 4080), z = Int(bounds.maximum.z + 4080)
        return UInt32((x << 14) | (y << 5) | (z >> 4) | (size << 27))
    }

    private static func traverse(_ node: Node, action: (Node) -> Void) {
        action(node); if let children = node.children { for child in children { traverse(child, action: action) } }
    }
    private static func traverseQuad(_ node: QuadNode, action: (QuadNode) -> Void) {
        action(node); for child in node.nodes.compactMap({ $0 }) { traverseQuad(child, action: action) }
    }
    private static func component(_ value: OniLevelVector3, _ index: Int) -> Float { index == 0 ? value.x : index == 1 ? value.y : value.z }
    private static func add(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 { OniLevelVector3(x: lhs.x+rhs.x, y: lhs.y+rhs.y, z: lhs.z+rhs.z) }
    private static func subtract(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> OniLevelVector3 { OniLevelVector3(x: lhs.x-rhs.x, y: lhs.y-rhs.y, z: lhs.z-rhs.z) }
    private static func scale(_ value: OniLevelVector3, _ amount: Float) -> OniLevelVector3 { OniLevelVector3(x: value.x*amount, y: value.y*amount, z: value.z*amount) }
    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float { lhs.x*rhs.x + lhs.y*rhs.y + lhs.z*rhs.z }
}
