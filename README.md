# OniSplit ARM64

A native macOS Apple Silicon implementation of the OniSplit command-line
tool, written in Swift. It requires no .NET or Mono runtime.

## Build

Run `./build-cli.sh` to build only the native command-line tool:

- `dist/onisplit`

If macOS reports a permissions error, make the script executable first:

```bash
chmod +x build-cli.sh
./build-cli.sh
```

### Build with Xcode

This repository is a Swift Package Manager project. Open `Package.swift` in
Xcode:

```bash
open Package.swift
```

In Xcode, select the `onisplit` scheme and choose **Product > Build**. The
native command-line product is built for the selected macOS architecture.

For an Apple Silicon build, choose **My Mac (Apple Silicon)** as the run
destination. To create a distributable command-line binary from Terminal,
use:

```bash
./build-cli.sh
```

The script writes the signed ad-hoc binary to `dist/onisplit`.

Initial native CLI commands:

```text
onisplit info <file.dat>
onisplit list [--tag TAG] [--names-only] <file.dat>
onisplit show <file.dat> <index-or-name>
onisplit extract-textures --output <directory> [--format png|jpg|bmp|tif|tga] <files...>
onisplit extract-sounds --output <directory> [--format wav|aif] <files...>
onisplit to-xml --output <directory> <files.oni...>
onisplit to-xml --lossless --output <directory> <files.oni...>
onisplit from-xml --output <directory> <files.xml...>
onisplit -export <directory> <file.dat>
onisplit -import:sep <directory> [additional-directories...] <file.dat>
onisplit -create:level <directory> <level-definition.xml> [-debug]
```

Readable, editable semantic XML is the standard output. All Level 14 `BINACJBO` families expose semantic fields: CHAR, CONS, DOOR, FLAG, FURN, NEUT, PART, PATR, PWRU, SNDG, TRGV, TRIG, TURR, and WEAP. `from-xml` builds a fresh VR32 `.oni` directly from those fields. Fresh files may normalize internal allocation metadata while preserving the represented game data. Empty `BINACJBO` object tables are also supported. Files whose semantic format has not been implemented yet temporarily fall back to lossless XML and print a notice.

Use `--lossless` when an exact native archive is desired. This includes a readable instance index and base64 `NativeArchive`; an unchanged lossless XML file reconstructs its `.oni` byte-for-byte. The former `--semantic-only` option remains accepted as an alias for the new default behavior.

`from-xml` and the compatible `-create` form also accept original OniSplit `<Texture>` XML. Static and animated textures, relative TGA image paths, mipmaps, animation speed and flags, environment-map links, and the BGRA4444, BGR555, BGRA5551, RGBA, BGR, and DXT1 formats are supported. Animated imports create their TXMP frame instances and TXAN link table automatically.

Named TXMP files export to the same editable `<Texture>` XML format by default. Their decoded pixels are written as neighboring TGA files; animated TXMP/TXAN files produce numbered TGA frames and preserve the animation speed, flags, pixel format, and environment-map reference.

ONWC weapon classes can be imported from and exported to readable OniSplit XML. Laser-sight, ammo-meter, recoil, firing-mode, particle, sound, glow, animation, and weapon flag fields are preserved. Referenced Collada geometry is converted to a complete native M3GM bundle on import and reconstructed as an editable `.dae` file on export.

ONCC character classes can also be imported from and exported to readable OniSplit XML. Character movement, shadow, damage, health, AI targeting and weapon skills, sounds, vision, animation links, particles, named impacts, body materials, and hit/block/kill impact mappings are editable. The linked ONCP, ONIA, CBPM, and CBPI records are rebuilt automatically.

The original-compatible `-import:sep` command packs VR32 `.oni` files into a VR31 level archive and writes the matching `.dat`, `.raw`, and `.sep` files. It rebuilds descriptor, name, and template tables; resolves named and private dependencies; removes the same safe duplicate instance families as OniSplit; remaps all instance links; and relocates embedded binary data into the appropriate companion file.

The original-compatible `-export` command unpacks every named instance in a VR31 level archive to an individual VR32 `.oni` file. Each file includes its private dependency graph and embedded binary data, while links to other named resources are preserved as named placeholders. `-export:PREFIX` limits export to names beginning with the supplied prefix.

Original OniSplit forms `-list`, `-export`, `-export:PREFIX`, `-room:extract`, `-extract:png`, `-extract:tga`, `-extract:jpg`, `-extract:bmp`, `-extract:tif`, `-extract:wav`, `-extract:aif`, `-extract:xml`, `-create`, `-version`, and `-help` are also accepted.

Character geometry extraction accepts `-noanim` and applies OniSplit's static default pose to ONCC and TRBS bodies:

```text
onisplit -extract:dae output -noanim ONCCcharacter.oni TRBSbody.oni
```

