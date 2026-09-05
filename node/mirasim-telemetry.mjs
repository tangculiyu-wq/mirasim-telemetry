#!/usr/bin/env node
/**
 * Mirasim 遥测 · 跨平台版（Node 22+，零依赖）
 *
 * 与 macOS 原生版同一套口径，换成「常驻脚本 + 本机网页面板」：
 *   采数  Mirasim 本地接口（/v1/limits 原始额度点、mirachannel 帧）+ 本机流水文件
 *   算数  美元（Mirasim 逐调用计量 × 官方价目）、整窗逆推、扣点公式等价、速度配对
 *   供数  回环 HTTP：/            网页面板
 *                    /quota.json  全部结论（JSON）
 *                    /events      SSE，数据一变就推
 *
 * 只读、只绑 127.0.0.1、不注入 Mirasim、不开调试端口、不改 Mirasim 的任何文件。
 * Windows / Linux / macOS 通用；Windows 上读会话令牌那一步走 PowerShell（见 sessionRoutes）。
 *
 *   node mirasim-telemetry.mjs            起服务并打开面板
 *   node mirasim-telemetry.mjs --doctor   逐层自检（换机器先跑这个，把输出发回来）
 *   node mirasim-telemetry.mjs --once     采一次打印就退
 */

import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, statSync, readdirSync, openSync, readSync, closeSync, existsSync, renameSync, chmodSync, unlinkSync, copyFileSync } from 'node:fs';
import { homedir, platform, userInfo } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const VERSION = '1.4.0';
const HERE = dirname(fileURLToPath(import.meta.url));
const HOME = homedir();
const STATE_DIR = join(HOME, '.mirasim-telemetry');
const INSIGHTS_DIR = join(HOME, '.mirasim', 'insights');
const CATALOG_FILE = join(HOME, '.mirasim', 'models-dev-cache.json');
const CLAUDE_PROJECTS = join(HOME, '.claude', 'projects');
const IS_WIN = platform() === 'win32';

const UI_PORT_LO = 5990, UI_PORT_HI = 5999;   // 与 MiraQuota 等同类工具常用的 4988–4995 错开，并存不抢
const LIMITS_EVERY_MS = 20_000;
const RELAY_EVERY_MS = 15_000;
const LEDGER_EVERY_MS = 60_000;
const STALE_AFTER_S = 90;

/* ---------------- 参数 ---------------- */

const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const opt = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };

if (flag('help') || flag('h')) {
  console.log(`用法 node mirasim-telemetry.mjs [选项]

  --doctor              逐层自检并退出（换机器先跑这个）
  --once                采一次、打印结论、退出
  --port <N>            网页面板端口（默认 ${UI_PORT_LO}–${UI_PORT_HI} 里第一个空闲的）
  --no-open             起服务但不打开浏览器
  --app                 用 Edge/Chrome 的应用窗口模式打开（无地址栏，像一个独立小窗）
  --channel-port <N>    mirachannel 端口（默认从 Mirasim 进程命令行解析，回退 4970–4980 扫描）
  --router-base <URL>   直接给 /v1/limits 的基址（形如 http://127.0.0.1:12345/<密钥>），跳过进程扫描
  --router-token <T>    该基址的会话令牌（等价环境变量 MIRASIM_TELEMETRY_TOKEN）
  --user <usr_...>      强制按该账号统计（默认跟随 Mirasim 当前登录账号）
  --alert <N>           提示区块的额度警戒线，百分比（默认 90）
  --lang zh|en          网页面板默认语言（默认跟浏览器语言；页脚可随时切换）
  --no-accounts         不记录登录过的账号（关掉一键切换账号）`);
  process.exit(0);
}

/* ---------------- 小工具 ---------------- */

const log = (m) => console.log(`[${new Date().toTimeString().slice(0, 8)}] ${m}`);
const num = (v) => { const n = typeof v === 'string' ? Number(v) : v; return typeof n === 'number' && Number.isFinite(n) ? n : null; };
/** ISO8601 或 unix 秒/毫秒 → 毫秒时间戳 */
const toMs = (v) => {
  if (v == null) return null;
  if (typeof v === 'string') { const t = Date.parse(v); if (Number.isFinite(t)) return t; }
  const n = num(v); if (n == null) return null;
  return n > 1e11 ? n : n * 1000;
};
const run = (cmd, args, ms = 8000) => new Promise((resolve) => {
  execFile(cmd, args, { timeout: ms, maxBuffer: 64 << 20, windowsHide: true },
    (err, stdout) => resolve(err && !stdout ? '' : String(stdout || '')));
});
const getJSON = async (url, ms = 3000, headers) => {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(ms), headers, cache: 'no-store' });
    return r.ok ? await r.json() : null;
  } catch { return null; }
};
/** 读文件尾部若干字节（账本几十 MB，整份读既慢又没必要），丢掉首行残片 */
function tail(path, bytes) {
  let fd;
  try {
    const size = statSync(path).size;
    const start = Math.max(0, size - bytes);
    fd = openSync(path, 'r');
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    let text = buf.toString('utf8');
    if (start > 0) { const nl = text.indexOf('\n'); text = nl >= 0 ? text.slice(nl + 1) : ''; }
    return text;
  } catch { return null; } finally { if (fd != null) try { closeSync(fd); } catch { /* 已关 */ } }
}
const median = (a) => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
mkdirSync(STATE_DIR, { recursive: true });
const loadJSON = (p, d) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return d; } };
const saveJSON = (p, v) => { try { writeFileSync(p, JSON.stringify(v)); } catch { /* 磁盘只读也不致命 */ } };

/* ---------------- 进程与端口发现 ---------------- */

/** Mirasim 主服务进程（命令行带 server.cjs）：[{pid, cmd}] */
async function mirasimProcesses() {
  if (IS_WIN) {
    const out = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*server.cjs*' } | " +
      'Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress'], 15000);
    if (!out.trim()) return [];
    let rows; try { rows = JSON.parse(out); } catch { return []; }
    rows = Array.isArray(rows) ? rows : [rows];
    return rows.map((r) => ({ pid: Number(r.ProcessId), cmd: String(r.CommandLine || '') }));
  }
  const out = await run('/bin/ps', ['-axo', 'pid=,command=']);
  return out.split('\n').filter((l) => l.includes('server.cjs')).map((l) => {
    const m = l.trim().match(/^(\d+)\s+(.*)$/);
    return m ? { pid: Number(m[1]), cmd: m[2] } : null;
  }).filter(Boolean);
}

/** 取 KEY=value（到空白为止）或 "KEY":"value"（命令行里的 --settings JSON，引号可能带反斜杠） */
function envValue(key, line) {
  let m = line.match(new RegExp(key + '=([^\\s"\'\\\\]+)'));
  if (m) return m[1];
  m = line.match(new RegExp('\\\\?"' + key + '\\\\?":\\s*\\\\?"([^"\\\\]+)'));
  return m ? m[1] : null;
}
const portOf = (u) => { const m = String(u || '').match(/127\.0\.0\.1:(\d+)/); return m ? Number(m[1]) : null; };

/**
 * 会话路由：/v1/limits 挂在 Mirasim 给每个会话开的回环端口上，令牌不落盘、只在会话进程的
 * 环境里。同一进程的 ANTHROPIC_BASE_URL 指向哪个端口，ANTHROPIC_AUTH_TOKEN 就是它的令牌，
 * 必须按进程配对。基址整段保留——新版 URL 带路径密钥，只抠端口去打是 401。
 *
 *   POSIX    ps eww -U <uid>（必须限定用户：不给选择符时只列同控制终端的进程，后台常驻会一无所获）
 *   Windows  ① Win32_Process 的命令行里若带 --settings JSON，直接从中取
 *            ② 否则用 PowerShell 读同用户进程的环境块（PEB→ProcessParameters→Environment，
 *              不需要管理员；x64 偏移 0x20 / 0x80 / 0x3F0）。两步都空时退回手工 --router-token。
 */
