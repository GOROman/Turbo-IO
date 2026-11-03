#!/usr/bin/env python3
"""Linear-sweep Thumb-2 disassembly of a Strix OS nuttx_ap.bin with symbol annotation.
Usage: disasm.py <bin> <symbols.json|none> <out.asm> <sweep_end_offset>
Addresses: vaddr = flash(0x10190000) + file_offset. Annotations: symbol starts and
branch/call targets resolved through the symbol table."""
import json, sys
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS

FLASH = 0x10190000

def main(binp, symp, outp, sweep_end):
    data = open(binp, "rb").read()
    sym = {}
    if symp != "none":
        d = json.load(open(symp))
        for e in d["entries"]:
            a = e["address"]
            if FLASH <= a < FLASH + len(data):
                sym.setdefault(a & ~1, e["name"])
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB + CS_MODE_MCLASS)
    md.detail = False
    md.skipdata = True
    code = data[:sweep_end]
    out = open(outp, "w", buffering=1024 * 1024)
    out.write(f"; {binp} base=0x{FLASH:08x} sweep=[0,{sweep_end}) symbols={len(sym)}\n")
    n = 0
    for ins in md.disasm(code, FLASH):
        a = ins.address
        if a in sym:
            out.write(f"\n{a:08x} <{sym[a]}>:\n")
        line = f"{a:08x}  {ins.bytes.hex():<12} {ins.mnemonic:<8} {ins.op_str}"
        if ins.mnemonic in ("bl", "blx", "b", "b.w", "bne", "beq", "bhi", "blo", "bhs", "bls", "bge", "blt", "bgt", "ble", "cbz", "cbnz"):
            t = ins.op_str.lstrip("#")
            try:
                tv = int(t, 0)
                if tv in sym: line += f"   ; -> {sym[tv]}"
            except ValueError:
                pass
        out.write(line + "\n")
        n += 1
    out.close()
    print(f"{binp}: instructions={n} -> {outp}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 0))
