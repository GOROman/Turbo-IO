# 逆アセンブル基盤 — Strix OS 1.0.4.12 nuttx_ap.bin
- ツール: Capstone 5.0.7 (ARM, THUMB+MCLASS), ドライバ tools/disasm_func.py（関数単位）
- ロードベース: flash 0x10190000
- シンボル: 既存研究で抽出済みの全表 35,062 件を symbols.json に収納（フラッシュ内ユニーク関数 31,843）。自分の抽出器 (tools/extract_symbols.py) でも独立に 32,811 件を復元し、既知表と照合して精度 100% を確認
- 成果物: symbols.json / functions.csv / disasm.asm.xz (3,839,918 命令、飛び先注釈付き)
