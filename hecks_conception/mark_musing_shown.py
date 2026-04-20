#!/usr/bin/env python3
"""Mark a musing as shown by setting `conceived: true` on the matching
record in musing.heki. Called from mindstream after surfacing a musing
to the status bar so the same musing doesn't surface again.

Usage:
  ./mark_musing_shown.py "<exact musing idea text>"
"""

import json
import os
import struct
import sys
import zlib

HEKI = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "information", "musing.heki")


def read():
    with open(HEKI, "rb") as f:
        data = f.read()
    if data[:4] != b"HEKI":
        return 0, {}
    count = struct.unpack(">I", data[4:8])[0]
    store = json.loads(zlib.decompress(data[8:]).decode("utf-8"))
    return count, store


def write(count, store):
    j = json.dumps(store, separators=(",", ":")).encode("utf-8")
    c = zlib.compress(j, level=9)
    with open(HEKI, "wb") as f:
        f.write(b"HEKI")
        f.write(struct.pack(">I", count))
        f.write(c)


def main():
    if len(sys.argv) < 2:
        sys.exit(0)
    target = sys.argv[1].strip()
    if not target:
        sys.exit(0)
    count, store = read()
    changed = False
    # The daemon truncates ideas to 80 chars before display, so match by
    # prefix as well as exact.
    for rec in store.values():
        idea = (rec.get("idea") or "").strip()
        if not idea:
            continue
        if idea == target or idea.startswith(target) or target.startswith(idea[:80]):
            if not rec.get("conceived"):
                rec["conceived"] = True
                changed = True
                break
    if changed:
        write(count, store)


if __name__ == "__main__":
    main()
