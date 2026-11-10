#!/usr/bin/env python3
"""Build Assets.car from the project's grid + pencil icon artwork.

Uses the standalone ``coreui-car`` project (sibling directory
``~/Projects/coreui-car``) — a pure-Python CoreUI asset-catalog compiler —
to emit a catalog byte-mirroring the AppIcon facet of a real Xcode-built
iOS app catalog:

  * one facet ``AppIcon`` (matches Info.plist CFBundleIconName), holding
    a MultisizeImage "holder" rendition named ``AppIcon`` (Part 218)
    whose SISM payload points at the 1024 pt entry, plus the concrete
    ``AppIcon_1024.png`` rendition (Part 220);
  * KeyFormat token order [7 ThemeAppearance, 13 Localization, 12 Scale,
    15 Idiom, 16 Subtype, 9 Dimension2, 8 Dimension1, 24 DisplayGamut,
    21 VerticalSizeClass, 17 Identifier, 1 Element, 2 Part] — the exact
    order actool writes for iOS app catalogs;
  * MLEC payload is the real chunked shape: version 3 (light) / 1 (dark),
    compression 2 = gzip members, KCBC chunks of 341 pixel rows + tail
    (MLEC v0 bare payloads are ignored by on-device CoreUI);
  * rendition + facet Identifier < 0x8000 (a value >= 0x8000 reads
    negative as signed int16 and the icon falls back to a placeholder);
  * APPEARANCEKEYS names are the CoreUI ground-truth strings
    ``UIAppearanceAny`` (bits 0x0000), ``UIAppearanceDark`` (0x0001) and
    ``ISAppearanceTintable`` (0x000a);
  * deployment platform ``ios`` with version 15.0 so iOS CoreUI treats
    the catalog as a first-class iOS catalog; header fields copied from
    the proven on-device ground truth (CoreUI 971, key semantics 2).

Regenerate via: python3 tools/car/make_icon_car.py
"""
import gzip
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))   # /home/.../Projects/worsegestalt
sys.path.insert(0, os.path.dirname(HERE))       # tools/ (preview_icon)
sys.path.insert(0, os.path.abspath(os.path.join(ROOT, "..", "coreui-car")))
                                                # sibling project (coreui_car)

from preview_icon import flat, render          # noqa: E402

from coreui_car.decode import gzip_compress         # noqa: E402
from coreui_car import structs as S             # noqa: E402
from coreui_car import blocks                   # noqa: E402
from coreui_car.writer import (Appearance, BuildOptions,   # noqa: E402
                           builder_from_options)
from coreui_car.blocks import (FacetToken, CSIHeader, Flags, Slice, Metric,  # noqa: E402
                           TlvSlices, TlvMetrics, TlvBlendModeOpacity,
                           TlvEXIFOrientation, TlvBytesPerRow)

# Attribute-token order of a real iOS app catalog (see header docstring).
IOS_KEY_TOKENS = [7, 13, 12, 15, 16, 9, 8, 24, 21, 17, 1, 2]
TOK = {name: idx for idx, name in enumerate(
    ("appearance", "localization", "scale", "idiom", "subtype",
     "dimension2", "dimension1", "gamut", "vsize", "identifier",
     "element", "part"))}

APPEARANCE_ANY = 0
APPEARANCE_DARK = 1
IDIOM_PHONE = 1

FACET_NAME = "AppIcon"
HOLDER_NAME = "AppIcon"
CONTENT_NAME = "AppIcon_1024.png"
DARK_NAME = "AppIcon_1024_dark.png"
IDENTIFIER = 0x4321   # facet + renditions share the Identifier attribute;
                      # must stay < 0x8000 — a value >= 0x8000 is negative
                      # as signed int16 and the icon falls back to a
                      # placeholder (empirically isolated).
ELEMENT = 85
PART_HOLDER = 218
PART_CONTENT = 220