async function sessionRoutes() {
  const base0 = opt('router-base', process.env.MIRASIM_TELEMETRY_BASE);
  const token0 = opt('router-token', process.env.MIRASIM_TELEMETRY_TOKEN);
  if (base0 && token0) return { routes: [{ base: base0.replace(/\/+$/, ''), token: token0, port: portOf(base0) }], method: '手工参数' };

  const routes = [], seen = new Set();
  const push = (base, token) => {
    if (!base || !token || !base.startsWith('http') || portOf(base) == null) return;
    base = base.replace(/\/+$/, '');
    const k = base + '|' + token;
    if (!seen.has(k)) { seen.add(k); routes.push({ base, token, port: portOf(base) }); }
  };

  if (!IS_WIN) {
    const uid = typeof process.getuid === 'function' ? String(process.getuid()) : (userInfo().username || '');
    const out = await run('/bin/ps', ['eww', '-U', uid, '-o', 'command=']);
    for (const line of out.split('\n')) push(envValue('ANTHROPIC_BASE_URL', line), envValue('ANTHROPIC_AUTH_TOKEN', line));
    return { routes, method: 'ps eww' };
  }

  // Windows ①：命令行
  const cmdOut = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*ANTHROPIC_AUTH_TOKEN*' } | " +
    'Select-Object -ExpandProperty CommandLine'], 15000);
  for (const line of cmdOut.split(/\r?\n/)) push(envValue('ANTHROPIC_BASE_URL', line), envValue('ANTHROPIC_AUTH_TOKEN', line));
  if (routes.length) return { routes, method: 'Win32_Process 命令行' };

  // Windows ②：环境块
  const script = String.raw`
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class MTEnv {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool b, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
  [StructLayout(LayoutKind.Sequential)] public struct PBI { public IntPtr R1; public IntPtr Peb; public IntPtr R2a; public IntPtr R2b; public IntPtr Pid; public IntPtr R3; }
  static IntPtr P(IntPtr h, IntPtr a){ var b=new byte[8]; IntPtr r; return ReadProcessMemory(h,a,b,(IntPtr)8,out r) ? (IntPtr)BitConverter.ToInt64(b,0) : IntPtr.Zero; }
  static uint U(IntPtr h, IntPtr a){ var b=new byte[4]; IntPtr r; return ReadProcessMemory(h,a,b,(IntPtr)4,out r) ? BitConverter.ToUInt32(b,0) : 0u; }
  public static string Env(int pid){
    IntPtr h = OpenProcess(0x0410, false, pid); if (h==IntPtr.Zero) return null;
    try { PBI pbi = new PBI(); int ret;
      if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret)!=0) return null;
      IntPtr pp = P(h, pbi.Peb + 0x20); if (pp==IntPtr.Zero) return null;
      IntPtr env = P(h, pp + 0x80); uint size = U(h, pp + 0x3F0);
      if (env==IntPtr.Zero || size==0 || size>4194304) return null;
      var buf = new byte[size]; IntPtr r; if(!ReadProcessMemory(h, env, buf, (IntPtr)size, out r)) return null;
      return Encoding.Unicode.GetString(buf, 0, (int)r);
    } finally { CloseHandle(h); } }
}
"@
$rows = @()
Get-Process | Where-Object { $_.ProcessName -match '^(node|claude|bun|cmd|pwsh|powershell)$' } | ForEach-Object {
  $e = [MTEnv]::Env($_.Id)
  if ($e -and $e.Contains('ANTHROPIC_AUTH_TOKEN=')) { $rows += $e.Replace([string][char]0, [string][char]10) }
}
$rows -join ([string][char]10 + '=====' + [string][char]10)
`;
  const envOut = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], 30000);
  for (const block of envOut.split('=====')) {
    let base = null, token = null;
    for (const line of block.split(/\r?\n/)) {
      if (line.startsWith('ANTHROPIC_BASE_URL=')) base = line.slice('ANTHROPIC_BASE_URL='.length).trim();
      else if (line.startsWith('ANTHROPIC_AUTH_TOKEN=')) token = line.slice('ANTHROPIC_AUTH_TOKEN='.length).trim();
    }
    push(base, token);
  }
  return { routes, method: routes.length ? '进程环境块' : '未找到（可用 --router-base/--router-token 手工给）' };
}

/** mirachannel 端口：参数 → 进程命令行 --port → 惯用 4970 → 4970–4980 扫描；以 /api/health 校验 */
async function discoverChannelPort(processes) {
  const verify = async (p) => { const j = await getJSON(`http://127.0.0.1:${p}/api/health`, 1500); return j && j.name === 'mirasim' ? p : null; };
  const explicit = Number(opt('channel-port', 0));
  if (explicit) return explicit;
  const fromCmd = processes.map((p) => p.cmd.match(/--port[= ](\d+)/)).filter(Boolean).map((m) => Number(m[1]));
  for (const p of [...new Set([...fromCmd, 4970])]) if (await verify(p)) return p;
  for (let p = 4971; p <= 4980; p++) if (await verify(p)) return p;
  return null;
}

/* ---------------- 精确源：/v1/limits ---------------- */

const spanOf = (name) => {
  const head = String(name).split('_')[0];
  const m = head.match(/^(\d+)([hdmw])$/);
  if (!m) return null;
  const n = Number(m[1]);
  return { h: 3600, d: 86400, m: 60, w: 604800 }[m[2]] * n;
};
const labelOf = (name) => {
  if (name === '5h') return '5 小时';
  if (name === '7d') return '7 天';
  if (name === '7d_fable') return '7 天 · Fable 5.1';
  const [head, ...rest] = String(name).split('_');
  const m = head.match(/^(\d+)([hdmw])$/);
  const unit = m ? { h: ' 小时', d: ' 天', m: ' 分钟', w: ' 周' }[m[2]] : '';
  return (m ? m[1] + unit : head) + (rest.length ? ' · ' + rest.join(' ') : '');
};

function parseLimits(root) {
  if (!root || typeof root.subject !== 'string' || !Array.isArray(root.windows)) return null;
  const windows = [];
  for (const w of root.windows) {
    const used = num(w.used), budget = num(w.budget);
    if (!w.name || used == null || budget == null || budget <= 0) continue;
    windows.push({
      name: String(w.name), usedPoints: used, budgetPoints: budget,
      usedPercent: used / budget * 100,                 // 上游可超发，不夹到 100
      resetAt: toMs(w.reset_at) ?? Date.now(),
      modelScoped: !!w.model_scoped, upstreamStatus: w.status ?? null, precision: 'exact',
    });
  }
  return windows.length ? { subject: root.subject, windows, suspended: !!root.suspended, unmetered: !!root.unmetered, degraded: !!root.degraded } : null;
}

let cachedRoute = null;
async function fetchLimits(expectedUserId) {
  const { routes } = await sessionRoutes();
  const ordered = cachedRoute && routes.some((r) => r.base === cachedRoute.base) ? [cachedRoute, ...routes.filter((r) => r.base !== cachedRoute.base)] : routes;
  for (const r of ordered) {
    const payload = parseLimits(await getJSON(`${r.base}/v1/limits`, 6000, { 'x-api-key': r.token, accept: 'application/json' }));
    if (!payload) continue;
    if (expectedUserId && payload.subject !== expectedUserId) continue;   // 读到别的账号（并行开发实例），弃
    cachedRoute = r;
    return payload;
  }
  cachedRoute = null;
  return null;
}

/* ---------------- 帧源：mirachannel WebSocket ---------------- */

class Relay {
  constructor() { this.ws = null; this.port = null; this.frame = null; this.lastUserId = null; this.status = 'connecting'; this.onFrame = null; this.backoff = 1000; this.sinceSnapshot = 0; }
  async start() {
    const procs = await mirasimProcesses();
    if (!procs.length) { this.status = 'nomirasim'; return this.retry(); }
    this.port = await discoverChannelPort(procs);
    if (!this.port) { this.status = 'nomirasim'; return this.retry(); }
    this.connect();
  }
  connect() {
    let ws;
    try { ws = new WebSocket(`ws://127.0.0.1:${this.port}/mirachannel/ws`); } catch { return this.retry(); }
    this.ws = ws;
    ws.addEventListener('open', () => {
      this.backoff = 1000; this.sinceSnapshot = 0;
      ws.send(JSON.stringify({ type: 'hello', v: 1, client: { name: 'mirasim-telemetry', platform: platform() } }));
      this.ask();
      this.timer = setInterval(() => {
        this.ask();
        if (++this.sinceSnapshot >= 4 && this.status !== 'mismatch') { this.status = 'mismatch'; this.onFrame?.(); }
      }, RELAY_EVERY_MS);
    });
    ws.addEventListener('message', (ev) => this.handle(String(ev.data)));
    ws.addEventListener('close', () => this.drop());
    ws.addEventListener('error', () => this.drop());
  }
  ask(fresh = false) { try { this.ws?.send(JSON.stringify({ type: 'host', payload: fresh ? { type: 'getRelay', fresh: true } : { type: 'getRelay' } })); } catch { /* 断了会走 close */ } }
  drop() { clearInterval(this.timer); this.ws = null; if (this.status !== 'nomirasim') this.status = 'connecting'; this.onFrame?.(); this.retry(); }
  retry() { setTimeout(() => this.start(), this.backoff); this.backoff = Math.min(this.backoff * 2, 30000); }
  handle(text) {
    if (!text.includes('usage') && !text.includes('relay')) return;
    let root; try { root = JSON.parse(text); } catch { return; }
    const payload = root.payload && typeof root.payload === 'object' ? root.payload : root;
    const relay = payload.relay || root.relay;
    if (!relay) return;
    const login = relay.login || {};
    if (login.userId) this.lastUserId = login.userId;
    const raw = relay.usage && relay.usage.windows;
    if (!Array.isArray(raw) || !raw.length) return;
    const windows = [];
    for (const w of raw) {
      const name = w.label ?? w.name; const used = num(w.usedPercent) ?? num(w.used_percent);
      const reset = toMs(w.resetAt) ?? toMs(w.reset_at) ?? (num(w.resetAfterSeconds) != null ? Date.now() + num(w.resetAfterSeconds) * 1000 : null);
      if (!name || used == null || reset == null) continue;
      windows.push({ name: String(name), usedPoints: null, budgetPoints: null, usedPercent: used, resetAt: reset,
        modelScoped: !!(w.modelScoped ?? w.model_scoped), upstreamStatus: w.status ?? null, precision: 'coarse' });
    }
    if (!windows.length) return;
    const referral = relay.referral || {};
    this.frame = {
      windows,
      account: { userId: login.userId ?? null, name: login.name ?? null, email: login.email ?? null,
        plan: login.plan ?? referral.currentPlan ?? null, planExpiry: toMs(login.planExp), paid: relay.paid ?? null,
        relayStatus: relay.relayStatus ?? null, host: relay.host ?? null },
      capturedAt: toMs(relay.usage.capturedAt) ?? Date.now(), receivedAt: Date.now(),
    };
    this.sinceSnapshot = 0; this.status = 'live';
    this.onFrame?.();
  }
}

/* ---------------- 价目与账本（对齐 Mirasim 流量监控页的口径） ---------------- */

