import Foundation

package enum OniRoomGridWeight: UInt8, CaseIterable {
    case clear = 0
    case nearWall = 1
    case border1 = 2
    case border2 = 3
    case semiPassable = 4
    case border3 = 5
    case border4 = 6
    case stairs = 7
    case danger = 8
    case impassable = 9
}

package struct OniRoomGrid {
    package static let tileSize: Float = 4
    package static let xOrigin = -2
    package static let zOrigin = -2

    package let xTiles: Int
    package let zTiles: Int
    package let data: [UInt8]

    package init(xTiles: Int, zTiles: Int, data: [UInt8]) {
        precondition(xTiles >= 0 && zTiles >= 0 && data.count == xTiles * zTiles)
        self.xTiles = xTiles
        self.zTiles = zTiles
        self.data = data
    }

    package subscript(x: Int, z: Int) -> OniRoomGridWeight? {
        guard x >= 0, x < xTiles, z >= 0, z < zTiles else { return nil }
        return OniRoomGridWeight(rawValue: data[x + z * xTiles])
    }

    package func compressed() -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var index = 0
        while index < data.count {
            let type = data[index]
            var count = 1
            while count < 255, index + count < data.count, data[index + count] == type {
                count += 1
            }
            if count < 16 {
                result.append(UInt8(count << 4) | type)
            } else {
                result.append(type)
                result.append(UInt8(count))
            }
            index += count
        }
        return result
    }

    package static func decompress(xTiles: Int, zTiles: Int, data: Data) throws -> OniRoomGrid {
        let expectedCount = xTiles * zTiles
        var output: [UInt8] = []
        output.reserveCapacity(expectedCount)
        var index = data.startIndex
        while index < data.endIndex {
            let run = data[index]
            index = data.index(after: index)
            let type = run & 0x0f
            var count = Int(run >> 4)
            if count == 0 {
                guard index < data.endIndex else { throw OniDatError.outOfBounds("room grid run length") }
                count = Int(data[index])
                index = data.index(after: index)
            }
            guard count > 0, output.count + count <= expectedCount else {
                throw OniDatError.outOfBounds("room grid decompression")
            }
            output.append(contentsOf: repeatElement(type, count: count))
        }
        guard output.count == expectedCount else { throw OniDatError.outOfBounds("room grid tile data") }
        return OniRoomGrid(xTiles: xTiles, zTiles: zTiles, data: output)
    }
}

