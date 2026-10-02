import Foundation

package enum OniNativeXMLError: LocalizedError {
    case invalidDocument(String)

    package var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail):
            return "The native Oni XML is not valid: \(detail)"
        }
    }
}

package struct OniNativeXMLArchive {
    package let fileName: String
    package let archiveData: Data

    package static func export(file: OniDatFile) -> Data {
        let root = XMLElement(name: "Oni")
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "utf-8"

        let archive = XMLElement(name: "NativeArchive")
        archive.addAttribute(XMLNode.attribute(withName: "schema", stringValue: "onisplit-native-1") as! XMLNode)
        archive.addAttribute(XMLNode.attribute(withName: "file", stringValue: file.url.lastPathComponent) as! XMLNode)
        archive.addAttribute(XMLNode.attribute(withName: "version", stringValue: file.header.versionBytes) as! XMLNode)
        archive.addAttribute(XMLNode.attribute(withName: "platform", stringValue: file.header.platformName) as! XMLNode)
        root.addChild(archive)

        let summary = XMLElement(name: "Summary")
        summary.addAttribute(XMLNode.attribute(withName: "instances", stringValue: String(file.instances.count)) as! XMLNode)
        summary.addAttribute(XMLNode.attribute(withName: "bytes", stringValue: String(file.data.count)) as! XMLNode)
        archive.addChild(summary)

        let instances = XMLElement(name: "Instances")
        for instance in file.instances {
            let element = XMLElement(name: "Instance")
            element.addAttribute(XMLNode.attribute(withName: "index", stringValue: String(instance.id)) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "type", stringValue: instance.templateTag) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "name", stringValue: instance.fullName) as! XMLNode)
            element.addAttribute(XMLNode.attribute(withName: "size", stringValue: String(instance.dataSize)) as! XMLNode)
            instances.addChild(element)
        }
        archive.addChild(instances)

        let payload = XMLElement(name: "ArchiveData", stringValue: file.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        payload.addAttribute(XMLNode.attribute(withName: "encoding", stringValue: "base64") as! XMLNode)
        archive.addChild(payload)
        if let objects = semanticObjects(from: file.data, fileName: file.url.lastPathComponent) {
            root.addChild(objects)
        }
        return document.xmlData(options: [.nodePrettyPrint])
    }

    package static func semanticExport(file: OniDatFile) throws -> Data {
        let document = try XMLDocument(data: export(file: file), options: [.nodePreserveAll])
        guard let root = document.rootElement(), !root.elements(forName: "Objects").isEmpty else {
            throw OniNativeXMLError.invalidDocument("semantic export is not supported for \(file.url.lastPathComponent) yet")
        }
        root.elements(forName: "NativeArchive").first?.detach()
        return document.xmlData(options: [.nodePrettyPrint])
    }

    package static func load(from data: Data, sourceFileName: String? = nil, resourceBaseURL: URL? = nil) throws -> OniNativeXMLArchive {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodePreserveAll])
        } catch {
            throw OniNativeXMLError.invalidDocument(error.localizedDescription)
        }
        guard let root = document.rootElement(), root.name == "Oni" else {
            throw OniNativeXMLError.invalidDocument("expected an <Oni> root element")
        }
        if let texture = root.elements(forName: "Texture").first {
            return try OniTextureXMLImporter.build(
                texture: texture,
                sourceFileName: sourceFileName,
                resourceBaseURL: resourceBaseURL
            )
        }
        if let weapon = root.elements(forName: "ONWC").first {
            return try OniWeaponXMLImporter.build(
                weapon: weapon,
                sourceFileName: sourceFileName,
                resourceBaseURL: resourceBaseURL
            )
        }
        if let character = root.elements(forName: "ONCC").first {
            return try OniCharacterXMLImporter.build(character: character, root: root, sourceFileName: sourceFileName)
        }
        guard let archive = root.elements(forName: "NativeArchive").first else {
            guard let objects = root.elements(forName: "Objects").first else {
                throw OniNativeXMLError.invalidDocument("expected NativeArchive or Objects")
            }
            return try buildObjectArchive(objects, sourceFileName: sourceFileName)
        }
        guard archive.attribute(forName: "schema")?.stringValue == "onisplit-native-1" else {
            throw OniNativeXMLError.invalidDocument("unsupported NativeArchive schema")
        }
        guard let encoded = archive.elements(forName: "ArchiveData").first?.stringValue,
              var archiveData = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              archiveData.count >= 64 else {
            throw OniNativeXMLError.invalidDocument("ArchiveData is missing or is not valid base64 ONI data")
        }
        var fileName = archive.attribute(forName: "file")?.stringValue ?? "reconstructed.oni"
        fileName = URL(fileURLWithPath: fileName).lastPathComponent
        if !fileName.lowercased().hasSuffix(".oni") { fileName += ".oni" }
        if let objects = root.elements(forName: "Objects").first {
            let records = objects.children?.compactMap { $0 as? XMLElement } ?? []
            let containsUnsupportedRecords = records.contains { $0.name == "Unsupported" }
            if !containsUnsupportedRecords {
                // Keep an untouched hybrid document byte-for-byte identical. Once its
                // semantic fields are edited, rebuild from those fields so every fully
                // supported object family is authoritative, including variable records.
                let originalObjects = semanticObjects(from: archiveData, fileName: fileName)
                if originalObjects == nil || !semanticElementsEqual(objects, originalObjects!) {
                    archiveData = try buildObjectArchive(objects, sourceFileName: fileName).archiveData
                }
            } else {
                // Partially supported tables still need the embedded bytes for records
                // that cannot yet be represented semantically.
                try applySemanticObjects(objects, to: &archiveData)
            }
        }
        return OniNativeXMLArchive(fileName: fileName, archiveData: archiveData)
    }
}

private extension OniNativeXMLArchive {
    static func semanticElementsEqual(_ lhs: XMLElement, _ rhs: XMLElement) -> Bool {
        guard lhs.name == rhs.name else { return false }
        let lhsAttributes = Dictionary(uniqueKeysWithValues: (lhs.attributes ?? []).map { ($0.name ?? "", $0.stringValue ?? "") })
        let rhsAttributes = Dictionary(uniqueKeysWithValues: (rhs.attributes ?? []).map { ($0.name ?? "", $0.stringValue ?? "") })
        guard lhsAttributes == rhsAttributes else { return false }
        let lhsChildren = lhs.children?.compactMap { $0 as? XMLElement } ?? []
        let rhsChildren = rhs.children?.compactMap { $0 as? XMLElement } ?? []
        guard lhsChildren.count == rhsChildren.count else { return false }
        if lhsChildren.isEmpty, lhs.stringValue != rhs.stringValue { return false }
        return zip(lhsChildren, rhsChildren).allSatisfy(semanticElementsEqual)
    }

    static func buildObjectArchive(_ objects: XMLElement, sourceFileName: String?) throws -> OniNativeXMLArchive {
        let records = objects.children?.compactMap { $0 as? XMLElement } ?? []
        let supported = ["CHAR", "CONS", "DOOR", "FLAG", "FURN", "NEUT", "PART", "PATR", "PWRU", "SNDG", "TRGV", "TRIG", "TURR", "WEAP"]
        let unsupported = records.filter { !supported.contains($0.name ?? "") }
        guard unsupported.isEmpty else {
            throw OniNativeXMLError.invalidDocument("archive-free XML contains unsupported object types")
        }

        var rawPayload = Data(repeating: 0, count: 32)
        rawPayload.append(contentsOf: "CJBO".utf8)
        let rawSizeOffset = rawPayload.count
        appendU32(&rawPayload, 0)
        appendU32(&rawPayload, 39)
        for record in records {
            switch record.name {
            case "CHAR": try appendCharacter(record, to: &rawPayload)
            case "CONS": try appendConsole(record, to: &rawPayload)
            case "DOOR": try appendDoor(record, to: &rawPayload)
            case "FLAG": try appendFlag(record, to: &rawPayload)
            case "FURN": try appendFurniture(record, to: &rawPayload)
            case "NEUT": try appendNeutral(record, to: &rawPayload)
            case "PART": try appendParticle(record, to: &rawPayload)
            case "PATR": try appendPatrol(record, to: &rawPayload)
            case "PWRU": try appendPowerUp(record, to: &rawPayload)
            case "SNDG": try appendSound(record, to: &rawPayload)
            case "TRGV": try appendTriggerVolume(record, to: &rawPayload)
            case "TRIG": try appendTrigger(record, to: &rawPayload)
            case "TURR": try appendTurret(record, to: &rawPayload)
            case "WEAP": try appendWeapon(record, to: &rawPayload)
            default: break
            }
        }
        appendU32(&rawPayload, 0)
        writeU32(&rawPayload, rawSizeOffset, UInt32(rawPayload.count - 32 - 8))
        let rawDataLength = rawPayload.count - 32

        var requestedName = objects.attribute(forName: "source")?.stringValue ?? sourceFileName ?? "BINACJBOCharacter.oni.xml"
        requestedName = URL(fileURLWithPath: requestedName).lastPathComponent
        if requestedName.lowercased().hasSuffix(".xml") { requestedName.removeLast(4) }
        if !requestedName.lowercased().hasSuffix(".oni") { requestedName += ".oni" }
        var instanceName = String(requestedName.dropLast(4))
        if !instanceName.hasPrefix("BINACJBO") { instanceName = "BINACJBO" + instanceName }
        let nameBytes = Data((instanceName + "\0").utf8)

        let nameOffset = 96
        let dataOffset = align32(nameOffset + nameBytes.count)
        let rawOffset = align32(dataOffset + 16)
        var output = Data()
        appendU64(&output, 0x0003_bcdf_33dc_271f)
        output.append(contentsOf: "23RV".utf8)
        appendU16(&output, 64); appendU16(&output, 20); appendU16(&output, 16); appendU16(&output, 8)
        appendU32(&output, 1); appendU32(&output, 0); appendU32(&output, 0)
        appendU32(&output, UInt32(dataOffset)); appendU32(&output, UInt32(rawOffset - dataOffset))
        appendU32(&output, UInt32(nameOffset)); appendU32(&output, UInt32(nameBytes.count))
        appendU32(&output, UInt32(rawOffset)); appendU32(&output, UInt32(rawPayload.count))
        appendU32(&output, 0); appendU32(&output, 0)
        output.append(contentsOf: "ANIB".utf8)
        appendU32(&output, 8); appendU32(&output, 0); appendU32(&output, 16); appendU32(&output, 0)
        pad(&output, to: nameOffset); output.append(nameBytes)
        pad(&output, to: dataOffset)
        appendU32(&output, 1); appendU32(&output, 0)
        appendU32(&output, UInt32(rawDataLength)); appendU32(&output, 32)
        pad(&output, to: rawOffset); output.append(rawPayload)
        return OniNativeXMLArchive(fileName: requestedName, archiveData: output)
    }

