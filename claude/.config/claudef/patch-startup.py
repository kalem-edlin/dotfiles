#!/usr/bin/env python3
"""Build a copy of Claude Code with our startup art in place of its mascot.

usage: patch-startup.py <stock binary> <output binary>

No setting, mod render site, or theme can remove the mascot or draw between the
title and the startup warnings. Native builds run Bun bytecode and ignore edits
to the embedded source, so this makes two edits that keep the file size and all
offsets the same:

- Mascot: empties its strings in the bytecode constants. A UTF-16 constant is
  laid out as [u32 length][u32 hash][chars], and an empty string draws no cells.
- Art: rewrites an unused first child of the startup notice list to draw the
  file named by $CLAUDEF_ART, then clears that one module's bytecode pointer so
  Bun runs its source.
- Title: drops the mascot's box and gap from the title module's source, so the
  title starts at the left edge. That module also runs from source.

The stock binary is never modified. Exits nonzero, leaving nothing behind, when
a build no longer matches. Identifiers are minified differently per release, so
the patterns capture them.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

GLYPHS = "▐▛▜▌▝▘▀▗▖▙▟▄█▞▚"
ANCHOR = "▝▜██████▀".encode("utf-16-le")
SOLID_BODY = "█████".encode("utf-16-le")
# The frames sort together in the constant table, next to the anchor.
WINDOW = 1200
UNIT = b"|".join(re.escape(c.encode("utf-16-le")) for c in GLYPHS + " ")
RUN = re.compile(b"(?:" + UNIT + b")+")

# Blank rows around the art, on top of the one Claude puts below the title.
ROWS_ABOVE_ART = 1
ROWS_BELOW_ART = 2

NOTICE_ANCHOR = b'alignItems:"center",marginTop:1,marginBottom:'
NOTICE_LIST = re.compile(
    rb"=(?P<gate>![\w$]+&&![\w$]+&&![\w$]+&&![\w$]+)\?null:[\w$]+\("
    rb'(?P<box>[\w$]+),\{flexDirection:"column",flexGrow:(?P<flag>[\w$]+)\?1:0,children:\['
    rb"(?P<slot>(?P=flag)&&(?P<jsx>[\w$]+)\([\w$]+\.Provider,\{value:!0,children:(?P=jsx)\((?P=box),"
    rb'\{flexDirection:"column",alignItems:"center",marginTop:1,marginBottom:[^{}]*?'
    rb"children:\([\w$]+\?\?null\)\?\.render\([\w$]+\)\}\)\}\))"
)
TEXT_ELEMENT = re.compile(rb"[\w$]+\((?P<text>[\w$]+),\{bold:!0,children:")
MASCOT_ANCHOR = b",{fullscreen:"
MASCOT_ELEMENT = re.compile(rb"([\w$]+)=[\w$]+\([\w$]+,\{fullscreen:[\w$]+,entrance:[\w$]+,ultra:")

BUN_TRAILER = b"\n---- Bun! ----\n"
OFFSETS_SIZE = 32
MODULE_SIZE = 52
BYTECODE_FIELD = 24


def find_all(data, needle):
    offsets, position = [], 0
    while (offset := data.find(needle, position)) >= 0:
        offsets.append(offset)
        position = offset + 1
    return offsets


def empty_constant(data, offset, chars):
    """Zero a constant's length if its header proves it is that exact string."""
    if offset < 8 or struct.unpack_from("<I", data, offset - 8)[0] != chars:
        return False
    struct.pack_into("<I", data, offset - 8, 0)
    return True


def hide_mascot(data):
    anchors = find_all(data, ANCHOR)
    if not anchors:
        raise ValueError("mascot frames not found")

    emptied = 0
    for anchor in anchors:
        low, high = max(0, anchor - WINDOW), anchor + WINDOW
        for match in RUN.finditer(bytes(data[low:high])):
            text = match.group(0).decode("utf-16-le", "replace")
            if any(c in GLYPHS for c in text):
                emptied += empty_constant(data, low + match.start(), len(text))

    bodies = [o for o in find_all(data, SOLID_BODY) if empty_constant(data, o, 5)]
    if len(bodies) != 1:
        raise ValueError(f"expected one solid body constant, found {len(bodies)}")
    if emptied < 3:
        raise ValueError(f"only {emptied} mascot constants matched")


def module_containing(data, offset):
    """Return (entry offset, contents start, contents end) from Bun's module table."""
    trailer = data.rfind(BUN_TRAILER)
    if trailer < 0:
        raise ValueError("Bun module graph not found")
    header = trailer - OFFSETS_SIZE
    byte_count = struct.unpack_from("<Q", data, header)[0]
    table, table_size = struct.unpack_from("<II", data, header + 8)
    base = header - byte_count
    if table_size % MODULE_SIZE:
        raise ValueError("Bun module table has an unknown layout")
    for entry in range(base + table, base + table + table_size, MODULE_SIZE):
        name, _, contents, size = struct.unpack_from("<IIII", data, entry)
        if data[base + name : base + name + 12] != b"/$bunfs/root":
            raise ValueError("Bun module table has an unknown layout")
        if base + contents <= offset < base + contents + size:
            return entry, base + contents, base + contents + size
    raise ValueError("no module holds that offset")


