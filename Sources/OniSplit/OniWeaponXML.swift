import Foundation

private struct OniWeaponInstance {
    let tag: String
    let name: String?
    var payload: Data?
}

private struct OniVector3 {
    let x: Float, y: Float, z: Float
}

private struct OniGeometryVertex: Hashable {
    let position: Int, normal: Int, texture: Int
}

private struct OniGeometryData {
    let points: [OniVector3]
    let normals: [OniVector3]
    let textureCoordinates: [(Float, Float)]
    let triangles: [Int]
    let textureName: String?
}

package struct OniWeaponXMLExport {
    package let xml: Data
    package let files: [(fileName: String, data: Data)]
}

package enum OniWeaponXMLExporter {
    private static let weaponFlags: [(UInt32, String)] = [
        (0x00000002,"NoHolster"),(0x00000004,"UsesCells"),(0x00000008,"TwoHanded"),(0x00000010,"RecoilAffectsAiming"),(0x00000020,"Automatic"),(0x00000080,"StunSwitcher"),(0x00000100,"KnockdownSwitcher"),(0x00000200,"Explosive"),(0x00000400,"SecondaryFire"),(0x00000800,"BarabbasWeapon"),(0x00001000,"Heavy"),(0x00002000,"AutoRelease"),(0x00004000,"HasReleaseDelay"),(0x00008000,"HasLaserSight"),(0x00020000,"ScaleCrosshair"),(0x00080000,"NoFade"),(0x00100000,"DrainAmmo")
    ]
    private static let animationNames: [UInt16:String] = [0:"None",150:"AutopistolRecoil",151:"PhaseRifleRecoil",152:"PhaseStreamRecoil",153:"SuperballRecoil",154:"VandegrafRecoil",155:"ScramCannonRecoil",156:"MercuryBowRecoil",157:"ScreamerRecoil",165:"ReloadPistol",166:"ReloadPhaseRifle",167:"ReloadPhaseStream",168:"ReloadSuperball",169:"ReloadVandegraf",170:"ReloadScramCannon",171:"ReloadMercuryBow",172:"ReloadScreamer"]

    package static func supports(file: OniDatFile) -> Bool {
        file.instances.contains { $0.templateTag == "ONWC" && !$0.fullName.isEmpty && $0.descriptorFlags & 2 == 0 }
    }

    package static func export(file: OniDatFile) throws -> OniWeaponXMLExport {
        guard let weapon = file.instances.first(where: { $0.templateTag == "ONWC" && !$0.fullName.isEmpty && $0.descriptorFlags & 2 == 0 }), weapon.dataSize >= 1812 else {
            throw OniNativeXMLError.invalidDocument("the file does not contain an exportable ONWC instance")
        }
        let root=XMLElement(name:"Oni"), document=XMLDocument(rootElement:root); document.version="1.0"; document.characterEncoding="utf-8"
        let onwc=XMLElement(name:"ONWC"); onwc.addAttribute(XMLNode.attribute(withName:"id",stringValue:"0") as! XMLNode); root.addChild(onwc)
        var cursor=weapon.dataOffset
        let laser=section(onwc,"LaserSight")
        add(laser,"Origin",readFloats(file.data,&cursor,3)); add(laser,"Stiffness",readFloat(file.data,&cursor)); add(laser,"AdditionalAzimuth",readFloat(file.data,&cursor)); add(laser,"AdditionalElevation",readFloat(file.data,&cursor)); add(laser,"LaserMaxLength",readFloat(file.data,&cursor)); add(laser,"LaserColor",readColor(file.data,&cursor)); add(laser,"NormalTexture",readLink(file,&cursor)); add(laser,"NormalColor",readColor(file.data,&cursor)); add(laser,"NormalScale",readFloat(file.data,&cursor)); add(laser,"LockedTexture",readLink(file,&cursor)); add(laser,"LockedColor",readColor(file.data,&cursor)); add(laser,"LockedScale",readFloat(file.data,&cursor)); add(laser,"TunnelTexture",readLink(file,&cursor)); add(laser,"TunnelColor",readColor(file.data,&cursor)); add(laser,"TunnelScale",readFloat(file.data,&cursor)); add(laser,"TunnelCount",String(readI32(file.data,&cursor))); add(laser,"TunnelSpacing",readFloat(file.data,&cursor))
        let ammo=section(onwc,"AmmoMeter"); for name in ["Icon","Empty","Fill"]{add(ammo,name,readLink(file,&cursor))}
        let geometryLink=readU32(file.data,cursor); cursor += 4
        var artifacts:[(String,Data)]=[]
        if geometryLink == 0 { add(onwc,"Geometry","") }
        else {
            let geometryIndex=Int(geometryLink>>8); guard geometryIndex<file.instances.count else{throw OniNativeXMLError.invalidDocument("ONWC geometry link is invalid")}
            let base=weapon.fullName.hasPrefix("ONWC") ? String(weapon.fullName.dropFirst(4)):weapon.fullName
            let name="\(base)_\(geometryIndex).dae"; let dae=try exportGeometry(file,index:geometryIndex); artifacts.append((name,dae)); add(onwc,"Geometry",name)
        }
        add(onwc,"Name",readString(file.data,cursor,32)); cursor += 32; add(onwc,"MouseSensitivity",readFloat(file.data,&cursor))
        let recoil=section(onwc,"Recoil"); for name in ["Base","Max","Factor","ReturnSpeed","FiringReturnSpeed"]{add(recoil,name,readFloat(file.data,&cursor))}
        cursor += 38
        let recoilType=readU16(file.data,cursor);cursor+=2;let reloadType=readU16(file.data,cursor);cursor+=2
        add(onwc,"RecoilAnimationType",animationNames[recoilType] ?? String(recoilType)); add(onwc,"ReloadAnimationType",animationNames[reloadType] ?? String(reloadType))
        for name in ["PauseAfterReload","MaxShots","ParticleCount","FiringModeCount","PauseBeforeReload","ReleaseDelay"]{add(onwc,name,String(readI16(file.data,&cursor)))}
        cursor += 2; let flags=readU32(file.data,cursor);cursor+=4;add(onwc,"Flags",weaponFlags.compactMap{flags&$0.0 != 0 ? $0.1:nil}.joined(separator:" "))
        let modes=section(onwc,"FiringModes"); for _ in 0..<2{writeFiringMode(section(modes,"AIFiringMode"),file.data,&cursor)}
        let particles=section(onwc,"Particles"); for _ in 0..<16{writeParticle(section(particles,"ONWCParticle"),file.data,&cursor)}
        add(onwc,"EmptyWeaponSound",readString(file.data,cursor,32));cursor+=36;add(onwc,"Glow",readLink(file,&cursor));add(onwc,"GlowAmmo",readLink(file,&cursor));add(onwc,"GlowTextureScale",readFloats(file.data,&cursor,2));add(onwc,"PickupHandleOffset",readFloats(file.data,&cursor,3));add(onwc,"HoveringHeight",readFloat(file.data,&cursor))
        return OniWeaponXMLExport(xml:document.xmlData(options:[.nodePrettyPrint]),files:artifacts)
    }

    private static func writeFiringMode(_ node:XMLElement,_ data:Data,_ cursor:inout Int){let f=readU32(data,cursor);cursor+=4;add(node,"Flags",f&1 != 0 ? "NoWildShots":"");add(node,"InverseDirection",readFloats(data,&cursor,12));add(node,"Direction",readFloats(data,&cursor,3));add(node,"Origin",readFloats(data,&cursor,3));for n in ["PredictionSpeed","MaxInaccuracyAngle","AimRadius","AISoundRadius","MinShootingDistance","MaxShootingDistance"]{add(node,n,readFloat(data,&cursor))};add(node,"MaxStartleMisses",String(readI16(data,&cursor)));add(node,"SkillIndex",String(readI16(data,&cursor)));add(node,"FightTimer",String(readI32(data,&cursor)));for n in ["ProjectileSpeed","ProjectileGravity","FireSpreadLength","FireSpreadWidth","FireSpreadSkew"]{add(node,n,readFloat(data,&cursor))}}
    private static func writeParticle(_ node:XMLElement,_ data:Data,_ cursor:inout Int){add(node,"Transform",readFloats(data,&cursor,12));add(node,"ParticleClass",readString(data,cursor,16));cursor+=20;for n in ["UsedAmmo","ShotDelay","RoughJusticeShotDelay","ActiveFrames","TriggeredBy","DelayBeforeFiring"]{add(node,n,String(readI16(data,&cursor)))}}

    private static func exportGeometry(_ file:OniDatFile,index:Int)throws->Data{
        let m=file.instances[index];guard m.templateTag=="M3GM",m.dataSize>=36 else{throw OniNativeXMLError.invalidDocument("ONWC geometry does not point to M3GM")};let b=m.dataOffset
        func linked(_ offset:Int,_ tag:String)throws->OniDatInstance{let i=Int(readU32(file.data,b+offset)>>8);guard i<file.instances.count,file.instances[i].templateTag==tag else{throw OniNativeXMLError.invalidDocument("M3GM \(tag) link is invalid")};return file.instances[i]}
        let p=try linked(4,"PNTA"),n=try linked(8,"VCRA"),t=try linked(16,"TXCA"),idx=try linked(20,"IDXA")
        let pointCount=Int(readU32(file.data,p.dataOffset+52)),normalCount=Int(readU32(file.data,n.dataOffset+20)),texCount=Int(readU32(file.data,t.dataOffset+20)),indexCount=Int(readU32(file.data,idx.dataOffset+20))
        guard pointCount>=0,normalCount>=pointCount,texCount>=pointCount,indexCount>=0 else{throw OniNativeXMLError.invalidDocument("geometry array counts are invalid")}
        var points:[Float]=[],normals:[Float]=[],uvs:[Float]=[],strips:[Int32]=[]
        for i in 0..<(pointCount*3){points.append(Float(bitPattern:readU32(file.data,p.dataOffset+56+i*4)))};for i in 0..<(pointCount*3){normals.append(Float(bitPattern:readU32(file.data,n.dataOffset+24+i*4)))};for i in 0..<(pointCount*2){let v=Float(bitPattern:readU32(file.data,t.dataOffset+24+i*4));uvs.append(i%2==1 ? 1-v:v)};for i in 0..<indexCount{strips.append(Int32(bitPattern:readU32(file.data,idx.dataOffset+24+i*4)))}
        let triangles=triangleList(strips);let textureIndex=Int(readU32(file.data,b+28)>>8);let textureName=(textureIndex<file.instances.count ? file.instances[textureIndex].fullName:nil) ?? ""
        return makeDAE(points:points,normals:normals,uvs:uvs,triangles:triangles,textureName:textureName)
    }

    private static func triangleList(_ strips:[Int32])->[Int]{var out:[Int]=[],face=[0,0,0],order=0,i=0;while i<strips.count{let v=strips[i];if v<0{face[0]=Int(UInt32(bitPattern:v)&0x7fffffff);i+=1;if i>=strips.count{break};face[1]=Int(strips[i]);i+=1;order=0;if i>=strips.count{break}}else{face[order]=face[2];order=(order+1)%2};face[2]=Int(strips[i]);out.append(contentsOf:face);i+=1};return out}
    private static func makeDAE(points:[Float],normals:[Float],uvs:[Float],triangles:[Int],textureName:String)->Data{
        let doc=XMLDocument();doc.version="1.0";doc.characterEncoding="utf-8";let root=XMLElement(name:"COLLADA");root.addAttribute(XMLNode.attribute(withName:"version",stringValue:"1.4.0") as! XMLNode);root.addAttribute(XMLNode.attribute(withName:"xmlns",stringValue:"http://www.collada.org/2005/11/COLLADASchema") as! XMLNode);doc.setRootElement(root)
        let asset=section(root,"asset"),unit=XMLElement(name:"unit");unit.addAttribute(XMLNode.attribute(withName:"meter",stringValue:"0.1") as! XMLNode);unit.addAttribute(XMLNode.attribute(withName:"name",stringValue:"decimeter") as! XMLNode);asset.addChild(unit);add(asset,"up_axis","Y_UP")
        if !textureName.isEmpty{
            let clean=textureName.hasPrefix("TXMP") ? String(textureName.dropFirst(4)):textureName
            let images=section(root,"library_images"),image=XMLElement(name:"image");image.addAttribute(XMLNode.attribute(withName:"id",stringValue:"material_image") as! XMLNode);images.addChild(image);add(image,"init_from",clean+".tga")
            let effects=section(root,"library_effects"),effect=XMLElement(name:"effect");effect.addAttribute(XMLNode.attribute(withName:"id",stringValue:"material_effect") as! XMLNode);effects.addChild(effect);let profile=section(effect,"profile_COMMON")
            let surfaceParam=XMLElement(name:"newparam");surfaceParam.addAttribute(XMLNode.attribute(withName:"sid",stringValue:"surface") as! XMLNode);profile.addChild(surfaceParam);let surface=XMLElement(name:"surface");surface.addAttribute(XMLNode.attribute(withName:"type",stringValue:"2D") as! XMLNode);surfaceParam.addChild(surface);add(surface,"init_from","material_image")
            let samplerParam=XMLElement(name:"newparam");samplerParam.addAttribute(XMLNode.attribute(withName:"sid",stringValue:"sampler") as! XMLNode);profile.addChild(samplerParam);let sampler=section(samplerParam,"sampler2D");add(sampler,"source","surface")
            let technique=XMLElement(name:"technique");technique.addAttribute(XMLNode.attribute(withName:"sid",stringValue:"common") as! XMLNode);profile.addChild(technique);let phong=section(technique,"phong"),diffuse=section(phong,"diffuse"),texture=XMLElement(name:"texture");texture.addAttribute(XMLNode.attribute(withName:"texture",stringValue:"sampler") as! XMLNode);texture.addAttribute(XMLNode.attribute(withName:"texcoord",stringValue:"diffuse_TEXCOORD") as! XMLNode);diffuse.addChild(texture)
            let materials=section(root,"library_materials"),material=XMLElement(name:"material");material.addAttribute(XMLNode.attribute(withName:"id",stringValue:"material") as! XMLNode);materials.addChild(material);let instanceEffect=XMLElement(name:"instance_effect");instanceEffect.addAttribute(XMLNode.attribute(withName:"url",stringValue:"#material_effect") as! XMLNode);material.addChild(instanceEffect)
        }
        let library=section(root,"library_geometries"),geometry=XMLElement(name:"geometry");geometry.addAttribute(XMLNode.attribute(withName:"id",stringValue:"geometry") as! XMLNode);library.addChild(geometry);let mesh=section(geometry,"mesh")
        daeSource(mesh,id:"position",values:points,stride:3,names:["X","Y","Z"]);daeSource(mesh,id:"normal",values:normals,stride:3,names:["X","Y","Z"]);daeSource(mesh,id:"texcoord",values:uvs,stride:2,names:["S","T"])
        let vertices=XMLElement(name:"vertices");vertices.addAttribute(XMLNode.attribute(withName:"id",stringValue:"vertices") as! XMLNode);mesh.addChild(vertices);daeInput(vertices,semantic:"POSITION",source:"#position",offset:nil)
        let tris=XMLElement(name:"triangles");tris.addAttribute(XMLNode.attribute(withName:"count",stringValue:String(triangles.count/3)) as! XMLNode);if !textureName.isEmpty{tris.addAttribute(XMLNode.attribute(withName:"material",stringValue:"material") as! XMLNode)};mesh.addChild(tris);daeInput(tris,semantic:"VERTEX",source:"#vertices",offset:0);daeInput(tris,semantic:"NORMAL",source:"#normal",offset:1);daeInput(tris,semantic:"TEXCOORD",source:"#texcoord",offset:2);var packed:[String]=[];for i in triangles{packed.append(String(i));packed.append(String(i));packed.append(String(i))};add(tris,"p",packed.joined(separator:" "))
        let scenes=section(root,"library_visual_scenes"),scene=XMLElement(name:"visual_scene");scene.addAttribute(XMLNode.attribute(withName:"id",stringValue:"scene") as! XMLNode);scenes.addChild(scene);let node=XMLElement(name:"node");node.addAttribute(XMLNode.attribute(withName:"id",stringValue:"geometry_node") as! XMLNode);scene.addChild(node);let ig=XMLElement(name:"instance_geometry");ig.addAttribute(XMLNode.attribute(withName:"url",stringValue:"#geometry") as! XMLNode);node.addChild(ig);if !textureName.isEmpty{let bind=section(ig,"bind_material"),common=section(bind,"technique_common"),instance=XMLElement(name:"instance_material");instance.addAttribute(XMLNode.attribute(withName:"symbol",stringValue:"material") as! XMLNode);instance.addAttribute(XMLNode.attribute(withName:"target",stringValue:"#material") as! XMLNode);common.addChild(instance)};let sceneRoot=section(root,"scene"),ivs=XMLElement(name:"instance_visual_scene");ivs.addAttribute(XMLNode.attribute(withName:"url",stringValue:"#scene") as! XMLNode);sceneRoot.addChild(ivs);return doc.xmlData(options:[.nodePrettyPrint])
    }
    private static func daeSource(_ mesh:XMLElement,id:String,values:[Float],stride:Int,names:[String]){let s=XMLElement(name:"source");s.addAttribute(XMLNode.attribute(withName:"id",stringValue:id) as! XMLNode);mesh.addChild(s);let a=XMLElement(name:"float_array",stringValue:values.map(floatText).joined(separator:" "));a.addAttribute(XMLNode.attribute(withName:"id",stringValue:id+"_array") as! XMLNode);a.addAttribute(XMLNode.attribute(withName:"count",stringValue:String(values.count)) as! XMLNode);s.addChild(a);let tc=section(s,"technique_common"),ac=XMLElement(name:"accessor");ac.addAttribute(XMLNode.attribute(withName:"source",stringValue:"#\(id)_array") as! XMLNode);ac.addAttribute(XMLNode.attribute(withName:"count",stringValue:String(values.count/stride)) as! XMLNode);ac.addAttribute(XMLNode.attribute(withName:"stride",stringValue:String(stride)) as! XMLNode);tc.addChild(ac);for name in names{let p=XMLElement(name:"param");p.addAttribute(XMLNode.attribute(withName:"name",stringValue:name) as! XMLNode);p.addAttribute(XMLNode.attribute(withName:"type",stringValue:"float") as! XMLNode);ac.addChild(p)}}
    private static func daeInput(_ p:XMLElement,semantic:String,source:String,offset:Int?){let e=XMLElement(name:"input");e.addAttribute(XMLNode.attribute(withName:"semantic",stringValue:semantic) as! XMLNode);e.addAttribute(XMLNode.attribute(withName:"source",stringValue:source) as! XMLNode);if let offset{e.addAttribute(XMLNode.attribute(withName:"offset",stringValue:String(offset)) as! XMLNode)};p.addChild(e)}
    private static func section(_ parent:XMLElement,_ name:String)->XMLElement{let e=XMLElement(name:name);parent.addChild(e);return e}
    private static func add(_ parent:XMLElement,_ name:String,_ value:String){parent.addChild(XMLElement(name:name,stringValue:value))}
    private static func readLink(_ file:OniDatFile,_ cursor:inout Int)->String{let link=readU32(file.data,cursor);cursor+=4;if link==0{return ""};let i=Int(link>>8);return i<file.instances.count ? file.instances[i].fullName:""}
    private static func readFloats(_ data:Data,_ cursor:inout Int,_ count:Int)->String{var v:[String]=[];for _ in 0..<count{v.append(readFloat(data,&cursor))};return v.joined(separator:" ")}
    private static func readFloat(_ data:Data,_ cursor:inout Int)->String{let v=Float(bitPattern:readU32(data,cursor));cursor+=4;return floatText(v)}
    private static func floatText(_ value:Float)->String{if value==0{return "0"};return String(value)}
    private static func readColor(_ data:Data,_ cursor:inout Int)->String{let v=readU32(data,cursor);cursor+=4;let r=(v>>16)&255,g=(v>>8)&255,b=v&255,a=(v>>24)&255;return a==255 ? "\(r) \(g) \(b)":"\(r) \(g) \(b) \(a)"}
    private static func readString(_ data:Data,_ offset:Int,_ length:Int)->String{let end=min(offset+length,data.count),zero=data[offset..<end].firstIndex(of:0) ?? end;return String(data:data[offset..<zero],encoding:.utf8) ?? ""}
    private static func readU16(_ data:Data,_ o:Int)->UInt16{UInt16(data[o])|UInt16(data[o+1])<<8}
    private static func readI16(_ data:Data,_ c:inout Int)->Int16{let v=Int16(bitPattern:readU16(data,c));c+=2;return v}
    private static func readU32(_ data:Data,_ o:Int)->UInt32{UInt32(data[o])|UInt32(data[o+1])<<8|UInt32(data[o+2])<<16|UInt32(data[o+3])<<24}
    private static func readI32(_ data:Data,_ c:inout Int)->Int32{let v=Int32(bitPattern:readU32(data,c));c+=4;return v}
}

