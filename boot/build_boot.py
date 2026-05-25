#!/usr/bin/env python3
"""Build an OS9Boot file: take a pristine NitrOS-9 boot, drop unused
modules to make room, and append our scwpt driver + /wt /wt1 /wt2
descriptors.  The boot file must fit in a contiguous 121 sectors
(30976 bytes) on the target disk or os9 gen will refuse it.
"""
import argparse
import sys
from pathlib import Path

# Stock NitrOS-9 modules not needed by this telnet bridge.  Dropping
# them frees enough boot-file room for our additions.
DROP = {
    "N", "Z1", "Z2", "Z3", "Z4", "Z5", "Z6", "Z7",
    "MIDI", "N4", "N5", "N6", "N7", "N8", "N9",
    "N10", "N11", "N12", "N13", "RAMD", "R0",
    "W6", "W7", "p",
}


def split_modules(blob: bytes):
    i = 0
    while i < len(blob) - 5:
        if blob[i] == 0x87 and blob[i + 1] == 0xCD:
            size = (blob[i + 2] << 8) | blob[i + 3]
            name_off = (blob[i + 4] << 8) | blob[i + 5]
            name = ""
            j = i + name_off
            while j < len(blob):
                c = blob[j]
                name += chr(c & 0x7F)
                if c & 0x80:
                    break
                j += 1
            yield name, blob[i : i + size]
            i += size
        else:
            i += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pristine", required=True, help="stock NitrOS-9 OS9Boot to base on")
    ap.add_argument("--out", required=True, help="output boot file")
    ap.add_argument("modules", nargs="+", help="assembled .mod files to append")
    args = ap.parse_args()

    # Gather modules we're about to add - skip any with the same name
    # in the pristine so the script is idempotent against a previously
    # modified boot.
    appended = []
    add_names = set()
    for path in args.modules:
        data = Path(path).read_bytes()
        for n, _ in split_modules(data):
            add_names.add(n)
        appended.append(data)

    pristine = Path(args.pristine).read_bytes()
    out = bytearray()
    kept = []
    for name, mod in split_modules(pristine):
        if name in DROP or name in add_names:
            continue
        out += mod
        kept.append(name)
    for data in appended:
        out += data
        for n, _ in split_modules(data):
            kept.append(n)

    Path(args.out).write_bytes(out)
    sectors = (len(out) + 255) // 256
    print(
        f"boot: {len(out)} bytes = {sectors} sectors, {len(kept)} modules",
        file=sys.stderr,
    )
    if sectors > 121:
        print(
            "WARNING: boot exceeds 121 sectors - os9 gen will report 'fragmented'",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