def draw_art(data):
    matches = []
    for anchor in find_all(data, NOTICE_ANCHOR):
        low, high = max(0, anchor - 400), anchor + 400
        for match in NOTICE_LIST.finditer(bytes(data[low:high])):
            matches.append((low, match))
    if len(matches) != 1:
        raise ValueError(f"expected one startup notice list, found {len(matches)}")
    low, match = matches[0]

    entry, start, end = module_containing(data, low + match.start())
    text = TEXT_ELEMENT.search(bytes(data[start:end]))
    if text is None:
        raise ValueError("text element not found")

    jsx, box = match["jsx"].decode(), match["box"].decode()
    art = (
        f"process.env.CLAUDEF_ART&&{jsx}({box},{{marginTop:{ROWS_ABOVE_ART},marginBottom:{ROWS_BELOW_ART},"
        f"children:{jsx}({text['text'].decode()},{{children:process.getBuiltinModule"
        '("fs").readFileSync(process.env.CLAUDEF_ART,"utf8").trimEnd()})})'
    ).encode()
    slot_start, slot_end = match.span("slot")
    room = slot_end - slot_start
    if len(art) > room:
        raise ValueError(f"art code needs {len(art)} bytes, the slot has {room}")
    data[low + slot_start : low + slot_end] = art.ljust(room)

    # Always draw the list, which is otherwise skipped when it has no notices.
    gate_start, gate_end = match.span("gate")
    data[low + gate_start : low + gate_end] = b"!1".rjust(gate_end - gate_start)

    struct.pack_into("<II", data, entry + BYTECODE_FIELD, 0, 0)
    flush_title(data)


def flush_title(data):
    # Since 2.1.325 the title lives in its own module, apart from the notices.
    # Windowed like draw_art: a whole-file scan of this regex takes ~25 s.
    found = {}
    for anchor in find_all(data, MASCOT_ANCHOR):
        low, high = max(0, anchor - 200), anchor + 200
        for match in MASCOT_ELEMENT.finditer(bytes(data[low:high])):
            found[low + match.start()] = match
    if len(found) != 1:
        raise ValueError(f"expected one startup mascot, found {len(found)}")
    (offset, mascot), = found.items()
    entry, start, end = module_containing(data, offset)
    module = bytes(data[start:end])
    row = re.compile(
        rb'flexDirection:"row",gap:2,alignItems:"center",children:\['
        + re.escape(mascot.group(1))
        + rb",(?P<title>[\w$]+)\]"
    )
    matches = list(row.finditer(module))
    if len(matches) != 1:
        raise ValueError(f"expected one title row, found {len(matches)}")
    match = matches[0]
    title_only = b'flexDirection:"row",children:[' + match["title"] + b"]"
    data[start + match.start() : start + match.end()] = title_only.ljust(len(match[0]))
    struct.pack_into("<II", data, entry + BYTECODE_FIELD, 0, 0)


def sign_like(stock, binary):
    """Ad-hoc sign with the stock entitlements, which include allow-jit."""
    if sys.platform != "darwin":
        return
    plist = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", stock],
        capture_output=True,
        check=True,
    ).stdout
    with tempfile.NamedTemporaryFile(suffix=".plist") as entitlements:
        entitlements.write(plist)
        entitlements.flush()
        subprocess.run(
            ["codesign", "-f", "-s", "-", "--entitlements", entitlements.name, binary],
            capture_output=True,
            check=True,
        )


def main():
    stock, output = Path(sys.argv[1]), Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    data = bytearray(stock.read_bytes())
    hide_mascot(data)
    draw_art(data)

    # Keep the stock file name: it is the process name tmux reports.
    build_dir = Path(tempfile.mkdtemp(dir=output.parent, prefix=".build-"))
    binary = build_dir / output.name
    try:
        binary.write_bytes(data)
        binary.chmod(0o755)
        sign_like(stock, binary)
        expected = subprocess.run([stock, "--version"], capture_output=True, check=True).stdout
        actual = subprocess.run([binary, "--version"], capture_output=True, check=True, timeout=60).stdout
        if actual != expected:
            raise ValueError(f"patched build reports {actual!r}, expected {expected!r}")
        os.replace(binary, output)
    finally:
        shutil.rmtree(build_dir, ignore_errors=True)

    # Each copy is close to 300 MB. Running sessions keep their unlinked copy.
    for other in output.parent.iterdir():
        if other != output and not other.name.startswith(".build-"):
            other.unlink()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"patch-startup: {error}")
