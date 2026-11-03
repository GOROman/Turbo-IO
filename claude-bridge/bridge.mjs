// claude-bridge.mjs — Turbo IO の codex-bridge 互換 HTTP 面を持つ最小ブリッジ。
// スマホ側 (Codex コンソール / CodexPush) からは codex-bridge と同じに見える。
// バックエンドは v0 として「ファイル inbox/outbox」方式:
//   POST /v1/message -> dataDir/inbox/<taskId>.json にタスクを書く
//   dataDir/replies/<taskId>.json が現れたら、その text を回答として完了にする
//   (Muse / 人 / 将来の Claude Agent SDK ランナーが返信ファイルを書く)
// 追加エンドポイント POST /v1/push は Muse -> グラス通知専用 (snapshot の events に載る)。
// 安全境界は codex-bridge に倣う: Bearer トークン必須 (token-file は 0600)、
// 本文サイズ上限、requestId による冪等化、承認は v0 では扱わない (自動承認しない)。
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync, unlinkSync, statSync } from 'node:fs';
import { resolve, join } from 'node:path';
import http from 'node:http';

class BridgeError extends Error { constructor(code, status = 400) { super(code); this.code = code; this.status = status; } }
const check = (ok, code, status) => { if (!ok) throw new BridgeError(code, status); };
const bounded = (s, n = 8192) => typeof s === 'string' && s.trim().length > 0 && Buffer.byteLength(s) <= n;
const clean = (s, n) => Array.from(String(s).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '')).slice(0, n).join('');

export class FileBridge {
  constructor({ dataDir, now = () => Date.now(), stub = false }) {
    this.dataDir = dataDir; this.now = now; this.stub = stub;
    this.tasks = new Map(); this.operations = new Map(); this.events = []; this.online = true;
    mkdirSync(join(dataDir, 'inbox'), { recursive: true, mode: 0o700 });
    mkdirSync(join(dataDir, 'replies'), { recursive: true, mode: 0o700 });
  }
  snapshot() {
    this.expire();
    return { protocolVersion: 1, online: this.online, workspace: this.dataDir, readOnly: true,
      events: this.events,
      tasks: [...this.tasks.values()].map(t => ({ id: t.id, threadId: t.id, turnId: t.turnId, status: t.status, answer: t.answer, pending: [] })) };
  }
  notify(task, { kind, title, content }) {
    this.events.push({ id: randomUUID(), taskId: task.id, turnId: task.turnId, kind, title,
      content: clean(content, 350), approvalId: null, createdAt: this.now(), expiresAt: this.now() + 3600000 });
    this.events = this.events.slice(-128);
  }
  expire() { this.events = this.events.filter(e => e.expiresAt > this.now()); }
  async once(key, action) {
    check(typeof key === 'string' && /^[a-zA-Z0-9-]{16,80}$/.test(key), 'idempotency_key_required');
    if (this.operations.has(key)) { const old = this.operations.get(key); check(old.result, 'previous_delivery_unknown_do_not_replay', 409); return old.result; }
    check(this.operations.size < 2048, 'operation_ledger_full', 409);
    this.operations.set(key, { pending: true });
    const result = await action();
    this.operations.set(key, { result }); return result;
  }
  async message({ taskId, text, requestId }) {
    check(bounded(text), 'invalid_text'); check(this.online, 'claude_unavailable', 503);
    return this.once(requestId, async () => {
      let task;
      if (taskId) {
        task = this.tasks.get(taskId); check(task, 'unknown_task', 404);
        check(!task.turnId, 'task_busy_stop_or_wait', 409);
      } else {
        check(this.tasks.size < 16, 'task_limit', 409);
        task = { id: randomUUID(), turnId: null, status: '準備中', answer: '' };
        this.tasks.set(task.id, task);
      }
      task.answer = ''; task.status = '実行中'; task.turnId = 'running';
      const file = join(this.dataDir, 'inbox', task.id + '.json');
      writeFileSync(file, JSON.stringify({ taskId: task.id, text, createdAt: this.now() }), { mode: 0o600 });
      if (this.stub) {
        setTimeout(() => this.complete(task.id,
          'Claude Bridge（スタブ応答）: タスクを受け取りました。本番バックエンド（Claude Agent SDK）接続前のため、これは自動応答です。'), 1500);
      }
      return { taskId: task.id, accepted: true };
    });
  }
  complete(taskId, answerText) {
    const task = this.tasks.get(taskId); if (!task || !task.turnId) return false;
    task.answer = clean(answerText, 16000); task.status = '完了'; task.turnId = null;
    this.notify(task, { kind: 'completed', title: 'Muse 完了', content: task.answer || 'タスクが完了しました。Turbo IOで確認してください。' });
    return true;
  }
  pollReplies() {
    for (const task of this.tasks.values()) {
      if (!task.turnId) continue;
      const file = join(this.dataDir, 'replies', task.id + '.json');
      if (!existsSync(file)) continue;
      try {
        const data = JSON.parse(readFileSync(file, 'utf8'));
        check(typeof data.text === 'string' && data.text.length > 0, 'invalid_reply');
        this.complete(task.id, data.text);
        unlinkSync(file);
        const inbox = join(this.dataDir, 'inbox', task.id + '.json');
        if (existsSync(inbox)) unlinkSync(inbox);
      } catch { /* 不正な返信ファイルは次周期で再試行せず残す */ }
    }
  }
  async stop({ taskId, requestId }) {
    return this.once(requestId, async () => {
      const task = this.tasks.get(taskId); check(task, 'unknown_task', 404);
      check(task.turnId, 'no_interruptible_turn', 409);
      task.turnId = null; task.status = '停止済み';
      const inbox = join(this.dataDir, 'inbox', task.id + '.json');
      if (existsSync(inbox)) unlinkSync(inbox);
      return { taskId, accepted: true };
    });
  }
  async decide() { throw new BridgeError('stale_or_wrong_request', 409); } // v0: 承認リクエストは発行しない
  async push({ title, content, requestId }) {
    check(bounded(title, 200), 'invalid_title'); check(bounded(content, 4000), 'invalid_content');
    return this.once(requestId, async () => {
      const event = { id: randomUUID(), taskId: 'muse-push', turnId: null, kind: 'completed',
        title: clean(title, 120), content: clean(content, 350), approvalId: null,
        createdAt: this.now(), expiresAt: this.now() + 3600000 };
      this.events.push(event); this.events = this.events.slice(-128);
      return { eventId: event.id, accepted: true };
    });
  }
}