    static func appendCharacter(_ character: XMLElement, to output: inout Data) throws {
        guard let id = try objectID(character), let header = character.elements(forName: "Header").first,
              let osd = character.elements(forName: "OSD").first else {
            throw OniNativeXMLError.invalidDocument("CHAR has an invalid Id or is missing Header or OSD")
        }
        appendU32(&output, 544)
        output.append(contentsOf: "RAHC".utf8)
        appendU32(&output, id)
        try appendFlags32(&output, value(header, "Flags"), objectFlagValues); try appendVector(&output, value(header, "Position")); try appendVector(&output, value(header, "Rotation"))
        try appendFlags32(&output, value(osd, "Flags"), characterFlagValues); try appendString(&output, value(osd, "Class"), 64); try appendString(&output, value(osd, "Name"), 32); try appendString(&output, value(osd, "Weapon"), 64)
        guard let scripts = osd.elements(forName: "Scripts").first else { throw OniNativeXMLError.invalidDocument("CHAR \(id) is missing Scripts") }
        for name in ["Spawn", "Die", "Combat", "Alarm", "Hurt", "Defeated", "OutOfAmmo", "NoPath"] { try appendString(&output, value(scripts, name), 32) }
        try appendNumber32(&output, value(osd, "AdditionalHealth"))
        guard let job = osd.elements(forName: "Job").first, let behaviors = osd.elements(forName: "Behaviors").first,
              let inventory = osd.elements(forName: "Inventory").first else { throw OniNativeXMLError.invalidDocument("CHAR \(id) is missing Job, Behaviors, or Inventory") }
        try appendEnum32(&output, value(job, "Type"), jobValues); try appendNumber16(&output, value(job, "PatrolPathId"))
        for name in ["CombatId", "MeleeId", "NeutralId"] { try appendNumber16(&output, value(behaviors, name)) }
        for name in ["Ammo", "EnergyCell", "Hypo", "Shield", "Invisibility"] {
            guard let item = inventory.elements(forName: name).first else { throw OniNativeXMLError.invalidDocument("CHAR \(id) is missing Inventory/\(name)") }
            try appendNumber16(&output, value(item, "Use")); try appendNumber16(&output, value(item, "Drop"))
        }
        appendU32(&output, 0)
        try appendEnum32(&output, value(osd, "Team"), teamValues); try appendNumber32(&output, value(osd, "AmmoPercentage"))
        guard let alert = osd.elements(forName: "Alert").first, let pursuit = osd.elements(forName: "Pursuit").first else { throw OniNativeXMLError.invalidDocument("CHAR \(id) is missing Alert or Pursuit") }
        for name in ["Initial", "Minimal", "JobStart", "Investigate"] { try appendEnum32(&output, value(alert, name), alertValues) }
        try appendNumber32(&output, value(osd, "AlarmGroups"))
        for name in ["StrongUnseen", "WeakUnseen", "StrongSeen", "WeakSeen"] { try appendEnum32(&output, value(pursuit, name), pursuitValues) }
        try appendEnum32(&output, value(pursuit, "Lost"), pursuitLostValues)
    }

    static func appendObjectHeader(_ object: XMLElement, tagBytes: String, size: UInt32, to output: inout Data) throws -> XMLElement {
        guard let id = try objectID(object), let header = object.elements(forName: "Header").first,
              let osd = object.elements(forName: "OSD").first else {
            throw OniNativeXMLError.invalidDocument("\(object.name ?? "object") has an invalid Id or is missing Header or OSD")
        }
        appendU32(&output, size); output.append(contentsOf: tagBytes.utf8); appendU32(&output, id)
        try appendFlags32(&output, value(header, "Flags"), objectFlagValues); try appendVector(&output, value(header, "Position")); try appendVector(&output, value(header, "Rotation"))
        return osd
    }

    static func variableObjectPayload(_ object: XMLElement, tagBytes: String) throws -> (Data, XMLElement) {
        guard let id = try objectID(object), let header = object.elements(forName: "Header").first,
              let osd = object.elements(forName: "OSD").first else { throw OniNativeXMLError.invalidDocument("\(object.name ?? "object") has an invalid Id or is missing Header or OSD") }
        var payload = Data(tagBytes.utf8); appendU32(&payload, id)
        try appendFlags32(&payload, value(header, "Flags"), objectFlagValues); try appendVector(&payload, value(header, "Position")); try appendVector(&payload, value(header, "Rotation"))
        return (payload, osd)
    }

    private static func objectID(_ object: XMLElement) throws -> UInt32? {
        guard let text = object.attribute(forName: "Id")?.stringValue else { return 0 }
        guard let id = UInt32(text) else {
            throw OniNativeXMLError.invalidDocument("\(object.name ?? "object") has invalid Id '\(text)'")
        }
        return id
    }

    static func finishVariableObject(_ payload: inout Data, events: XMLElement?, to output: inout Data) throws {
        try appendEvents(events, to: &payload)
        while payload.count % 4 != 0 { payload.append(0) }
        appendU32(&output, UInt32(payload.count)); output.append(payload)
    }

    static func appendConsole(_ object: XMLElement, to output: inout Data) throws {
        var (payload, osd) = try variableObjectPayload(object, tagBytes: "SNOC")
        try appendString(&payload, value(osd, "Class"), 63); try appendNumber16(&payload, value(osd, "ConsoleId")); try appendFlags16(&payload, value(osd, "Flags"), consoleFlagValues); try appendString(&payload, value(osd, "InactiveTexture", alias: "DisabledTexture"), 63); try appendString(&payload, value(osd, "ActiveTexture", alias: "EnabledTexture"), 63); try appendString(&payload, value(osd, "TriggeredTexture", alias: "UsedTexture"), 63)
        try finishVariableObject(&payload, events: osd.elements(forName: "Events").first, to: &output)
    }

    static func appendDoor(_ object: XMLElement, to output: inout Data) throws {
        var (payload, osd) = try variableObjectPayload(object, tagBytes: "ROOD")
        try appendString(&payload, value(osd, "Class"), 63); try appendNumber16(&payload, value(osd, "DoorId")); try appendNumber16(&payload, value(osd, "KeyId", default: "0")); try appendFlags16(&payload, value(osd, "Flags"), doorFlagValues); try appendVector(&payload, value(osd, "Center")); try appendFloat(&payload, value(osd, "SquaredActivationRadius", default: "900")); try appendString(&payload, value(osd, "Texture1", default: ""), 63); try appendString(&payload, value(osd, "Texture2", default: ""), 63)
        try finishVariableObject(&payload, events: osd.elements(forName: "Events").first, to: &output)
    }

