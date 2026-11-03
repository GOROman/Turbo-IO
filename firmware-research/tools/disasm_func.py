#!/usr/bin/env python3
"""Per-function disassembly driven by the embedded symbol table.
Usage: disasm_func.py <bin> <symbols.json> <out.asm>
Each function symbol (flash range) is disassembled from its start to the next
symbol start; branch/call targets are annotated with symbol names. Literal pools
at function tails may decode as garbage - they appear after the real code."""
import json, sys
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS

FLASH = 0x10190000

def main(binp, symp, outp):
    data = open(binp, "rb").read()
    d = json.load(open(symp))
    sym = {}
    for e in d["entries"]:
        a = e["address"]
        if FLASH <= a < FLASH + len(data):
            sym.setdefault(a & ~1, e["name"])
    addrs = sorted(sym)
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB + CS_MODE_MCLASS)
    md.skipdata = True
    out = open(outp, "w", buffering=1024 * 1024)
    out.write(f"; {binp} base=0x{FLASH:08x} functions={len(addrs)} mode=per-function\n")
    total = 0
    for i, a in enumerate(addrs):
        end = addrs[i + 1] if i + 1 < len(addrs) else min(a + 4096, FLASH + len(data))
        off, ln = a - FLASH, end - a
        if ln <= 0: continue
        out.write(f"\n{a:08x} <{sym[a]}>:\n")
        for ins in md.disasm(data[off:off + ln], a):
            line = f"{ins.address:08x}  {ins.bytes.hex():<12} {ins.mnemonic:<8} {ins.op_str}"
            if ins.mnemonic.startswith("b") or ins.mnemonic in ("bl", "blx"):
                try:
                    tv = int(ins.op_str.lstrip("#"), 0)
                    if tv in sym: line += f"   ; -> {sym[tv]}"
                except ValueError:
                    pass
            out.write(line + "\n")
            total += 1
    out.close()
    print(f"{binp}: functions={len(addrs)} instructions={total} -> {outp}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
