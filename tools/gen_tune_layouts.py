#!/usr/bin/env python3
"""Generate shared/tune/TuneLayouts.mc: where the tune fields sit in each Refloat release's config.

A Refloat config travels as `[signature:u32][field][field]...`, fields in the XML's <SerOrder>, each
a fixed width decided by its type and transmit type (VESC Tool `ConfigParams::getParamSerial`). The
signature is VESC Tool's CRC32C over every serialized field's name, type, transmit type and enum
names (`ConfigParams::getSignature`), so it identifies the layout exactly.

The watch cannot read the schema from the board (it is sent zlib-compressed), so this script reads
`src/conf/settings.xml` from every Refloat release on GitHub and emits, per signature, the config
length and the byte ranges of the tune fields. A tune is the fields in the subgroups listed in
TUNE_SUBGROUPS: how the board rides, not its lights, battery, faults or remote.

Run: python3 tools/gen_tune_layouts.py
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "lukash/refloat"
TUNE_SUBGROUPS = ["Tune", "Tune Modifiers", "ATR"]
OUT = Path(__file__).resolve().parent.parent / "watch" / "source" / "tune" / "TuneLayouts.mc"

# VESC Tool datatypes.h
CFG_T_DOUBLE, CFG_T_INT, CFG_T_QSTRING, CFG_T_ENUM, CFG_T_BOOL, CFG_T_BITFIELD = 1, 2, 3, 4, 5, 6
TX_WIDTH = {1: 1, 2: 1, 3: 2, 4: 2, 5: 4, 6: 4, 7: 2, 8: 4, 9: 4}


def fetch(url):
    # curl uses the system certificate store, which a python.org Python may not have set up.
    return subprocess.run(["curl", "-fsSL", url], check=True, capture_output=True).stdout


def crc32c(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 & -(crc & 1))
    return ~crc & 0xFFFFFFFF


def parse(xml):
    params = {}
    body = re.search(r"<Params>(.*?)</Params>", xml, re.S).group(1)
    for m in re.finditer(r"<([A-Za-z0-9_.]+)>\s*<longName>(.*?)</\1>", body, re.S):
        name, inner = m.group(1), m.group(2)
        field = lambda tag: (re.search(rf"<{tag}>(.*?)</{tag}>", inner, re.S) or [None, None])[1]
        params[name] = {
            "type": int(field("type") or 0),
            "vTx": int(field("vTx") or 0),
            "enumNames": re.findall(r"<enumNames>(.*?)</enumNames>", inner, re.S),
        }
    order = re.findall(r"<ser>(.*?)</ser>", re.search(r"<SerOrder>(.*?)</SerOrder>", xml, re.S).group(1))
    tune = []
    grouping = re.search(r"<Grouping>(.*?)</Grouping>", xml, re.S).group(1)
    for sub in re.finditer(r"<subgroup>(.*?)</subgroup>", grouping, re.S):
        if re.search(r"<subgroupName>(.*?)</subgroupName>", sub.group(1)).group(1).strip() in TUNE_SUBGROUPS:
            tune += [p for p in re.findall(r"<param>(.*?)</param>", sub.group(1)) if not p.startswith("::")]
    return params, order, tune


def signature(params, order):
    text = ""
    for name in order:
        text += name
        p = params.get(name)
        if p:
            text += f"{p['type']}{p['vTx']}" + "".join(unescape(n) for n in p["enumNames"])
    return crc32c(text.encode("utf-8"))


def unescape(s):
    return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'").replace("&amp;", "&")


def width(p):
    if p["type"] == CFG_T_DOUBLE:
        return TX_WIDTH[p["vTx"]]
    if p["type"] == CFG_T_INT:
        return TX_WIDTH[p["vTx"]]
    if p["type"] in (CFG_T_ENUM, CFG_T_BOOL, CFG_T_BITFIELD):
        return 1
    raise ValueError(f"variable-width field type {p['type']}")


def layout(params, order, tune):
    """Config length (after the signature) and merged [offset, length] ranges of the tune fields."""
    offset, ranges = 0, []
    for name in order:
        w = width(params[name])
        if name in tune:
            if ranges and ranges[-1][0] + ranges[-1][1] == offset:
                ranges[-1][1] += w
            else:
                ranges.append([offset, w])
        offset += w
    return offset, ranges


def check_signature_algorithm():
    """VESC Tool generated 32903057 for the package library's example config."""
    xml = fetch(f"https://raw.githubusercontent.com/{REPO}/main/vesc_pkg_lib/examples/config/conf/settings.xml").decode()
    params, order, _ = parse(xml)
    got = signature(params, order)
    if got != 32903057:
        sys.exit(f"signature algorithm mismatch: {got} != 32903057")


def main():
    check_signature_algorithm()
    tags = [t["name"] for t in json.loads(fetch(f"https://api.github.com/repos/{REPO}/tags?per_page=100"))]
    layouts = {}
    for tag in tags:
        if tag.startswith("testing"):
            continue
        try:
            xml = fetch(f"https://raw.githubusercontent.com/{REPO}/{tag}/src/conf/settings.xml").decode()
        except Exception as error:
            print(f"skip {tag}: {error}")
            continue
        params, order, tune = parse(xml)
        missing = [t for t in tune if t not in order]
        if missing:
            sys.exit(f"{tag}: tune fields not serialized: {missing}")
        sig = signature(params, order)
        length, ranges = layout(params, order, tune)
        entry = layouts.setdefault(sig, {"length": length, "ranges": ranges, "tags": [], "fields": len(tune)})
        if entry["length"] != length or entry["ranges"] != ranges:
            sys.exit(f"{tag}: same signature, different layout")
        entry["tags"].append(tag)
        print(f"{tag}: signature {sig}, {length} bytes, {len(tune)} tune fields in {len(ranges)} ranges")

    lines = [
        "import Toybox.Lang;",
        "",
        "// Generated by tools/gen_tune_layouts.py from Refloat's settings.xml. Do not edit.",
        "",
        "//! Where the tune fields (" + ", ".join(TUNE_SUBGROUPS) + ") sit in a Refloat config, per config",
        "//! signature. Offsets count from the first byte after the signature.",
        "module TuneLayouts {",
        "    //! [config length, [offset, length, offset, length, ...]], or null for an unknown layout.",
        "    function find(signature as Number) as [Number, Array<Number>] or Null {",
    ]
    for sig, entry in sorted(layouts.items(), key=lambda kv: kv[1]["tags"][-1]):
        signed = sig - (1 << 32) if sig >= 1 << 31 else sig
        flat = ", ".join(str(n) for r in entry["ranges"] for n in r)
        lines.append(f"        // {', '.join(reversed(entry['tags']))}")
        lines.append(f"        if (signature == {signed}) {{")
        lines.append(f"            return [{entry['length']}, [{flat}]];")
        lines.append("        }")
    lines += ["        return null;", "    }", "", "    //! Refloat releases each signature belongs to, for messages.", "    function releases(signature as Number) as String? {"]
    for sig, entry in layouts.items():
        signed = sig - (1 << 32) if sig >= 1 << 31 else sig
        tags = sorted(t.lstrip("v") for t in entry["tags"])
        lines.append(f"        if (signature == {signed}) {{ return \"{tags[0]}{'-' + tags[-1] if len(tags) > 1 else ''}\"; }}")
    lines += ["        return null;", "    }", "}", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines))
    print(f"wrote {OUT} ({len(layouts)} layouts)")


if __name__ == "__main__":
    main()
