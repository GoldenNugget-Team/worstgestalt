# The CoreUI `.car` Format

This document specifies Apple's CoreUI asset-catalog (`.car`, internal name
*BOM-based CoreUI Theme*) file format as reverse-engineered for the port in
`tools/car/`. Sources of truth:

* the Rust reference crate at `/tmp/opencode/car-parser/` (Apple's
  `coreui` crate semantics, field by field),
* two real Xcode 27.2 catalogs used as ground truth:
  * **G1** — `IDESXSupportCore.ideplugin/Contents/Resources/Assets.car`
    (27 KB, 17 renditions, 1 facet, Deepmap2 rasters),
  * **G2** — `IconFoundation.framework/.../Assets.car`
    (6.5 MB, 136 renditions, 33 facets, LZFSE + Deepmap2 rasters).

Implementation map (code moved to the standalone `/home/awesomenull/Projects/coreui-car` project, sibling of this repo; see its README):

| Concern                     | File (coreui-car)           |
|-----------------------------|-----------------------------|
| BOM container + B+ trees    | `coreui_car/bom.py`         |
| CAR blocks (header/CSI/...) | `coreui_car/blocks.py`      |
| Constants and ids           | `coreui_car/structs.py`     |
| Payload decompression       | `coreui_car/decode.py`      |
| LZFSE sidecar               | `lzfse-sidecar/`            |
| High-level reader           | `coreui_car/car.py`         |
| Writer / compiler           | `coreui_car/writer.py`      |
| CLI builder                 | `tools/build_car.py`        |
| Tests                       | `tests/test_car.py`         |

## Endianness — the golden rule

**The outer BOM container is BIG-endian. Anything inside a CAR block is
LITTLE-endian.** This is the single most common mistake with `.car` files:
Apple's BOMStore layer (`BOMStore`, `tree`, path nodes, index, vars table)
is big-endian, while all CoreUI structures (`RATC`, `META`, `tmfk`, `ISTC`,
TLVs, `MLEC` payloads, rendition keys) are little-endian.

## 1. BOM container

```
offset 0   : container header, 32 bytes, BIG-endian
offset 512 : first block (blocks are 16-byte aligned; the first 512 bytes
             are header + zero padding in all observed files)
   ...     : blocks ...
   ...     : vars table
   ...     : small gap (uninitialized)
   ...     : block index + trailing pad (EOF)
```

### Container header (32 bytes, BE)

| off | size | field                                   |
|-----|------|-----------------------------------------|
|  0  | 8    | magic `BOMStore`                        |
|  8  | 4    | version (1)                             |
| 12  | 4    | block count (slots used + 1; slot 0 reserved) |
| 16  | 4    | index offset                            |
| 20  | 4    | index length                            |
| 24  | 4    | vars offset                             |
| 28  | 4    | vars length                             |

### Block index (BE), at `index_offset`

```
u32 slot_count
then slot_count entries of (u32 offset, u32 length)
u32[0] is the null slot (0,0); block i lives in slot i.
trailing zero padding after the last full slot: 20 bytes in all observed
files (both G1/G2). Copy it on write; ignore on read.
```

G1 uses `slot_count = 256`, G2 uses 384 (small catalogs always get ≥256).

### Variable table (BE), at `vars_offset`

```
u32 var_count
then per var: u32 block_id + u8 name_len + name bytes (no padding)
```

Variables map *names* to tree-header block ids. Observed set: `CARHEADER`,
`RENDITIONS`, `FACETKEYS`, `KEYFORMAT`, `EXTENDED_METADATA`, `BITMAPKEYS`;
`APPEARANCEKEYS` is optional (absent unless appearance variants exist).
The crate special-cases a missing `APPEARANCEKEYS` to an empty map.

### Tree header block (BE) — block a var points to

```
'tree'(4) + u32 version(=1) + u32 first_path_block +
u32 block_size(4096 for RENDITIONS/FACETKEYS; 1024 in G1's BITMAPKEYS)
+ u32 full_path_count + 1 zero byte
```

G1's BITMAPKEYS tree header ends with `0x01` instead of `0x00` — the byte
appears to be insignificant.

### Path node (B+ tree node, BE)

