import Foundation

package enum OniBinaryDestination { case raw, sep }
package enum OniBinarySize { case inferred, constant(Int), field(String, Int) }

package indirect enum OniPackLayout {
    case skip(Int)
    case pointer
    case binary(OniBinaryDestination, OniBinarySize)
    case field(String, OniPackLayout)
    case fields([OniPackLayout])
    case array(Int, OniPackLayout)
    case variable(Int, OniPackLayout)
}

package struct OniTemplateSchema {
    package let checksum: UInt64
    package let layout: OniPackLayout
}

package enum OniPackSchema {
    private static let pcSpecial: [String: OniTemplateSchema] = [
        "BINA": .init(checksum: 0xdb41, layout: .fields([.field("DataSize",.skip(4)),.field("DataOffset",.binary(.raw,.inferred))])),
        "OSBD": .init(checksum: 0xdb6c, layout: .fields([.field("DataSize",.skip(4)),.field("DataOffset",.binary(.raw,.inferred))])),
        "TXMP": .init(checksum: 0x891187581, layout: .fields([.skip(128),.skip(4),.skip(2),.skip(2),.skip(4),.pointer,.pointer,.binary(.raw,.inferred),.skip(12)])),
        "SNDD": .init(checksum: 0x370578, layout: .fields([.skip(56),.skip(2),.skip(4),.binary(.raw,.inferred)]))
    ]
    private static let macSpecial: [String: OniTemplateSchema] = [
        "BINA": .init(checksum: 0x15e11, layout: .fields([.skip(4),.binary(.sep,.inferred)])),
        "OSBD": .init(checksum: 0x15e3c, layout: .fields([.skip(4),.binary(.sep,.inferred)])),
        "TXMP": .init(checksum: 0x8911eeb5f, layout: .fields([.skip(128),.skip(4),.skip(2),.skip(2),.skip(4),.pointer,.pointer,.skip(4),.binary(.sep,.inferred),.skip(8)])),
        "SNDD": .init(checksum: 0x411eb, layout: .fields([.skip(12),.binary(.raw,.inferred)]))
    ]

    package static func source(_ tag: String, checksum: UInt64) -> OniTemplateSchema? {
        if checksum == 0x0003_bcdf_23c1_3061, let value = macSpecial[tag] { return value }
        return pcSpecial[tag] ?? generated[tag]
    }

    package static func mac(_ tag: String) -> OniTemplateSchema? { macSpecial[tag] ?? generated[tag] }

    package static func containsPointer(_ layout: OniPackLayout) -> Bool {
        switch layout {
        case .pointer: true
        case .field(_,let value),.array(_,let value),.variable(_,let value): containsPointer(value)
        case .fields(let values): values.contains(where: containsPointer)
        default: false
        }
    }

    package static func walk(_ layout: OniPackLayout, data: inout Data, cursor: inout Int,
                             pointer: (Int, UInt32) throws -> UInt32,
                             binary: (Int, UInt32, OniBinaryDestination) throws -> UInt32) throws {
        switch layout {
        case .skip(let count): try advance(count,data,&cursor)
        case .pointer:
            let at=cursor,old=try u32(data,at);try advance(4,data,&cursor);if old != 0 { put32(&data,at,try pointer(at,old)) }
        case .binary(let destination,_):
            let at=cursor,old=try u32(data,at);try advance(4,data,&cursor);if old != 0 { put32(&data,at,try binary(at,old,destination)) }
        case .field(_,let value): try walk(value,data:&data,cursor:&cursor,pointer:pointer,binary:binary)
        case .fields(let values): for value in values { try walk(value,data:&data,cursor:&cursor,pointer:pointer,binary:binary) }
        case .array(let count,let value): for _ in 0..<count { try walk(value,data:&data,cursor:&cursor,pointer:pointer,binary:binary) }
        case .variable(let bytes,let value):
            let count:Int
            switch bytes { case 2: count=Int(try u16(data,cursor));case 4: count=Int(try u32(data,cursor));default: throw OniDatError.invalidHeader("unsupported metadata array count") }
            try advance(bytes,data,&cursor);guard count>=0,count<10_000_000 else{throw OniDatError.invalidHeader("invalid metadata array count")}
            for _ in 0..<count { try walk(value,data:&data,cursor:&cursor,pointer:pointer,binary:binary) }
        }
    }

    private static func advance(_ count:Int,_ data:Data,_ cursor:inout Int)throws{guard count>=0,cursor>=0,cursor<=data.count-count else{throw OniDatError.outOfBounds("metadata traversal")};cursor += count}
    private static func u16(_ d:Data,_ o:Int)throws->UInt16{guard o>=0,o+2<=d.count else{throw OniDatError.outOfBounds("metadata value")};return UInt16(d[o])|UInt16(d[o+1])<<8}
    private static func u32(_ d:Data,_ o:Int)throws->UInt32{guard o>=0,o+4<=d.count else{throw OniDatError.outOfBounds("metadata value")};return UInt32(d[o])|UInt32(d[o+1])<<8|UInt32(d[o+2])<<16|UInt32(d[o+3])<<24}
    private static func put32(_ d:inout Data,_ o:Int,_ v:UInt32){for i in 0..<4{d[o+i]=UInt8((v>>UInt32(i*8))&255)}}
}