/** 内置官方牌价（美元/百万 token：输入、输出、缓存读、缓存写），只在目录缺该型号时用；顺序即优先级 */
const BUILTIN = [
  ['claude-fable-5-1', [10, 50, 0.25, 12.5]], ['claude-mythos-5-1', [10, 50, 0.25, 12.5]],
  ['claude-fable-5', [10, 50, 1, 12.5]], ['claude-mythos-5', [10, 50, 1, 12.5]],
  ['claude-opus-5', [5, 25, 0.5, 6.25]], ['claude-opus-4-5', [5, 25, 0.5, 6.25]], ['claude-opus-4-6', [5, 25, 0.5, 6.25]],
  ['claude-opus-4-7', [5, 25, 0.5, 6.25]], ['claude-opus-4-8', [5, 25, 0.5, 6.25]], ['claude-opus-4-9', [5, 25, 0.5, 6.25]],
  ['claude-opus-4', [15, 75, 1.5, 18.75]], ['claude-sonnet-5', [2, 10, 0.2, 2.5]], ['claude-sonnet-4', [3, 15, 0.3, 3.75]],
  ['claude-haiku-4-5', [1, 5, 0.1, 1.25]], ['claude-haiku', [0.8, 4, 0.08, 1]],
  ['gpt-5.6-luna', [0.2, 1.2, 0.02, 0.25]], ['gpt-5.6-terra', [2, 12, 0.2, 2.5]], ['gpt-5.6', [4, 20, 0.4, 5]],
];
const FIRST_PARTY = ['anthropic', 'openai', 'google', 'deepseek', 'xai', 'moonshotai', 'zai', 'alibaba', 'mistral'];
const canonicalProvider = (p) => { let s = String(p || '').toLowerCase(); for (const suf of ['-responses', '-chat', '-completions', '-compat', '-messages']) if (s.endsWith(suf)) { s = s.slice(0, -suf.length); break; } return s; };

class Ledger {
  constructor() { this.entries = []; this.unmetered = []; this.recent = []; this.files = new Map(); this.catalog = new Map(); this.catalogStamp = null; this.rateCache = new Map(); this._serviceStart = undefined; }
  loadCatalogIfChanged() {
    let st; try { st = statSync(CATALOG_FILE); } catch { return false; }
    const stamp = st.size + ':' + st.mtimeMs;
    if (this.catalogStamp === stamp) return false;
    this.catalogStamp = stamp; this.rateCache.clear();
    const out = new Map();
    try {
      const root = JSON.parse(readFileSync(CATALOG_FILE, 'utf8'));
      for (const [prov, pv] of Object.entries(root.data || {})) {
        const table = new Map();
        for (const [mid, mv] of Object.entries(pv?.models || {})) {
          const c = mv?.cost; const i = num(c?.input), o = num(c?.output);
          if (i == null || o == null || (i <= 0 && o <= 0)) continue;     // 零价条目是占位
          table.set(mid, [i, o, num(c.cache_read) ?? i * 0.1, num(c.cache_write) ?? i * 1.25]);
        }
        if (table.size) out.set(prov.toLowerCase(), table);
      }
    } catch { /* 目录坏了就只剩内置表 */ }
    this.catalog = out;
    return true;
  }
  rate(provider, model) {
    const key = provider + '/' + model;
    if (this.rateCache.has(key)) return this.rateCache.get(key);
    let found = this.catalog.get(canonicalProvider(provider))?.get(model) ?? this.catalog.get(String(provider).toLowerCase())?.get(model);
    if (!found) for (const p of FIRST_PARTY) { const r = this.catalog.get(p)?.get(model); if (r) { found = r; break; } }
    if (!found) { const b = BUILTIN.find(([pre]) => model.startsWith(pre)); if (b) found = b[1]; }
    if (!found) {
      const suffixed = '/' + model;
      for (const p of [...this.catalog.keys()].sort()) {
        const t = this.catalog.get(p);
        if (t.has(model)) { found = t.get(model); break; }
        const k = [...t.keys()].find((x) => x.endsWith(suffixed)); if (k) { found = t.get(k); break; }
      }
    }
    const r = found || [10, 50, 1, 12.5];   // 全不认识按最贵档，宁可高估
    this.rateCache.set(key, r);
    return r;
  }
  usageFiles() {
    let names; try { names = readdirSync(INSIGHTS_DIR); } catch { return []; }
    return names.filter((n) => n.startsWith('usage-') && n.endsWith('.ndjson')).sort().slice(-3);
  }
  get serviceStart() {
    if (this._serviceStart !== undefined) return this._serviceStart;
    this._serviceStart = null;
    let names; try { names = readdirSync(INSIGHTS_DIR).filter((n) => n.startsWith('usage-') && n.endsWith('.ndjson')).sort(); } catch { return null; }
    if (!names.length) return null;
    try {
      const fd = openSync(join(INSIGHTS_DIR, names[0]), 'r'); const buf = Buffer.alloc(16384); const n = readSync(fd, buf, 0, 16384, 0); closeSync(fd);
      for (const line of buf.toString('utf8', 0, n).split('\n')) { try { const t = toMs(JSON.parse(line).ts); if (t) { this._serviceStart = t; break; } } catch { /* 半行 */ } }
    } catch { /* 读不到 */ }
    return this._serviceStart;
  }
  /** 重扫流水。按文件 (大小, 修改时间) 缓存——回填会原地改写历史行，不能用游标 */
  refresh() {
    if (this.loadCatalogIfChanged()) this.files.clear();
    const wanted = this.usageFiles();
    const horizon = Date.now() - 35 * 86400_000;
    let changed = false;
    for (const name of wanted) {
      const path = join(INSIGHTS_DIR, name);
      let st; try { st = statSync(path); } catch { continue; }
      const c = this.files.get(name);
      if (c && c.size === st.size && c.mtime === st.mtimeMs) continue;
      const es = [], um = [], rc = [];
      const recentHorizon = Date.now() - 24 * 3600_000;
      let text; try { text = readFileSync(path, 'utf8'); } catch { continue; }
      for (const line of text.split('\n')) {
        if (!line.includes('"leg":"relay"')) continue;
        let o; try { o = JSON.parse(line); } catch { continue; }
        if (o.leg !== 'relay' || !o.id) continue;
        const at = toMs(o.ts); if (at == null || at < horizon) continue;
        const input = num(o.input) ?? 0, output = num(o.output) ?? 0, read = num(o.cacheRead) ?? 0, write = num(o.cacheWrite) ?? 0;
        const user = o.userId ?? null, session = o.sessionId ?? null, workspace = o.workspace ?? null;
        const status = num(o.status) ?? 0, durationMs = num(o.durationMs) ?? 0, agent = o.agent || '?';
        const model = o.model || '';
        const tokens = input + output + read + write;
        let usd = 0;
        if (tokens > 0) { const r = this.rate(o.provider || 'anthropic', model); usd = (input * r[0] + output * r[1] + read * r[2] + write * r[3]) / 1e6; }
        // 近 24 小时每次调用都记一笔（含失败与未回填），供活动条、失败统计与「最近调用」
        if (at >= recentHorizon) rc.push({ id: o.id, at, model, status, durationMs, tokens, usd, session, workspace, user, agent });
        if (tokens <= 0) { if (status === 200) um.push({ at, user, session }); continue; }
        if (usd <= 0) continue;
        es.push({ id: o.id, at, usd, model, user, input, output, read, write, session, workspace });
      }
      this.files.set(name, { size: st.size, mtime: st.mtimeMs, entries: es, unmetered: um, recent: rc });
      changed = true;
    }
    for (const k of [...this.files.keys()]) if (!wanted.includes(k)) { this.files.delete(k); changed = true; }
    if (!changed) return false;
    this.entries = wanted.flatMap((n) => this.files.get(n)?.entries || []);
    this.unmetered = wanted.flatMap((n) => this.files.get(n)?.unmetered || []);
    this.recent = wanted.flatMap((n) => this.files.get(n)?.recent || []);
    return true;
  }
  /** 花费与次数；modelGroup 为模型名子串过滤（fable / claude），userId 只算该账号 */
  spent(since, until = null, modelGroup = null, userId = null, repriceAs = null) {
    const r = repriceAs ? this.rate('anthropic', repriceAs) : null;
    const g = modelGroup ? modelGroup.toLowerCase() : null;
    let usd = 0, n = 0;
    for (const e of this.entries) {
      if (e.at < since || (until != null && e.at >= until)) continue;
      if (g && !e.model.toLowerCase().includes(g)) continue;
      if (userId && e.user !== userId) continue;
      usd += r ? (e.input * r[0] + e.output * r[1] + e.read * r[2] + e.write * r[3]) / 1e6 : e.usd; n++;
    }
    return { usd, n };
  }
  daily(days, userId) {
    const start = new Date(); start.setHours(0, 0, 0, 0); start.setDate(start.getDate() - (days - 1));
    const acc = new Map();
    for (const e of this.entries) {
      if (e.at < start.getTime() || (userId && e.user !== userId)) continue;
      const d = new Date(e.at); d.setHours(0, 0, 0, 0);
      const k = d.getTime(); const cur = acc.get(k) || { usd: 0, count: 0 }; cur.usd += e.usd; cur.count++; acc.set(k, cur);
    }
    return [...acc.entries()].sort((a, b) => a[0] - b[0]).map(([day, v]) => ({ day, ...v }));
  }
  backfillGap(since, userId) {
    let metered = 0, unmetered = 0;
    for (const e of this.entries) if (e.at >= since && (!userId || e.user === userId)) metered++;
    for (const u of this.unmetered) if (u.at >= since && (!userId || u.user === userId)) unmetered++;
    return { metered, unmetered };
  }
  /** 会话卡：按 Claude Code 会话号归并，整个会话累计（不限窗口），只取 activeSince 之后还有调用的 */
  sessions(activeSince, userId, limit = 5) {
    const acc = new Map();
    for (const e of this.entries) {
      if (!e.session || (userId && e.user !== userId)) continue;
      let s = acc.get(e.session);
      if (!s) { s = { id: e.session, workspace: e.workspace, usd: 0, calls: 0, pending: 0, input: 0, output: 0, read: 0, write: 0, firstAt: e.at, lastAt: e.at, models: new Map() }; acc.set(e.session, s); }
      s.usd += e.usd; s.calls++; s.input += e.input; s.output += e.output; s.read += e.read; s.write += e.write;
      if (e.at < s.firstAt) s.firstAt = e.at;
      if (e.at > s.lastAt) s.lastAt = e.at;
      if (e.workspace && !s.workspace) s.workspace = e.workspace;
      s.models.set(e.model, (s.models.get(e.model) || 0) + 1);
    }
    for (const u of this.unmetered) {
      if (!u.session || (userId && u.user !== userId)) continue;
      const s = acc.get(u.session); if (s) { s.pending++; if (u.at > s.lastAt) s.lastAt = u.at; }
    }
    return [...acc.values()].filter((s) => s.lastAt >= activeSince).sort((a, b) => b.lastAt - a.lastAt).slice(0, limit)
      .map((s) => ({ ...s, tokens: s.input + s.output + s.read + s.write, models: [...s.models.entries()].sort((a, b) => b[1] - a[1]), title: sessionTitle(s.id, s.workspace) }));
  }
  /** since 起的请求成败：成功/失败数、失败码分布、按格分桶、近 10 分钟撞过 429 的模型 */
  requestStats(since, userId, buckets = 12) {
    const now = Date.now(); const span = Math.max(1, now - since);
    const out = { ok: 0, failed: 0, codes: {}, rateLimited: [], buckets: Array.from({ length: buckets }, () => ({ ok: 0, failed: 0 })) };
    for (const r of this.recent) {
      if (r.at < since || (userId && r.user !== userId)) continue;
      const i = Math.min(buckets - 1, Math.max(0, Math.floor((r.at - since) / span * buckets)));
      if (r.status === 200) { out.ok++; out.buckets[i].ok++; continue; }
      out.failed++; out.buckets[i].failed++; out.codes[r.status] = (out.codes[r.status] || 0) + 1;
      if (r.status === 429 && now - r.at < 600_000 && !out.rateLimited.includes(r.model)) out.rateLimited.push(r.model);
    }
    return out;
  }
  recentCalls(limit, userId) {
    return this.recent.filter((r) => !userId || r.user === userId).sort((a, b) => b.at - a.at).slice(0, limit);
  }
}