package enum OniWeaponXMLImporter {
    private static let weaponFlags: [String: UInt32] = [
        "NoHolster": 0x00000002, "UsesCells": 0x00000004, "TwoHanded": 0x00000008,
        "RecoilAffectsAiming": 0x00000010, "Automatic": 0x00000020, "StunSwitcher": 0x00000080,
        "KnockdownSwitcher": 0x00000100, "Explosive": 0x00000200, "SecondaryFire": 0x00000400,
        "BarabbasWeapon": 0x00000800, "Heavy": 0x00001000, "AutoRelease": 0x00002000,
        "HasReleaseDelay": 0x00004000, "HasLaserSight": 0x00008000,
        "ScaleCrosshair": 0x00020000, "NoFade": 0x00080000, "DrainAmmo": 0x00100000
    ]
    private static let animationTypes: [String: UInt16] = [
        "None": 0, "AutopistolRecoil": 150, "PhaseRifleRecoil": 151,
        "PhaseStreamRecoil": 152, "SuperballRecoil": 153, "VandegrafRecoil": 154,
        "ScramCannonRecoil": 155, "MercuryBowRecoil": 156, "ScreamerRecoil": 157,
        "ReloadPistol": 165, "ReloadPhaseRifle": 166, "ReloadPhaseStream": 167,
        "ReloadSuperball": 168, "ReloadVandegraf": 169, "ReloadScramCannon": 170,
        "ReloadMercuryBow": 171, "ReloadScreamer": 172
    ]

    package static func buildStandaloneGeometry(from sourceURL: URL, name requestedName: String) throws -> OniNativeXMLArchive {
        let cleanName = requestedName.lowercased().hasPrefix("m3gm") ? String(requestedName.dropFirst(4)) : requestedName
        guard !cleanName.isEmpty else { throw OniNativeXMLError.invalidDocument("imported physics geometry requires a name") }
        let geometry = try readGeometry(sourceURL)
        var instances: [OniWeaponInstance] = []
        var references: [String: Int] = [:]
        let link = appendGeometry(geometry, to: &instances, references: &references)
        let index = Int(link >> 8)
        let root = instances[index]
        instances[index] = OniWeaponInstance(tag: "M3GM", name: "M3GM" + cleanName, payload: root.payload)
        return OniNativeXMLArchive(
            fileName: "M3GM\(cleanName).oni",
            archiveData: buildArchive(instances)
        )
    }

    package static func standaloneGeometryNames(from sourceURL: URL, name requestedName: String) throws -> [String] {
        let cleanName = requestedName.lowercased().hasPrefix("m3gm") ? String(requestedName.dropFirst(4)) : requestedName
        guard !cleanName.isEmpty else { throw OniNativeXMLError.invalidDocument("imported physics geometry requires a name") }
        let entries = try readGeometryEntries(sourceURL)
        return generatedGeometryNames(baseName: cleanName, entries: entries)
    }

    package static func buildStandaloneGeometries(from sourceURL: URL, name requestedName: String) throws -> [OniNativeXMLArchive] {
        let cleanName = requestedName.lowercased().hasPrefix("m3gm") ? String(requestedName.dropFirst(4)) : requestedName
        guard !cleanName.isEmpty else { throw OniNativeXMLError.invalidDocument("imported physics geometry requires a name") }
        let entries = try readGeometryEntries(sourceURL)
        let names = generatedGeometryNames(baseName: cleanName, entries: entries)
        return zip(entries, names).map { entry, name in
            standaloneGeometry(entry.geometry, name: name)
        }
    }

    package static func buildStandaloneGeometries(
        from sourceURL: URL, namedSourceIndices: [(index: Int, name: String)]
    ) throws -> [OniNativeXMLArchive] {
        let entries = try readGeometryEntries(sourceURL)
        return try namedSourceIndices.map { item in
            let index = item.index
            guard entries.indices.contains(index) else {
                throw OniNativeXMLError.invalidDocument("imported physics geometry index is out of range in \(sourceURL.lastPathComponent)")
            }
            let requestedName = item.name
            let cleanName = requestedName.lowercased().hasPrefix("m3gm")
                ? String(requestedName.dropFirst(4)) : requestedName
            guard !cleanName.isEmpty else {
                throw OniNativeXMLError.invalidDocument("imported physics geometry requires a node name")
            }
            return standaloneGeometry(entries[index].geometry, name: cleanName)
        }
    }

    private static func standaloneGeometry(_ geometry: OniGeometryData, name: String) -> OniNativeXMLArchive {
        var instances: [OniWeaponInstance] = []
        var references: [String: Int] = [:]
        let link = appendGeometry(geometry, to: &instances, references: &references)
        let index = Int(link >> 8)
        let root = instances[index]
        instances[index] = OniWeaponInstance(tag: "M3GM", name: "M3GM" + name, payload: root.payload)
        return OniNativeXMLArchive(fileName: "M3GM\(name).oni", archiveData: buildArchive(instances))
    }

    private static func generatedGeometryNames(
        baseName: String, entries: [(sourceName: String, geometry: OniGeometryData)]
    ) -> [String] {
        guard entries.count > 1 else { return [baseName] }
        var used = Set<String>()
        return entries.enumerated().map { index, entry in
            let cleaned = entry.sourceName.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" ? Character(String(scalar)) : "_"
            }
            let suffix = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let stem = baseName + "_" + (suffix.isEmpty ? String(format: "%02d", index + 1) : suffix)
            var candidate = stem
            var duplicate = 2
            while !used.insert(candidate.lowercased()).inserted {
                candidate = stem + "_" + String(format: "%02d", duplicate)
                duplicate += 1
            }
            return candidate
        }
    }

    package static func build(weapon: XMLElement, sourceFileName: String?, resourceBaseURL: URL?) throws -> OniNativeXMLArchive {
        guard let sourceFileName else { throw OniNativeXMLError.invalidDocument("ONWC XML needs a source filename") }
        var outputName = URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent
        if !outputName.lowercased().hasSuffix(".oni") { outputName += ".oni" }
        let instanceName = URL(fileURLWithPath: outputName).deletingPathExtension().lastPathComponent
        var instances = [OniWeaponInstance(tag: "ONWC", name: instanceName.hasPrefix("ONWC") ? instanceName : "ONWC" + instanceName, payload: nil)]
        var references: [String: Int] = [:]

        func addReference(_ text: String, tag: String) -> UInt32 {
            guard !text.isEmpty else { return 0 }
            let name = text.hasPrefix(tag) ? text : tag + text
            let key = "\(tag):\(name)"
            if let index = references[key] { return instanceID(index) }
            let index = instances.count
            instances.append(OniWeaponInstance(tag: tag, name: name, payload: nil))
            references[key] = index
            return instanceID(index)
        }

        guard let laser = child(weapon, "LaserSight"), let ammo = child(weapon, "AmmoMeter"),
              let recoil = child(weapon, "Recoil") else {
            throw OniNativeXMLError.invalidDocument("ONWC is missing LaserSight, AmmoMeter, or Recoil")
        }
        var payload = Data()
        try appendFloats(&payload, text(laser, "Origin"), count: 3)
        for name in ["Stiffness", "AdditionalAzimuth", "AdditionalElevation", "LaserMaxLength"] { try appendFloat(&payload, text(laser, name)) }
        try appendColor(&payload, text(laser, "LaserColor")); appendU32(&payload, addReference(text(laser, "NormalTexture"), tag: "TXMP"))
        try appendColor(&payload, text(laser, "NormalColor")); try appendFloat(&payload, text(laser, "NormalScale"))
        appendU32(&payload, addReference(text(laser, "LockedTexture"), tag: "TXMP")); try appendColor(&payload, text(laser, "LockedColor")); try appendFloat(&payload, text(laser, "LockedScale"))
        appendU32(&payload, addReference(text(laser, "TunnelTexture"), tag: "TXMP")); try appendColor(&payload, text(laser, "TunnelColor")); try appendFloat(&payload, text(laser, "TunnelScale")); try appendI32(&payload, text(laser, "TunnelCount")); try appendFloat(&payload, text(laser, "TunnelSpacing"))
        for name in ["Icon", "Empty", "Fill"] { appendU32(&payload, addReference(text(ammo, name), tag: "TXMP")) }

        let geometryText = text(weapon, "Geometry")
        if geometryText.isEmpty {
            appendU32(&payload, 0)
        } else if geometryText.lowercased().hasSuffix(".dae") {
            let baseURL = resourceBaseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let geometryURL = geometryText.hasPrefix("/") ? URL(fileURLWithPath: geometryText) : baseURL.appendingPathComponent(geometryText)
            let geometry = try readGeometry(geometryURL)
            appendU32(&payload, appendGeometry(geometry, to: &instances, references: &references))
        } else {
            appendU32(&payload, addReference(geometryText, tag: "M3GM"))
        }
        try appendString(&payload, text(weapon, "Name"), length: 32); try appendFloat(&payload, text(weapon, "MouseSensitivity"))
        for name in ["Base", "Max", "Factor", "ReturnSpeed", "FiringReturnSpeed"] { try appendFloat(&payload, text(recoil, name)) }
        payload.append(Data(repeating: 0, count: 38))
        try appendU16(&payload, enum16(text(weapon, "RecoilAnimationType"), values: animationTypes)); try appendU16(&payload, enum16(text(weapon, "ReloadAnimationType"), values: animationTypes))
        for name in ["PauseAfterReload", "MaxShots", "ParticleCount", "FiringModeCount", "PauseBeforeReload", "ReleaseDelay"] { try appendI16(&payload, text(weapon, name)) }
        appendU16(&payload, 0); appendU32(&payload, try flags(text(weapon, "Flags"), values: weaponFlags))

        let firingModes = child(weapon, "FiringModes")?.children?.compactMap { $0 as? XMLElement }.filter { $0.name == "AIFiringMode" } ?? []
        for index in 0..<2 { try appendFiringMode(index < firingModes.count ? firingModes[index] : nil, to: &payload) }
        let particles = child(weapon, "Particles")?.children?.compactMap { $0 as? XMLElement }.filter { $0.name == "ONWCParticle" } ?? []
        for index in 0..<16 { try appendParticle(index < particles.count ? particles[index] : nil, to: &payload) }
        try appendString(&payload, text(weapon, "EmptyWeaponSound"), length: 32); appendU32(&payload, 0)
        appendU32(&payload, addReference(text(weapon, "Glow"), tag: "TXMP")); appendU32(&payload, addReference(text(weapon, "GlowAmmo"), tag: "TXMP"))
        try appendFloats(&payload, text(weapon, "GlowTextureScale"), count: 2); try appendFloats(&payload, text(weapon, "PickupHandleOffset"), count: 3); try appendFloat(&payload, text(weapon, "HoveringHeight"))
        guard payload.count == 1812 else { throw OniNativeXMLError.invalidDocument("internal ONWC size mismatch (\(payload.count))") }
        instances[0].payload = payload
        return OniNativeXMLArchive(fileName: outputName, archiveData: buildArchive(instances))
    }

    private static func appendFiringMode(_ mode: XMLElement?, to data: inout Data) throws {
        guard let mode else { data.append(Data(repeating: 0, count: 128)); return }
        appendU32(&data, try flags(text(mode, "Flags"), values: ["NoWildShots": 1]))
        try appendFloats(&data, text(mode, "InverseDirection"), count: 12); try appendFloats(&data, text(mode, "Direction"), count: 3); try appendFloats(&data, text(mode, "Origin"), count: 3)
        for name in ["PredictionSpeed", "MaxInaccuracyAngle", "AimRadius", "AISoundRadius", "MinShootingDistance", "MaxShootingDistance"] { try appendFloat(&data, text(mode, name)) }
        try appendI16(&data, text(mode, "MaxStartleMisses")); try appendI16(&data, text(mode, "SkillIndex")); try appendI32(&data, text(mode, "FightTimer"))
        for name in ["ProjectileSpeed", "ProjectileGravity", "FireSpreadLength", "FireSpreadWidth", "FireSpreadSkew"] { try appendFloat(&data, text(mode, name)) }
    }

    private static func appendParticle(_ particle: XMLElement?, to data: inout Data) throws {
        guard let particle else { data.append(Data(repeating: 0, count: 80)); return }
        try appendFloats(&data, text(particle, "Transform"), count: 12); try appendString(&data, text(particle, "ParticleClass"), length: 16); appendU32(&data, 0)
        for name in ["UsedAmmo", "ShotDelay", "RoughJusticeShotDelay", "ActiveFrames", "TriggeredBy", "DelayBeforeFiring"] { try appendI16(&data, text(particle, name)) }
    }

    private static func appendGeometry(_ geometry: OniGeometryData, to instances: inout [OniWeaponInstance], references: inout [String: Int]) -> UInt32 {
        let m3gm = instances.count
        instances.append(OniWeaponInstance(tag: "M3GM", name: nil, payload: nil))
        let pnta = instances.count; instances.append(OniWeaponInstance(tag: "PNTA", name: nil, payload: pointsPayload(geometry.points)))
        let vcra1 = instances.count; instances.append(OniWeaponInstance(tag: "VCRA", name: nil, payload: vectorsPayload(geometry.normals)))
        let faceNormals = makeFaceNormals(points: geometry.points, triangles: geometry.triangles)
        let vcra2 = instances.count; instances.append(OniWeaponInstance(tag: "VCRA", name: nil, payload: vectorsPayload(faceNormals)))
        let txca = instances.count; instances.append(OniWeaponInstance(tag: "TXCA", name: nil, payload: texCoordsPayload(geometry.textureCoordinates)))
        var strips: [Int32] = []
        for index in stride(from: 0, to: geometry.triangles.count, by: 3) {
            strips.append(Int32(bitPattern: UInt32(geometry.triangles[index]) | 0x80000000)); strips.append(Int32(geometry.triangles[index + 1])); strips.append(Int32(geometry.triangles[index + 2]))
        }
        let idxa1 = instances.count; instances.append(OniWeaponInstance(tag: "IDXA", name: nil, payload: indicesPayload(strips)))
        let idxa2 = instances.count; instances.append(OniWeaponInstance(tag: "IDXA", name: nil, payload: indicesPayload((0..<faceNormals.count).map(Int32.init))))
        var textureLink: UInt32 = 0
        if let texture = geometry.textureName, !texture.isEmpty {
            let name = texture.hasPrefix("TXMP") ? texture : "TXMP" + texture
            let key = "TXMP:\(name)"
            if let existing = references[key] { textureLink = instanceID(existing) }
            else { let index = instances.count; instances.append(OniWeaponInstance(tag: "TXMP", name: name, payload: nil)); references[key] = index; textureLink = instanceID(index) }
        }
        var payload = Data(repeating: 0, count: 4)
        for index in [pnta, vcra1, vcra2, txca, idxa1, idxa2] { appendU32(&payload, instanceID(index)) }
        appendU32(&payload, textureLink); appendU32(&payload, 0)
        instances[m3gm].payload = payload
        return instanceID(m3gm)
    }

    private static func readGeometry(_ url: URL) throws -> OniGeometryData {
        let entries = try readGeometryEntries(url)
        guard entries.count == 1 else {
            throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) must contain exactly one geometry mesh")
        }
        return entries[0].geometry
    }

    private static func readGeometryEntries(_ url: URL) throws -> [(sourceName: String, geometry: OniGeometryData)] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OniNativeXMLError.invalidDocument("could not find geometry file '\(url.lastPathComponent)'") }
        let document = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        let meshes = try document.nodes(forXPath: "//*[local-name()='geometry']/*[local-name()='mesh']").compactMap { $0 as? XMLElement }
        guard !meshes.isEmpty else { throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) does not contain geometry meshes") }
        let imagePath = (try? document.nodes(forXPath: "//*[local-name()='library_images']/*[local-name()='image'][1]/*[local-name()='init_from'][1]").first?.stringValue) ?? nil
        let textureName = imagePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        return try meshes.enumerated().map { meshIndex, mesh in
            guard let triangles = mesh.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "triangles" }) else {
                throw OniNativeXMLError.invalidDocument("\(url.lastPathComponent) geometry mesh \(meshIndex + 1) is not triangulated")
            }
        var sources: [String: ([Float], Int)] = [:]
        for source in mesh.children?.compactMap({ $0 as? XMLElement }).filter({ $0.localName == "source" }) ?? [] {
            guard let id = source.attribute(forName: "id")?.stringValue,
                  let array = source.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "float_array" }),
                  let values = floats(array.stringValue ?? ""),
                  let accessor = (try? source.nodes(forXPath: ".//*[local-name()='accessor']").first as? XMLElement) ?? nil,
                  let strideText = accessor.attribute(forName: "stride")?.stringValue, let stride = Int(strideText) else { continue }
            sources[id] = (values, stride)
        }
        let vertices = mesh.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "vertices" })
        let positionSource = vertices?.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "input" && $0.attribute(forName: "semantic")?.stringValue == "POSITION" })?.attribute(forName: "source")?.stringValue?.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var inputs: [(String, String, Int)] = []
        for input in triangles.children?.compactMap({ $0 as? XMLElement }).filter({ $0.localName == "input" }) ?? [] {
            guard var semantic = input.attribute(forName: "semantic")?.stringValue,
                  var source = input.attribute(forName: "source")?.stringValue,
                  let offset = Int(input.attribute(forName: "offset")?.stringValue ?? "0") else { continue }
            source = source.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if semantic == "VERTEX", let positionSource { semantic = "POSITION"; source = positionSource }
            inputs.append((semantic, source, offset))
        }
        guard let packedText = triangles.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == "p" })?.stringValue,
              let packed = ints(packedText), !inputs.isEmpty else { throw OniNativeXMLError.invalidDocument("COLLADA triangle indices are missing") }
        let stride = (inputs.map(\.2).max() ?? 0) + 1
        guard packed.count % stride == 0 else { throw OniNativeXMLError.invalidDocument("COLLADA triangle indices are malformed") }
        var map: [OniGeometryVertex: Int] = [:], points: [OniVector3] = [], normals: [OniVector3] = [], texcoords: [(Float, Float)] = [], outputTriangles: [Int] = []
        for corner in 0..<(packed.count / stride) {
            func index(_ semantic: String) -> Int { inputs.first(where: { $0.0 == semantic }).map { packed[corner * stride + $0.2] } ?? -1 }
            let key = OniGeometryVertex(position: index("POSITION"), normal: index("NORMAL"), texture: index("TEXCOORD"))
            if let existing = map[key] { outputTriangles.append(existing); continue }
            guard let positionInput = inputs.first(where: { $0.0 == "POSITION" }), let position = vector3(sources[positionInput.1], key.position) else { throw OniNativeXMLError.invalidDocument("COLLADA position index is invalid") }
            let normal = inputs.first(where: { $0.0 == "NORMAL" }).flatMap { vector3(sources[$0.1], key.normal) } ?? OniVector3(x: 0, y: 0, z: 0)
            let uv = inputs.first(where: { $0.0 == "TEXCOORD" }).flatMap { vector2(sources[$0.1], key.texture) } ?? (0, 0)
            let newIndex = points.count; map[key] = newIndex; outputTriangles.append(newIndex); points.append(position); normals.append(normal); texcoords.append((uv.0, 1 - uv.1))
        }
            let source = mesh.parent as? XMLElement
            let sourceName = source?.attribute(forName: "name")?.stringValue
                ?? source?.attribute(forName: "id")?.stringValue
                ?? String(format: "%02d", meshIndex + 1)
            return (sourceName, OniGeometryData(points: points, normals: normals, textureCoordinates: texcoords, triangles: outputTriangles, textureName: textureName))
        }
    }

    private static func pointsPayload(_ points: [OniVector3]) -> Data {
        var data = Data(repeating: 0, count: 12)
        let minimum = OniVector3(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0, z: points.map(\.z).min() ?? 0)
        let maximum = OniVector3(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0, z: points.map(\.z).max() ?? 0)
        appendVector(&data, minimum); appendVector(&data, maximum)
        let center = OniVector3(x: points.map(\.x).reduce(0,+) / Float(Swift.max(points.count,1)), y: points.map(\.y).reduce(0,+) / Float(Swift.max(points.count,1)), z: points.map(\.z).reduce(0,+) / Float(Swift.max(points.count,1)))
        appendVector(&data, center); appendFloat(&data, points.map { let x=$0.x-center.x,y=$0.y-center.y,z=$0.z-center.z; return x*x+y*y+z*z }.max().map(sqrt) ?? 0)
        appendU32(&data, UInt32(points.count)); for point in points { appendVector(&data, point) }; return data
    }

    private static func vectorsPayload(_ vectors: [OniVector3]) -> Data { var data = Data(repeating: 0, count: 20); appendU32(&data, UInt32(vectors.count)); for vector in vectors { appendVector(&data, vector) }; return data }
    private static func texCoordsPayload(_ values: [(Float, Float)]) -> Data { var data = Data(repeating: 0, count: 20); appendU32(&data, UInt32(values.count)); for value in values { appendFloat(&data, value.0); appendFloat(&data, value.1) }; data.append(Data(repeating: 0, count: 480)); return data }
    private static func indicesPayload(_ values: [Int32]) -> Data { var data = Data(repeating: 0, count: 20); appendU32(&data, UInt32(values.count)); for value in values { appendU32(&data, UInt32(bitPattern: value)) }; return data }
    private static func makeFaceNormals(points: [OniVector3], triangles: [Int]) -> [OniVector3] { stride(from: 0, to: triangles.count, by: 3).map { i in let a=points[triangles[i]],b=points[triangles[i+1]],c=points[triangles[i+2]]; let x=(b.y-a.y)*(c.z-a.z)-(b.z-a.z)*(c.y-a.y),y=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z),z=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x),l=max(sqrt(x*x+y*y+z*z),Float.leastNonzeroMagnitude); return OniVector3(x:x/l,y:y/l,z:z/l) } }

    private static func buildArchive(_ instances: [OniWeaponInstance]) -> Data {
        let nameOffset = align32(64 + instances.count * 20); var names = Data(), nameOffsets: [UInt32] = []
        for instance in instances { if let name=instance.name { nameOffsets.append(UInt32(names.count)); names.append(Data((name+"\0").utf8)) } else { nameOffsets.append(0) } }
        let dataOffset = align32(nameOffset + names.count); var offsets=[UInt32](repeating:0,count:instances.count), dataLength=0
        for i in instances.indices where instances[i].payload != nil { offsets[i]=UInt32(dataLength+8); dataLength += align32(instances[i].payload!.count+8) }
        var output=Data(); appendU64(&output,0x0003_bcdf_33dc_271f); output.append(Data("23RV".utf8)); appendU16(&output,64); appendU16(&output,20); appendU16(&output,16); appendU16(&output,8); appendU32(&output,UInt32(instances.count)); appendU32(&output,0); appendU32(&output,0); appendU32(&output,UInt32(dataOffset)); appendU32(&output,UInt32(dataLength)); appendU32(&output,UInt32(nameOffset)); appendU32(&output,UInt32(names.count)); appendU32(&output,0); appendU32(&output,0); appendU64(&output,0)
        for i in instances.indices { let item=instances[i]; output.append(Data(String(item.tag.reversed()).utf8)); appendU32(&output,offsets[i]); appendU32(&output,nameOffsets[i]); appendU32(&output,UInt32((item.payload?.count ?? -8)+8)); appendU32(&output,item.payload == nil ? 2 : (item.name == nil ? 1 : 0)) }
        pad(&output,to:nameOffset); output.append(names); pad(&output,to:dataOffset)
        for i in instances.indices { guard let payload=instances[i].payload else {continue}; pad(&output,to:align32(output.count)); appendU32(&output,instanceID(i)); appendU32(&output,0); output.append(payload) }
        pad(&output,to:dataOffset+dataLength); return output
    }

    private static func child(_ parent:XMLElement,_ name:String)->XMLElement? { parent.elements(forName:name).first }
    private static func text(_ parent:XMLElement,_ name:String)->String { child(parent,name)?.stringValue ?? "" }
    private static func floats(_ value:String)->[Float]? { let values=value.split(whereSeparator:\.isWhitespace).compactMap{Float($0)}; return values.count == value.split(whereSeparator:\.isWhitespace).count ? values:nil }
    private static func ints(_ value:String)->[Int]? { let values=value.split(whereSeparator:\.isWhitespace).compactMap{Int($0)}; return values.count == value.split(whereSeparator:\.isWhitespace).count ? values:nil }
    private static func vector3(_ source:([Float],Int)?,_ index:Int)->OniVector3? { guard let (v,s)=source,index>=0,index*s+2<v.count else{return nil}; return OniVector3(x:v[index*s],y:v[index*s+1],z:v[index*s+2]) }
    private static func vector2(_ source:([Float],Int)?,_ index:Int)->(Float,Float)? { guard let (v,s)=source,index>=0,index*s+1<v.count else{return nil}; return (v[index*s],v[index*s+1]) }
    private static func flags(_ value:String,values:[String:UInt32]) throws->UInt32 { var result:UInt32=0; for token in value.split(whereSeparator:{ $0.isWhitespace || $0=="," || $0=="|" }) { guard let bit=values[String(token)] else{throw OniNativeXMLError.invalidDocument("unknown flag '\(token)'")}; result |= bit }; return result }
    private static func enum16(_ value:String,values:[String:UInt16]) throws->UInt16 { if let n=UInt16(value){return n}; guard let n=values[value] else{throw OniNativeXMLError.invalidDocument("unknown enum value '\(value)'")}; return n }
    private static func appendFloats(_ data:inout Data,_ value:String,count:Int)throws { guard let numbers=floats(value),numbers.count==count else{throw OniNativeXMLError.invalidDocument("expected \(count) floating-point values in '\(value)'")}; for n in numbers{appendFloat(&data,n)} }
    private static func appendFloat(_ data:inout Data,_ value:String)throws { guard let n=Float(value) else{throw OniNativeXMLError.invalidDocument("'\(value)' is not a floating-point number")}; appendFloat(&data,n) }
    private static func appendI16(_ data:inout Data,_ value:String)throws { guard let n=Int16(value) else{throw OniNativeXMLError.invalidDocument("'\(value)' is not a 16-bit number")}; appendU16(&data,UInt16(bitPattern:n)) }
    private static func appendI32(_ data:inout Data,_ value:String)throws { guard let n=Int32(value) else{throw OniNativeXMLError.invalidDocument("'\(value)' is not a 32-bit number")}; appendU32(&data,UInt32(bitPattern:n)) }
    private static func appendColor(_ data:inout Data,_ value:String)throws { guard let n=floats(value),n.count==3 || n.count==4,n.allSatisfy({$0>=0 && $0<=255}) else{throw OniNativeXMLError.invalidDocument("'\(value)' is not a color")}; let r=UInt32(n[0]),g=UInt32(n[1]),b=UInt32(n[2]),a=UInt32(n.count==4 ? n[3]:255); appendU32(&data,b|(g<<8)|(r<<16)|(a<<24)) }
    private static func appendString(_ data:inout Data,_ value:String,length:Int)throws { let bytes=Data(value.utf8); guard bytes.count<length else{throw OniNativeXMLError.invalidDocument("string is too long for \(length)-byte field")}; data.append(bytes); data.append(Data(repeating:0,count:length-bytes.count)) }
    private static func appendVector(_ data:inout Data,_ v:OniVector3){appendFloat(&data,v.x);appendFloat(&data,v.y);appendFloat(&data,v.z)}
    private static func appendFloat(_ data:inout Data,_ v:Float){appendU32(&data,v.bitPattern)}
    private static func appendU16(_ data:inout Data,_ v:UInt16){data.append(UInt8(v&255));data.append(UInt8(v>>8))}
    private static func appendU32(_ data:inout Data,_ v:UInt32){for s in stride(from:0,through:24,by:8){data.append(UInt8((v>>UInt32(s))&255))}}
    private static func appendU64(_ data:inout Data,_ v:UInt64){for s in stride(from:0,through:56,by:8){data.append(UInt8((v>>UInt64(s))&255))}}
    private static func instanceID(_ i:Int)->UInt32{UInt32(i<<8)|1}
    private static func align32(_ n:Int)->Int{(n+31) & ~31}
    private static func pad(_ data:inout Data,to n:Int){if data.count<n{data.append(Data(repeating:0,count:n-data.count))}}
}