# MLEC payload shape of the ground truth: version 3 (light), 1 (dark),
# compression 2 = gzip members, KCBC chunks of 341 pixel rows + tail.
MLEC_VERSION_LIGHT = 3
MLEC_VERSION_DARK = 1
MLEC_COMP_GZIP = S.COMP_GZIP
KCBC_CHUNK_ROWS = 341
KCBC_TAG = b"KCBC"


def build_mlec_payload(pixels: bytes, width: int, version: int = MLEC_VERSION_LIGHT) -> bytes:
    """MLEC v1/v3 payload exactly like the ground truth: a counted list of
    KCBC chunks, each a gzip member of ``rows * width * 4`` BGRA bytes
    (3 strips of 341 rows + a 1-row tail for 1024x1024)."""
    assert len(pixels) == width * width * 4
    row_bytes = width * 4
    n_rows = width
    h = KCBC_CHUNK_ROWS
    chunks = []
    off = 0
    while n_rows > 0:
        rows = min(h, n_rows)
        chunks.append((rows, gzip_compress(pixels[off:off + rows * row_bytes])))
        off += rows * row_bytes
        n_rows -= rows
    return blocks.build_theme_payload_multi(MLEC_COMP_GZIP, chunks, version=version,
                                            tag=KCBC_TAG)


def artwork_pixels(size: int, mode: str = "light") -> bytes:
    """BGRA pixel buffer of the project artwork in the given appearance."""
    rows = render(size, mode, flat((0.95, 0.95, 0.97)), crop=False)
    pixels = bytearray(size * size * 4)
    for y, row in enumerate(rows):
        data = row[1:]  # strip the PNG filter byte
        for x in range(size):
            r, g, b, a = data[x * 4:x * 4 + 4]
            i = (y * size + x) * 4
            pixels[i] = b  # BGRA memory order
            pixels[i + 1] = g
            pixels[i + 2] = r
            pixels[i + 3] = a
    return bytes(pixels)


def key_values(*, appearance: int, idiom: int, scale: int, dimension2: int,
               part: int, identifier: int = IDENTIFIER) -> list:
    """Rendition-key u16s ordered per IOS_KEY_TOKENS."""
    values = {t: 0 for t in IOS_KEY_TOKENS}
    values.update({
        7: appearance,       # ThemeAppearance
        12: scale,           # Scale
        15: idiom,           # Idiom (1 = phone)
        9: dimension2,       # Dimension2 (0 = multisize holder, 1 = content)
        17: identifier,      # Identifier (facet grouping key)
        1: ELEMENT,          # Element
        2: part,             # Part (218 holder / 220 content)
    })
    return [values[t] for t in IOS_KEY_TOKENS]


def build_sism_payload(entries) -> bytes:
    """'SISM' multisize image-set payload: version 1, one entry each
    (width, height, index, idiom) — byte-parallel to the ground truth."""
    out = b"SISM" + struct.pack("<2I", 1, len(entries))
    for width, height, index, idiom in entries:
        out += struct.pack("<2I2H", width, height, index, idiom)
    return out


def build_holder_csi(identifier: int) -> bytes:
    """MultisizeImage rendition 'AppIcon' (Part 218): the icon-set holder
    whose SISM payload declares one 1024x1024 entry (index 1, any idiom)."""
    tlvs = [
        TlvBlendModeOpacity(0, 0.0),
        TlvEXIFOrientation(1),
    ]
    csi = CSIHeader(
        version=1,
        flags=Flags(),
        width=0,
        height=0,
        scale_factor=0,                 # real holder CSI scale is 0 (only the
                                        # key attribute Scale=1 matters)
        encoding=b"\x00\x00\x00\x00",   # encoding None (holder carries none)
        color_model=0,                  # ColorModel None
        modification_time=0,
        layout_type=S.LayoutType.MultisizeImage.value,
        name=HOLDER_NAME,
        tlv_length=0,
        bitmap_count=1,
        _bitmap_zero=0,
        rendition_length=0,
        tlvs=tlvs,
        payload=None,
    )
    csi.payload = build_sism_payload([(1024, 1024, 1, 0)])
    return blocks.build_csi_block(csi)