/** 会话标题：Claude Code 账本里该会话的第一句用户话（≤30 字）；找不到给 null，面板退回仓库名或会话号 */
const titleCache = new Map();
function sessionTitle(sid, workspace) {
  if (!sid) return null;
  if (titleCache.has(sid)) return titleCache.get(sid);
  const candidates = [];
  if (workspace) candidates.push(join(CLAUDE_PROJECTS, workspace.replace(/[\\/:.]/g, '-'), sid + '.jsonl'));   // Claude Code 的项目目录名＝路径里的分隔符与点换成 -
  let dirs = []; try { dirs = readdirSync(CLAUDE_PROJECTS); } catch { /* 没有账本 */ }
  for (const d of dirs) candidates.push(join(CLAUDE_PROJECTS, d, sid + '.jsonl'));
  let title = null;
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    let head = '';
    try { const fd = openSync(p, 'r'); const buf = Buffer.alloc(98304); const n = readSync(fd, buf, 0, 98304, 0); closeSync(fd); head = buf.toString('utf8', 0, n); } catch { continue; }
    for (const line of head.split('\n')) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.type !== 'user' || o.isMeta) continue;
      const c = o.message?.content;
      let t = typeof c === 'string' ? c : Array.isArray(c) ? (c.find((x) => x.type === 'text')?.text ?? '') : '';
      t = t.trim().replace(/\s+/g, ' ');
      if (!t || t.startsWith('<') || t.startsWith('[Request interrupted')) continue;
      title = t.length > 30 ? t.slice(0, 30) + '…' : t; break;
    }
    if (title) break;
  }
  if (titleCache.size > 300) titleCache.clear();
  titleCache.set(sid, title);
  return title;
}

/* ---------------- 速度：Mirasim 耗时 × Claude Code 账本 token，按请求号精确配对 ---------------- */

const lineCache = new Map();   // path → {size, mtime, lines}
function cachedLines(path) {
  let st; try { st = statSync(path); } catch { return []; }
  const c = lineCache.get(path);
  if (c && c.size === st.size && c.mtime === st.mtimeMs) return c.lines;
  const lines = [];
  const text = tail(path, 1_200_000);
  if (text) for (const line of text.split('\n')) {
    if (!line.includes('"usage"')) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    const at = toMs(o.timestamp); const usage = o.message?.usage;
    if (at == null || !usage) continue;
    lines.push({ at, out: num(usage.output_tokens), req: o.requestId ?? null });
  }
  lineCache.set(path, { size: st.size, mtime: st.mtimeMs, lines });
  if (lineCache.size > 120) lineCache.clear();
  return lines;
}
function ledgerLines() {
  let dirs; try { dirs = readdirSync(CLAUDE_PROJECTS).map((n) => join(CLAUDE_PROJECTS, n)); } catch { return []; }
  const recent = dirs.map((d) => { try { return [d, statSync(d).mtimeMs]; } catch { return null; } }).filter(Boolean).sort((a, b) => b[1] - a[1]).slice(0, 3).map((x) => x[0]);
  const active = Date.now() - 6 * 3600_000;
  const out = [];
  for (const dir of recent) {
    let files; try { files = readdirSync(dir); } catch { continue; }
    const jsonl = files.filter((n) => n.endsWith('.jsonl')).map((n) => { try { return [join(dir, n), statSync(join(dir, n)).mtimeMs]; } catch { return null; } })
      .filter((x) => x && x[1] > active).sort((a, b) => b[1] - a[1]).slice(0, 6);
    for (const [f] of jsonl) {
      out.push(...cachedLines(f));
      // 子代理账本 <会话id>/subagents/agent-*.jsonl：它们的请求号不进主账本
      const sub = join(dir, f.split(/[\\/]/).pop().replace(/\.jsonl$/, ''), 'subagents');
      let subs; try { subs = readdirSync(sub); } catch { continue; }
      const agents = subs.filter((n) => n.endsWith('.jsonl')).map((n) => { try { return [join(sub, n), statSync(join(sub, n)).mtimeMs]; } catch { return null; } })
        .filter((x) => x && x[1] > active).sort((a, b) => b[1] - a[1]).slice(0, 12);
      for (const [a] of agents) out.push(...cachedLines(a));
    }
  }
  return out;
}
function recentTurns(limit, userId) {
  let names; try { names = readdirSync(INSIGHTS_DIR).filter((n) => n.startsWith('usage-') && n.endsWith('.ndjson')).sort(); } catch { return []; }
  if (!names.length) return [];
  const text = tail(join(INSIGHTS_DIR, names[names.length - 1]), 220_000);
  if (!text) return [];
  const out = [];
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0 && out.length < limit; i--) {
    let o; try { o = JSON.parse(lines[i]); } catch { continue; }
    if (o.status !== 200 || !o.model) continue;
    const ms = num(o.durationMs); const at = toMs(o.ts);
    if (!ms || ms <= 0 || at == null) continue;
    if (userId && o.userId !== userId) continue;
    out.push({ at, model: o.model, durationMs: ms, agent: o.agent || '?', requestId: o.providerCallId ?? null });
  }
  return out;
}
function prettyModel(id) {
  const base = id.replace('[1m]', ''); const parts = base.split('-');
  let s = id;
  if (parts[0] === 'claude' && parts.length >= 3) {
    const family = parts[1][0].toUpperCase() + parts[1].slice(1);
    const nums = []; for (const p of parts.slice(2)) { if (p.length <= 2 && /^\d+$/.test(p)) nums.push(p); else break; }
    if (nums.length) s = family + ' ' + nums.join('.');
  } else if (base.startsWith('gpt-')) s = 'GPT-' + base.slice(4);
  if (id.includes('[1m]') && !s.includes('1M')) s += ' · 1M';
  return s;
}
function speedRows(userId) {
  const turns = recentTurns(60, userId);
  if (!turns.length) return { rows: [], paired: 0, probed: 0 };
  const byReq = new Map(), byTime = [];
  for (const l of ledgerLines()) {
    if (l.req) { const e = byReq.get(l.req) || { first: l.at, out: 0 }; if (l.at < e.first) e.first = l.at; if (l.out != null && l.out > e.out) e.out = l.out; byReq.set(l.req, e); }
    if (l.out != null && l.out > 0) byTime.push([l.at, l.out]);
  }
  byTime.sort((a, b) => b[0] - a[0]);
  let paired = 0, probed = 0;
  for (const t of turns.slice(0, 12)) { probed++; if (t.requestId && byReq.has(t.requestId)) paired++; }
  const byModel = new Map();
  for (const t of turns) { if (!byModel.has(t.model)) byModel.set(t.model, []); byModel.get(t.model).push(t); }
  const rows = [];
  for (const [model, group] of byModel) {
    const newestAt = Math.max(...group.map((t) => t.at));
    const sample = group.filter((t) => newestAt - t.at < 45 * 60_000).slice(0, 12);
    if (!sample.length) continue;
    const durations = sample.map((t) => t.durationMs / 1000).sort((a, b) => a - b);
    const tps = [], first = [];
    for (const t of sample) {
      let outTok = null;
      const e = t.requestId ? byReq.get(t.requestId) : null;
      if (e) {
        if (e.out > 0) outTok = e.out;
        const f = (e.first - t.at) / 1000;
        if (f > 0.05 && f < t.durationMs / 1000 + 30) first.push(f);
      } else {
        const endAt = t.at + t.durationMs;
        const hit = byTime.find((x) => Math.abs(x[0] - endAt) < 12_000) || byTime.find((x) => Math.abs(x[0] - t.at) < 12_000);
        outTok = hit ? hit[1] : null;
      }
      if (outTok != null && t.durationMs / 1000 > 0.2) tps.push(outTok / (t.durationMs / 1000));
    }
    rows.push({ id: model, model: prettyModel(model), medianSeconds: durations[Math.floor(durations.length / 2)],
      tokensPerSecond: tps.length >= 3 ? median(tps) : null, firstSeconds: first.length >= 3 ? median(first) : null,
      count: sample.length, lastAt: newestAt, background: !sample.some((t) => t.agent === 'claude') });
  }
  rows.sort((a, b) => (a.background !== b.background) ? (a.background ? 1 : -1) : b.lastAt - a.lastAt);
  return { rows, paired, probed };
}

