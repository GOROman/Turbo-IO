# Strix OS ファームウェア ライブラリ / インベントリ

RayNeo iO（国際版, BES2800）用 Strix OS の収集済みファームウェア一式。
実機の稼働版は **1.0.2.12**（アプリ経由の状態読み取り `glasses.firmwareVersion = Strix OS 1.0.2.12` で確認）。
各版とも OtaFileInfo.json の Size/MD5 と実ファイルの照合済み（「照合」欄）。

| 版 | 入手元 | ファイル数 | nuttx_ap.bin サイズ | nuttx_ap.bin SHA-256 | 照合 | 備考 |
|---|---|---|---|---|---|---|
| 1.0.2.12 | 公式アプリ OTA キャッシュ（iPhone 内 com.rayneo.venus.dev の Documents/ota/Strix_OS_1.0.2.12 を CoreDevice 経由で Mac にコピー） | 15+清単 | 9,280,676 | 39b4046a1eb64d510bf21d8dde43dcfa8ad60e6e8e144aec816637bcea030b54 | 15/15 OK | **実機稼働版と同版**。この版のみ nuttx_ota.bin (622,408) を含む |
| 1.0.4.12 | 公式アプリ OTA キャッシュ（同上 Strix_OS_1.0.4.12）＋ GitHub Release (Turbo1123/Turbo-IO, stock-strix-1.0.4.12-archive) の REPACK zip | 15+清単 | 9,466,560 | 53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988 | 15/15 OK（両経路で全ファイル一致） | REPACK zip SHA-256: 54eb155b1b9980c0334005c2051720879204b6b5448180ee594eb735b92e905a。archive.py verify 済み。実機にはダウンロードされたが未適用（実機は 1.0.2.12 のまま） |
| 1.0.5.5 | GitHub Release (Turbo1123/Turbo-IO, firmware-strix-1.0.5.5-tmig1) の original zip（リポジトリ内 stock/ にも同一物を保管） | 15+清単 | 7,208,648 | b3d6d9d7a4ece97e1dbaa64fc080eb5db8a5f7c9fecf340888ebb97a9112cc6c | 15/15 OK | zip SHA-256: 2927917f976ef3c9b183253e2342a7a0c85a3e454e973876100f3158da5ec367。この版のみ bt_controller.bin (625,364) を含み、nuttx_ota.bin は無い |

## ケース用ファームウェア
- `cb_fw_venus.bin`（114,592 bytes, SHA-256 8799f12071bdac082218e3601c24ab0989275fc2f7db74e37b8314a225c2cf7d）は **3版すべてで同一**。自己申告 V1.1.42、N32G4FR + RT-Thread。詳細は `CASE.md`。

## 版間で同一のペイロード（抜粋）
- cb_fw_venus.bin / fac_test_img.bin (18eb0901…) / rives.bin (836bc019…) / pil_algo_wakeup_dll_nand.dll (d1594cb8…) は 1.0.2.12 と 1.0.4.12 で同一（fac/rives/wakeup は 1.0.5.5 でも同一）。

## 差分・逆アセンブル
- 版間差分は VERSION-DIFF.md、ケース解析は CASE.md、逆アセンブル成果物は各版の disasm/ フォルダ（DISASM.md 参照）。

## 含まれないもの
- 整機フラッシュのダンプ、デバイス固有の校正/バインディング情報、ユーザーデータ、NAND ユーザー領域。これらは OTA パッケージには元々含まれず、実機からの吸い出し経路も確認できていない（解析メモ参照）。
