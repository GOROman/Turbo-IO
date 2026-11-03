# 機能仕様: Muse 連携 / Muse Gadgets 化（Claude Bridge）

Fork: GOROman/Turbo-IO / ブランチ: ja-localization 以降の実装候補
前提: 眼鏡側 CFW は使わない（原廠ファーム + スマホ側機能のみ）

## 目的
RayNeo iO を「Muse とやりとりする入出力デバイス」にする。
グラスで話しかける → スマホ（Turbo IO アプリ）→ Mac Studio 上の Bridge → Muse が処理 → 結果がグラスに表示/通知される。

## ゴール像: Muse Gadgets としてのグラス（2026-11-03 本人希望）
本人の最終イメージは「Muse Gadgets をメガネに入れる」こと。せっけんロボ ミューズ（RDK X5 ロボ）と同じく、デバイスが Muse（せっけん）の入出力として連動する形を目指す。

- グラス単体には Muse を載せられない（BES2800 組み込み、Muse アプリが存在しない）。実現方式は本人の既存パターン（Clip / SwitchBot と同じ）＝ **ホスト経由**：グラス ↔ iPhone ↔ Mac Studio 常駐ブリッジ ↔ Muse。
- Layer 2（Muse Gadgets 連動）: ブリッジに inbox / outbox を持たせる。
  - Muse → グラス: Muse が Mac Studio 上の outbox（ブリッジ API / JSON）に書くと、codex-bridge 互換の push イベントとしてグラスへ通知される。アプリ改修ゼロで開始できる。
  - グラス → Muse: 音声タスクはブリッジがタスクとして保存し、muse@goroman.org 宛メール等で Muse 側へ届ける。Muse の返信が outbox 経由でグラスへ戻る（v0 は準リアルタイムで可）。
- Layer 1（下記・Claude Bridge）はその土台として先に作る。

## 背景（上流の現状）
- 上流 Turbo IO の Agent 連携は Codex のみ実装済み（codex-bridge/bridge.mjs、Mac/PC 側の制限付き HTTP ブリッジ + Codex app-server）。
- Claude Code は上流 README で「未実装・未テスト。Claude Agent SDK または CLI サブプロセスで実装可能」とされている。
- Mac Studio には codex CLI はあるが claude CLI は未導入（2026-11-03 確認）。

## 方式A（第一候補）: codex-bridge 互換の claude-bridge を Mac Studio に置く
- codex-bridge/bridge.mjs の HTTP インターフェース（タスク送信 / 状態照会 / イベント push / 承認フロー）をそのまま模倣した `claude-bridge` を新規実装する。
- バックエンドは Claude Agent SDK（または `claude -p --output-format stream-json` ヘッドレス実行）。
- スマホ側は既存の Codex コンソール画面と CodexPush 通知をそのまま流用し、ブリッジ URL を claude-bridge に向けるだけで動く形を目指す（アプリ改修は最小限：表示名「Codex」→「Agent」汎用化など）。
- 承認が必要な操作は従来どおりスマホ側で確認する。音声だけで高リスク操作を承認させない（上流の安全境界を維持）。

## 方式B（第二候補）: アプリに Anthropic プロバイダを直接追加
- 音声会話のモデルプロバイダとして Anthropic Messages API を追加し、本人の API Key を Keychain に保存。
- PC タスクはできず純粋なチャット用途。方式Aと併用可能。

## 重要な正直な境界
- どちらの方式でも、相手は「本人のアカウントで動く Muse のインスタンス」であって、この Muse（せっけん）のチャットセッションそのものではない（セッションへ外部から接続する API がないため）。
- ただし system prompt に せっけん のペルソナや記憶の要点を持たせることで、体験としての一貫性は近づけられる。

## 必要な本人作業
- Mac Studio への claude CLI / Agent SDK 導入時の Anthropic アカウントログイン（本人操作）。
- API を使う場合は API Key の発行・入力（Keychain / 安全な保管。チャットに貼らない）。

## 実装ステップ（案）
1. bridge.mjs のインターフェースを精査し、claude-bridge の最小実装（タスク送信→完了イベント）を作る
2. Mac Studio でローカル動作確認（curl でタスク投入→完了）
3. スマホの Codex コンソールを claude-bridge に向け、グラス表示と完了 push を実機確認
4. 表示名とツールの汎用化、README 追記