def build_content_csi(name: str, pixels: bytes, width: int, height: int,
                      version: int = MLEC_VERSION_LIGHT) -> bytes:
    """Concrete icon rendition (Part 220, OnePartScale) with the exact TLV
    profile of the ground-truth 1024 renditions."""
    tlvs = [
        TlvSlices([Slice(0, 0, width, height)]),
        TlvMetrics(Metric(0, 0), Metric(0, 0), Metric(width, height)),
        TlvBlendModeOpacity(0, 1.0),
        TlvEXIFOrientation(1),
        TlvBytesPerRow(width * 4),
    ]
    csi = CSIHeader(
        version=1,
        flags=Flags(),
        width=width,
        height=height,
        scale_factor=100,
        encoding=b"BGRA",
        color_model=S.COLORMODEL_RGB,
        modification_time=0,
        layout_type=S.LayoutType.OnePartScale.value,
        name=name,
        tlv_length=0,
        bitmap_count=1,
        _bitmap_zero=0,
        rendition_length=0,
        tlvs=tlvs,
        payload=None,
    )
    csi.payload = build_mlec_payload(pixels, width, version=version)
    return blocks.build_csi_block(csi)


def main() -> int:
    opts = BuildOptions(
        deployment_platform="ios",
        deployment_platform_version="15.0",
        version_string="Xcode 26.1.1 (17B100) via AssetCatalogSimulatorAgent",
        authoring_tool="@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.2  [IIO-2784.1.3.3]",
        # header fields copied verbatim from the ground-truth catalog that
        # installs with a visible icon on this device
        coreui_version=971,
        main_version_string="@(#)PROGRAM:CoreUI  PROJECT:CoreUI-971.6",
        key_semantics=2,
    )
    builder = builder_from_options(opts, key_tokens=IOS_KEY_TOKENS)

    builder.add_appearance(Appearance("UIAppearanceAny", b"\x00\x00"))
    builder.add_appearance(Appearance("UIAppearanceDark", b"\x01\x00"))
    # also present in the ground truth even for light+dark-only icons
    builder.add_appearance(Appearance("ISAppearanceTintable", b"\x0a\x00"))

    builder.add_raw_facet(FACET_NAME, blocks.build_facet_token(
        FacetToken(0, 0, [(1, ELEMENT), (2, PART_CONTENT), (17, IDENTIFIER)])))

    # holder: MultisizeImage set (Part 218, Dimension2 = 0 -> holder ranking)
    builder.add_raw_rendition(
        blocks.encode_key_values(key_values(
            appearance=APPEARANCE_ANY, idiom=IDIOM_PHONE, scale=1,
            dimension2=0, part=PART_HOLDER)),
        build_holder_csi(IDENTIFIER))

    # light 1024 content
    light = artwork_pixels(1024, "light")
    builder.add_raw_rendition(
        blocks.encode_key_values(key_values(
            appearance=APPEARANCE_ANY, idiom=IDIOM_PHONE, scale=1,
            dimension2=1, part=PART_CONTENT)),
        build_content_csi(CONTENT_NAME, light, 1024, 1024))

    # dark 1024 content (ThemeAppearance 1) — ground truth uses MLEC v1 here
    dark = artwork_pixels(1024, "dark")
    builder.add_raw_rendition(
        blocks.encode_key_values(key_values(
            appearance=APPEARANCE_DARK, idiom=IDIOM_PHONE, scale=1,
            dimension2=1, part=PART_CONTENT)),
        build_content_csi(DARK_NAME, dark, 1024, 1024, version=MLEC_VERSION_DARK))

    data = builder.build()
    out = os.path.normpath(os.path.join(HERE, "..", "..", "Assets.car"))
    with open(out, "wb") as fh:
        fh.write(data)
    n = 3  # holder + light + dark
    print(f"wrote {out}: {len(data)} bytes, {n} renditions, facet '{FACET_NAME}'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