/* ---------------- 账号库与一键切换云端账号 ---------------- */

const SETTING_FILE = join(HOME, '.mirasim', 'setting.json');
const ACCOUNTS_FILE = join(STATE_DIR, 'accounts.json');
const BACKUP_DIR = join(STATE_DIR, 'setting-backups');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const writePrivate = (path, text) => { writeFileSync(path, text, { mode: 0o600 }); try { chmodSync(path, 0o600); } catch { /* Windows 无 POSIX 权限位 */ } };

/**
 * 记住在 Mirasim 里登录过的每个云端账号的 `auth` 块（setting.json 里 Mirasim 写出的加密块，原样保存、不解析、不外发），
 * 切换＝备份整份 setting.json → 把选中账号的块写回 → 让 Mirasim 重载 → 核对帧里的账号；限时没切过去就整份还原。
 */
class AccountVault {
  constructor() { this.accounts = loadJSON(ACCOUNTS_FILE, []); this.stamp = null; this.lastSaveAt = 0; }
  save() { mkdirSync(STATE_DIR, { recursive: true }); writePrivate(ACCOUNTS_FILE, JSON.stringify(this.accounts, null, 2)); this.lastSaveAt = Date.now(); }
  static readSetting() { try { return JSON.parse(readFileSync(SETTING_FILE, 'utf8')); } catch { return null; } }
  static currentUserIdOnDisk() { return AccountVault.readSetting()?.auth?.userId ?? null; }
  static canonical(obj) { return JSON.stringify(Object.fromEntries(Object.entries(obj).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))); }
  /** 3 秒一拍：setting.json 变了就记下当前登录；用结论里的账号/窗口补套餐与用量。返回库有没有变 */
  captureIfChanged(result) {
    let st; try { st = statSync(SETTING_FILE); } catch { return false; }
    const stamp = st.size + ':' + st.mtimeMs;
    let changed = false;
    if (stamp !== this.stamp) {
      this.stamp = stamp;
      const auth = AccountVault.readSetting()?.auth;
      if (auth && typeof auth.userId === 'string' && auth.userId && typeof auth.token === 'string' && auth.token) {
        const json = AccountVault.canonical(auth); const now = Date.now();
        const a = this.accounts.find((x) => x.userId === auth.userId);
        if (a) { if (a.authJSON !== json) { a.authJSON = json; a.capturedAt = now; } a.lastSeenAt = now; if (auth.name) a.name = auth.name; }
        else this.accounts.push({ userId: auth.userId, name: auth.name ?? null, plan: null, planExpiry: null, authJSON: json, capturedAt: now, lastSeenAt: now, lastWindows: [] });
        changed = true;
      }
    }
    const uid = result?.account?.userId;
    const a = uid ? this.accounts.find((x) => x.userId === uid) : null;
    if (a && result.windows?.length) {
      const before = JSON.stringify(a);
      if (result.account.plan) a.plan = result.account.plan;
      if (result.account.planExpiry) a.planExpiry = result.account.planExpiry;
      if (result.account.name) a.name = result.account.name;
      a.lastWindows = result.windows.map((w) => ({ name: w.name, usedPercent: w.usedPercent, resetAt: w.resetAt }));
      a.lastSeenAt = Date.now();
      if (JSON.stringify(a) !== before && (changed || Date.now() - this.lastSaveAt > 60_000)) changed = true;
    }
    if (changed) this.save();
    return changed;
  }
  remove(userId) { this.accounts = this.accounts.filter((a) => a.userId !== userId); this.save(); }
  /** 只给界面看的字段，绝不带 authJSON */
  publicList() {
    return this.accounts.map((a) => { let exp = null; try { const e = JSON.parse(a.authJSON).exp; exp = e ? (e > 1e11 ? e : e * 1000) : null; } catch { /* 无 exp */ }
      return { userId: a.userId, name: a.name, plan: a.plan, planExpiry: a.planExpiry, capturedAt: a.capturedAt, lastSeenAt: a.lastSeenAt, tokenExpiry: exp, lastWindows: a.lastWindows }; });
  }
  backups() { let names; try { names = readdirSync(BACKUP_DIR); } catch { return []; } return names.filter((n) => n.startsWith('setting-') && n.endsWith('.json')).sort().reverse().map((n) => join(BACKUP_DIR, n)); }
  /** 备份整份 → 原子替换 auth 块；返回备份路径 */
  writeAuth(userId) {
    const target = this.accounts.find((a) => a.userId === userId); if (!target) throw new Error('账号库里没有这个账号');
    const root = AccountVault.readSetting(); if (!root) throw new Error('读不到 ~/.mirasim/setting.json');
    if (root.auth?.userId === userId) throw new Error('已经是当前账号');
    mkdirSync(BACKUP_DIR, { recursive: true, mode: 0o700 });
    const d = new Date(), p = (n) => String(n).padStart(2, '0');
    const backup = join(BACKUP_DIR, `setting-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-${String(root.auth?.userId ?? 'unknown').slice(0, 12)}.json`);
    copyFileSync(SETTING_FILE, backup); try { chmodSync(backup, 0o600); } catch { /* Windows */ }
    for (const old of this.backups().slice(12)) { try { unlinkSync(old); } catch { /* 忽略 */ } }
    root.auth = JSON.parse(target.authJSON);
    const tmp = SETTING_FILE + '.mt-tmp';
    writePrivate(tmp, JSON.stringify(root, null, 2));
    renameSync(tmp, SETTING_FILE);           // 同目录 rename 原子替换，Mirasim 读到的永远是完整的一份
    try { const st = statSync(SETTING_FILE); this.stamp = st.size + ':' + st.mtimeMs; } catch { /* 下一拍再说 */ }
    return backup;
  }
  restore(backup) { const tmp = SETTING_FILE + '.mt-tmp'; writePrivate(tmp, readFileSync(backup, 'utf8')); renameSync(tmp, SETTING_FILE); }
}

const switchStatus = { switching: null, last: null };
async function switchAccount(userId) {
  if (switchStatus.switching) throw new Error('正在切换中');
  const cur = state.relay.frame?.account?.userId ?? state.relay.lastUserId ?? null;
  if (cur === userId) throw new Error('已经是当前账号');
  switchStatus.switching = { target: userId, since: Date.now(), phase: 'write' }; compute();
  let backup;
  try { backup = state.vault.writeAuth(userId); }
  catch (e) { switchStatus.switching = null; switchStatus.last = { ok: false, target: userId, at: Date.now(), message: e.message }; compute(); return switchStatus.last; }
  // Mirasim 每次用 token 都重读 setting.json，不必重启（重启会杀掉它拉起的全部 Claude Code 会话）。
  // 证据两路：会话回环的 /v1/limits 已按新账号返回（强）；帧里的账号变成目标（帧走长连接，可能滞后）。
  switchStatus.switching.phase = 'verify'; compute();
  const deadline = Date.now() + 30_000;
  let ok = false;
  while (Date.now() < deadline) {
    state.relay.ask(true);
    if (await fetchLimits(userId)) { ok = true; break; }
    if (state.relay.frame?.account?.userId === userId) { ok = true; break; }
    await sleep(2000);
  }
  if (ok) {
    state.accountOverride = userId;
    switchStatus.last = { ok: true, target: userId, at: Date.now() };
    refreshLimits().then(refreshLedger).catch(() => {});
  } else {
    const any = await fetchLimits(null);
    if (any && any.subject !== userId) {   // 有会话在、读得到额度，却还是旧账号：文件没被吃到，不能留半截
      try { state.vault.restore(backup); } catch { /* 还原失败会在下一拍被采集成新状态 */ }
      switchStatus.last = { ok: false, target: userId, at: Date.now(), message: 'Mirasim 没有切过去，已还原原来的登录', messageEn: 'Mirasim did not switch; the previous sign-in was restored', backup };
    } else {
      switchStatus.last = { ok: false, unconfirmed: true, target: userId, at: Date.now(), backup,
        message: '已写入新登录，Mirasim 还没确认（没有活跃会话时要等它下次刷新）', messageEn: 'Wrote the new sign-in; Mirasim has not confirmed yet (with no active session it waits for its next refresh)' };
    }
  }
  switchStatus.switching = null; compute();
  return switchStatus.last;
}
/** 把切换前备份的整份 setting.json 还原回去 */
function restoreSwitch() {
  const b = switchStatus.last?.backup; if (!b) { switchStatus.last = null; compute(); return; }
  state.vault.restore(b); state.accountOverride = null; switchStatus.last = null; compute();
  refreshLimits().then(refreshLedger).catch(() => {});
}