```
u16 is_leaf + u16 entry_count + u32 forward + u32 backward,
then entry_count entries of (u32 value_id, u32 key_id)
```

* Leaf entries reference **separate key and value blocks** (ids into the
  block index) — the key/value bytes are *not* inline in the leaf.
  NOTE: earlier reverse-engineering guessed "value then key inverted";
  the pair is `(value_block, key_block)` exactly like the Rust crate reads.
* Internal-node entries point at the child path block through `value_id`
  (first-child descent + `forward` chaining through leaves covers all
  entries).
* Real files order leaf entries by **raw key bytes (unsigned byte order)**;
  the writer must do the same.
* Apple tolerates *dangling block ids*: the `BITMAPKEYS` leaf key id points
  outside the allocated block range (G1: `0x989A` — the catalog's pooled
  Identifier value, as a BE u32; G2: per-facet ids like 2257/4571/4885).
  Readers must not crash (the Python `BOMStore.block()` returns `b""`).

## 2. Tree contents

### RENDITIONS

* key block: rendition key = **u16 LE attribute values** in KeyFormat token
  order (no tags; the count is implied by KEYFORMAT).
* value block: a full CSI rendition block (below).

### FACETKEYS

* key block: facet name, UTF-8, NUL-terminated.
* value block: **FacetToken**:

| off | type   | field                          |
|-----|--------|--------------------------------|
|  0  | u16 LE | x                              |
|  2  | u16 LE | y                              |
|  4  | u16 LE | attribute count                |
|  6  | ..     | attrs: (u16 tag, u16 value) LE |

Facet lookup uses the `Identifier` (tag 17) attribute only.

Example (G2 app-bundle facet): `[(1,85),(2,220),(17,44052)]`.

### APPEARANCEKEYS

key = appearance name, value = opaque 4-byte bit record. Absent in both
ground truths.

### BITMAPKEYS

Present in G1 and G2 but *never read by the Rust crate*. Value record:

```
G1 = struct.pack("<16I", 1,0,52,12,
                 0xffffffff,0xffffffff,0xffffffff,
                 7,1,1,6,1,
                 0xffffffff,32,530,14)   # 64 bytes, LE u32s
```

G2 carries one such record *per facet* (33 entries). Semantics unknown
(documented risk).

## 3. CARHEADER block (`RATC`, 436 bytes, LE)

| off | size | field                                        | G1 value |
|-----|------|----------------------------------------------|----------|
|   0 | 4    | magic `RATC`                                 |          |
|   4 | 4×u32| coreui_version, storage_version, timestamp, rendition_count | 1011, 17, 0, 17 |
|  20 | 128  | MainVersionString (NUL-padded fixed width)   | `@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1011.3 [LAR]` |
| 148 | 256  | VersionString                                | `Xcode 27.2 (27B49) via AssetCatalogAgent-AssetRuntime` |
| 404 | 16   | UUID (G1: all zero)                          |          |
| 420 | u32  | associated_checksum                          | 0        |
| 424 | u32  | schema_version                               | 2        |
| 428 | u32  | color_space (1=sRGB, 3=DisplayP3, ...)       | 1        |
| 432 | u32  | key_semantics                                | 1        |

G1's authoring tool string (stored in EXTENDED_METADATA):
`@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-664 [LAR]
[IIO-2851.1.5][LAR] AppleJPEG[1][32]  CMPhoto[1][222]] [IR-120(sw)]`

## 4. EXTENDED_METADATA block (`META`, 1028 bytes, LE)

magic + four 256-byte NUL-padded strings:

1. ThinningArguments (often empty)
2. DeploymentPlatformVersion (`26.0` in the built sample)
3. DeploymentPlatform (`macosx`)
4. AuthoringTool (see above)

## 5. KEYFORMAT block (`tmfk`, LE)

```
'tmfk' + u32 version(0) + u32 count
+ count × (u16 attr_tag LE, u16 reserved=0)
```

Confirmed attribute semantics on the ground truths:

