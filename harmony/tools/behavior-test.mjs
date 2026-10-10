////////////////////////////////////////////////////////////////////////////////
//
// harmony/tools/behavior-test.mjs
//
// 「收藏/发送历史同步到登录账号」的**行为**测试：真跑 VoiceInputAccount 和
// ServerConfig 这两个类，不是源字符串判定。
//
// 做法：用 DevEco 自带的 typescript 把 .ets transpile 成 CommonJS，注入假的
// preferences / http / asset / fileIo / util / hilog 和确定性时钟，在 node 里
// 真实执行类逻辑。entry 和 pad 两端各跑一遍同一套用例。
//
// 覆盖（复审点名要的四条 + 互斥）：
//   1. 离线重启：队列落盘 → 新进程 → 会话恢复 → 续传
//   2. 上传期间新编辑：voice POST 在途加收藏，不被回执覆盖
//   3. 切账号旧回包：旧账号的 POST 回执到达时不能污染新账号
//   4. rest 在 voice POST 在途：personal PUT 必须先 flush、绝不与 POST 并发
//   5. 端到端不丢：keepPendingPersonal 时个人改动保留并最终上传
//   6. 乱序迟到的旧 GET 不得回退已确认状态（个人版本下限，取 X-Personal-Version 原始值）
//   7. ack 前进幅度不是 +1（另一台设备并发写过）时，下限照样护住已确认收藏
//   8. 普通 GET 采纳也记已见版本 → 新的先到、旧的后到不得回退
//   9. 切账号清本账号下限（不能拿 alice 的下限拒 bob 的快照）
//
// 跑法（退出码 0 = 全绿）：
//   node harmony/tools/behavior-test.mjs
// 不联网、不碰真机、不启轮询、不写仓库外任何文件。
//
////////////////////////////////////////////////////////////////////////////////

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const requireCJS = createRequire(import.meta.url);

// ---- DevEco 自带 typescript（离线可用，不装依赖）----
function loadTS() {
  const cands = [
    process.env.DEVECO_TYPESCRIPT,
    '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript',
    '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript',
    '/Applications/DevEco-Studio.app/Contents/plugins/codelinter/node_modules/typescript',
  ].filter(Boolean);
  for (const c of cands) {
    try { return requireCJS(c); } catch (e) { /* 换下一个 */ }
  }
  throw new Error('找不到 DevEco 自带的 typescript；设 DEVECO_TYPESCRIPT 指向 typescript 模块目录');
}
const TS = loadTS();

let PASS = 0, FAIL = 0;
const failures = [];
function ok(name, cond, extra) {
  if (cond) { PASS++; console.log(`  ✅ ${name}`); }
  else { FAIL++; failures.push(name); console.log(`  ❌ ${name}${extra !== undefined ? '  →  ' + extra : ''}`); }
}
const section = (t) => console.log(`\n--- ${t} ---`);

// 清空 microtask（用真 setImmediate；setTimeout 被下面的假时钟劫持了）
const micro = () => new Promise((r) => setImmediate(r));

// ---- 确定性时钟：劫持全局 setTimeout/setInterval ----
class Clock {
  constructor() { this.now = 0; this._seq = 0; this._timers = new Map(); }
  install() {
    this._saved = { setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout,
                    setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval };
    globalThis.setTimeout = (fn, ms, ...a) => this._add(fn, ms, 0, a);
    globalThis.clearTimeout = (id) => { this._timers.delete(id); };
    globalThis.setInterval = (fn, ms, ...a) => this._add(fn, ms, ms || 1, a);
    globalThis.clearInterval = (id) => { this._timers.delete(id); };
  }
  uninstall() { if (this._saved) Object.assign(globalThis, this._saved); }
  _add(fn, ms, interval, args) {
    const id = ++this._seq;
    this._timers.set(id, { id, at: this.now + (ms || 0), fn, interval, args });
    return id;
  }
  get pendingCount() { return this._timers.size; }
  _earliest(limit) {
    let best = null;
    for (const t of this._timers.values()) {
      if (t.at > limit) { continue; }
      if (best === null || t.at < best.at || (t.at === best.at && t.id < best.id)) { best = t; }
    }
    return best;
  }
  /** 推进 ms 毫秒，逐个执行到期定时器（每个之后清 microtask）*/
  async advance(ms) {
    const limit = this.now + ms;
    let fired = 0;
    for (;;) {
      const t = this._earliest(limit);
      if (t === null) { break; }
      this.now = t.at;
      if (t.interval > 0) { t.at = this.now + t.interval; } else { this._timers.delete(t.id); }
      t.fn(...t.args);
      fired++;
      await micro();
      if (fired > 500) { throw new Error('时钟推进出现死循环'); }
    }
    this.now = limit;
    await micro();
    return fired;
  }
  /** 一直推到没有定时器为止（有上限防 setInterval 死循环）*/
  async drain(max = 400) {
    let n = 0;
    while (this.pendingCount > 0 && n < max) { n += await this.advance(60000); }
    await micro();
    return n;
  }
}