/* ---------------- 结论：窗口成本、等价、燃烧、累计 ---------------- */

const POINTS_PER_REGULAR_DOLLAR = 100;   // 普通模型每 $1 标价扣 100 点（实测 96–101）
const POINTS_PER_FABLE5_DOLLAR = 200;    // Fable 每 $1 Fable 5 标价扣 200 点；5.1 也按 5 的价目扣（整窗预测偏差 −0.2%）

const state = {
  ledger: new Ledger(), relay: new Relay(), vault: new AccountVault(), limits: null, limitsAt: 0, accountOverride: null,
  samples: loadJSON(join(STATE_DIR, 'samples.json'), []),
  equiv: loadJSON(join(STATE_DIR, 'equiv.json'), {}),
  speeds: { rows: [], paired: 0, probed: 0 }, snapshotAt: 0, result: null, listeners: new Set(),
};

/** 当前快照：精确源优先，否则帧；帧超过 90 秒没更新算过期 */
function snapshot() {
  const frame = state.relay.frame;
  // 刚切过账号时帧（长连接）身份可能滞后：以切换核对过的账号为准，帧跟上来就撤销覆盖
  if (state.accountOverride && frame?.account?.userId === state.accountOverride) state.accountOverride = null;
  const uid = opt('user', null) || state.accountOverride || frame?.account?.userId || state.limits?.subject || null;
  let account = { ...(frame?.account || {}), userId: uid };
  if (state.accountOverride && frame?.account?.userId !== uid) {
    const saved = state.vault.accounts.find((a) => a.userId === uid);
    account = { userId: uid, name: saved?.name ?? null, plan: saved?.plan ?? null, planExpiry: saved?.planExpiry ?? null, paid: state.limits?.paid ?? null, host: frame?.account?.host ?? null, relayStatus: frame?.account?.relayStatus ?? null };
  }
  if (state.limits && Date.now() - state.limitsAt < STALE_AFTER_S * 1000) {
    return { windows: state.limits.windows, account, capturedAt: state.limitsAt, precision: 'exact', flags: state.limits };
  }
  if (frame) return { windows: frame.windows, account, capturedAt: frame.capturedAt, precision: 'coarse', flags: {} };
  return null;
}

function recordSamples(snap) {
  const now = Date.now();
  for (const w of snap.windows) state.samples.push({ at: now, window: w.name, percent: w.usedPercent, resetAt: w.resetAt, user: snap.account.userId });
  const cutoff = now - 24 * 3600_000;
  if (state.samples.length && state.samples[0].at < cutoff) state.samples = state.samples.filter((s) => s.at >= cutoff);
}

function equivalentRates(windows, uid) {
  const L = state.ledger; let regular = null, fable = null;
  const w7 = windows.find((w) => w.name === '7d'), wf = windows.find((w) => w.modelScoped && w.name.includes('fable'));
  const ss = L.serviceStart;
  if (w7 && wf && w7.usedPoints != null && wf.usedPoints != null && ss != null) {
    const s7 = w7.resetAt - spanOf(w7.name) * 1000, sf = wf.resetAt - spanOf(wf.name) * 1000;
    if (s7 >= ss && sf >= ss) {
      const fableActual = L.spent(sf, null, 'fable', uid).usd;
      if (wf.usedPoints >= 12_000 && fableActual > 0) { const as51 = L.spent(sf, null, 'fable', uid, 'claude-fable-5-1').usd; if (as51 > 0) fable = as51 / wf.usedPoints; }
      const fableIn7d = (Math.abs(s7 - sf) < 120_000 || fableActual <= 0 || wf.usedPoints <= 0) ? wf.usedPoints
        : L.spent(s7, null, 'fable', uid).usd / (fableActual / wf.usedPoints);
      const regPts = w7.usedPoints - fableIn7d;
      const regUSD = L.spent(s7, null, 'claude', uid).usd - L.spent(s7, null, 'fable', uid).usd;
      if (regPts >= 12_000 && regUSD > 0) regular = regUSD / regPts;
    }
  }
  const sane = (p) => (p != null && p >= 0.0005 && p <= 0.1) ? p : null;
  regular = sane(regular); fable = sane(fable);
  if (regular == null) regular = 1 / POINTS_PER_REGULAR_DOLLAR;
  if (fable == null && wf) {
    const sf = wf.resetAt - spanOf(wf.name) * 1000;
    const at51 = L.spent(sf, null, 'fable', uid, 'claude-fable-5-1').usd, at5 = L.spent(sf, null, 'fable', uid, 'claude-fable-5').usd;
    if (at5 > 1 && at51 > 0) fable = sane(at51 / at5 / POINTS_PER_FABLE5_DOLLAR);
  }
  if (uid) {
    const saved = state.equiv[uid] || {};
    if (regular != null) saved.regular = regular; if (fable != null) saved.fable = fable;
    state.equiv[uid] = saved; saveJSON(join(STATE_DIR, 'equiv.json'), state.equiv);
    return { regular: regular ?? saved.regular ?? null, fable: fable ?? saved.fable ?? null };
  }
  return { regular, fable };
}

const LABEL_EN = { exact: 'Exact', live: 'Live', stale: 'Stale', nomirasim: 'Mirasim not running', mismatch: 'Bad frame', connecting: 'Connecting' };
function labelEnOf(name) {
  const fixed = { '5h': '5 hours', '7d': '7 days', '7d_fable': '7 days · Fable 5.1' };
  if (fixed[name]) return fixed[name];
  const [head, ...rest] = name.split('_'); const m = /^(\d+)([hdmw])$/.exec(head);
  const unit = m ? { h: 'hour', d: 'day', m: 'min', w: 'week' }[m[2]] : null;
  const base = m ? `${m[1]} ${unit}${unit !== 'min' && m[1] !== '1' ? 's' : ''}` : head;
  return rest.length ? base + ' · ' + rest.join(' ') : base;
}
/** 时长的中英两种读法，最多两级 */
function durationText(ms) {
  const s = Math.max(0, Math.floor(ms / 1000)); const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  const zh = d ? `${d} 天${h ? ` ${h} 小时` : ''}` : h ? `${h} 小时${m ? ` ${m} 分钟` : ''}` : m ? `${m} 分钟` : `${s} 秒`;
  const en = d ? `${d} d${h ? ` ${h} h` : ''}` : h ? `${h} h${m ? ` ${m} min` : ''}` : m ? `${m} min` : `${s} s`;
  return { zh, en };
}

