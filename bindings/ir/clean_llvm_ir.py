#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def drop_metadata_refs(line, metadata_ids):
    start = line.find("!{")
    end = line.find("}", start)
    if start == -1 or end == -1:
        return line

    prefix = line[: start + 2]
    suffix = line[end:]
    items = [item.strip() for item in line[start + 2 : end].split(",")]
    items = [item for item in items if item and item not in metadata_ids]
    return prefix + ", ".join(items) + suffix


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: clean_llvm_ir.py <input.ll> <output.ll>")

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    lines = src.read_text().splitlines()

    reflect_ids = {
        line.split(" ", 1)[0]
        for line in lines
        if '"nvvm-reflect-ftz"' in line and re.match(r"^!\d+ = !\{", line)
    }

    out = []
    for line in lines:
        if '"nvvm-reflect-ftz"' in line:
            continue
        if reflect_ids and line.startswith("!llvm.module.flags = "):
            line = drop_metadata_refs(line, reflect_ids)
        if line.startswith("define"):
            line = re.sub(r" align [0-9]+", "", line)
        out.append(line)

    dst.write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