// ---- 假 preferences ----
class FakePrefs {
  constructor(map) { this.map = map; }
  getSync(key, def) { return this.map.has(key) ? this.map.get(key) : def; }
  putSync(key, v) { this.map.set(key, v); }
  has(key) { return Promise.resolve(this.map.has(key)); }
  get(key, def) { return Promise.resolve(this.map.has(key) ? this.map.get(key) : def); }
  put(key, v) { this.map.set(key, v); return Promise.resolve(); }
  delete(key) { this.map.delete(key); return Promise.resolve(); }
  flush() { return Promise.resolve(); }
}

// ---- 假 HTTP ----
const BASE = 'https://blink-api.douwantech.com';

// 卡住「一发」请求：匹配到的第一个请求在发出时就把响应冻结下来（所以交付的是
// 那一瞬间的旧内容），由 release() 决定什么时候交付 —— 用来造「在途」和「迟到旧 GET」。
class Hold {
  constructor(match) {
    this.match = match; this.entered = 0; this.captured = false; this.open = false; this._release = null;
    this.promise = new Promise((r) => { this._release = r; });
  }
  release() { this.open = true; const r = this._release; this._release = null; if (r) { r(); } }
}

function makeHttp(env) {
  class HttpRequest {
    request(url, options) {
      const path = url.startsWith(BASE) ? url.slice(BASE.length) : url;
      const rec = {
        method: options.method, path, body: options.extraData,
        bearer: (options.header || {}).Authorization || '',
        t: env.clock.now, tEnd: -1,
      };
      env.httpLog.push(rec);
      const wrap = (r) => ({ responseCode: r.code, result: r.body === undefined ? '' : r.body, header: r.header || {} });
      const hold = env.holds.find((h) => !h.captured && h.match(rec));
      if (hold) {
        // 关键：在「请求发出」这一瞬间就把响应体算出来冻住，交付推迟到 release()
        hold.captured = true; hold.entered++;
        env.server.clockNow = env.clock.now;
        return env.server.handle(rec).then((r) => hold.promise.then(() => {
          rec.tEnd = env.clock.now;
          return wrap(r);
        }), (e) => { rec.tEnd = env.clock.now; throw e; });
      }
      const go = Promise.resolve();
      return go.then(() => { env.server.clockNow = env.clock.now; return env.server.handle(rec); }).then((r) => {
        rec.tEnd = env.clock.now;
        return wrap(r);
      }, (e) => { rec.tEnd = env.clock.now; throw e; });
    }
    destroy() { }
  }
  return {
    RequestMethod: { GET: 'GET', PUT: 'PUT', POST: 'POST' },
    HttpDataType: { STRING: 'string' },
    createHttp: () => new HttpRequest(),
  };
}

// ---- 假服务器：行为等价的最小模型 ----
function emptyVoice() { return { favorites: [], history: [], favoriteCounts: {} }; }

function applyVoiceOp(state, op) {
  if (op.kind === 'addFavorite') { if (state.favorites.indexOf(op.text) < 0) { state.favorites.push(op.text); } }
  else if (op.kind === 'removeFavorite') {
    state.favorites = state.favorites.filter((t) => t !== op.text);
    const c = {}; for (const k of Object.keys(state.favoriteCounts)) { if (k !== op.text) { c[k] = state.favoriteCounts[k]; } }
    state.favoriteCounts = c;
  }
  else if (op.kind === 'clearFavorites') { state.favorites = []; state.favoriteCounts = {}; }
  else if (op.kind === 'useFavorite') { if (state.favorites.indexOf(op.text) >= 0) { state.favoriteCounts[op.text] = (state.favoriteCounts[op.text] || 0) + 1; } }
  else if (op.kind === 'recordHistory') { state.history = state.history.filter((t) => t !== op.text); state.history.push(op.text); state.history = state.history.slice(-40); }
  else if (op.kind === 'removeHistory') { state.history = state.history.filter((t) => t !== op.text); }
  else if (op.kind === 'clearHistory') { state.history = []; }
}

