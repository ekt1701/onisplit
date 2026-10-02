// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OniSplit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "onisplit", targets: ["OniSplitCLI"])
    ],
    targets: [
        .target(
            name: "OniSplit",
            path: "Sources/OniSplit",
            sources: ["OniDatFile.swift", "OniMetadata.swift", "OniSound.swift", "OniNativeXML.swift", "OniTextureXML.swift", "OniWeaponXML.swift", "OniCharacterXML.swift", "OniPackSchema.swift", "OniPackSchemas.generated.swift", "OniDatPacker.swift", "OniDatUnpacker.swift", "OniDaeExporter.swift", "OniLevelBuilder.swift", "OniLevelRuntime.swift", "OniLevelFilmBuilder.swift", "OniLevelCameraBuilder.swift", "OniLevelTextureBuilder.swift", "OniColladaGeometry.swift", "OniGunkGeometry.swift", "OniAkiraGeometry.swift", "OniRoomGeometry.swift", "OniRoomExtractor.swift", "OniRoomGrid.swift", "OniRoomGridBuilder.swift", "OniRoomArchive.swift", "OniStandaloneArchive.swift", "OniAKEVBuilder.swift", "OniONLVBuilder.swift", "OniSpatialOctree.swift", "OniTransparencyBSP.swift"]
        ),
        .executableTarget(
            name: "OniSplitCLI",
            dependencies: ["OniSplit"],
            path: "Sources/OniSplitCLI"
        )
    ]
)
