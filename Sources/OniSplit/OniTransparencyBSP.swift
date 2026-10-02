import Foundation

package struct OniTransparencyBSPNode {
    package let polygonIndex: Int
    package let planeIndex: Int
    package let frontChildIndex: Int
    package let backChildIndex: Int
}

package struct OniTransparencyBSP {
    package let nodes: [OniTransparencyBSPNode]

    package var abnaPayload: Data {
        var data = Data(repeating: 0, count: 20)
        append(&data, UInt32(nodes.count))
        for node in nodes {
            append(&data, UInt32(node.polygonIndex))
            append(&data, UInt32(node.planeIndex))
            append(&data, UInt32(bitPattern: Int32(node.frontChildIndex)))
            append(&data, UInt32(bitPattern: Int32(node.backChildIndex)))
        }
        return data
    }

    private func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
}

package enum OniTransparencyBSPBuilder {
    private final class WorkingNode {
        let polygonIndex: Int
        let planeIndex: Int
        var algorithmFront: WorkingNode?
        var algorithmBack: WorkingNode?

        init(polygonIndex: Int, planeIndex: Int) {
            self.polygonIndex = polygonIndex
            self.planeIndex = planeIndex
        }
    }

    package static func build(
        geometry: OniAkiraGeometry,
        transparentMaterialNames: Set<String>,
        polygonCount: Int? = nil
    ) -> OniTransparencyBSP {
        let candidates = 0..<min(polygonCount ?? geometry.polygons.count, geometry.polygons.count)
        let polygonIndices = candidates.filter { index in
            let polygon = geometry.polygons[index]
            let material = geometry.materials[polygon.materialIndex]
            return polygon.flags & 0x80 != 0
                && material.lowercased() != "_marker_door"
        }
        guard let root = build(polygonIndices, geometry: geometry) else { return OniTransparencyBSP(nodes: []) }
        var nodes: [OniTransparencyBSPNode] = []
        convert(root, to: &nodes)
        return OniTransparencyBSP(nodes: nodes)
    }

    private static func build(_ polygonIndices: [Int], geometry: OniAkiraGeometry) -> WorkingNode? {
        guard let separatorIndex = polygonIndices.first else { return nil }
        let separator = geometry.planes[geometry.polygons[separatorIndex].planeIndex]
        let node = WorkingNode(polygonIndex: separatorIndex, planeIndex: geometry.polygons[separatorIndex].planeIndex)
        if polygonIndices.count > 1 {
            var front: [Int] = [], back: [Int] = []
            for polygonIndex in polygonIndices.dropFirst() {
                let polygon = geometry.polygons[polygonIndex]
                let plane = geometry.planes[polygon.planeIndex]
                var isFront = false, isBack = false
                let dx = plane.normal.x - separator.normal.x
                let dy = plane.normal.y - separator.normal.y
                let dz = plane.normal.z - separator.normal.z
                if abs(plane.d - separator.d) < 0.001, sqrt(dx*dx + dy*dy + dz*dz) < 0.001 {
                    isFront = true
                } else {
                    for pointIndex in polygon.pointIndices {
                        let point = geometry.points[pointIndex]
                        if dot(separator.normal, point) + separator.d > 0 { isFront = true }
                        else { isBack = true }
                    }
                }
                if isFront { front.append(polygonIndex) }
                if isBack { back.append(polygonIndex) }
            }
            node.algorithmFront = build(front, geometry: geometry)
            node.algorithmBack = build(back, geometry: geometry)
        }
        return node
    }

    @discardableResult
    private static func convert(_ source: WorkingNode?, to nodes: inout [OniTransparencyBSPNode]) -> Int {
        guard let source else { return -1 }
        let index = nodes.count
        nodes.append(OniTransparencyBSPNode(polygonIndex: source.polygonIndex, planeIndex: source.planeIndex, frontChildIndex: -1, backChildIndex: -1))
        // OniSplit's AlphaBspNode constructor historically passes these two branches
        // to its base class in reverse order; retain that serialized behavior.
        let storedFront = convert(source.algorithmBack, to: &nodes)
        let storedBack = convert(source.algorithmFront, to: &nodes)
        nodes[index] = OniTransparencyBSPNode(
            polygonIndex: source.polygonIndex,
            planeIndex: source.planeIndex,
            frontChildIndex: storedFront,
            backChildIndex: storedBack
        )
        return index
    }

    private static func dot(_ lhs: OniLevelVector3, _ rhs: OniLevelVector3) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }
}
