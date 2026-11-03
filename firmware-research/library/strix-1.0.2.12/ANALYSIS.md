# Strix OS 1.0.2.12（実機稼働版）解析メモ — 読み出し経路と AP/OTA の要点

## 実機からの読み出し経路の評価
- **コンパニオンプロトコル（business 15）**: RnLinkMsgProcessor のハンドラ集合（175 関数）をシンボルで確認した範囲では、フラッシュ/ファイルの読み出し系ハンドラは存在しない。あるのは設定・状態・通知・OTA 書き込み系と、ZIP/差分転送の書き込み系のみ。グラス内ファイル（/account_info.json 等）を電話へ返すコマンドは未確認。
- **実機から実際に取得できたもの**: アプリ経由の状態読み取りで、版数（Strix OS 1.0.2.12）、全設定値（rawGeneralSettings）、ユーザー名ファイルの保存先 (/account_info.json) の存在。いずれも「値の報告」であってイメージの読み出しではない。
- **OTA 機構**: nuttx_ota.bin は OTA ドメイン（OTA-REMAP、norflash リマップ設定のブートローダ同期、factory セクション CRC）。"verify" は工場領域の CRC 検証、"dd_verify" / "Hex dump" は BES トレースシェルのデバッグコマンドであり、コンパニオン経由の読み戻し（readback）機能は見つからなかった。
- **ハードウェア経路（評価のみ、未実施）**: NSH コンソールと工場コマンドは基板側 UART0 (ttyS0) にあり、到達には開封が必要。充電接点（ポゴ）は充電とケース通信の多重ラインで、NSH は出ていない（詳細は同フォルダの POGO-UART.md / GPIO-ASSIGNMENT.md の別途調査）。
- **結論**: 現時点で実機フラッシュの直接読み出し経路は確立していない。代替として、実機稼働版と同版の OTA パッケージ一式（本フォルダ、全ファイル照合済み）が解析に使える。OTA パッケージに含まれないデバイス固有情報（校正/バインディング、NAND ユーザー領域の実データ）は代替できない。

## グラス内ファイルパス（nuttx_ap.bin 文字列より）
- /mnt/nand_resource/cb_fw_venus.bin, fac_test_img.bin, images.bin, lotties.bin（BurnMode 3 の配置先）
- /mnt/nand_data/recordings/recordings_info.json（ライフログ録音の索引）
- /mnt/nand_data/system_stats/system_stats.bin, /mnt/nand_data/pending_batches.bin
- /data/mini_block_board.bin, /data/mini_block_player.bin（a2ui ミニアプリ）
- /widgets_data.json, /glasses_base_v1.json（ダッシュボード/ウィジェット）

## バージョン表記
- NSH バナー: "NuttShell (NSH) NuttX-Strix OS 1.0.2" / "Strix OS 1.0.2"。