class FakeServer {
  constructor() {
    this.global = 7;
    this.personal = new Map();       // username -> uint
    this.users = new Map();
    this.tokens = new Map();         // token -> username
    this.voice = new Map();
    this.cfg = new Map();
    this.online = true;
    this.nextUid = 1;
    this.nextToken = 1;
    this.putLog = [];                // 每次 PUT 的记录（路径 + body）
    this.voicePostLog = [];          // 每次 voice POST 的记录
    this.throwOnRequest = false;
  }
  addUser(username, password) {
    this.users.set(username, { id: this.nextUid++, username, password, isAdmin: true, canWrite: true });
    this.personal.set(username, 40);
    this.voice.set(username, emptyVoice());
    this.cfg.set(username, {
      tabsVersion: 1, tabs: [], closedIds: [], agents: {},
      selection: { tabId: '', restSessions: 'tom-markmini-1' },
    });
    return this;
  }
  userOfBearer(bearer) { return this.tokens.get(bearer.replace(/^Bearer /, '')) || null; }
  version(username) { return `${this.global}:${this.personal.get(username)}`; }
  snapshot(username) {
    const c = this.cfg.get(username);
    const u = this.users.get(username);
    return {
      version: this.version(username),
      user: { id: u.id, username, isAdmin: u.isAdmin, canWrite: u.canWrite },
      machines: [{ id: 'markmini', name: 'markmini', host: 'markmini.lan', token: 'mtok' }],
      tabs: { version: c.tabsVersion, tabs: c.tabs, closedIds: c.closedIds },
      selection: c.selection,
      agents: c.agents,
      voiceInput: this.voice.get(username),
      pinned: [{ title: '后台', url: 'https://admin.douwantech.com/admin', position: 0 }],
    };
  }
  async handle(rec) {
    if (this.throwOnRequest) { throw new Error('offline'); }
    if (!this.online) { throw new Error('offline'); }
    if (rec.method === 'POST' && rec.path === '/v1/login') {
      const b = JSON.parse(rec.body);
      const u = this.users.get(b.username);
      if (!u || u.password !== b.password) { return { code: 401, body: 'bad credentials' }; }
      const tok = 'tok-' + (this.nextToken++);
      this.tokens.set(tok, u.username);
      return { code: 200, body: JSON.stringify({ token: tok, user: { id: u.id, username: u.username, isAdmin: u.isAdmin, canWrite: u.canWrite } }) };
    }
    const who = this.userOfBearer(rec.bearer);
    if (who === null) { return { code: 401, body: 'unauthorized' }; }

    if (rec.method === 'GET' && rec.path.startsWith('/v1/config')) {
      const qi = rec.path.indexOf('?version=');
      const want = qi >= 0 ? decodeURIComponent(rec.path.slice(qi + 9)) : '';
      if (want.length > 0 && want === this.version(who)) {
        return { code: 304, body: '', header: { 'x-config-version': this.version(who) } };
      }
      return { code: 200, body: JSON.stringify(this.snapshot(who)) };
    }

    if (rec.method === 'POST' && rec.path === '/v1/config/voice-input') {
      const b = JSON.parse(rec.body);
      const state = this.voice.get(who);
      for (const op of b.operations) { applyVoiceOp(state, op); }
      const pv = this.personal.get(who) + 1;      // POST 推进个人版本
      this.personal.set(who, pv);
      this.voicePostLog.push({ user: who, ops: b.operations.map((o) => o.kind + ':' + o.text), personal: pv, t: this.clockNow });
      return { code: 200, body: JSON.stringify(state), header: { 'X-Personal-Version': String(pv) } };
    }

    if (rec.method === 'PUT' && rec.path.startsWith('/v1/config/')) {
      const what = rec.path.slice('/v1/config/'.length);
      const body = JSON.parse(rec.body);
      const c = this.cfg.get(who);
      if (what === 'tabs') { c.tabs = body.tabs || []; c.closedIds = body.closedIds || []; c.tabsVersion = body.version; }
      else if (what === 'selection') { c.selection = body; }
      else if (what === 'agents') { c.agents = body; }
      this.personal.set(who, this.personal.get(who) + 1);
      this.putLog.push({ user: who, what, body, personal: this.personal.get(who), t: this.clockNow });
      return { code: 204, body: '' };
    }
    return { code: 404, body: 'no route' };
  }
}

// ---- 环境（一次「装机/进程」）----
class Env {
  constructor(backing) {
    this.clock = new Clock();
    this.holds = [];
    this.httpLog = [];
    this.server = new FakeServer();
    this.server.clockNow = 0;
    this.backing = backing || {
      prefs: new Map(),      // name -> Map
      asset: new Map(),      // alias -> text
      files: new Map(),      // path -> text
    };
    this.installed = false;
  }
  prefsMap(name) {
    if (!this.backing.prefs.has(name)) { this.backing.prefs.set(name, new Map()); }
    return this.backing.prefs.get(name);
  }
  /** 同机「重启」：同一份落盘、同一个时钟、同一个服务器，全新类实例 */
  restart() {
    const e = new Env(this.backing);
    e.server = this.server;
    e.clock = this.clock;
    return e;
  }
  /** 卡住一发匹配的请求（发出即冻结响应，release 才交付）。 */
  hold(match) { const h = new Hold(match); this.holds.push(h); return h; }
  installClock() { this.clock.install(); this.installed = true; }
  uninstall() { if (this.installed) { this.clock.uninstall(); this.installed = false; } }