function compute() {
  const snap = snapshot();
  const L = state.ledger;
  const now = Date.now();
  const uid = snap?.account?.userId || opt('user', null) || null;
  const relayStatus = state.relay.status;
  let level = 'connecting';
  if (snap) level = (now - snap.capturedAt > STALE_AFTER_S * 1000 && snap.precision === 'coarse') ? 'stale' : (snap.precision === 'exact' ? 'exact' : 'live');
  else if (relayStatus === 'nomirasim') level = 'nomirasim';
  else if (relayStatus === 'mismatch') level = 'mismatch';
  const LABEL = { exact: '精确', live: '实时', stale: '已过期', nomirasim: 'Mirasim 未运行', mismatch: '读不懂帧', connecting: '连接中' };

  const windows = [];
  if (snap) {
    const eq = equivalentRates(snap.windows, uid);
    const w7 = snap.windows.find((w) => w.name === '7d');
    const inverted = (w) => {
      const span = spanOf(w.name); if (span == null) return null;
      const start = w.resetAt - span * 1000; const ss = L.serviceStart;
      if (ss == null || start < ss || w.usedPercent <= 0.01) return null;
      const enough = w.usedPoints != null ? w.usedPoints >= 12_000 : w.usedPercent >= 3;
      if (!enough) return null;
      const group = w.modelScoped ? w.name.split('_').slice(1).join('_') : 'claude';
      const { usd, n } = L.spent(start, null, group, uid);
      if (usd <= 0) return null;
      return { usd, n, full: usd / (w.usedPercent / 100), per: w.usedPoints > 0 ? usd / w.usedPoints : null };
    };
    const per7 = w7 ? inverted(w7)?.per ?? null : null;
    for (const w of snap.windows) {
      const span = spanOf(w.name);
      const start = span != null ? w.resetAt - span * 1000 : null;
      const group = w.modelScoped ? w.name.split('_').slice(1).join('_') : 'claude';
      let cost;
      const inv = uid ? inverted(w) : null;
      if (inv) cost = { spentUSD: inv.usd, requests: inv.n, perPointUSD: inv.per, fullUSD: inv.full };
      else {
        const { usd, n } = start != null && uid ? L.spent(start, null, group, uid) : { usd: 0, n: 0 };
        const per = per7 ?? (w.modelScoped ? eq.fable : eq.regular);
        cost = (per != null && w.usedPoints != null && w.budgetPoints != null)
          ? { spentUSD: per * w.usedPoints, requests: n, perPointUSD: per, fullUSD: per * w.budgetPoints }
          : { spentUSD: usd, requests: n, perPointUSD: null, fullUSD: null };
      }
      if (w.budgetPoints != null) {
        if (!w.modelScoped) cost.fullRegularUSD = eq.regular != null ? eq.regular * w.budgetPoints : null;
        if (!w.modelScoped || group === 'fable') cost.fullFableUSD = eq.fable != null ? eq.fable * w.budgetPoints : null;
        if (group === 'fable' && eq.fable != null) cost.fullFableAtF5USD = w.budgetPoints / POINTS_PER_FABLE5_DOLLAR;
      }
      // 燃烧速率：同账号、同窗口周期、近 6 小时样本的首尾斜率
      const pts = state.samples.filter((s) => s.window === w.name && s.user === uid && uid && Math.abs(s.resetAt - w.resetAt) < 1000 && now - s.at < 6 * 3600_000).sort((a, b) => a.at - b.at);
      let burn = null;
      if (pts.length >= 3) {
        const spanS = (pts[pts.length - 1].at - pts[0].at) / 1000;
        if (spanS >= 60) {
          const rate = (pts[pts.length - 1].percent - pts[0].percent) / (spanS / 3600);
          let exhaustAt = null;
          if (rate > 0.01) { const h = (100 - w.usedPercent) / rate; if (Number.isFinite(h) && h >= 0 && h < 24 * 30) exhaustAt = now + h * 3600_000; }
          burn = { percentPerHour: rate, exhaustAt, samples: pts.length, span: spanS, trustworthy: pts.length >= 3 && spanS >= 300 };
        }
      }
      const trendBack = 2 * 3600_000;
      const trend = state.samples.filter((s) => s.window === w.name && s.user === uid && now - s.at < trendBack).map((s) => [Math.round(s.at / 1000), +s.percent.toFixed(3)]);
      const pace = span != null ? Math.min(100, Math.max(0, (now - start) / (span * 1000) * 100)) : null;
      windows.push({ name: w.name, label: labelOf(w.name), labelEn: labelEnOf(w.name), usedPercent: w.usedPercent, usedPoints: w.usedPoints, budgetPoints: w.budgetPoints,
        remainingPoints: w.usedPoints != null ? Math.max(0, w.budgetPoints - w.usedPoints) : null, resetAt: w.resetAt, windowStart: start,
        pacePercent: pace, paceDelta: pace != null ? w.usedPercent - pace : null, modelScoped: w.modelScoped, modelGroup: w.modelScoped ? group : null,
        precision: w.precision, upstreamStatus: w.upstreamStatus, cost, burn, trend: trend.filter((_, i, a) => i % Math.max(1, Math.floor(a.length / 120)) === 0) });
    }
  }

  // 累计：本周（周一起）/ 本月 / 今日 / 近 14 天，只算当前账号
  let totals = null;
  if (uid) {
    const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
    const week = new Date(midnight); week.setDate(week.getDate() - ((week.getDay() + 6) % 7));
    const month = new Date(midnight); month.setDate(1);
    const today = L.spent(midnight.getTime(), null, null, uid), wk = L.spent(week.getTime(), null, null, uid), mo = L.spent(month.getTime(), null, null, uid);
    const daily = L.daily(14, uid);
    const w7 = windows.find((w) => w.name === '7d');
    const weekBudget = w7?.cost?.fullUSD ?? null;
    const daysInMonth = new Date(midnight.getFullYear(), midnight.getMonth() + 1, 0).getDate();
    const elapsedDays = Math.max(1, Math.ceil((now - week.getTime()) / 86400_000));
    const full = daily.filter((d) => d.day < midnight.getTime()).slice(-7);
    const monthEnd = new Date(midnight.getFullYear(), midnight.getMonth() + 1, 1).getTime();
    const avg = full.length ? full.reduce((s, d) => s + d.usd, 0) / full.length : null;
    const gap = L.backfillGap(now - 86400_000, uid);
    totals = { today, week: wk, month: mo, daily, weekBudget, monthBudget: weekBudget != null ? weekBudget / 7 * daysInMonth : null,
      dayAverage: wk.usd > 0 ? wk.usd / elapsedDays : null,
      monthProjection: (mo.usd > 0 && avg != null) ? mo.usd + avg * Math.max(0, (monthEnd - now) / 86400_000) : null,
      coverageWarning: (gap.unmetered >= 20 && gap.unmetered > (gap.metered + gap.unmetered) * 0.05) ? `近 24 小时有 ${gap.unmetered} 次调用还没回填用量，已花是下界` : null };
  }

  // 会话卡 / 请求成败 / 最近调用 / 提示区块（中英各一份文案，页面按语言取）
  const sessions = uid ? L.sessions(now - 6 * 3600_000, uid, 5) : [];
  const stats = L.requestStats(now - 3600_000, uid, 12);
  const recent = L.recentCalls(10, uid);
  const flags = snap?.flags || {};
  const accountNotice = flags.suspended ? { zh: '账号被暂停，额度数字仅供参考', en: 'Account suspended; quota figures are indicative only' }
    : flags.unmetered ? { zh: '账号不计量，额度上限不适用', en: 'Account is unmetered; quota caps do not apply' }
    : flags.degraded ? { zh: '上游降级运行中', en: 'Upstream is running degraded' } : null;
  const notices = [];
  const alertAt = Number(opt('alert', 90)) || 90;
  for (const w of windows) {
    if (w.usedPercent < alertAt) continue;
    const left = durationText(w.resetAt - now);
    notices.push(w.usedPercent >= 100
      ? { level: 2, zh: `${w.label} 已用满，${left.zh} 后重置`, en: `${w.labelEn} exhausted, resets in ${left.en}` }
      : { level: 1, zh: `${w.label} 已用 ${w.usedPercent.toFixed(0)}%，${left.zh} 后重置`, en: `${w.labelEn} ${w.usedPercent.toFixed(0)}% used, resets in ${left.en}` });
  }
  const failed30 = L.recent.filter((r) => r.at >= now - 1800_000 && (!uid || r.user === uid) && r.status !== 200).length;
  if (failed30 >= 2) {
    const codes = Object.entries(stats.codes).sort((a, b) => b[1] - a[1]).map(([c, n]) => `${c}×${n}`).join(' ');
    notices.push({ level: 1, zh: `近 30 分钟 ${failed30} 次请求失败（近 1 小时错误码 ${codes}）`, en: `${failed30} failed requests in the last 30 min (1h codes: ${codes})` });
  }
  if (stats.rateLimited.length) {
    const names = stats.rateLimited.map(prettyModel);
    notices.push({ level: 1, zh: `限流中：${names.join('、')} 近 10 分钟有 429`, en: `Rate limited: ${names.join(', ')} returned 429 in the last 10 min` });
  }
  if (accountNotice) notices.push({ level: 1, ...accountNotice });
  if (totals?.coverageWarning) {
    const gap = L.backfillGap(now - 86400_000, uid);
    notices.push({ level: 0, zh: totals.coverageWarning, en: `${gap.unmetered} calls in the last 24h have no usage backfilled yet; spent is a lower bound` });
  }
  notices.sort((a, b) => b.level - a.level);
  state.result = {
    version: VERSION, generatedAt: now, state: level, stateLabel: LABEL[level], stateLabelEn: LABEL_EN[level], precision: snap?.precision ?? null,
    capturedAt: snap?.capturedAt ?? null, account: snap?.account ?? null, accountNotice: accountNotice?.zh ?? null,
    windows, totals, speeds: state.speeds.rows, pairing: { paired: state.speeds.paired, probed: state.speeds.probed }, channelPort: state.relay.port,
    sessions, stats, recent, notices, lang: opt('lang', null),
    accounts: flag('no-accounts') ? [] : state.vault.publicList(), switching: switchStatus.switching, lastSwitch: switchStatus.last,
  };
  for (const fn of state.listeners) fn();
  return state.result;
}

/* ---------------- 采集节拍 ---------------- */

async function refreshLimits() {
  const p = await fetchLimits(state.accountOverride || state.relay.lastUserId);
  if (p) { state.limits = p; state.limitsAt = Date.now(); }
  else if (Date.now() - state.limitsAt > STALE_AFTER_S * 1000) state.limits = null;
  const snap = snapshot();
  if (snap) recordSamples(snap);
  compute();
}
let ledgerBusy = false, lastLedgerAt = 0, pendingLedger = null, insightsStamp = null;
function refreshLedger() {
  if (ledgerBusy) return; ledgerBusy = true;
  try {
    const uid = opt('user', null) || state.relay.lastUserId || state.limits?.subject || null;
    state.ledger.refresh();
    state.speeds = speedRows(uid);
    lastLedgerAt = Date.now();
    compute();
  } finally { ledgerBusy = false; }
}
/** 流水文件一变就刷（1.2–5 秒内），不必等整分钟 */
function pollInsights() {
  if (!flag('no-accounts') && !switchStatus.switching && state.vault.captureIfChanged(state.result)) compute();
  const names = state.ledger.usageFiles(); if (!names.length) return;
  let st; try { st = statSync(join(INSIGHTS_DIR, names[names.length - 1])); } catch { return; }
  const stamp = st.size + ':' + st.mtimeMs;
  if (insightsStamp === stamp) return;
  const first = insightsStamp == null; insightsStamp = stamp;
  if (first) return;
  clearTimeout(pendingLedger);
  pendingLedger = setTimeout(refreshLedger, Math.max(1200, 5000 - (Date.now() - lastLedgerAt)));
}

/* ---------------- HTTP：面板 + JSON + SSE ---------------- */