`-room:extract` creates starter BNV floor geometry from one or more environment
COLLADA models. It applies scene transforms and coordinate conversion, keeps
upward-facing polygons at the original OniSplit slope threshold, and combines
suitable coplanar triangle pairs into quads. Add `--connect` (or `-connect`) to
merge additional coplanar fragments when their union remains convex, then
generate ghost portals across the remaining shared horizontal floor edges.
Every emitted BNV floor is a non-degenerate four-corner polygon. Residual
fragments are merged into a compatible convex quadrilateral when possible;
triangles, polygons with other vertex counts, and collapsed wedge-shaped quads
are reported and omitted.
Every merged floor must preserve the combined projected area, and every portal
is checked with the same two-room probe used by level creation; invalid,
ambiguous, and unpaired candidates are omitted. The connector samples original
steep and vertical environment polygons to suppress fully walled boundaries,
clips portals to open intervals such as doorways, and limits their height when
it finds overhead obstruction. Connected output should still be reviewed before
production use because this is geometric inference rather than authored intent.
As a final conservative cleanup, isolated floor surfaces smaller than 64 square
Oni units are omitted; small surfaces with a valid room connection are retained.

```text
onisplit -room:extract -out:rooms.dae environment.dae
onisplit -room:extract -out:rooms-connected.dae --connect environment.dae
onisplit -room:extract -out:rooms-connected.dae --connect --report:rooms-report.json environment.dae
```

The optional JSON report lists every room footprint, bounds, height, adjacency,
and isolation status, together with each accepted portal's connected rooms,
kind, width, height, and vertices. Its summary also records every merge,
discard, blocked boundary, and rejected portal decision.

## Level creation

The native CLI includes `-create:level`, `create:level`, and `create-level`. The level command
writes the AKEV environment, ONLV level root, all 14 object
tables, imported environment textures, and referenced shared furniture and
marker textures. Imported `<Characters>` and `<Particles>` files populate the
ONLV AISA script-character and ENVP environment-particle arrays, including
named ONCC/ONWC links. Imported `<Physics>` files using shared `<Geometry>`
names populate OBOA, M3GA, optional OBAN links, transforms, and per-object ENVP
arrays; their shared M3GM and TXMP dependencies are copied automatically.
Triangle COLLADA `<Import>` geometry is converted to standalone M3GM files and
its source textures are imported to TXMP. Multi-node physics scenes are split
into their original node objects, with node-named geometry, sequential script
IDs, optional named-geometry script-ID overrides, parent-composed animation
transforms, per-node OBAN clips, and AutoStart selection. Corpse arrays are also
generated with the required runtime reserve.
Shared `<Animation>` references are rebuilt as OBAN dependencies too; their
first frame initializes the physics setup, while `Local` animation keys are
rebased by the object's placement as in the original importer.
Camera imports are accepted both inside the environment `<Model>` and in the
level's standalone `<Cameras>` section.
Environment models accept both `<Import>` and the original-compatible `<Scene>`
alias.
Environment texture settings and imported texture-setting files honor image,
format, size, animation, environment-map, GunkFlags, default-format, and
maximum-size options; matching polygon flags are updated before AKEV creation.
Referenced shared textures that lack mipmaps are decoded and rebuilt with a
complete mip chain, while existing mipmapped TXMP files are copied unchanged.
AKEV room topology preserves ordinary ghost portals and directional stair
portals, while malformed portals remain in geometry without invalid room links.
Room-grid generation also applies OniSplit's stair-volume collision pass before
rasterization so nearby geometry does not incorrectly block stair navigation.
AKEV world bounds include generated room-floor geometry, matching OniSplit even
when a room extends beyond all serialized environment and portal polygons.
Physics declarations nested in environment model nodes also generate OBOA,
node-named M3GM, inherited child setups, particles, script IDs, object flags,
and per-node OBAN animation clips. Physics-marked COLLADA subtrees are omitted
from AKEV, while ordinary descendants inherit their nearest scene/node gunk
flags and script ID, matching the original importer.
Door objects now contribute their class geometry to AKEV with OniSplit's
no-collision/no-decals flags and object-map IDs. Their opening-animation scale,
placement correction, double-door side transforms, script IDs, face-collision
OBOA setups, per-side texture overrides, and private M3GM dependencies are
rebuilt from the shared DOOR, OFGA, OBAN, and M3GM classes. The Mirror flag
selects the engine-mirrored side for both the OBOA origin and baked AKEV gunk,
including mirrored single doors and the opposite-side rule for double doors.
Placed console classes contribute every OFGA geometry part to AKEV with console
object-map IDs, while trigger rails and turret bases use their class M3GM and
class-specific gunk flags. Furniture-class ENVP emitters are transformed from
class-local to world space and receive the placement's particle-tag prefix in
the level ENVP array.
Generated level directories can be packed with `-import:sep` to produce the
matching `.dat`, `.raw`, and `.sep` files.

Pass `-debug` to the original-compatible command, or `--debug` to
`create-level`, to include AGDB source object/file names for every AKEV polygon
and include generated room portals in the diagnostic spatial trees, matching
the original OniSplit debug mode.
