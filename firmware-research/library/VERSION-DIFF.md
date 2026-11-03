# Strix OS バージョン間差分（バイナリ解析からの推定変更履歴）

本書は公式の変更履歴ではなく、収集した OTA イメージのバイナリ比較からの推定である。
各項目に確度ラベルを付す: [確定:ハッシュ] [確定:文字列] [確定:構成] [推定:シンボル差分] [推定:サイズ]。
シンボル比較は 1.0.2.12（自前抽出、既知表で精度100%/再現率93.5%を検証）と 1.0.4.12（全表 35,062件）の比較であり、
1.0.2.12 側の抽出漏れが「追加」側に最大で約2千件混入しうる。削除側と大きなクラスタ単位の傾向は信頼できる。
1.0.5.5 は同形式の内蔵シンボル表を持たないため、関数レベルの比較はできていない。

## ペイロード行列（SHA-256 先頭8桁、同一は = で示す）
| ファイル | 1.0.2.12 | 1.0.4.12 | 1.0.5.5 |
|---|---|---|---|
| nuttx_ap.bin | 9,280,676 / 39b4046a | 9,466,560 / 53afdf52 | 7,208,648 / b3d6d9d7 |
| nuttx_audio.bin | 1,464,528 / 6cb228ed | 1,461,920 / 549a72c0 | = 1.0.4.12 |
| nuttx_apc1.bin | 1,388,120 / 876d08a7 | 97d56ffc | 1,423,532 / (相違) |
| nuttx_bth.bin | 1,133,156 / 7e6fa134 | a8f45948 | 1,189,216 / (相違) |
| nuttx_ota.bin | 622,408 / a3b4c5a1 | **なし** | **なし** |
| bt_controller.bin | なし | なし | 625,364 / **新規** |
| cb_fw_venus.bin | 114,592 / 8799f120 | = | = |
| fac_test_img.bin | 1,821,552 / 18eb0901 | = | = |
| rives.bin | 689,431 / 836bc019 | = | = |
| images.bin | 332,724 / 1eabd7de | 192fefaa | 383,431 / (相違) |
| lotties.bin | 872,295 / 737834c3 | ad66d83a | 651,481 / (相違) |
| smf.json | 23,480 / 02bd8457 | 2713dc3a | 23,510 / (相違) |
| pil wakeup dll | d1594cb8 | = | = |
| pil vad dll | d78e549e | 7ac5b519 | (相違) |
| pil up dll | 2362ffbe | e266726f | (相違) |

## 1.0.2.12 → 1.0.4.12 で変わったこと
- [確定:構成] nuttx_ota.bin（OTA ドメインイメージ）がパッケージから消えた。OTA の実装が AP 本体側へ統合された可能性。
- [推定:シンボル差分] **OTA/リソース更新機構の再構築**: RnLinkMsgProcessor に LocalZip 系ハンドラ群（handleLocalZipInstallRequest / PackageInfo / Progress / Done、localZipInstallWorkerEntry 等）と NAND リソース差分転送（prepare/finalizeNandResourceDifferentialTransfer、findNext/LastSliceTransferFileIndex、writeStandbyNandResourceTargetManifest）が追加。逆に cancelPendingModeSetting、finishOtaValidationSuccessSideEffectsAfterAdopt が削除（Adopt 系から Confirm 系へフロー変更を示唆）。
- [推定:シンボル差分] ハンドラ集合は 175 → 198（+26/−3）。追加は上記 OTA ZIP/差分転送と、リモートマイク許可のリクエスト管理（PendingRemoteRequest / RemoteMicrophonePermission 系）に集中。
- [推定:シンボル差分] 通知まわりの増強: rayneo::service::notification +88 関数、CallNotification のスナップショット/マスクアニメーション追加。
- [推定:シンボル差分] Assistant の NLP 表示を増分 append 方式（appendParsedLine 等）から行スロット生成方式（createLineSlot / render*RowChildren）へ再設計。
- [確定:文字列] 天気ウィジェット無効時の更新を無視するログ "ignore weather update for disabled widget" は 1.0.2.12 に無く、1.0.4.12 で追加された。
- [確定:文字列] ユニーク文字列 77,309 → 80,194（集合差分 +12,401 / −9,516）。
- [推定:サイズ] nuttx_ap.bin は +185,884 バイト。
- [確定:文字列] NSH バナーは "NuttX-Strix OS 1.0.4"、SW_VER="Strix OS 1.0.4" を含む。
- ディスパッチ構造: receiveMessage は両版とも BL 60 回・リテラル構成が同型で、骨格に大きな変化なし [推定:逆アセンブル]。数値 type → ハンドラ対応表の 1.0.2.12 側の抽出は未実施（1.0.4.12 側は既存研究で確定済み）。

## 1.0.4.12 → 1.0.5.5 で変わったこと
- [確定:構成] bt_controller.bin（625,364）が新規追加。Bluetooth コントローラ FW の分離/同梱方式が変わった。
- [確定:抽出試行] 内蔵シンボル表が同形式では存在しない（"Boot_Loader" 文字列自体が無い）。よりリーンな、またはストリップされたビルド。
- [確定:文字列] ユニーク文字列 80,194 → 49,304（集合差分 +11,142 / −42,032）。大規模な削減。
- [推定:サイズ] nuttx_ap.bin は −2,257,912 バイト（7,208,648）。
- [確定:文字列] 機能キーワードの出現数変化: navigation 11 → 58（ネイティブナビ関連の増強を示唆）、a2ui 473 → 157（ミニアプリ基盤の縮小）、Focus 313 → 143、didi が新規に出現（3件）。
- [確定:文字列] "ignore weather update for disabled widget" は 1.0.5.5 にも存在する（「1.0.4.12 のみ」という先行理解は誤りで、本調査で訂正）。
- [確定:ハッシュ] nuttx_audio.bin は 1.0.4.12 と同一。cb_fw_venus / fac_test_img / rives / wakeup dll も全版同一（ケース FW は版を通して V1.1.42 のまま）。

## 逆アセンブル基盤（本差分の土台）
| 版 | ベース | シンボル | 関数数 | 成果物 |
|---|---|---|---|---|
| 1.0.2.12 | 0x10190000 | 内蔵表を復元 31,509件 | 30,524 | strix-1.0.2.12/disasm/ |
| 1.0.4.12 | 0x10190000 | 既存全表 35,062件 | 31,843 | strix-1.0.4.12-ota-cache/disasm/ |
| 1.0.5.5 | 0x10190000 | 復元不可（表なし） | — | strix-1.0.5.5/disasm/（線形スイープのみ） |
ツール: Capstone 5.0.7 + tools/disasm_func.py / tools/extract_symbols.py。
