# 充電ケース (Charging Box / "CB") ファームウェア解析

対象: `cb_fw_venus.bin` — グラス用 OTA パッケージ全版 (1.0.2.12 / 1.0.4.12 / 1.0.5.5) に同梱。
SHA-256 は全版で同一: `8799f12071bdac082218e3601c24ab0989275fc2f7db74e37b8314a225c2cf7d` (114,592 bytes)。
根拠はすべて当該バイナリとグラス側 nuttx_ap.bin (1.0.2.12) の文字列。実機でのケース接続状態の取得は未実施（グラスがケース外のときはケース情報が報告されない）。

## ケース側ハードウェア / RTOS
- MCU: **N32G4FR**（Nations 社 Cortex-M4。文字列 `n32g4fr_adc_convert`）。先頭ベクタ: SP=0x20020000 台 / Reset=0x08028f11 → フラッシュ 0x08000000 台配置。
- RTOS: **RT-Thread**（"2006 - 2019 Copyright by rt-thread team"、rt_adc / rt_pin_irq 等の API 名、MSH コマンド `__cmd_version`）。
- 自己申告バージョン文字列: **`V1.1.42`**。ビルド日文字列: `Jul 21 2026`。
- 役割: 充電制御（USB 充電器の挿抜検出、グラスへの充電、SoC 監視、NTC 温度変換 `convert_to_temp`）、蓋・グラス収納検出、状態機械 `GlassesCase_*`（GlassesIn / GlassesOut / LidClosed / StateSync / Pairing / DVS / OTA 等）。

## ケース ⇔ グラス間リンク
- 物理層: **UART**（グラス側ログ `Charger box plugout open UART failed`、ケース側 `[W/UART]`）。ドック（ポゴピン）経由とみられる。フレームは CRC 付きで同期回復処理あり（`CRC validation failed, discarding frame and attempting sync recovery`）、ハートビートあり（`Charger box RX timer handler, is_heartbeat`）。
- ケース → グラスの電池レポート（グラス側ログ形式）:
  `Batt Report: Battery: %d%%, Charging: %s, Version: v%d.%d.%d, Vendor: 0x%02X, LidStatus: %u`
  拡張版: `Batt Report Response: Batt: %d%%, Charging, Advertising, NeedUpdate, Shutdown, Voltage: %umV, ... SleepMode`
  → 電池残量・充電状態・ケース版数・ベンダ ID・蓋状態・電圧がグラスへ渡る。ケースに "Advertising" 状態とペアリング概念がある（ケース側 `Glasses are in pairing state, Switch to pairing mode` / `retrying Pairing`）。ただし cb_fw 内に BLE スタックの明示文字列は見つかっていない。
- グラス → スマホへの中継: グラス側 BatteryMonitor に `getChargeBoxVersion` / `updateChargeBoxStatus` / `DeviceStatusManager::sendChargeBoxStateCommand` があり、報告 JSON のキーとして `case_state` / `case_in` / `case_out` / `case_software_version` が AP バイナリ内に存在する。**ケース独自の BLE でスマホと直接話す経路は確認できず、報告はグラス経由**。

## ケースの OTA 更新フロー
- グラスはケース用イメージを自 NAND 上に保持: `/mnt/nand_resource/cb_fw_venus.bin`（OTA マニフェストでは BurnMode 3 / BurnPath `cb_fw_venus.bin` でグラスに書き込まれる）。
- グラス側モジュール `cb_fw_source.c`: `cb_fw_source_begin_upgrade / read / tx_checksum / version / end_upgrade` で版数確認しながらチャンク送信。
- ケース側 OTA 状態: "Case need update, Switch to OTA mode" → **Flash-B を消去**（デュアルバンク構成）→ チャンク受信（ACK/再送要求、500ms 無受信で再送 ACK）→ 検証 (`Firmware verified, sending COMPLETE`)。**蓋を開けると OTA 中止** (`[APP OTA] Lid open, abort OTA`)。前提条件: ケース電池残量が十分なこと（グラス側 `Box capacity low for upgrade`）、ケースがアドバタイジング中は開始しない。

## 入手の壁
- ケース用イメージはグラス用 OTA に同梱されるため追加の入手経路は不要だった（上記のとおり確保済み）。
- ケース単体からの読み出し経路（SWD 等）は筐体開封が必要なため未実施。ケース版数のライブ取得はグラスをケースに収納した状態での状態照会が必要。