function startServer() {
  const UI_FILE = join(HERE, 'ui.html');
  const server = createServer((req, res) => {
    const path = (req.url || '/').split('?')[0];
    const head = { 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': 'http://127.0.0.1' };
    if (path === '/' || path === '/index.html') {
      let html; try { html = readFileSync(UI_FILE, 'utf8'); } catch { res.writeHead(500, head); return res.end('ui.html 不在脚本旁边'); }
      res.writeHead(200, { ...head, 'Content-Type': 'text/html; charset=utf-8' }); return res.end(html);
    }
    if (path === '/quota.json') { res.writeHead(200, { ...head, 'Content-Type': 'application/json; charset=utf-8' }); return res.end(JSON.stringify(state.result || { state: 'connecting', stateLabel: '连接中', windows: [] })); }
    if (path === '/api/health') { res.writeHead(200, { ...head, 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ name: 'mirasim-telemetry', version: VERSION })); }
    if (path === '/refresh' && req.method === 'POST') { state.relay.ask(true); refreshLimits().then(refreshLedger); res.writeHead(204, head); return res.end(); }
    if (path === '/accounts') { res.writeHead(200, { ...head, 'Content-Type': 'application/json; charset=utf-8' }); return res.end(JSON.stringify({ accounts: state.vault.publicList(), current: state.relay.frame?.account?.userId ?? null, switching: switchStatus.switching, lastSwitch: switchStatus.last })); }
    if (path === '/switch/restore' && req.method === 'POST') { try { restoreSwitch(); res.writeHead(204, head); } catch (e) { res.writeHead(500, head); res.write(e.message); } return res.end(); }
    if (path === '/switch/ack' && req.method === 'POST') { switchStatus.last = null; compute(); res.writeHead(204, head); return res.end(); }
    if ((path === '/switch' || path === '/accounts/remove') && req.method === 'POST') {
      let body = ''; req.on('data', (c) => { body += c; if (body.length > 4096) req.destroy(); });
      req.on('end', () => {
        let uid = null; try { uid = JSON.parse(body || '{}').userId; } catch { /* 空体 */ }
        if (!uid) { res.writeHead(400, head); return res.end('userId?'); }
        if (path === '/accounts/remove') { state.vault.remove(uid); compute(); res.writeHead(204, head); return res.end(); }
        switchAccount(uid).catch((e) => log(`切换账号失败：${e.message}`));
        res.writeHead(202, head); res.end();     // 进度看 /quota.json 的 switching / lastSwitch（SSE 会推）
      });
      return;
    }
    if (path === '/events') {
      res.writeHead(200, { ...head, 'Content-Type': 'text/event-stream', Connection: 'keep-alive' });
      res.write(': hi\n\n');
      const push = () => { try { res.write('event: update\ndata: 1\n\n'); } catch { /* 客户端走了 */ } };
      const beat = setInterval(() => { try { res.write(': beat\n\n'); } catch { /* 同上 */ } }, 15000);
      state.listeners.add(push);
      req.on('close', () => { state.listeners.delete(push); clearInterval(beat); });
      return;
    }
    res.writeHead(404, head); res.end();
  });
  return new Promise((resolve, reject) => {
    const explicit = Number(opt('port', 0)); let port = explicit || UI_PORT_LO;
    server.on('error', (e) => { if (e.code === 'EADDRINUSE' && !explicit && port < UI_PORT_HI) server.listen(++port, '127.0.0.1'); else reject(e); });
    server.on('listening', () => resolve({ server, port }));
    server.listen(port, '127.0.0.1');   // 只绑回环
  });
}

function openPanel(url) {
  const app = flag('app');
  if (IS_WIN) {
    // 应用窗口模式：无地址栏的小窗。Edge 是 Windows 自带的，优先；没有就 Chrome，再没有就默认浏览器
    const args = app ? [`--app=${url}`, '--window-size=400,860'] : [url];
    execFile('cmd.exe', ['/c', 'start', '', app ? 'msedge' : url, ...(app ? args : [])], { windowsHide: true }, (err) => {
      if (err && app) execFile('cmd.exe', ['/c', 'start', '', 'chrome', ...args], { windowsHide: true }, (e2) => { if (e2) execFile('cmd.exe', ['/c', 'start', '', url], { windowsHide: true }); });
    });
  } else if (platform() === 'darwin') {
    if (app) execFile('open', ['-na', 'Google Chrome', '--args', `--app=${url}`, '--window-size=400,860'], (err) => { if (err) execFile('open', [url]); });
    else execFile('open', [url]);
  } else execFile('xdg-open', [url]);
}

/* ---------------- 自检 ---------------- */

async function doctor() {
  const say = (s) => console.log(s);
  say(`Mirasim 遥测 跨平台版 ${VERSION} · ${platform()} ${process.arch} · Node ${process.version}`);
  const procs = await mirasimProcesses();
  say(`1. Mirasim 进程：${procs.length ? procs.map((p) => `pid ${p.pid}`).join('、') : '未找到（Mirasim 没开，或进程命令行里没有 server.cjs）'}`);
  const channel = await discoverChannelPort(procs);
  say(`2. mirachannel 端口：${channel ?? '未发现（/api/health 校验失败）'}`);
  const frame = await new Promise((resolve) => {
    if (!channel) return resolve(null);
    const r = new Relay(); r.port = channel; r.onFrame = () => { if (r.frame) { try { r.ws?.close(); } catch { /* */ } resolve(r.frame); } };
    r.connect(); setTimeout(() => resolve(r.frame), 6000);
  });
  if (frame) say(`3. relay 帧：可读，账号 ${frame.account.userId ?? '?'}（${frame.account.name ?? '?'} · ${frame.account.plan ?? '?'}）；窗口 ${frame.windows.map((w) => `${w.name} ${w.usedPercent.toFixed(1)}%`).join('，')}`);
  else say('3. relay 帧：读不到');
  const { routes, method } = await sessionRoutes();
  say(`4. 会话路由：${routes.length} 条（${method}）${routes.length ? '，端口 ' + routes.map((r) => r.port).join('、') : ''}`);
  let limits = null;
  for (const r of routes) {
    const p = parseLimits(await getJSON(`${r.base}/v1/limits`, 6000, { 'x-api-key': r.token, accept: 'application/json' }));
    say(`   ${r.base.replace(/\/[^/]{8,}$/, '/…')} → ${p ? `账号 ${p.subject}：` + p.windows.map((w) => `${w.name} ${Math.round(w.usedPoints)}/${Math.round(w.budgetPoints)} 点`).join('，') : '读不到（401/超时/无该端点）'}`);
    if (p && !limits) limits = p;
  }
  if (!routes.length) say('   Windows 上若两步都空：在 Claude Code 会话里执行 echo $env:ANTHROPIC_BASE_URL / $env:ANTHROPIC_AUTH_TOKEN，用 --router-base 与 --router-token 传进来');
  const uid = frame?.account?.userId || limits?.subject || null;
  const L = state.ledger; L.refresh();
  const files = L.usageFiles();
  say(`5. 流水 ${INSIGHTS_DIR}：${files.length ? files.join('、') : '不存在'}；已计价 ${L.entries.length} 条，价目目录 ${existsSync(CATALOG_FILE) ? '在' : '缺（用内置表）'}`);
  if (uid) { const m = new Date(); m.setHours(0, 0, 0, 0); const t = L.spent(m.getTime(), null, null, uid); say(`   今日（账号 ${uid}）≈$${t.usd.toFixed(2)} / ${t.n} 次`); }
  const sp = speedRows(uid);
  say(`6. Claude Code 账本 ${CLAUDE_PROJECTS}：${existsSync(CLAUDE_PROJECTS) ? '在' : '不存在'}；最近 12 次请求配上号的 ${sp.paired}/${sp.probed}`);
  for (const r of sp.rows.slice(0, 4)) say(`   ${r.model}${r.background ? '(后台)' : ''}: ${r.medianSeconds.toFixed(1)}s/轮${r.tokensPerSecond ? ` ${r.tokensPerSecond.toFixed(0)}tok/s` : ''}${r.firstSeconds ? ` 首字${r.firstSeconds.toFixed(1)}s` : ''}`);
  say(`7. 结论：${limits ? '精确口径可用' : frame ? '只有帧口径（0.1%，无点数）——按第 4 步提示补令牌' : '取不到额度'}`);
}

/* ---------------- 主流程 ---------------- */

if (flag('doctor')) { await doctor(); process.exit(0); }

if (flag('once')) {
  const procs = await mirasimProcesses();
  const channel = await discoverChannelPort(procs);
  const frame = await new Promise((resolve) => {
    if (!channel) return resolve(null);
    const r = new Relay(); r.port = channel; r.onFrame = () => { if (r.frame) resolve(r.frame); }; r.connect(); setTimeout(() => resolve(r.frame), 6000);
  });
  if (frame) { state.relay.frame = frame; state.relay.lastUserId = frame.account.userId; state.relay.status = 'live'; state.relay.port = channel; }
  const p = await fetchLimits(frame?.account?.userId); if (p) { state.limits = p; state.limitsAt = Date.now(); }
  state.ledger.refresh(); state.speeds = speedRows(frame?.account?.userId || p?.subject || null);
  const r = compute();
  console.log(JSON.stringify(r, null, 2));
  process.exit(r.windows.length ? 0 : 1);
}

const { server, port } = await startServer();
const url = `http://127.0.0.1:${port}/`;
log(`面板 ${url}   JSON ${url}quota.json`);
state.relay.onFrame = () => { const s = snapshot(); if (s) recordSamples(s); compute(); };
state.relay.start();
refreshLedger();
await refreshLimits();
setInterval(() => refreshLimits().catch(() => {}), LIMITS_EVERY_MS);
setInterval(refreshLedger, LEDGER_EVERY_MS);
setInterval(pollInsights, 3000);
setInterval(() => saveJSON(join(STATE_DIR, 'samples.json'), state.samples), 60_000);
if (!flag('no-open')) openPanel(url);

function shutdown() { saveJSON(join(STATE_DIR, 'samples.json'), state.samples); server.close(); process.exit(0); }
process.on('SIGINT', shutdown); process.on('SIGTERM', shutdown);