export function createHandler(bridge, token) {
  check(typeof token === 'string' && /^[A-Za-z0-9_-]{32,256}$/.test(token), 'invalid_server_token');
  const expected = Buffer.from('Bearer ' + token);
  return async (req, res) => {
    const reply = (status, object) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(JSON.stringify(object)); };
    try {
      const actual = Buffer.from(req.headers.authorization || '');
      check(!req.headers.origin && actual.length === expected.length && timingSafeEqual(actual, expected), 'unauthorized', 401);
      if (req.method === 'GET' && req.url === '/v1/state') { reply(200, bridge.snapshot()); return; }
      const action = ({ '/v1/message': 'message', '/v1/stop': 'stop', '/v1/decision': 'decide', '/v1/push': 'push' })[req.url];
      check(req.method === 'POST' && action, 'not_found', 404);
      check(req.headers['content-type']?.startsWith('application/json'), 'json_required', 415);
      let text = ''; for await (const chunk of req) { text += chunk; check(Buffer.byteLength(text) <= 16384, 'body_too_large', 413); }
      let body; try { body = JSON.parse(text); } catch { throw new BridgeError('invalid_json'); }
      check(body && typeof body === 'object' && !Array.isArray(body), 'invalid_body');
      check(!bridge.mutating, 'bridge_busy', 409); bridge.mutating = true;
      try { reply(200, await bridge[action](body)); } finally { bridge.mutating = false; }
    } catch (error) { reply(error.status || 500, { error: error instanceof BridgeError ? error.code : 'internal_error' }); }
  };
}

async function main() {
  const args = process.argv.slice(2); const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
  const tokenFile = option('--token-file'); check(tokenFile, 'token_file_required');
  check((statSync(tokenFile).mode & 0o077) === 0, 'token_file_must_be_private');
  const token = readFileSync(tokenFile, 'utf8').trim();
  const host = option('--host') || '127.0.0.1', port = Number(option('--port') || 8788);
  check(['127.0.0.1', '::1', '100.89.199.56'].includes(host), 'remote_requires_tls'); // 100.89.199.56 = Mac Studio Tailscale IP (WireGuard encrypted)
  const dataDir = resolve(option('--data-dir') || 'claude-bridge-data');
  const bridge = new FileBridge({ dataDir, stub: args.includes('--stub') });
  setInterval(() => bridge.pollReplies(), 1000).unref();
  const server = http.createServer(createHandler(bridge, token));
  server.requestTimeout = 35000; server.headersTimeout = 10000;
  server.listen(port, host, () => console.log(`Claude bridge listening; port=${port}; dataDir=${dataDir}; stub=${bridge.stub}; no credentials logged`));
  const stop = () => server.close();
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
}
if (process.argv[1] && import.meta.url === new URL('file://' + resolve(process.argv[1])).href) main().catch(() => { console.error('Bridge startup failed; check token file (0600) and args.'); process.exitCode = 1; });
