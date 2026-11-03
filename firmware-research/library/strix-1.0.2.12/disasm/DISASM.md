# 逆アセンブル基盤 — Strix OS 1.0.2.12 (実機稼働版) nuttx_ap.bin
- ツール: Capstone 5.0.7 (ARM, THUMB+MCLASS), tools/.venv, ドライバ tools/disasm_func.py（関数単位）
- ロードベース: flash 0x10190000（ファイルオフセット = アドレス − 0x10190000）
- シンボル: バイナリ内蔵シンボル表を tools/extract_symbols.py で復元（{name_ptr, addr} 8バイト記録、文字列ベース B=0x17fc49e4 を Boot_Loader アンカーで導出）。復元 31,509 件（うちフラッシュ内ユニーク関数 30,524）
- 検証: 抽出手法を 1.0.4.12 の既知シンボル表で検証 → 精度 100% / 再現率 93.5%。本版では handleAccountInfoCommand (0x10711404) が push.w プロローグから正しく復号されることを確認
- 成果物: symbols.json / functions.csv (address,name,size_est) / disasm.asm.xz (関数単位逆アセンブル、飛び先注釈付き、3,772,819 命令)
- cb_fw_disasm.asm.xz: 充電ケース FW (N32G4FR, ベース 0x08000000) の線形スイープ（シンボルなし、49,751 命令）