| tag | name              | notes                                             |
|-----|-------------------|---------------------------------------------------|
|  1  | Element           | pooled value (85 = app icon slot, 9 in G1 icons)  |
|  2  | Part              | pooled value (220 = app icon slot, 181 in G1)     |
|  17 | Identifier        | CRC-style pooled id (e.g. 0x989A)                 |
|  8  | Dimension1        |                                                   |
|  9  | Dimension2        |                                                   |
|  10 | State             |                                                   |
|  14 | PresentationState |                                                   |
|  12 | Scale             | **multiplier** (@1x=1, @2x=2, @3x=3), *not*       |
|     |                   | 100/200/300 — the CSI keeps scale_factor=200      |
|  19 | PreviousState     |                                                   |
|  18 | PreviousValue     |                                                   |
|  24 | DisplayGamut      | only in G2's 11-token format                      |
|  25 | DeploymentTarget  | typically 5                                       |
|  26 | GlyphWeight       |                                                   |
|  27 | GlyphSize         |                                                   |

Formats seen:

* **G1** and the sample builder: `[1,2,17,9,10,14,12,19,18,25,26,27]`
  (12 tokens → 24-byte keys).
* **G2**: `[1,2,17,8,9,10,14,12,24,19,18]`.

## 6. CSI rendition block (`ISTC`)

The 4-byte magic in files is literally **`ISTC`** (i.e. "CSTI" read
backwards — the tag is stored byte-reversed). Fixed header is **184 bytes,
LE**:

| off  | size | field                                             |
|------|------|---------------------------------------------------|
|   0  | 4    | magic `ISTC`                                      |
|   4  | u32  | version (1)                                       |
|   8  | u32  | flags bitfield (below)                            |
|  12  | 3×u32| pixel width, pixel height, scale_factor (100-based) |
|  24  | 4    | pixel encoding tag (`BGRA`, `YARG`, ` 8AG`, …)    |
|  28  | 3×u32| color_model (1=RGB, 2=Monochrome), modification_time, layout_type |
|  40  | 128  | rendition name (NUL-padded)                       |
| 168  | 4×u32| tlv_length, bitmap_count(=1), zero, rendition_length |
| 184  |   …  | TLVs (tlv_length bytes) then payload (rendition_length) |

### Flags bitfield (u32 LE, LSB first)

| bit | field                                        |
|-----|----------------------------------------------|
| 0   | is_header_flagged_fpo                        |
| 1   | is_excluded_from_contrast_filter             |
| 2   | is_vector_based                              |
| 3   | is_opaque                                    |
| 4–7 | bitmap_encoding (nibble)                     |
| 8   | opt_out_of_thinning                          |
| 9   | flippable                                    |
| 10  | tintable                                     |
| 11  | preserved_vector_representation              |

Pixels in `BGRA` encoding are stored memory order **B,G,R,A**.

### Layout types

| id   | name                    |
|------|-------------------------|
|  10  | OnePartFixedSize (flat icons) |
|  12  | OnePartScale (G2 icons) |
| 1003 | InternalReference       |
| 1004 | PackedImage             |
| 1009 | Color                   |
| 1010 | MultisizeImage          |
| 1017 | (G1 raster layout id)   |

Layout ids 10–14 with a raster encoding are classified as DecodedRaster by
the crate.

### TLVs (LE): each is `u32 tag, u32 length, body`

| tag  | body                                                              |
|------|-------------------------------------------------------------------|
| 1001 | Slices: u32 count + count×(4×u32: x,y,width,height)               |
| 1003 | Metrics: u32(=1) + 3×(2×u32): bottom_left_inset, top_right_inset, image_size |
| 1004 | BlendModeAndOpacity: u32 blend + f32 opacity                      |
| 1005 | UTI: u32 string length + u32 padding + string bytes. Modeled by the Rust crate but absent in the G1/G2 samples — treat as informational. |
| 1006 | EXIFOrientation: u32                                              |
| 1007 | BytesPerRow: u32 (row stride, may exceed width×bpp)               |

G2 icon profile (layout 12, 104 bytes from TLVs): Slices, Metrics
(`image_size = points//128`, 0 for <128 pt), BlendMode (0, opacity 1.0),
EXIF 1 (Normal), BytesPerRow = width×4.

### Payloads (magic at payload start)

* `MLEC` — compressed image/theme data (the common raster case):