    static func appendTrigger(_ object: XMLElement, to output: inout Data) throws {
        var (payload, osd) = try variableObjectPayload(object, tagBytes: "GIRT")
        try appendString(&payload, value(osd, "Class"), 63); try appendNumber16(&payload, value(osd, "TriggerId")); try appendFlags16(&payload, value(osd, "Flags"), triggerFlagValues); try appendColor(&payload, value(osd, "LaserColor")); try appendFloat(&payload, value(osd, "StartPosition")); try appendFloat(&payload, value(osd, "Speed")); try appendNumber16(&payload, value(osd, "EmitterCount")); try appendNumber16(&payload, value(osd, "TimeOn")); try appendNumber16(&payload, value(osd, "TimeOff"))
        try finishVariableObject(&payload, events: osd.elements(forName: "Events").first, to: &output)
    }

    static func appendFlag(_ flag: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(flag, tagBytes: "GALF", size: 172, to: &output)
        try appendColor(&output, value(osd, "Color")); try appendNumber16(&output, value(osd, "Prefix")); try appendNumber16(&output, value(osd, "FlagId")); try appendString(&output, value(osd, "Notes", default: ""), 128)
    }

    static func appendFurniture(_ object: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(object, tagBytes: "NRUF", size: 116, to: &output)
        try appendString(&output, value(osd, "Class"), 32); try appendString(&output, value(osd, "Particle", default: ""), 48)
    }

    static func appendPowerUp(_ object: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(object, tagBytes: "URWP", size: 40, to: &output)
        try appendEnum32(&output, value(osd, "Class"), powerUpClassValues)
    }

    static func appendParticle(_ object: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(object, tagBytes: "TRAP", size: 160, to: &output)
        try appendString(&output, value(osd, "Class"), 64); try appendString(&output, value(osd, "Tag", default: ""), 48)
        try appendNumber16(&output, value(osd, "Flags", default: "0"))
        let scale = try vectorValues(value(osd, "DecalScale", default: "1 1"), count: 2); appendU32(&output, scale[0].bitPattern); appendU32(&output, scale[1].bitPattern); output.append(contentsOf: [0, 0])
    }

    static func appendNeutral(_ object: XMLElement, to output: inout Data) throws {
        var (payload, osd) = try variableObjectPayload(object, tagBytes: "TUEN")
        try appendString(&payload, value(osd, "Name"), 32); try appendNumber16(&payload, value(osd, "NeutralId"))
        let lines = osd.elements(forName: "DialogLines").first?.elements(forName: "DialogLine") ?? []
        appendU16(&payload, UInt16(lines.count)); try appendFlags32(&payload, value(osd, "Flags"), neutralFlagValues)
        guard let ranges = osd.elements(forName: "Ranges").first, let speech = osd.elements(forName: "Speech").first,
              let script = osd.elements(forName: "Script").first, let rewards = osd.elements(forName: "Rewards").first else { throw OniNativeXMLError.invalidDocument("NEUT is missing Ranges, Speech, Script, or Rewards") }
        for name in ["Trigger", "Talk", "Follow", "Enemy"] { try appendFloat(&payload, value(ranges, name)) }
        for name in ["Trigger", "Abort", "Enemy"] { try appendString(&payload, value(speech, name), 32) }
        try appendString(&payload, value(script, "AfterTalk"), 32); try appendString(&payload, value(rewards, "WeaponClass"), 32)
        for name in ["Ammo", "EnergyCell", "Hypo"] { try appendNumber8(&payload, value(rewards, name, default: "0")) }
        try appendEnum8(&payload, value(rewards, "Other", default: "0"), neutralItemValues)
        for line in lines {
            try appendFlags16(&payload, value(line, "Flags"), neutralDialogFlagValues); payload.append(contentsOf: [0, 0]); try appendNumber16(&payload, value(line, "Anim")); try appendNumber16(&payload, value(line, "OtherAnim")); try appendString(&payload, value(line, "SpeechName"), 32)
        }
        while payload.count % 4 != 0 { payload.append(0) }
        appendU32(&output, UInt32(payload.count)); output.append(payload)
    }

