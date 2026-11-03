# claude-bridge (v0)

Turbo IO の `codex-bridge` と同じ HTTP 面（プロトコル）を持つ、Muse 用の最小ブリッジ。
スマホ側（Codex コンソール / CodexPush）からは codex-bridge と同じに見える。

## HTTP 面（Bearer トークン必須、token-file は 0600）
- `GET  /v1/state` — 状態スナップショット（tasks / events）
- `POST /v1/message` `{taskId?, text, requestId}` — タスク送信
- `POST /v1/stop` `{taskId, requestId}` — 停止
- `POST /v1/decision` — v0 では常に 409（承認リクエストを発行しない＝自動承認しない）
- `POST /v1/push` `{title, content, requestId}` — Muse → グラス通知（追加エンドポイント）

## バックエンド (v0: ファイル inbox/outbox)
- タスクは `dataDir/inbox/<taskId>.json` に書かれる
- `dataDir/replies/<taskId>.json` に `{"text": "..."}` を書くと、その内容でタスクが完了し、
  完了イベント（グラス通知）が snapshot に載る
- 返信者: Muse（せっけん）/ 人 / 将来の Claude Agent SDK ランナー
- `--stub` を付けると自動応答で疎通確認できる

## 起動例 (Mac Studio)
```
node claude-bridge/bridge.mjs --token-file ~/.claude-bridge-token --port 8788 --data-dir ~/.claude-bridge-data
```
既定は 127.0.0.1 のみ待受（リモートは TLS 必須の方針は codex-bridge と同じ）。
iPhone から到達させる方法（Tailscale / LAN + TLS）は接続フェーズで決める。

## 状態 (2026-11-03)
- Mac Studio で常駐起動し、認証・state・message→inbox→reply→完了イベント・push を curl で検証済み
- 残: 眼鏡ペアリング後のアプリ接続設定、Claude Agent SDK による自動返信化