package final class OniRoomGridRasterizer {
    private struct Point {
        var x: Int
        var y: Int

        static let unitX = Point(x: 1, y: 0)
        static let unitY = Point(x: 0, y: 1)

        static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
        static func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    }

    private final class Edge {
        let maxY: Int
        var currentX: Float
        let reciprocalSlope: Float

        init(_ current: Point, _ next: Point) {
            maxY = max(current.y, next.y)
            reciprocalSlope = Float(current.x - next.x) / Float(current.y - next.y)
            currentX = current.y == maxY ? Float(next.x) : Float(current.x)
        }
    }

    private static let origin = -2
    private static let margin = 3

    package let xTiles: Int
    package let zTiles: Int
    private let worldOrigin: OniLevelVector3
    private var data: [UInt8]

    package init(minimum: OniLevelVector3, maximum: OniLevelVector3) {
        xTiles = Int((maximum.x - minimum.x) / OniRoomGrid.tileSize + Float(-Self.origin * 2 + 1)) + Self.margin * 2
        zTiles = Int((maximum.z - minimum.z) / OniRoomGrid.tileSize + Float(-Self.origin * 2 + 1)) + Self.margin * 2
        worldOrigin = minimum
        data = Array(repeating: OniRoomGridWeight.clear.rawValue, count: xTiles * zTiles)
    }

    package convenience init(room: OniRoom) {
        self.init(minimum: room.minimum, maximum: room.maximum)
    }

    package func clear(_ weight: OniRoomGridWeight) {
        data = Array(repeating: weight.rawValue, count: data.count)
    }

    package func drawFloor(_ points: [OniLevelVector3]) {
        for point in scanPolygon(points.map(worldToGrid)) { set(point, .clear) }
    }

    package func drawDanger(_ points: [OniLevelVector3]) {
        for point in scanPolygon(points.map(worldToGrid)) { set(point, .danger) }
    }

    package func drawWall(_ points: [OniLevelVector3]) {
        guard let endpoints = endpoints(points) else { return }
        let p0 = worldToGrid(endpoints.0)
        let p1 = worldToGrid(endpoints.1)
        drawLine(p0, p1, .impassable)
        drawLine(p0 - .unitY, p1 - .unitY, .semiPassable)
        drawLine(p0 + .unitY, p1 + .unitY, .semiPassable)
        drawLine(p0 + .unitX, p1 + .unitX, .semiPassable)
        drawLine(p0 - .unitX, p1 - .unitX, .semiPassable)
    }

    package func drawStairsEntry(_ points: [OniLevelVector3]) {
        guard let endpoints = endpoints(points) else { return }
        let p0 = worldToGrid(endpoints.0)
        let p1 = worldToGrid(endpoints.1)
        drawLine(p0, p1, .stairs)
        drawLine(p0 - .unitY, p1 - .unitY, .clear)
        drawLine(p0 + .unitY, p1 + .unitY, .clear)
        drawLine(p0 + .unitX, p1 + .unitX, .clear)
        drawLine(p0 - .unitX, p1 - .unitX, .clear)
        for point in points.sorted(by: { $0.y < $1.y }).prefix(2) { drawImpassable(point) }
    }

    package func drawImpassable(_ points: [OniLevelVector3]) {
        for point in scanPolygon(points.map(worldToGrid)) { drawTile(point.x, point.y, .impassable) }
    }

    package func drawImpassable(_ position: OniLevelVector3) {
        let point = worldToGrid(position)
        drawTile(point.x, point.y, .impassable)
        for x in -1...1 {
            for y in -1...1 where x != 0 || y != 0 {
                drawTile(point.x + x, point.y + y, .semiPassable)
            }
        }
    }

    package func addBorders() {
        addBorder(around: .danger, onlyIf: .clear, border: .border4)
        addBorder(around: .border4, onlyIf: .clear, border: .border3)
        addBorder(around: .border3, onlyIf: .clear, border: .border2)
        addBorder(around: .border2, onlyIf: .clear, border: .border1)
        addBorder(around: .semiPassable, onlyIf: .clear, border: .nearWall)
    }

    package func grid() -> OniRoomGrid {
        let width = xTiles - Self.margin * 2
        let height = zTiles - Self.margin * 2
        var cropped = Array(repeating: UInt8(0), count: width * height)
        for z in Self.margin..<(zTiles - Self.margin) {
            for x in Self.margin..<(xTiles - Self.margin) {
                cropped[(x - Self.margin) + (z - Self.margin) * width] = data[x + z * xTiles]
            }
        }
        return OniRoomGrid(xTiles: width, zTiles: height, data: cropped)
    }

    private func endpoints(_ points: [OniLevelVector3]) -> (OniLevelVector3, OniLevelVector3)? {
        guard var minimum = points.first else { return nil }
        var maximum = minimum
        for point in points {
            if point.x < minimum.x || (point.x == minimum.x && point.z < minimum.z) { minimum = point }
            if point.x > maximum.x || (point.x == maximum.x && point.z > maximum.z) { maximum = point }
        }
        return (minimum, maximum)
    }

    private func worldToGrid(_ point: OniLevelVector3) -> Point {
        Point(
            x: Int((point.x - worldOrigin.x) / OniRoomGrid.tileSize) - Self.origin + Self.margin,
            y: Int((point.z - worldOrigin.z) / OniRoomGrid.tileSize) - Self.origin + Self.margin
        )
    }

    private func set(_ point: Point, _ weight: OniRoomGridWeight) {
        guard point.x >= 0, point.x < xTiles, point.y >= 0, point.y < zTiles else { return }
        data[point.x + point.y * xTiles] = weight.rawValue
    }

    private func drawTile(_ x: Int, _ y: Int, _ weight: OniRoomGridWeight) {
        guard x >= 0, x < xTiles, y >= 0, y < zTiles else { return }
        let index = x + y * xTiles
        if weight.rawValue > data[index] { data[index] = weight.rawValue }
    }

    private func drawLine(_ start: Point, _ end: Point, _ weight: OniRoomGridWeight) {
        var x0 = start.x, y0 = start.y
        let x1 = end.x, y1 = end.y
        let dx = abs(x1 - x0), dy = abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var error = dx - dy
        while true {
            drawTile(x0, y0, weight)
            if x0 == x1, y0 == y1 { break }
            let doubled = error * 2
            if doubled > -dy { error -= dy; x0 += sx }
            if doubled < dx { error += dx; y0 += sy }
        }
    }

    private func addBorder(around: OniRoomGridWeight, onlyIf: OniRoomGridWeight, border: OniRoomGridWeight) {
        for z in 0..<zTiles {
            for x in 0..<xTiles where data[x + z * xTiles] == around.rawValue {
                for (neighborX, neighborZ) in [(x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)] {
                    guard neighborX >= 0, neighborX < xTiles, neighborZ >= 0, neighborZ < zTiles else { continue }
                    let index = neighborX + neighborZ * xTiles
                    if data[index] == onlyIf.rawValue { data[index] = border.rawValue }
                }
            }
        }
    }

    private func scanPolygon(_ points: [Point]) -> [Point] {
        guard points.count >= 3, let minimumY = points.map(\.y).min(), let maximumY = points.map(\.y).max() else { return [] }
        var edgeTable = Array(repeating: [Edge](), count: maximumY - minimumY + 1)
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            guard current.y != next.y else { continue }
            let edge = Edge(current, next)
            edgeTable[min(current.y, next.y) - minimumY].append(edge)
        }
        var active: [Edge] = []
        var result: [Point] = []
        for row in edgeTable.indices {
            active.append(contentsOf: edgeTable[row])
            let y = minimumY + row
            active.removeAll { $0.maxY <= y }
            active.sort {
                $0.currentX == $1.currentX
                    ? $0.reciprocalSlope < $1.reciprocalSlope
                    : $0.currentX < $1.currentX
            }
            var index = 0
            while index + 1 < active.count {
                if y >= 0, y < zTiles {
                    let start = max(0, Int(ceil(active[index].currentX)))
                    let end = min(xTiles - 1, Int(active[index + 1].currentX))
                    if start <= end {
                        for x in start...end { result.append(Point(x: x, y: y)) }
                    }
                }
                index += 2
            }
            for edge in active { edge.currentX += edge.reciprocalSlope }
        }
        return result
    }
}