  loadWorld(modelDir) {
    const env = this;
    const registry = new Map();

    const utilStub = {
      generateRandomUUID: (() => { let n = 0; return () => 'uuid-' + (++n); })(),
      TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
      TextDecoder: { create: () => ({ decodeToString: (b) => new TextDecoder().decode(b) }) },
    };
    const stubs = {
      '@kit.ArkData': { preferences: { getPreferences: (ctx, name) => Promise.resolve(new FakePrefs(env.prefsMap(name))) } },
      '@kit.ArkTS': { util: utilStub },
      '@kit.NetworkKit': { http: makeHttp(env) },
      '@kit.PerformanceAnalysisKit': { hilog: { warn() { }, error() { }, info() { } } },
      '@kit.CoreFileKit': {
        fileIo: {
          OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
          openSync: (p) => ({ fd: p }),
          writeSync: (fd, data) => { env.backing.files.set(fd, data); },
          closeSync: () => { },
          readTextSync: (p) => { if (!env.backing.files.has(p)) { throw new Error('ENOENT'); } return env.backing.files.get(p); },
          unlinkSync: (p) => { env.backing.files.delete(p); },
        },
      },
      '@kit.AssetStoreKit': {
        asset: {
          Tag: { ALIAS: 'ALIAS', SECRET: 'SECRET', RETURN_TYPE: 'RETURN_TYPE', ACCESSIBILITY: 'ACCESSIBILITY' },
          ReturnType: { ALL: 'ALL' },
          Accessibility: { DEVICE_FIRST_UNLOCKED: 'DFU' },
          query: (q) => {
            const alias = env._aliasOf(q);
            if (!env.backing.asset.has(alias)) { return Promise.resolve([]); }
            const m = new Map();
            m.set('SECRET', env.backing.asset.get(alias));
            return Promise.resolve([m]);
          },
          add: (m) => { env.backing.asset.set(env._aliasOf(m), m.get('SECRET')); return Promise.resolve(); },
          remove: (q) => { env.backing.asset.delete(env._aliasOf(q)); return Promise.resolve(); },
        },
      },
    };
    env._aliasOf = (m) => {
      const a = m.get ? m.get('ALIAS') : undefined;
      return typeof a === 'string' ? a : new TextDecoder().decode(a);
    };

    function req(spec, fromDir) {
      if (spec.startsWith('.')) {
        const abs = resolve(fromDir, spec + (spec.endsWith('.ets') ? '' : '.ets'));
        return load(abs);
      }
      if (Object.prototype.hasOwnProperty.call(stubs, spec)) { return stubs[spec]; }
      throw new Error('未 stub 的模块：' + spec);
    }
    function load(abs) {
      if (registry.has(abs)) { return registry.get(abs); }
      const src = readFileSync(abs, 'utf8');
      const out = TS.transpileModule(src, {
        compilerOptions: { target: TS.ScriptTarget.ES2020, module: TS.ModuleKind.CommonJS },
      });
      const mod = { exports: {} };
      registry.set(abs, mod.exports);
      const fn = new Function('require', 'exports', 'module', '__filename', '__dirname', out.outputText);
      fn((s) => req(s, dirname(abs)), mod.exports, mod, abs, dirname(abs));
      registry.set(abs, mod.exports);
      return mod.exports;
    }

    return {
      BlinkStore: load(resolve(modelDir, 'BlinkStores.ets')).BlinkStore,
      VoiceInputAccount: load(resolve(modelDir, 'VoiceInputAccount.ets')).VoiceInputAccount,
      ServerConfig: load(resolve(modelDir, 'ServerConfig.ets')).ServerConfig,
    };
  }
}

// 只看配置同步的请求（登录 POST 不算）
const netLog = (env) => env.httpLog.filter((r) => r.path !== '/v1/login');
const voicePosts = (env) => env.httpLog.filter((r) => r.method === 'POST' && r.path === '/v1/config/voice-input');
const personalPuts = (env) => env.httpLog.filter((r) => r.method === 'PUT');