    static func appendPatrol(_ object: XMLElement, to output: inout Data) throws {
        var (payload, osd) = try variableObjectPayload(object, tagBytes: "RTAP")
        try appendString(&payload, value(osd, "Name"), 32)
        guard let points = osd.elements(forName: "Points").first else { throw OniNativeXMLError.invalidDocument("PATR is missing Points") }
        let info = osd.elements(forName: "Info").first ?? osd
        var entries: [XMLElement] = []
        for element in points.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let loopChildren = element.children?.compactMap { $0 as? XMLElement } ?? []
            if element.name == "Loop", !loopChildren.isEmpty {
                let loopStart = entries.count
                entries.append(contentsOf: loopChildren)
                let loop = XMLElement(name: loopStart == 0 ? "Loop" : "LoopFrom")
                if loopStart > 0 { loop.addAttribute(attribute("Point", String(loopStart))) }
                entries.append(loop)
            } else {
                entries.append(element)
            }
        }
        appendU32(&payload, UInt32(entries.count)); try appendNumber16(&payload, value(info, "PatrolId")); try appendNumber16(&payload, value(info, "ReturnToNearest"))
        let nameToType = Dictionary(uniqueKeysWithValues: patrolPointNames.map { ($0.value, $0.key) })
        for point in entries {
            guard let name = point.name, let type = nameToType[name] else { throw OniNativeXMLError.invalidDocument("unsupported patrol point '\(point.name ?? "")'") }
            appendU32(&payload, UInt32(type))
            switch type {
            case 0, 3, 5: try appendNumber16(&payload, point.attribute(forName: "FlagId")?.stringValue ?? "0")
            case 20, 21: try appendNumber16(&payload, point.attribute(forName: "ScriptId")?.stringValue ?? "0")
            case 2: try appendNumber32(&payload, point.attribute(forName: "Frames")?.stringValue ?? "0")
            case 7:
                let text = point.attribute(forName: "Mode")?.stringValue ?? "0"
                let modes = ["ByAlertLevel":0, "Stop":1, "Crouch":2, "Creep":3, "WalkNoAim":4, "Walk":5, "RunNoAim":6, "Run":7]
                try appendNumber32(&payload, modes[text].map(String.init) ?? text)
            case 9:
                let text = point.attribute(forName: "Facing")?.stringValue ?? "0"
                let facings = ["Forward":0, "Backward":1, "Left":1, "Right":2, "Stopped":3]
                try appendNumber32(&payload, facings[text].map(String.init) ?? text)
            case 10, 15:
                try appendNumber16(&payload, point.attribute(forName: "FlagId")?.stringValue ?? "0"); try appendFloat(&payload, point.attribute(forName: "Distance")?.stringValue ?? "0")
            case 14:
                try appendNumber16(&payload, point.attribute(forName: "FlagId")?.stringValue ?? "0"); try appendNumber32(&payload, point.attribute(forName: "Frames")?.stringValue ?? "0")
            case 17:
                try appendNumber16(&payload, point.attribute(forName: "Frames")?.stringValue ?? "0"); try appendFloat(&payload, point.attribute(forName: "Rotation")?.stringValue ?? "0")
            case 19:
                try appendNumber16(&payload, point.attribute(forName: "Frames")?.stringValue ?? "0"); try appendNumber16(&payload, point.attribute(forName: "FlagId")?.stringValue ?? "0"); try appendFloat(&payload, point.attribute(forName: "Rotation")?.stringValue ?? "0")
            case 23:
                try appendNumber16(&payload, point.attribute(forName: "FlagId")?.stringValue ?? "0"); try appendNumber16(&payload, point.attribute(forName: "Frames")?.stringValue ?? "0"); try appendFloat(&payload, point.attribute(forName: "Spread")?.stringValue ?? "0")
            case 4, 8:
                for key in ["X", "Y", "Z"] { try appendFloat(&payload, point.attribute(forName: key)?.stringValue ?? "0") }
            case 11:
                for key in ["X", "Y", "Z", "Distance"] { try appendFloat(&payload, point.attribute(forName: key)?.stringValue ?? "0") }
            case 16: try appendNumber32(&payload, point.attribute(forName: "Point")?.stringValue ?? "0")
            case 22:
                let text = point.attribute(forName: "Value")?.stringValue ?? "0"
                let booleans = ["Yes":"1", "No":"0", "True":"1", "False":"0"]
                try appendNumber8(&payload, booleans[text] ?? text)
            default: break
            }
        }
        while payload.count % 4 != 0 { payload.append(0) }
        appendU32(&output, UInt32(payload.count)); output.append(payload)
    }

    static func appendSound(_ sound: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(sound, tagBytes: "GDNS", size: 104, to: &output)
        try appendString(&output, value(osd, "Class"), 32)
        if let box = osd.elements(forName: "Box").first {
            output.append(contentsOf: "EMLV".utf8); try appendVector(&output, value(box, "Min")); try appendVector(&output, value(box, "Max")); try appendFloat(&output, value(osd, "Volume")); try appendFloat(&output, value(osd, "Pitch"))
        } else if let sphere = osd.elements(forName: "Sphere").first {
            output.append(contentsOf: "RHPS".utf8); try appendFloat(&output, value(sphere, "MinRadius")); try appendFloat(&output, value(sphere, "MaxRadius")); try appendFloat(&output, value(osd, "Volume")); try appendFloat(&output, value(osd, "Pitch")); output.append(Data(repeating: 0, count: 16))
        } else {
            throw OniNativeXMLError.invalidDocument("SNDG is missing Box or Sphere")
        }
    }

    static func appendTriggerVolume(_ object: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(object, tagBytes: "VGRT", size: 352, to: &output)
        try appendString(&output, value(osd, "Name"), 63)
        guard let scripts = osd.elements(forName: "Scripts").first else { throw OniNativeXMLError.invalidDocument("TRGV is missing Scripts") }
        for name in ["Entry", "Inside", "Exit"] { try appendString(&output, value(scripts, name), 32) }
        try appendNumber8(&output, value(osd, "Teams")); output.append(contentsOf: [0, 0, 0])
        try appendVector(&output, value(osd, "Size")); try appendNumber32(&output, value(osd, "TriggerVolumeId"))
        try appendNumber32(&output, osd.elements(forName: "ParentId").first?.stringValue ?? "0")
        try appendString(&output, osd.elements(forName: "Notes").first?.stringValue ?? "", 128)
        try appendFlags32(&output, value(osd, "Flags"), triggerVolumeFlagValues); output.append(0)
    }

    static func appendTurret(_ object: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(object, tagBytes: "RRUT", size: 144, to: &output)
        try appendString(&output, value(osd, "Class"), 63); try appendNumber16(&output, value(osd, "TurretId")); try appendFlags16(&output, value(osd, "Flags"), turretFlagValues); output.append(Data(repeating: 0, count: 36)); try appendFlags32(&output, value(osd, "TargetedTeams"), turretTeamValues); output.append(0)
    }

    static func appendWeapon(_ object: XMLElement, to output: inout Data) throws {
        let osd = try appendObjectHeader(object, tagBytes: "PAEW", size: 68, to: &output)
        try appendString(&output, value(osd, "Class"), 32)
    }

    static func semanticObjects(from data: Data, fileName: String) -> XMLElement? {
        guard let objectTable = objectTable(in: data) else { return nil }
        let objects = XMLElement(name: "Objects")
        objects.addAttribute(attribute("source", fileName))
        var cursor = objectTable + 12
        while cursor + 4 <= data.count {
            let size = Int(readU32(data, cursor))
            if size == 0 { break }
            let base = cursor + 4
            guard size >= 8, base + size <= data.count else { return nil }
            let tag = readTag(data, base)
            let id = readU32(data, base + 4)
            if tag == "CHAR", size >= 544 {
                objects.addChild(characterElement(data, base: base, id: id))
            } else if tag == "FLAG", size >= 172 {
                objects.addChild(flagElement(data, base: base, id: id))
            } else if tag == "SNDG", size >= 104 {
                objects.addChild(soundElement(data, base: base, id: id))
            } else if tag == "FURN", size >= 116 {
                objects.addChild(furnitureElement(data, base: base, id: id))
            } else if tag == "PWRU", size >= 40 {
                objects.addChild(powerUpElement(data, base: base, id: id))
            } else if tag == "TRGV", size >= 352 {
                objects.addChild(triggerVolumeElement(data, base: base, id: id))
            } else if tag == "TURR", size >= 144 {
                objects.addChild(turretElement(data, base: base, id: id))
            } else if tag == "WEAP", size >= 68 {
                objects.addChild(weaponElement(data, base: base, id: id))
            } else if tag == "PART", size >= 160 {
                objects.addChild(particleElement(data, base: base, id: id))
            } else if tag == "NEUT", size >= 296 {
                objects.addChild(neutralElement(data, base: base, id: id, size: size))
            } else if tag == "PATR", size >= 76 {
                objects.addChild(patrolElement(data, base: base, id: id, size: size))
            } else if tag == "CONS", size >= 296 {
                objects.addChild(consoleElement(data, base: base, id: id))
            } else if tag == "DOOR", size >= 252 {
                objects.addChild(doorElement(data, base: base, id: id))
            } else if tag == "TRIG", size >= 124 {
                objects.addChild(triggerElement(data, base: base, id: id))
            } else {
                let element = XMLElement(name: "Unsupported")
                element.addAttribute(attribute("Type", tag))
                element.addAttribute(attribute("Id", String(id)))
                element.addAttribute(attribute("Size", String(size)))
                objects.addChild(element)
            }
            cursor = base + size
        }
        return objects
    }

    static func characterElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let character = XMLElement(name: "CHAR")
        character.addAttribute(attribute("Id", String(id)))
        let header = XMLElement(name: "Header")
        add(header, "Flags", flagsName(readU32(data, base + 8), objectFlagNames))
        add(header, "Position", vector(data, base + 12))
        add(header, "Rotation", vector(data, base + 24))
        character.addChild(header)

        let osd = XMLElement(name: "OSD")
        add(osd, "Flags", flagsName(readU32(data, base + 36), characterFlagNames))
        add(osd, "Class", readString(data, base + 40, 64))
        add(osd, "Name", readString(data, base + 104, 32))
        add(osd, "Weapon", readString(data, base + 136, 64))
        let scripts = XMLElement(name: "Scripts")
        let scriptNames = ["Spawn", "Die", "Combat", "Alarm", "Hurt", "Defeated", "OutOfAmmo", "NoPath"]
        for (index, name) in scriptNames.enumerated() { add(scripts, name, readString(data, base + 200 + index * 32, 32)) }
        osd.addChild(scripts)
        add(osd, "AdditionalHealth", String(readI32(data, base + 456)))
        let job = XMLElement(name: "Job")
        add(job, "Type", enumName(readU32(data, base + 460), jobNames))
        add(job, "PatrolPathId", String(readI16(data, base + 464)))
        osd.addChild(job)
        let behaviors = XMLElement(name: "Behaviors")
        add(behaviors, "CombatId", String(readI16(data, base + 466)))
        add(behaviors, "MeleeId", String(readI16(data, base + 468)))
        add(behaviors, "NeutralId", String(readI16(data, base + 470)))
        osd.addChild(behaviors)
        let inventory = XMLElement(name: "Inventory")
        for (index, name) in ["Ammo", "EnergyCell", "Hypo", "Shield", "Invisibility"].enumerated() {
            let item = XMLElement(name: name)
            add(item, "Use", String(readI16(data, base + 472 + index * 4)))
            add(item, "Drop", String(readI16(data, base + 474 + index * 4)))
            inventory.addChild(item)
        }
        osd.addChild(inventory)
        add(osd, "Team", enumName(readU32(data, base + 496), teamNames))
        add(osd, "AmmoPercentage", String(readI32(data, base + 500)))
        let alert = XMLElement(name: "Alert")
        for (index, name) in ["Initial", "Minimal", "JobStart", "Investigate"].enumerated() {
            add(alert, name, enumName(readU32(data, base + 504 + index * 4), alertNames))
        }
        osd.addChild(alert)
        add(osd, "AlarmGroups", String(readI32(data, base + 520)))
        let pursuit = XMLElement(name: "Pursuit")
        for (index, name) in ["StrongUnseen", "WeakUnseen", "StrongSeen", "WeakSeen"].enumerated() {
            add(pursuit, name, enumName(readU32(data, base + 524 + index * 4), pursuitNames))
        }
        add(pursuit, "Lost", enumName(readU32(data, base + 540), pursuitLostNames))
        osd.addChild(pursuit)
        character.addChild(osd)
        return character
    }

    static func commonObjectElement(_ name: String, data: Data, base: Int, id: UInt32) -> (XMLElement, XMLElement) {
        let object = XMLElement(name: name); object.addAttribute(attribute("Id", String(id)))
        let header = XMLElement(name: "Header")
        add(header, "Flags", hex(readU32(data, base + 8))); add(header, "Position", vector(data, base + 12)); add(header, "Rotation", vector(data, base + 24))
        object.addChild(header)
        let osd = XMLElement(name: "OSD"); object.addChild(osd)
        return (object, osd)
    }

    static func flagElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (flag, osd) = commonObjectElement("FLAG", data: data, base: base, id: id)
        add(osd, "Color", color(data, base + 36)); add(osd, "Prefix", String(readI16(data, base + 40))); add(osd, "FlagId", String(readI16(data, base + 42))); add(osd, "Notes", readString(data, base + 44, 128))
        return flag
    }

    static func soundElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (sound, osd) = commonObjectElement("SNDG", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 32))
        let volumeTag = readTag(data, base + 68)
        if volumeTag == "VLME" {
            let box = XMLElement(name: "Box"); add(box, "Min", vector(data, base + 72)); add(box, "Max", vector(data, base + 84)); osd.addChild(box)
            add(osd, "Volume", floatText(readFloat(data, base + 96))); add(osd, "Pitch", floatText(readFloat(data, base + 100)))
        } else {
            let sphere = XMLElement(name: "Sphere"); add(sphere, "MinRadius", floatText(readFloat(data, base + 72))); add(sphere, "MaxRadius", floatText(readFloat(data, base + 76))); osd.addChild(sphere)
            add(osd, "Volume", floatText(readFloat(data, base + 80))); add(osd, "Pitch", floatText(readFloat(data, base + 84)))
        }
        return sound
    }

    static func furnitureElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("FURN", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 32)); add(osd, "Particle", readString(data, base + 68, 48))
        return object
    }

    static func powerUpElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("PWRU", data: data, base: base, id: id)
        add(osd, "Class", enumValue(readU32(data, base + 36), [0x424D4D41:"Ammo",0x454D4D41:"EnergyCell",0x4F505948:"Hypo",0x444C4853:"Shield",0x49564E49:"Invisibility",0x49534C41:"LSI"]))
        return object
    }

    static func triggerVolumeElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("TRGV", data: data, base: base, id: id)
        add(osd, "Name", readString(data, base + 36, 63))
        let scripts = XMLElement(name: "Scripts")
        for (index, name) in ["Entry", "Inside", "Exit"].enumerated() { add(scripts, name, readString(data, base + 99 + index * 32, 32)) }
        osd.addChild(scripts)
        add(osd, "Teams", String(data[base + 195])); add(osd, "Size", vector(data, base + 199)); add(osd, "TriggerVolumeId", String(readI32(data, base + 211))); add(osd, "ParentId", String(readI32(data, base + 215))); add(osd, "Notes", readString(data, base + 219, 128)); add(osd, "Flags", hex(readU32(data, base + 347)))
        return object
    }

    static func turretElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("TURR", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 63)); add(osd, "TurretId", String(readI16(data, base + 99))); add(osd, "Flags", String(readU16(data, base + 101))); add(osd, "TargetedTeams", hex(readU32(data, base + 139)))
        return object
    }

    static func weaponElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("WEAP", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 32))
        return object
    }

    static func particleElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("PART", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 64)); add(osd, "Tag", readString(data, base + 100, 48)); add(osd, "Flags", String(readU16(data, base + 148))); add(osd, "DecalScale", [readFloat(data, base + 150), readFloat(data, base + 154)].map(floatText).joined(separator: " "))
        return object
    }

    static func neutralElement(_ data: Data, base: Int, id: UInt32, size: Int) -> XMLElement {
        let (object, osd) = commonObjectElement("NEUT", data: data, base: base, id: id)
        add(osd, "Name", readString(data, base + 36, 32)); add(osd, "NeutralId", String(readI16(data, base + 68))); add(osd, "Flags", hex(readU32(data, base + 72)))
        let ranges = XMLElement(name: "Ranges"); for (index, name) in ["Trigger", "Talk", "Follow", "Enemy"].enumerated() { add(ranges, name, floatText(readFloat(data, base + 76 + index * 4))) }; osd.addChild(ranges)
        let speech = XMLElement(name: "Speech"); for (index, name) in ["Trigger", "Abort", "Enemy"].enumerated() { add(speech, name, readString(data, base + 92 + index * 32, 32)) }; osd.addChild(speech)
        let script = XMLElement(name: "Script"); add(script, "AfterTalk", readString(data, base + 188, 32)); osd.addChild(script)
        let rewards = XMLElement(name: "Rewards"); add(rewards, "WeaponClass", readString(data, base + 220, 32)); add(rewards, "Ammo", String(data[base + 252])); add(rewards, "EnergyCell", String(data[base + 253])); add(rewards, "Hypo", String(data[base + 254])); add(rewards, "Other", enumName(UInt32(data[base + 255]), neutralItemNames)); osd.addChild(rewards)
        let dialog = XMLElement(name: "DialogLines"); let count = Int(readU16(data, base + 70))
        for index in 0..<count where base + 256 + (index + 1) * 40 <= base + size {
            let offset = base + 256 + index * 40, line = XMLElement(name: "DialogLine")
            add(line, "Flags", String(readU16(data, offset))); add(line, "Anim", String(readI16(data, offset + 4))); add(line, "OtherAnim", String(readI16(data, offset + 6))); add(line, "SpeechName", readString(data, offset + 8, 32)); dialog.addChild(line)
        }
        osd.addChild(dialog); return object
    }

    static let patrolPointNames = [0:"MoveToFlag",1:"Stop",2:"Pause",3:"LookAtFlag",4:"LookAtPoint",5:"MoveAndFaceFlag",6:"Loop",7:"MovementMode",8:"MoveToPoint",9:"LockFacing",10:"MoveThroughFlag",11:"MoveThroughPoint",12:"StopLooking",13:"FreeFacing",14:"GlanceAtFlagFor",15:"MoveNearFlag",16:"LoopFrom",17:"Scan",18:"StopScanning",19:"MoveToFlagLookAndWait",20:"CallScript",21:"ForkScript",22:"IgnorePlayer",23:"FaceToFlagAndFire"]

    static func patrolElement(_ data: Data, base: Int, id: UInt32, size: Int) -> XMLElement {
        let (object, osd) = commonObjectElement("PATR", data: data, base: base, id: id)
        add(osd, "Name", readString(data, base + 36, 32))
        let info = XMLElement(name: "Info"); add(info, "PatrolId", String(readI16(data, base + 72))); add(info, "ReturnToNearest", String(readI16(data, base + 74))); osd.addChild(info)
        let points = XMLElement(name: "Points"), count = Int(readU32(data, base + 68)); var cursor = base + 76
        for _ in 0..<count where cursor + 4 <= base + size {
            let type = Int(readU32(data, cursor)); cursor += 4
            let point = XMLElement(name: patrolPointNames[type] ?? "Unknown")
            func attr(_ name: String, _ text: String) { point.addAttribute(attribute(name, text)) }
            switch type {
            case 0, 3, 5: attr("FlagId", String(readI16(data, cursor))); cursor += 2
            case 20, 21: attr("ScriptId", String(readI16(data, cursor))); cursor += 2
            case 2: attr("Frames", String(readI32(data, cursor))); cursor += 4
            case 7: attr("Mode", String(readI32(data, cursor))); cursor += 4
            case 9: attr("Facing", String(readI32(data, cursor))); cursor += 4
            case 10, 15: attr("FlagId", String(readI16(data, cursor))); attr("Distance", floatText(readFloat(data, cursor + 2))); cursor += 6
            case 14: attr("FlagId", String(readI16(data, cursor))); attr("Frames", String(readI32(data, cursor + 2))); cursor += 6
            case 17: attr("Frames", String(readI16(data, cursor))); attr("Rotation", floatText(readFloat(data, cursor + 2))); cursor += 6
            case 19: attr("Frames", String(readI16(data, cursor))); attr("FlagId", String(readI16(data, cursor + 2))); attr("Rotation", floatText(readFloat(data, cursor + 4))); cursor += 8
            case 23: attr("FlagId", String(readI16(data, cursor))); attr("Frames", String(readI16(data, cursor + 2))); attr("Spread", floatText(readFloat(data, cursor + 4))); cursor += 8
            case 4, 8: for (index, key) in ["X", "Y", "Z"].enumerated() { attr(key, floatText(readFloat(data, cursor + index * 4))) }; cursor += 12
            case 11: for (index, key) in ["X", "Y", "Z", "Distance"].enumerated() { attr(key, floatText(readFloat(data, cursor + index * 4))) }; cursor += 16
            case 16: attr("Point", String(readI32(data, cursor))); cursor += 4
            case 22: attr("Value", String(data[cursor])); cursor += 1
            default: break
            }
            points.addChild(point)
        }
        osd.addChild(points); return object
    }

    static let eventNames = [0:"None",1:"Script",2:"ActivateTurret",3:"DeactivateTurret",4:"ActivateConsole",5:"DeactivateConsole",6:"ActivateAlarm",7:"DeactivateAlarm",8:"ActivateTrigger",9:"DeactivateTrigger",10:"LockDoor",11:"UnlockDoor"]

    static func addEvents(_ osd: XMLElement, data: Data, countOffset: Int, end: Int) {
        let events = XMLElement(name: "Events")
        var cursor = countOffset + 2
        for _ in 0..<Int(readU16(data, countOffset)) where cursor + 2 <= end {
            let type = Int(readU16(data, cursor)); cursor += 2
            let event = XMLElement(name: eventNames[type] ?? "Unknown")
            if type == 1, cursor + 32 <= end { event.addAttribute(attribute("Function", readString(data, cursor, 32))); cursor += 32 }
            else if type != 0, cursor + 2 <= end { event.addAttribute(attribute("TargetId", String(readI16(data, cursor)))); cursor += 2 }
            events.addChild(event)
        }
        osd.addChild(events)
    }

    static func consoleElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("CONS", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 63)); add(osd, "ConsoleId", String(readI16(data, base + 99))); add(osd, "Flags", String(readU16(data, base + 101))); add(osd, "InactiveTexture", readString(data, base + 103, 63)); add(osd, "ActiveTexture", readString(data, base + 166, 63)); add(osd, "TriggeredTexture", readString(data, base + 229, 63)); addEvents(osd, data: data, countOffset: base + 292, end: data.count)
        return object
    }

    static func doorElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("DOOR", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 63)); add(osd, "DoorId", String(readI16(data, base + 99))); add(osd, "KeyId", String(readI16(data, base + 101))); add(osd, "Flags", String(readU16(data, base + 103))); add(osd, "Center", vector(data, base + 105)); add(osd, "SquaredActivationRadius", floatText(readFloat(data, base + 117))); add(osd, "Texture1", readString(data, base + 121, 63)); add(osd, "Texture2", readString(data, base + 184, 63)); addEvents(osd, data: data, countOffset: base + 247, end: data.count)
        return object
    }

    static func triggerElement(_ data: Data, base: Int, id: UInt32) -> XMLElement {
        let (object, osd) = commonObjectElement("TRIG", data: data, base: base, id: id)
        add(osd, "Class", readString(data, base + 36, 63)); add(osd, "TriggerId", String(readI16(data, base + 99))); add(osd, "Flags", String(readU16(data, base + 101))); add(osd, "LaserColor", color(data, base + 103)); add(osd, "StartPosition", floatText(readFloat(data, base + 107))); add(osd, "Speed", floatText(readFloat(data, base + 111))); add(osd, "EmitterCount", String(readI16(data, base + 115))); add(osd, "TimeOn", String(readI16(data, base + 117))); add(osd, "TimeOff", String(readI16(data, base + 119))); addEvents(osd, data: data, countOffset: base + 121, end: data.count)
        return object
    }

    static func applySemanticObjects(_ objects: XMLElement, to data: inout Data) throws {
        guard let table = objectTable(in: data) else {
            throw OniNativeXMLError.invalidDocument("the embedded archive does not contain a BINA OBJC object table")
        }
        var records: [String: Int] = [:]
        var cursor = table + 12
        while cursor + 4 <= data.count {
            let size = Int(readU32(data, cursor))
            if size == 0 { break }
            let base = cursor + 4
            guard size >= 8, base + size <= data.count else { break }
            records["\(readTag(data, base)):\(readU32(data, base + 4))"] = base
            cursor = base + size
        }
        for character in objects.elements(forName: "CHAR") {
            guard let idText = character.attribute(forName: "Id")?.stringValue,
                  let id = UInt32(idText), let base = records["CHAR:\(id)"] else {
                throw OniNativeXMLError.invalidDocument("a CHAR object has an unknown or missing Id")
            }
            guard let header = character.elements(forName: "Header").first,
                  let osd = character.elements(forName: "OSD").first else {
                throw OniNativeXMLError.invalidDocument("CHAR \(id) is missing Header or OSD")
            }
            try patchFlags32(&data, base + 8, value(header, "Flags"), objectFlagValues)
            try patchVector(&data, base + 12, value(header, "Position"))
            try patchVector(&data, base + 24, value(header, "Rotation"))
            try patchFlags32(&data, base + 36, value(osd, "Flags"), characterFlagValues)
            try patchString(&data, base + 40, 64, value(osd, "Class"))
            try patchString(&data, base + 104, 32, value(osd, "Name"))
            try patchString(&data, base + 136, 64, value(osd, "Weapon"))
            if let scripts = osd.elements(forName: "Scripts").first {
                for (index, name) in ["Spawn", "Die", "Combat", "Alarm", "Hurt", "Defeated", "OutOfAmmo", "NoPath"].enumerated() {
                    try patchString(&data, base + 200 + index * 32, 32, value(scripts, name))
                }
            }
            try patchI32(&data, base + 456, value(osd, "AdditionalHealth"))
            if let job = osd.elements(forName: "Job").first {
                try patchEnum32(&data, base + 460, value(job, "Type"), jobValues); try patchI16(&data, base + 464, value(job, "PatrolPathId"))
            }
            if let behaviors = osd.elements(forName: "Behaviors").first {
                try patchI16(&data, base + 466, value(behaviors, "CombatId")); try patchI16(&data, base + 468, value(behaviors, "MeleeId")); try patchI16(&data, base + 470, value(behaviors, "NeutralId"))
            }
            if let inventory = osd.elements(forName: "Inventory").first {
                for (index, name) in ["Ammo", "EnergyCell", "Hypo", "Shield", "Invisibility"].enumerated() where inventory.elements(forName: name).first != nil {
                    let item = inventory.elements(forName: name)[0]
                    try patchI16(&data, base + 472 + index * 4, value(item, "Use")); try patchI16(&data, base + 474 + index * 4, value(item, "Drop"))
                }
            }
            try patchEnum32(&data, base + 496, value(osd, "Team"), teamValues); try patchI32(&data, base + 500, value(osd, "AmmoPercentage"))
            if let alert = osd.elements(forName: "Alert").first {
                for (index, name) in ["Initial", "Minimal", "JobStart", "Investigate"].enumerated() { try patchEnum32(&data, base + 504 + index * 4, value(alert, name), alertValues) }
            }
            try patchI32(&data, base + 520, value(osd, "AlarmGroups"))
            if let pursuit = osd.elements(forName: "Pursuit").first {
                for (index, name) in ["StrongUnseen", "WeakUnseen", "StrongSeen", "WeakSeen"].enumerated() { try patchEnum32(&data, base + 524 + index * 4, value(pursuit, name), pursuitValues) }
                try patchEnum32(&data, base + 540, value(pursuit, "Lost"), pursuitLostValues)
            }
        }
        for flag in objects.elements(forName: "FLAG") {
            guard let idText = flag.attribute(forName: "Id")?.stringValue, let id = UInt32(idText), let base = records["FLAG:\(id)"],
                  let osd = try patchObjectHeader(flag, data: &data, base: base) else { throw OniNativeXMLError.invalidDocument("FLAG has an unknown or missing Id") }
            try patchColor(&data, base + 36, value(osd, "Color")); try patchI16(&data, base + 40, value(osd, "Prefix")); try patchI16(&data, base + 42, value(osd, "FlagId")); try patchString(&data, base + 44, 128, value(osd, "Notes"))
        }
        for sound in objects.elements(forName: "SNDG") {
            guard let idText = sound.attribute(forName: "Id")?.stringValue, let id = UInt32(idText), let base = records["SNDG:\(id)"],
                  let osd = try patchObjectHeader(sound, data: &data, base: base) else { throw OniNativeXMLError.invalidDocument("SNDG has an unknown or missing Id") }
            try patchString(&data, base + 36, 32, value(osd, "Class"))
            if let box = osd.elements(forName: "Box").first {
                data.replaceSubrange((base + 68)..<(base + 72), with: "EMLV".utf8); try patchVector(&data, base + 72, value(box, "Min")); try patchVector(&data, base + 84, value(box, "Max")); try patchFloat(&data, base + 96, value(osd, "Volume")); try patchFloat(&data, base + 100, value(osd, "Pitch"))
            } else if let sphere = osd.elements(forName: "Sphere").first {
                data.replaceSubrange((base + 68)..<(base + 72), with: "RHPS".utf8); try patchFloat(&data, base + 72, value(sphere, "MinRadius")); try patchFloat(&data, base + 76, value(sphere, "MaxRadius")); try patchFloat(&data, base + 80, value(osd, "Volume")); try patchFloat(&data, base + 84, value(osd, "Pitch")); for index in (base + 88)..<(base + 104) { data[index] = 0 }
            }
        }
        for object in objects.children?.compactMap({ $0 as? XMLElement }) ?? [] where ["FURN", "PWRU", "TRGV", "TURR", "WEAP"].contains(object.name ?? "") {
            let tag = object.name ?? ""
            guard let idText = object.attribute(forName: "Id")?.stringValue, let id = UInt32(idText), let base = records["\(tag):\(id)"],
                  let osd = try patchObjectHeader(object, data: &data, base: base) else { throw OniNativeXMLError.invalidDocument("\(tag) has an unknown or missing Id") }
            switch tag {
            case "FURN":
                try patchString(&data, base + 36, 32, value(osd, "Class")); try patchString(&data, base + 68, 48, value(osd, "Particle"))
            case "PWRU": try patchU32(&data, base + 36, value(osd, "Class"))
            case "TRGV":
                try patchString(&data, base + 36, 63, value(osd, "Name"))
                guard let scripts = osd.elements(forName: "Scripts").first else { throw OniNativeXMLError.invalidDocument("TRGV is missing Scripts") }
                for (index, name) in ["Entry", "Inside", "Exit"].enumerated() { try patchString(&data, base + 99 + index * 32, 32, value(scripts, name)) }
                try patchU8(&data, base + 195, value(osd, "Teams")); try patchVector(&data, base + 199, value(osd, "Size")); try patchI32(&data, base + 211, value(osd, "TriggerVolumeId")); try patchI32(&data, base + 215, value(osd, "ParentId")); try patchString(&data, base + 219, 128, value(osd, "Notes")); try patchU32(&data, base + 347, value(osd, "Flags"))
            case "TURR":
                try patchString(&data, base + 36, 63, value(osd, "Class")); try patchI16(&data, base + 99, value(osd, "TurretId")); try patchI16(&data, base + 101, value(osd, "Flags")); try patchU32(&data, base + 139, value(osd, "TargetedTeams"))
            case "WEAP": try patchString(&data, base + 36, 32, value(osd, "Class"))
            default: break
            }
        }
    }

    static func patchObjectHeader(_ object: XMLElement, data: inout Data, base: Int) throws -> XMLElement? {
        guard let header = object.elements(forName: "Header").first, let osd = object.elements(forName: "OSD").first else { return nil }
        try patchFlags32(&data, base + 8, value(header, "Flags"), objectFlagValues); try patchVector(&data, base + 12, value(header, "Position")); try patchVector(&data, base + 24, value(header, "Rotation"))
        return osd
    }

    static func objectTable(in data: Data) -> Int? {
        guard data.count >= 64 else { return nil }
        let count = Int(readU32(data, 20)), descriptorSize = Int(readU16(data, 14)), table = Int(readU16(data, 12))
        let dataOffset = Int(readU32(data, 32)), rawTable = Int(readU32(data, 48))
        for index in 0..<count {
            let descriptor = table + index * descriptorSize
            guard descriptor + 20 <= data.count else { return nil }
            if readTag(data, descriptor) == "BINA" {
                let body = dataOffset + Int(readU32(data, descriptor + 4))
                guard body + 8 <= data.count else { return nil }
                let raw = rawTable + Int(readU32(data, body + 4))
                guard raw + 12 <= data.count, readTag(data, raw) == "OBJC" else { return nil }
                return raw
            }
        }
        return nil
    }

    static func attribute(_ name: String, _ value: String) -> XMLNode { XMLNode.attribute(withName: name, stringValue: value) as! XMLNode }
    static func add(_ parent: XMLElement, _ name: String, _ text: String) { parent.addChild(XMLElement(name: name, stringValue: text)) }
    static func value(_ parent: XMLElement, _ name: String) throws -> String {
        guard let value = parent.elements(forName: name).first?.stringValue else { throw OniNativeXMLError.invalidDocument("missing \(name)") }
        return value
    }
    static func value(_ parent: XMLElement, _ name: String, alias: String) throws -> String {
        if let value = parent.elements(forName: name).first?.stringValue { return value }
        if let value = parent.elements(forName: alias).first?.stringValue { return value }
        throw OniNativeXMLError.invalidDocument("missing \(name)")
    }
    static func value(_ parent: XMLElement, _ name: String, default defaultValue: String) -> String {
        parent.elements(forName: name).first?.stringValue ?? defaultValue
    }
    static func hex(_ value: UInt32) -> String { String(format: "0x%08X", value) }
    static func enumValue(_ value: UInt32, _ names: [UInt32:String]) -> String { names[value].map { "\(value) (\($0))" } ?? String(value) }
    static let objectFlagNames:[(UInt32,String)]=[(1,"Locked"),(2,"PlacedInGame"),(4,"Temporary"),(8,"Gunk")]
    static let characterFlagNames:[(UInt32,String)]=[(1,"IsPlayer"),(2,"RandomCostume"),(4,"NotInitiallyPresent"),(8,"NonCombatant"),(16,"CanSpawnMultiple"),(32,"Spawned"),(64,"Unkillable"),(128,"InfiniteAmmo"),(256,"Omniscient"),(512,"HasLSI"),(1024,"Boss"),(2048,"UpgradeDifficulty"),(4096,"NoAutoDrop")]
    static let jobNames:[UInt32:String]=[0:"None",1:"Idle",2:"Guard",3:"Patrol",4:"TeamBatle",5:"Combat",6:"Melee",7:"Alarm",8:"Neutral",9:"Panic"]
    static let teamNames:[UInt32:String]=[0:"Konoko",1:"TCTF",2:"Syndicate",3:"Neutral",4:"SecurityGuard",5:"RogueKonoko",6:"Switzerland",7:"SyndicateAccessory"]
    static let alertNames:[UInt32:String]=[0:"Lull",1:"Low",2:"Medium",3:"High",4:"Combat"]
    static let pursuitNames:[UInt32:String]=[0:"None",1:"Forget",2:"GoTo",3:"Wait",4:"Look",5:"Move",6:"Hunt",7:"Glanc"]
    static let pursuitLostNames:[UInt32:String]=[0:"ReturnToJob",1:"KeepLooking",2:"FindAlarm"]
    static let objectFlagValues=Dictionary(uniqueKeysWithValues:objectFlagNames.map{($0.1,$0.0)})
    static let characterFlagValues=Dictionary(uniqueKeysWithValues:characterFlagNames.map{($0.1,$0.0)})
    static let jobValues=Dictionary(uniqueKeysWithValues:jobNames.map{($0.value,$0.key)}).merging(["TeamBattle":4]){$1}
    static let teamValues=Dictionary(uniqueKeysWithValues:teamNames.map{($0.value,$0.key)})
    static let alertValues=Dictionary(uniqueKeysWithValues:alertNames.map{($0.value,$0.key)})
    static let pursuitValues=Dictionary(uniqueKeysWithValues:pursuitNames.map{($0.value,$0.key)}).merging(["Glance":7]){$1}
    static let pursuitLostValues=Dictionary(uniqueKeysWithValues:pursuitLostNames.map{($0.value,$0.key)})
    static let consoleFlagValues: [String:UInt32] = ["InitialActive":8,"Punch":32,"IsAlarm":64]
    static let doorFlagValues: [String:UInt32] = ["InitialLocked":1,"InDoorFrame":4,"Manual":16,"DoubleDoor":128,"Mirror":256,"OneWay":512,"Reverse":1024,"Jammed":2048,"InitialOpen":4096]
    static let neutralFlagValues: [String:UInt32] = ["NoResume":1,"NoResumeAfterGive":2,"Uninterruptible":4]
    static let neutralItemNames: [UInt32:String] = [0:"None", 1:"Shield", 2:"Invisibility", 4:"LSI"]
    static let neutralItemValues: [String:UInt32] = ["None":0, "Shield":1, "Invisibility":2, "LSI":4]
    static let neutralDialogFlagValues: [String:UInt32] = ["IsPlayer":1,"GiveItems":2,"AnimOnce":4,"OtherAnimOnce":8]
    static let triggerVolumeFlagValues: [String:UInt32] = ["OneTimeEnter":1,"OneTimeInside":2,"OneTimeExit":4,"EnterDisabled":8,"InsideDisabled":16,"ExitDisabled":32,"Disabled":64,"PlayerOnly":128]
    static let triggerFlagValues: [String:UInt32] = ["InitialActive":8,"ReverseAnim":16,"PingPong":32]
    static let turretFlagValues: [String:UInt32] = ["InitialActive":2]
    static let turretTeamValues: [String:UInt32] = ["Konoko":1,"TCTF":2,"Syndicate":4,"Neutral":8,"SecurityGuard":16,"RogueKonoko":32,"Switzerland":64,"SyndicateAccessory":128]
    static let powerUpClassValues: [String:UInt32] = ["Ammo":0x424D4D41,"EnergyCell":0x454D4D41,"Hypo":0x4F505948,"Shield":0x444C4853,"Invisibility":0x49564E49,"LSI":0x49534C41]
    static func enumName(_ value:UInt32,_ names:[UInt32:String])->String{names[value] ?? String(value)}
    static func flagsName(_ value:UInt32,_ names:[(UInt32,String)])->String{var remaining=value;let found=names.compactMap{bit,name->String? in guard value&bit != 0 else{return nil};remaining &= ~bit;return name};return (found+(remaining==0 ? []:[hex(remaining)])).joined(separator:" ")}
    static func vector(_ data: Data, _ offset: Int) -> String { [readFloat(data, offset), readFloat(data, offset + 4), readFloat(data, offset + 8)].map { String(format: "%.9g", $0) }.joined(separator: " ") }
    static func floatText(_ value: Float) -> String { String(format: "%.9g", value) }
    static func color(_ data: Data, _ offset: Int) -> String {
        let value = readU32(data, offset), r = (value >> 16) & 0xff, g = (value >> 8) & 0xff, b = value & 0xff, a = (value >> 24) & 0xff
        return a == 255 ? "\(r) \(g) \(b)" : "\(r) \(g) \(b) \(a)"
    }
    static func readU16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    static func readU32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24 }
    static func readI16(_ data: Data, _ offset: Int) -> Int16 { Int16(bitPattern: readU16(data, offset)) }
    static func readI32(_ data: Data, _ offset: Int) -> Int32 { Int32(bitPattern: readU32(data, offset)) }
    static func readFloat(_ data: Data, _ offset: Int) -> Float { Float(bitPattern: readU32(data, offset)) }
    static func readTag(_ data: Data, _ offset: Int) -> String { String(bytes: data[offset..<(offset + 4)].reversed(), encoding: .ascii) ?? "????" }
    static func readString(_ data: Data, _ offset: Int, _ length: Int) -> String { String(bytes: data[offset..<(offset + length)].prefix { $0 != 0 }, encoding: .utf8) ?? "" }
    static func number(_ text: String) throws -> Int64 {
        let token = text.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? text
        if token.lowercased().hasPrefix("0x"), let value = UInt64(token.dropFirst(2), radix: 16) { return Int64(bitPattern: value) }
        guard let value = Int64(token) else { throw OniNativeXMLError.invalidDocument("'\(text)' is not a number") }
        return value
    }
    static func enumNumber(_ text:String,_ values:[String:UInt32])throws->UInt32{if let n=try? number(text){return UInt32(truncatingIfNeeded:n)};let clean=text.trimmingCharacters(in:.whitespacesAndNewlines);if clean.isEmpty{return 0};if let n=values[clean]{return n};if let n=values.first(where:{$0.key.caseInsensitiveCompare(clean) == .orderedSame})?.value{return n};throw OniNativeXMLError.invalidDocument("'\(text)' is not a recognized enum value")}
    static func flagsNumber(_ text:String,_ values:[String:UInt32])throws->UInt32{let clean=text.trimmingCharacters(in:.whitespacesAndNewlines);if clean.isEmpty{return 0};if let n=try? number(clean){return UInt32(truncatingIfNeeded:n)};var result:UInt32=0;for token in clean.split(whereSeparator:{$0.isWhitespace||$0==","||$0=="|"}){let name=String(token);if let n=values[name] ?? values.first(where:{$0.key.caseInsensitiveCompare(name) == .orderedSame})?.value{result|=n}else{throw OniNativeXMLError.invalidDocument("'\(name)' is not a recognized flag")}};return result}
    static func patchEnum32(_ data:inout Data,_ offset:Int,_ text:String,_ values:[String:UInt32])throws{writeU32(&data,offset,try enumNumber(text,values))}
    static func patchFlags32(_ data:inout Data,_ offset:Int,_ text:String,_ values:[String:UInt32])throws{writeU32(&data,offset,try flagsNumber(text,values))}
    static func patchU32(_ data: inout Data, _ offset: Int, _ text: String) throws { writeU32(&data, offset, UInt32(truncatingIfNeeded: try number(text))) }
    static func patchI32(_ data: inout Data, _ offset: Int, _ text: String) throws { writeU32(&data, offset, UInt32(truncatingIfNeeded: try number(text))) }
    static func patchI16(_ data: inout Data, _ offset: Int, _ text: String) throws { let value = UInt16(truncatingIfNeeded: try number(text)); data[offset] = UInt8(value & 0xff); data[offset + 1] = UInt8(value >> 8) }
    static func patchU8(_ data: inout Data, _ offset: Int, _ text: String) throws { data[offset] = UInt8(truncatingIfNeeded: try number(text)) }
    static func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) { for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff) } }
    static func patchVector(_ data: inout Data, _ offset: Int, _ text: String) throws {
        let values = text.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
        guard values.count == 3 else { throw OniNativeXMLError.invalidDocument("vector '\(text)' must contain three numbers") }
        for index in 0..<3 { writeU32(&data, offset + index * 4, values[index].bitPattern) }
    }
    static func patchFloat(_ data: inout Data, _ offset: Int, _ text: String) throws {
        guard let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw OniNativeXMLError.invalidDocument("'\(text)' is not a floating-point number") }
        writeU32(&data, offset, value.bitPattern)
    }
    static func colorBytes(_ text: String) throws -> [UInt8] {
        let values = text.split(whereSeparator: \.isWhitespace).compactMap { UInt8($0) }
        guard values.count == 3 || values.count == 4 else { throw OniNativeXMLError.invalidDocument("color '\(text)' must contain RGB or RGBA bytes") }
        return [values[2], values[1], values[0], values.count == 4 ? values[3] : 255]
    }
    static func patchColor(_ data: inout Data, _ offset: Int, _ text: String) throws { let bytes = try colorBytes(text); for index in 0..<4 { data[offset + index] = bytes[index] } }
    static func patchString(_ data: inout Data, _ offset: Int, _ length: Int, _ text: String) throws {
        let bytes = Array(text.utf8)
        guard bytes.count < length else { throw OniNativeXMLError.invalidDocument("'\(text)' is too long for a \(length)-byte string") }
        for index in 0..<length { data[offset + index] = index < bytes.count ? bytes[index] : 0 }
    }
    static func align32(_ value: Int) -> Int { (value + 31) & ~31 }
    static func pad(_ data: inout Data, to count: Int) { if data.count < count { data.append(Data(repeating: 0, count: count - data.count)) } }
    static func appendU16(_ data: inout Data, _ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
    static func appendU32(_ data: inout Data, _ value: UInt32) { for index in 0..<4 { data.append(UInt8((value >> UInt32(index * 8)) & 0xff)) } }
    static func appendU64(_ data: inout Data, _ value: UInt64) { for index in 0..<8 { data.append(UInt8((value >> UInt64(index * 8)) & 0xff)) } }
    static func appendNumber16(_ data: inout Data, _ text: String) throws { appendU16(&data, UInt16(truncatingIfNeeded: try number(text))) }
    static func appendNumber8(_ data: inout Data, _ text: String) throws { data.append(UInt8(truncatingIfNeeded: try number(text))) }
    static func appendEnum8(_ data: inout Data, _ text: String, _ values: [String:UInt32]) throws { data.append(UInt8(truncatingIfNeeded: try enumNumber(text, values))) }
    static func appendNumber32(_ data: inout Data, _ text: String) throws { appendU32(&data, UInt32(truncatingIfNeeded: try number(text))) }
    static func appendEnum32(_ data:inout Data,_ text:String,_ values:[String:UInt32])throws{appendU32(&data,try enumNumber(text,values))}
    static func appendFlags32(_ data:inout Data,_ text:String,_ values:[String:UInt32])throws{appendU32(&data,try flagsNumber(text,values))}
    static func appendFlags16(_ data:inout Data,_ text:String,_ values:[String:UInt32])throws{appendU16(&data,UInt16(truncatingIfNeeded:try flagsNumber(text,values)))}
    static func appendVector(_ data: inout Data, _ text: String) throws {
        let values = try vectorValues(text, count: 3)
        for value in values { appendU32(&data, value.bitPattern) }
    }
    static func vectorValues(_ text: String, count: Int) throws -> [Float] {
        let values = text.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
        guard values.count == count else { throw OniNativeXMLError.invalidDocument("vector '\(text)' must contain \(count) numbers") }
        return values
    }
    static func appendFloat(_ data: inout Data, _ text: String) throws {
        guard let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw OniNativeXMLError.invalidDocument("'\(text)' is not a floating-point number") }
        appendU32(&data, value.bitPattern)
    }
    static func appendColor(_ data: inout Data, _ text: String) throws { data.append(contentsOf: try colorBytes(text)) }
    static func appendEvents(_ events: XMLElement?, to data: inout Data) throws {
        let children = events?.children?.compactMap { $0 as? XMLElement } ?? []
        appendU16(&data, UInt16(children.count))
        let nameToType = Dictionary(uniqueKeysWithValues: eventNames.map { ($0.value, $0.key) })
        for event in children {
            guard let name = event.name, let type = nameToType[name] else { throw OniNativeXMLError.invalidDocument("unsupported event '\(event.name ?? "")'") }
            appendU16(&data, UInt16(type))
            if type == 1 { try appendString(&data, event.attribute(forName: "Function")?.stringValue ?? "", 32) }
            else if type != 0 { try appendNumber16(&data, event.attribute(forName: "TargetId")?.stringValue ?? "0") }
        }
    }
    static func appendString(_ data: inout Data, _ text: String, _ length: Int) throws {
        let bytes = Array(text.utf8)
        guard bytes.count < length else { throw OniNativeXMLError.invalidDocument("'\(text)' is too long for a \(length)-byte string") }
        data.append(contentsOf: bytes)
        data.append(Data(repeating: 0, count: length - bytes.count))
    }
}