| ver | layout                                                            |
|-----|-------------------------------------------------------------------|
| 0/2 | single chunk, no part headers: `'MLEC' + u32 version + u32 compression + u32 uncompressed_len + chunk bytes` |
| 1/3 | part headers `'KCBC'` + per chunk `KCBC + u32×4 (…, chunk_height, chunk_len) + bytes` |

* `RLOC` — colors; `DWAR` — raw data; `SISM` — multisize sets.

### Compression codes (u32 LE inside `MLEC`)

| code | label        | decode support in this port                  |
|------|--------------|----------------------------------------------|
| 0    | Uncompressed | ✅ pure Python                                |
| 1    | Rle (PackBits)| ✅ pure Python                               |
| 2    | Zip          | ✅ gzip members via stdlib zlib (writer emits gzip; zlib streams tolerated on read) |
| 3    | Lzvn         | ❌ not implemented                            |
| 4    | Lzfse        | ✅ via Rust sidecar (`lzfse_rust`)            |
| 5–10 |              | ❌ not implemented                            |
| 11   | Deepmap2     | ❌ not implemented (fine: present in G1/G2 but only needed for their bundled art) |

The writer emits **compression 0 (raw)** or **2 (gzip)** — the crate
decodes both (`car/src/decode.rs` treats code 2 as MultiGzDecoder, so the
bytes must be gzip, not raw zlib).

## 7. Writer strategy (compiler)

The writer (`coreui_car/writer.py`) reconstructs the container exactly like the
observed files. Emission order (no forward references are needed because
key/CSI blocks are allocated before the leaf that references them):

```
CARHEADER block                    → var CARHEADER
rendition key blocks (sorted by raw key bytes)
rendition CSI blocks
RENDITIONS leaf path node          → var RENDITIONS
facet name key blocks, facet token blocks
FACETKEYS leaf                     → var FACETKEYS
[APPEARANCEKEYS tree]              → var APPEARANCEKEYS (only if added)
KEYFORMAT                          → var KEYFORMAT
EXTENDED_METADATA                  → var EXTENDED_METADATA
BITMAPKEYS tree + leaf + value     → var BITMAPKEYS (dangling key id kept)
```

Index slots: `max(256, block_count+1)`, 20-byte trailing pad. Blocks start
at offset 512 and are 16-byte aligned. Vars table, gap, index at EOF.

## 8. Verification

```sh
# build a fresh flat AppIcon catalog (raw BGRA, 120×120 @2x)
python3 tools/car/build_car.py --output /tmp/opencode/AppIcon.car

# gate: the Rust reference crate must parse it
/tmp/opencode/car-parser/target/release/car-cli info /tmp/opencode/AppIcon.car
#   → Name AppIcon, Rendition Name AppIcon60x60@2x.png,
#     ARGB 120×120, Scale 2, Compression Uncompressed

# full suite: G1/G2 summaries, G1 structural round trip, build + car-cli
python3 tools/car/test_car.py
```

Structural round trip (implemented in the test): parse G1 → rebuild every
block with the writer (reusing rendition keys/CSI/facet bytes verbatim) →
re-parse → `Car.to_dict()` equality. The rebuilt file passes this check,
which pins down BOM layout, tree wrappers, CSI/TLV serialization, facet
tokens and the dangling-BITMAPKEYS-key reproduction all together.

## 9. Open risks / unknowns

* **BITMAPKEYS record semantics** — opaque; copied verbatim. The crate
  never reads it, and the dangling key ids (e.g. `0x989A`) are reproduced
  exactly.
* **Meta platform strings** — `DeploymentPlatformVersion` etc. were taken
  from one build; other platforms (iOS/tvos) presumably use different
  strings, which is untested against real `actool` output.
* **Deepmap2 / LZFSE encode paths** are not part of the writer (decoding
  LZFSE is provided via the sidecar; Deepmap2 encode would require
  reimplementing Apple's deep-map codec).
* **`image_size = points//128`** heuristic in the icon TLV profile comes
  from G2 observations only.
* **KeyFormat unknown attributes** beyond tag ≤27 are passed through but
  their value semantics are unverified.
* **APPEARANCEKEYS** record layout is opaque 4 bytes; appearance variants
  are untested end-to-end.