// ---- 装配一台「手机」----
async function boot(env, world, username, opts = {}) {
  const ctx = { filesDir: '/mem/files' };
  const store = new world.BlinkStore();
  await store.load(ctx);
  const cfg = new world.ServerConfig(ctx, store);
  cfg.onApplied = () => { };
  // 页面里就是这条接线：store 落盘个人状态 → ServerConfig.markDirty（防抖上传）
  store.onLocalChange = () => cfg.markDirty();
  const has = await cfg.hasSession();
  if (!has && username !== null) {
    await cfg.login(username, opts.password || 'pw');
  }
  return { ctx, store, cfg };
}

// ---------------------------------------------------------------------------

function suiteFor(end) {
  const modelDir = resolve(REPO, 'harmony', end, 'src', 'main', 'ets', 'model');
  console.log(`\n================  ${end}  ================`);

  return [
    {
      name: '1. 离线重启：队列落盘 → 新进程 → 会话恢复 → 续传',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          await cfg.hasSession();
          cfg.isOnline = true;

          // 离线：请求全失败
          env.server.online = false;
          store.performVoiceInput('addFavorite', '离线加的收藏');
          await env.clock.advance(5000);      // 定时器都跑一遍
          ok('离线时上传不出去，队列留着', store.voiceInputPending('alice').length === 1,
            'pending=' + store.voiceInputPending('alice').length);
          ok('离线时请求失败：服务器没收到（请求本身允许发出去）', env.server.voicePostLog.length === 0,
            'server voicePost=' + env.server.voicePostLog.length);
          ok('离线把这台标记成不在线', cfg.isOnline === false, 'isOnline=' + cfg.isOnline);

          // 「重启」：同一份落盘，新实例
          const env2 = env.restart();
          const w2 = env2.loadWorld(modelDir);
          const { store: store2, cfg: cfg2 } = await boot(env2, w2, 'alice');
          const has = await cfg2.hasSession();
          ok('重启后仍有会话（token 在安全存储）', has === true);
          ok('重启后队列还在（离线改动没丢）', store2.voiceInputPending('alice').length === 1,
            'pending=' + store2.voiceInputPending('alice').length);
          ok('重启后收藏已乐观可见', store2.favorites.indexOf('离线加的收藏') >= 0);

          // 网络恢复 → refresh → 续传
          env2.server.online = true;
          await cfg2.refresh();
          await env2.clock.advance(5000);
          ok('恢复网络后 pending 被续传干净', store2.voiceInputPending('alice').length === 0,
            'pending=' + store2.voiceInputPending('alice').length);
          ok('服务器收到了那条收藏',
            env2.server.voice.get('alice').favorites.indexOf('离线加的收藏') >= 0,
            JSON.stringify(env2.server.voice.get('alice').favorites));
        } finally { env.uninstall(); }
      },
    },

    {
      name: '2. 上传期间新编辑：voice POST 在途加的收藏不被回执覆盖',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;

          store.performVoiceInput('addFavorite', 'A');
          // 卡住 POST
          const gate = env.hold((r) => r.method === 'POST' && r.path === '/v1/config/voice-input');
          await env.clock.advance(1000);
          ok('voice POST 已发出并在途', gate.entered === 1 && voicePosts(env).some((r) => r.tEnd < 0));

          // 在途期间又加一条
          store.performVoiceInput('addFavorite', 'B');
          await env.clock.advance(3000);

          // 放行：回执只含 A
          gate.release();
          await micro(); await env.clock.advance(3000);

          ok('在途期间加的 B 没被回执抹掉', store.favorites.indexOf('B') >= 0,
            JSON.stringify(store.favorites));
          ok('A 也在（回执带回来的）', store.favorites.indexOf('A') >= 0, JSON.stringify(store.favorites));
          ok('B 被第二次 POST 补传出去',
            voicePosts(env).some((r) => JSON.parse(r.body).operations.some((o) => o.kind === 'addFavorite' && o.text === 'B')),
            JSON.stringify(voicePosts(env).map((r) => r.body)));
          ok('服务器上 A、B 都在',
            env.server.voice.get('alice').favorites.join(',') === 'A,B',
            JSON.stringify(env.server.voice.get('alice').favorites));
          ok('最终队列清空（pending 有人续传）', store.voiceInputPending('alice').length === 0,
            JSON.stringify(store.voiceInputPending('alice').map((o) => o.kind + ':' + o.text)));
        } finally { env.uninstall(); }
      },
    },

    {
      name: '3. 切账号旧回包：旧账号在途回执不污染新账号',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          env.server.addUser('bob', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;

          store.performVoiceInput('addFavorite', 'alice 的收藏');
          const gate = env.hold((r) => r.method === 'POST' && r.path === '/v1/config/voice-input');
          await env.clock.advance(1000);
          ok('alice 的 POST 在途', gate.entered === 1);

          // 切账号：登出 + 登 bob
          await cfg.logout();
          await cfg.login('bob', 'pw');
          cfg.isOnline = true;
          const bobBefore = JSON.stringify(store.favorites);

          // 现在放行 alice 的旧回执
          gate.release();
          await micro(); await env.clock.advance(3000);

          ok('旧回执没有把 alice 的收藏塞进 bob 的界面', JSON.stringify(store.favorites) === bobBefore,
            'bob 看到了 ' + JSON.stringify(store.favorites));
          ok('bob 没有 alice 的待传队列', store.voiceInputPending('bob').length === 0,
            JSON.stringify(store.voiceInputPending('bob').map((o) => o.kind + ':' + o.text)));
          ok('bob 的账号没有被旧回执改掉', cfg.username === 'bob', cfg.username);
        } finally { env.uninstall(); }
      },
    },

    {
      name: '4. rest 在 voice POST 在途：personal PUT 不得与 POST 并发',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;
          env.server.clockNow = 0;

          store.performVoiceInput('addFavorite', 'A');
          const gate = env.hold((r) => r.method === 'POST' && r.path === '/v1/config/voice-input');
          await env.clock.advance(1000);
          ok('voice POST 在途', gate.entered === 1);

          // 在途期间用户动了休息开关 → markDirty → personal 定时器
          store.restActive = ['tom-markmini-2'];
          store.restLoaded = true;
          store.saveResting();
          await env.clock.advance(3000);      // personal 的 800ms 定时器早就到点了

          const inFlight = env.httpLog.filter((r) => r.tEnd < 0);
          ok('POST 在途时 personal PUT 被挡住（互斥）', personalPuts(env).length === 0,
            'PUT: ' + JSON.stringify(personalPuts(env).map((r) => r.path)));
          ok('确实有一发请求卡在途（防假绿）', inFlight.some((r) => r.path === '/v1/config/voice-input'),
            JSON.stringify(inFlight.map((r) => r.method + ' ' + r.path)));

          // 放行 POST：回执版本 = 自己写入 +1
          gate.release();
          await micro(); await env.clock.advance(6000);

          const post = voicePosts(env)[0];
          const puts = personalPuts(env);
          ok('POST 之后 personal PUT 才发出（不并发）', puts.length >= 3,
            'puts=' + JSON.stringify(puts.map((r) => r.path)));
          const overlap = puts.some((p) => p.t < post.tEnd);
          ok('没有任何 PUT 与 POST 时间窗重叠', overlap === false,
            `post=[${post.t},${post.tEnd}] puts=` + JSON.stringify(puts.map((p) => [p.t, p.tEnd])));

          // 在途时改的休息开关必须活下来，并且最终传上去
          ok('在途时改的 rest 没被回读抹掉', JSON.stringify(store.restActive) === JSON.stringify(['tom-markmini-2']),
            JSON.stringify(store.restActive));
          const sentRest = env.server.putLog.filter((p) => p.what === 'selection').map((p) => p.body.restSessions);
          ok('rest 改动最终被 PUT 上传', sentRest.indexOf('tom-markmini-2') >= 0, JSON.stringify(sentRest));
          ok('服务器上就是新值', env.server.cfg.get('alice').selection.restSessions === 'tom-markmini-2',
            env.server.cfg.get('alice').selection.restSessions);
          ok('队列最终清空', store.voiceInputPending('alice').length === 0);
        } finally { env.uninstall(); }
      },
    },

    {
      name: '5. dirty 先于 voice：voice 先 flush personal（before 取在 PUT 之后）',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;

          // 先排 voice（定时器先在），再 markDirty —— 两个定时器同在 t+800
          store.performVoiceInput('addFavorite', 'A');
          store.restActive = ['tom-markmini-3'];
          store.restLoaded = true;
          store.saveResting();          // → markDirty → personal 定时器

          await env.clock.advance(6000);

          const order = netLog(env).filter((r) => r.method === 'PUT' || r.method === 'POST')
            .map((r) => r.method);
          const firstPost = order.indexOf('POST');
          const putsBeforePost = order.slice(0, firstPost).filter((m) => m === 'PUT').length;
          ok('voice 先 flush personal：POST 之前先跑完 PUT',
            firstPost >= 0 && putsBeforePost >= 3, JSON.stringify(order));
          ok('恰好一次 voice POST（没有并发重入）',
            order.filter((m) => m === 'POST').length === 1, JSON.stringify(order));

          const restSent = env.server.putLog.filter((p) => p.what === 'selection').map((p) => p.body.restSessions);
          ok('personal 改动随 flush 上传', restSent.indexOf('tom-markmini-3') >= 0, JSON.stringify(restSent));
          ok('收藏上传成功', env.server.voice.get('alice').favorites.indexOf('A') >= 0);
          ok('最终不残留 dirty', cfg.dirty === false, 'dirty=' + cfg.dirty);
          ok('最终队列清空', store.voiceInputPending('alice').length === 0);
        } finally { env.uninstall(); }
      },
    },

    {
      name: '6. keepPendingPersonal：回读不拿旧快照覆盖本地未上传的个人段',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;

          store.performVoiceInput('addFavorite', 'A');
          const gate = env.hold((r) => r.method === 'POST' && r.path === '/v1/config/voice-input');
          await env.clock.advance(1000);
          ok('voice POST 在途', gate.entered === 1);

          // 在途期间把本地 tabs 也改了（模拟新建/关闭标签）+ rest
          store.tabs = [{ id: 'local-1', machineId: 'markmini', workDirId: '/w', tmuxSession: 'tom-markmini-9', useTmux: true }];
          store.closedIds = ['local-closed'];
          store.restActive = ['tom-markmini-9'];
          store.restLoaded = true;
          store.saveResting();
          await env.clock.advance(3000);

          gate.release();
          await micro(); await env.clock.advance(6000);

          ok('回读没有把本地刚建的标签冲掉',
            store.tabs.length === 1 && store.tabs[0].id === 'local-1',
            JSON.stringify(store.tabs.map((t) => t.id)));
          ok('回读没有把本地墓碑冲掉', store.closedIds.indexOf('local-closed') >= 0, JSON.stringify(store.closedIds));
          ok('回读没有把 rest 改动冲掉', store.restActive.indexOf('tom-markmini-9') >= 0, JSON.stringify(store.restActive));
          // 「本地改动必须最终上传」
          await env.clock.drain();
          ok('本地标签最终被上传到服务器',
            env.server.cfg.get('alice').tabs.some((t) => t.id === 'local-1'),
            JSON.stringify(env.server.cfg.get('alice').tabs.map((t) => t.id)));
          ok('墓碑最终被上传', env.server.cfg.get('alice').closedIds.indexOf('local-closed') >= 0,
            JSON.stringify(env.server.cfg.get('alice').closedIds));
        } finally { env.uninstall(); }
      },
    },

    {
      name: '7. 迟到旧 GET 不得抹掉已确认收藏（ack 的版本不是 +1：另一台设备并发写过）',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;
          ok('起始版本 7:40', cfg.version === '7:40', cfg.version);

          // 让这发 GET 一定返 200，并把它冻在「ack 之前」的内容上（收藏还是空的）
          env.server.global = 8;
          const late = env.hold((r) => r.method === 'GET' && r.path.startsWith('/v1/config'));
          const inflight = cfg.refresh();
          await micro();
          ok('旧 GET 发出且被冻住在途（未交付）',
            late.entered === 1 && netLog(env).some((r) => r.method === 'GET' && r.tEnd < 0),
            JSON.stringify(netLog(env).map((r) => r.method + ' ' + r.path + ' [' + r.t + ',' + r.tEnd + ']')));

          // 另一台设备先写过一次：personal 40 → 41
          env.server.personal.set('alice', 41);
          // 本机再写收藏 → POST 之后 personal = 42（前进 2，不是 +1）
          store.performVoiceInput('addFavorite', 'ack 后的收藏');
          await env.clock.advance(2000);

          const acked = env.server.voicePostLog[env.server.voicePostLog.length - 1];
          ok('本轮 ack 的 personal 前进幅度是 2（不是 +1）',
            acked !== undefined && acked.personal === 42, JSON.stringify(acked));
          ok('ownConfigVersion 对 7:40→42 返回空（只靠 +1 认不出自己这次写入）',
            w.VoiceInputAccount.ownConfigVersion('7:40', '42') === '');
          ok('下限被抬到**原始** X-Personal-Version 42（不靠 +1）',
            cfg.voiceFloorPersonal === 42, 'floor=' + cfg.voiceFloorPersonal);
          ok('已确认的收藏在服务器上',
            env.server.voice.get('alice').favorites.indexOf('ack 后的收藏') >= 0,
            JSON.stringify(env.server.voice.get('alice').favorites));
          ok('本机也已确认', store.favorites.indexOf('ack 后的收藏') >= 0, JSON.stringify(store.favorites));

          // 现在才交付那发迟到的旧 GET（内容是 ack 之前的：收藏为空、personal 40）
          late.release();
          await micro(); await env.clock.advance(3000);
          await inflight;

          ok('迟到旧 GET 没有抹掉已确认的收藏', store.favorites.indexOf('ack 后的收藏') >= 0,
            JSON.stringify(store.favorites));
          ok('收藏没被清空', store.favorites.length === 1, JSON.stringify(store.favorites));
          ok('下限没被旧快照拉低', cfg.voiceFloorPersonal === 42, 'floor=' + cfg.voiceFloorPersonal);
        } finally { env.uninstall(); }
      },
    },

    {
      name: '8. GET 乱序：新快照先采纳、旧快照后到不得回退（普通 GET 采纳也记已见版本）',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;

          store.performVoiceInput('addFavorite', 'A');
          await env.clock.advance(2000);
          ok('A 已 ack', env.server.voice.get('alice').favorites.join(',') === 'A',
            JSON.stringify(env.server.voice.get('alice').favorites));
          ok('ack 后下限是 41', cfg.voiceFloorPersonal === 41, 'floor=' + cfg.voiceFloorPersonal);

          // G1：冻在「现在」的内容上（9:41、只有 A），先不交付
          env.server.global = 9;
          const g1 = env.hold((r) => r.method === 'GET' && r.path.startsWith('/v1/config'));
          const p1 = cfg.refresh();
          await micro();
          ok('G1 冻住在途', g1.entered === 1);

          // 另一台设备写入：personal 41 → 42，收藏多一条 B
          env.server.personal.set('alice', 42);
          env.server.voice.set('alice', { favorites: ['A', 'B'], history: [], favoriteCounts: {} });

          // G2 拿到新内容并被采纳
          await cfg.refresh();
          await env.clock.advance(3000);
          ok('G2 被采纳：本机看到 B', store.favorites.indexOf('B') >= 0, JSON.stringify(store.favorites));
          ok('普通 GET 采纳把下限抬到 42（不只 ack 抬）',
            cfg.voiceFloorPersonal === 42, 'floor=' + cfg.voiceFloorPersonal);

          // 现在交付迟到的 G1（9:41、只有 A）
          g1.release();
          await micro(); await env.clock.advance(3000);
          await p1;
          ok('迟到的旧 GET 没把 B 回退掉', store.favorites.indexOf('B') >= 0, JSON.stringify(store.favorites));
          ok('收藏仍是两条', store.favorites.length === 2, JSON.stringify(store.favorites));
          ok('下限仍是 42', cfg.voiceFloorPersonal === 42, 'floor=' + cfg.voiceFloorPersonal);
        } finally { env.uninstall(); }
      },
    },

    {
      name: '9. 切账号清本账号下限：新账号的快照不被上一个账号的下限拒掉',
      async run() {
        const env = new Env();
        env.installClock();
        try {
          env.server.addUser('alice', 'pw');
          env.server.addUser('bob', 'pw');
          env.server.voice.set('bob', { favorites: ['bob 的收藏'], history: [], favoriteCounts: {} });
          const w = env.loadWorld(modelDir);
          const { store, cfg } = await boot(env, w, 'alice');
          cfg.isOnline = true;

          store.performVoiceInput('addFavorite', 'alice 的收藏');
          await env.clock.advance(2000);
          ok('alice 的下限已经抬起来', cfg.voiceFloorPersonal > 0, 'floor=' + cfg.voiceFloorPersonal);

          await cfg.logout();
          ok('登出立刻清空下限', cfg.voiceFloorPersonal === -1, 'floor=' + cfg.voiceFloorPersonal);

          await cfg.login('bob', 'pw');
          cfg.isOnline = true;
          ok('bob 的下限是自己的（bob 自己的 personal = 40），不是 alice 的 41',
            cfg.voiceFloorPersonal === 40, 'floor=' + cfg.voiceFloorPersonal);
          ok('bob 的快照真被采纳了（看得到 bob 自己的收藏）',
            store.favorites.indexOf('bob 的收藏') >= 0, JSON.stringify(store.favorites));
          ok('bob 看不到 alice 的收藏', store.favorites.indexOf('alice 的收藏') < 0,
            JSON.stringify(store.favorites));
        } finally { env.uninstall(); }
      },
    },
  ];
}


// ---------------------------------------------------------------------------
const ends = ['entry', 'pad'];
for (const end of ends) {
  for (const t of suiteFor(end)) {
    section(`${end} · ${t.name}`);
    try { await t.run(); }
    catch (e) { FAIL++; failures.push(`${end} · ${t.name}`); console.log(`  ❌ 抛异常：${e && e.stack ? e.stack : e}`); }
  }
}

console.log(`\n===== 行为测试结果：${PASS} 通过 / ${FAIL} 失败 =====`);
if (FAIL > 0) { console.log('失败项：\n  - ' + failures.join('\n  - ')); }
process.exit(FAIL === 0 ? 0 : 1);
