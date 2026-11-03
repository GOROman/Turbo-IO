#!/usr/bin/env python3
"""Extract the embedded symbol table from a Strix OS nuttx_ap.bin.

Format (reverse-engineered from the 1.0.4.12 ground-truth pair):
  records of 8 bytes {name_ptr u32, addr u32}, sorted by addr.
  name_ptr points into a string segment whose file offset = name_ptr - B,
  where B is constant per image. B is derived from the Boot_Loader anchor:
  the lowest-address record is Boot_Loader in every observed build.
Output: JSON {flash, base_B, count, entries:[{name,address,tableOffset}]}.
"""
import struct, json, sys

FLASH = 0x10190000

def find_records(data):
    n = len(data)
    def np_ok(v): return 0x18000000 <= v < 0x18300000
    def ad_ok(v): return (FLASH <= v < FLASH + n) or (0x20000000 <= v < 0x24000000) or (0x02000000 <= v < 0x03000000)
    def ok(o):
        if o + 8 > n: return False
        a, b = struct.unpack_from("<2I", data, o)
        return np_ok(a) and ad_ok(b)
    runs = []
    o = 0
    while o < n - 8:
        if ok(o):
            s = o; bad = 0
            while o < n - 8:
                if ok(o): bad = 0
                else:
                    bad += 1
                    if bad > 4: break
                o += 8
            runs.append((s, o - bad * 8))
        else:
            o += 4
    return runs

def main(path, out):
    data = open(path, "rb").read()
    runs = find_records(data)
    runs.sort(key=lambda r: r[1] - r[0], reverse=True)
    s, e = runs[0]
    recs = []
    for o in range(s, e, 8):
        np_, ad = struct.unpack_from("<2I", data, o)
        recs.append((np_, ad, o))
    # string base B from Boot_Loader anchor (lowest flash addr record)
    flash_recs = [r for r in recs if FLASH <= r[1] < FLASH + len(data)]
    first = min(flash_recs, key=lambda r: r[1])
    off = data.find(b"Boot_Loader\x00")
    assert off >= 0, "Boot_Loader not found"
    B = first[0] - off
    def name(np_):
        so = np_ - B
        if so < 0 or so >= len(data): return None
        end = data.find(b"\x00", so)
        if end < 0 or end - so > 250: return None
        try: return data[so:end].decode("ascii")
        except Exception: return None
    entries, bad = [], 0
    for np_, ad, o in recs:
        nm = name(np_)
        if nm is None: bad += 1; continue
        entries.append({"name": nm, "address": ad, "tableOffset": o})
    doc = {"binary": path.split("/")[-1], "flash": hex(FLASH), "stringBase": hex(B),
           "tableRegion": [s, e], "count": len(entries), "unresolved": bad, "entries": entries}
    json.dump(doc, open(out, "w"), indent=1)
    print(f"{path}: records={len(entries)} unresolved={bad} B={hex(B)} region={s}-{e}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
