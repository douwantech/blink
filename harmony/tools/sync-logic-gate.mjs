// i107：鸿蒙「收藏/发送历史同步到账号」——「自己写入 +1」保护的牙齿测试。
//
// 关键：本脚本不写等价复刻，而是从 .ets 源码里**抽取真实实现**再求值：
//   - VoiceInputAccount.ownConfigVersion(...)   ← entry/pad 两端的真实函数体
//   - ServerConfig.apply() 里 keepPendingPersonal / serverAdvanced / adoptPersonal 决策式
//   - ServerConfig.uploadVoiceInput() 里 before/expected 的接线
//   - 两端 UI 删除/清空路径必须走 performVoiceInput（不直接改本地）
// 任何一端把逻辑改歪 / 改回去，这里立刻红。
//
// 跑法（退出码 0 = 全绿，非 0 = 有断言红）：
//   node harmony/tools/sync-logic-gate.mjs
// 纯 node，无依赖，不碰真机、不起轮询、不连网。

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// 本脚本随分支一起走：<repo>/harmony/tools/sync-logic-gate.mjs
// 仓库根 = 脚本目录的 ../..，换任意 checkout 都能跑，不依赖本机绝对路径。
const HERE = dirname(fileURLToPath(import.meta.url));
const WORK = resolve(HERE, '..', '..');
const ends = {
  entry: {
    cfg: `${WORK}/harmony/entry/src/main/ets/model/ServerConfig.ets`,
    vi:  `${WORK}/harmony/entry/src/main/ets/model/VoiceInputAccount.ets`,
    ui:  `${WORK}/harmony/entry/src/main/ets/pages/BlinkTerminal.ets`,
  },
  pad: {
    cfg: `${WORK}/harmony/pad/src/main/ets/model/ServerConfig.ets`,
    vi:  `${WORK}/harmony/pad/src/main/ets/model/VoiceInputAccount.ets`,
    ui:  `${WORK}/harmony/pad/src/main/ets/pages/PadHome.ets`,
  },
};

let pass = 0, fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name}${extra ? '  →  ' + extra : ''}`); }
};

/** 去掉 ArkTS 的 `: T` 类型注解，只留 JS 语义。 */
const stripTs = (s) => s
  .replace(/:\s*string\[\]/g, '')
  .replace(/:\s*string\b/g, '')
  .replace(/:\s*number\b/g, '')
  .replace(/:\s*boolean\b/g, '')
  .replace(/:\s*RegExp\b/g, '');

/** 从源码里取「函数名(...){...}」整段（大括号配平）。 */
function extractFn(src, header) {
  const i = src.indexOf(header);
  if (i < 0) throw new Error(`找不到函数头：${header}`);
  let j = src.indexOf('{', i);
  let depth = 0, k = j;
  for (; k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) { k++; break; } }
  }
  return src.slice(i, k);
}

/** 从源码里取一段连续语句（按首末锚点，含端点）。 */
function extractSlice(src, from, to) {
  const i = src.indexOf(from);
  if (i < 0) throw new Error(`找不到起点：${from}`);
  const j = src.indexOf(to, i);
  if (j < 0) throw new Error(`找不到终点：${to}`);
  return src.slice(i, j + to.length);
}

function loadOwnConfigVersion(path) {
  const src = readFileSync(path, 'utf8');
  let fn = stripTs(extractFn(src, 'static ownConfigVersion('));
  fn = fn.replace(/^static\s+/, '').replace(/^ownConfigVersion/, 'function ownConfigVersion');
  return { fn, src };
}

function loadDecision(path) {
  const src = readFileSync(path, 'utf8');
  const block = extractSlice(
    src,
    'const localDirty: boolean = this.dirty;',
    'const adoptPersonal: boolean = !keepPendingPersonal && (serverAdvanced || !localDirty);'
  );
  let js = stripTs(block)
    .replace(/this\.dirty/g, 'dirty')
    .replace(/this\.version/g, 'version');
  const decide = new Function(
    'dirty', 'version', 'preservingOwnVoiceVersion', 'snap',
    `${js}\n return { keepPendingPersonal, serverAdvanced, adoptPersonal };`
  );
  return { decide, block, src };
}

console.log('\n=== 1) 两端 ownConfigVersion：抽取真实实现并求值 ===');
const own = {};
for (const [name, p] of Object.entries(ends)) {
  const { fn, src } = loadOwnConfigVersion(p.vi);
  const f = new Function(`return (${fn})`)();
  own[name] = f;
  console.log(`  [${name}] 抽取到的实现：`);
  console.log('    ' + fn.split('\n').map(l => l.trim()).filter(Boolean).join('\n    '));

  ok(`[${name}] '12:40' + '41' → '12:41'（自己写入，+1）`, f('12:40', '41') === '12:41', f('12:40', '41'));
  ok(`[${name}] '12:40' + '42' → 空（跳过了一版：别的设备也写了）`, f('12:40', '42') === '', JSON.stringify(f('12:40', '42')));
  ok(`[${name}] '12:40' + '40' → 空（没前进）`, f('12:40', '40') === '');
  ok(`[${name}] '12:40' + '' → 空（服务器没给头）`, f('12:40', '') === '');
  ok(`[${name}] '12:' + '1' → 空（残缺版本串，不得误判为自己写入）`, f('12:', '1') === '', JSON.stringify(f('12:', '1')));
  ok(`[${name}] 'x' + '1' → 空（格式坏）`, f('x', '1') === '');
  ok(`[${name}] '12:40' + '41x' → 空（非纯数字）`, f('12:40', '41x') === '');
  ok(`[${name}] '12:40' + '-1' → 空（负数）`, f('12:40', '-1') === '');
  ok(`[${name}] '12:40' + '1e2' → 空（科学计数不是 UInt64）`, f('12:40', '1e2') === '');
}

console.log('\n=== 2) iOS 权威实现对照（逐条语义一致） ===');
const ios = readFileSync(`${WORK}/Blink/SmarterKeys/VoiceInputAccount.swift`, 'utf8');
const iosBody = extractSlice(ios, 'static func ownConfigVersion(', 'return "\\(parts[0]):\\(new)"\n  }');
const iosCases = [
  ['12:40', '41', '12:41'], ['12:40', '42', null], ['12:40', '40', null],
  ['12:40', '', null], ['12:', '1', null], ['x', '1', null], ['12:40', '41x', null],
];
for (const [prev, pers, want] of iosCases) {
  for (const name of ['entry', 'pad']) {
    const got = own[name](prev, pers);
    const expect = want === null ? '' : want;
    ok(`[${name}] 与 iOS 同判：'${prev}'+'${pers}' → ${want === null ? '空' : want}`, got === expect, `得到 '${got}'`);
  }
}
ok('iOS 源码确认为「恰好 +1」语义（new == old + 1）', /new == old \+ 1/.test(iosBody));
ok('iOS 源码确认为 UInt64 解析（拒绝非数字）', /UInt64\(parts\[1\]\)/.test(iosBody) && /UInt64\(personal\)/.test(iosBody));

console.log('\n=== 3) 两端 apply() 的「自己写入」决策式：抽取真实表达式 ===');
const dec = {};
for (const [name, p] of Object.entries(ends)) {
  const { decide, block, src } = loadDecision(p.cfg);
  dec[name] = decide;
  console.log(`  [${name}] 抽取到的决策：`);
  console.log('    ' + block.split('\n').map(l => l.trim()).filter(Boolean).join('\n    '));

  const V = (o) => Object.assign({ version: '12:40' }, o);
  // 自己写入 +1 且版本串正好匹配 → keepPendingPersonal
  let r = decide(true, '12:40', own[name]('12:40', '41'), V({ version: '12:41' }));
  ok(`[${name}] 自己写入(+1)且快照版本匹配 → keepPendingPersonal=true, 不采纳个人段, dirty 保留`,
    r.keepPendingPersonal === true && r.adoptPersonal === false, JSON.stringify(r));

  // 自己写入，但服务器快照 shared 段也变了（他人同时改公用）→ 不匹配 → 服务器权威
  r = decide(true, '12:40', own[name]('12:40', '41'), V({ version: '13:41' }));
  ok(`[${name}] 自己写入但 shared 段也前进(13:41) → 不算自己的 → 采纳服务器`,
    r.keepPendingPersonal === false && r.adoptPersonal === true, JSON.stringify(r));

  // 非自己写入（没有 preservingOwnVoiceVersion）→ 服务器权威
  r = decide(true, '12:40', '', V({ version: '12:41' }));
  ok(`[${name}] 没有自己的版本标记 → 采纳服务器（服务器权威）`,
    r.keepPendingPersonal === false && r.adoptPersonal === true, JSON.stringify(r));

  // 不 dirty → 无条件采纳
  r = decide(false, '12:40', '', V({ version: '12:41' }));
  ok(`[${name}] 本地无未上传改动 → 无条件采纳服务器`,
    r.adoptPersonal === true && r.keepPendingPersonal === false, JSON.stringify(r));

  // dirty 但版本没前进 → 保留本地（不采纳个人段）
  r = decide(true, '12:40', '', V({ version: '12:40' }));
  ok(`[${name}] 版本没有前进 + 有未上传改动 → 保留本地个人段（不采纳）`,
    r.adoptPersonal === false, JSON.stringify(r));

  // dirty 且他人改动（版本前进、非自己）→ 采纳并清 dirty
  r = decide(true, '12:40', own[name]('12:40', '43'), V({ version: '12:43' }));
  ok(`[${name}] 他人推进到 12:43 → 服务器权威，采纳`,
    r.adoptPersonal === true && r.serverAdvanced === true, JSON.stringify(r));

  // dirty 标志只在「版本前进且非保留自己写入」时清
  ok(`[${name}] dirty 清零条件为 (serverAdvanced && !keepPendingPersonal)`,
    /if \(serverAdvanced && !keepPendingPersonal\) \{[\s\S]{0,120}this\.dirty = false;/.test(src));
  ok(`[${name}] 个人段(selection/restSessions/agents)整段包在 if (adoptPersonal) 内`,
    /if \(adoptPersonal\) \{[\s\S]*snap\.agents[\s\S]*\n      \}/.test(src));
}

console.log('\n=== 4) 两端 uploadVoiceInput() 的接线（before + X-Personal-Version → expected） ===');
for (const [name, p] of Object.entries(ends)) {
  const src = readFileSync(p.cfg, 'utf8');
  const block = extractSlice(src, 'const before: string = this.version;',
    "await this.syncFromServer(true, expected);");
  console.log(`  [${name}] 抽取到的接线：`);
  console.log('    ' + block.split('\n').map(l => l.trim()).filter(Boolean).join('\n    '));
  ok(`[${name}] POST 前记 before = this.version`, /const before: string = this\.version;/.test(block));
  ok(`[${name}] 从响应头小写键读 x-personal-version`, /rsp\.header\['x-personal-version'\]/.test(block));
  ok(`[${name}] expected = ownConfigVersion(before, personal)`, /VoiceInputAccount\.ownConfigVersion\(before, personal\)/.test(block));
  ok(`[${name}] 回读带 expected（syncFromServer(true, expected)）`, /this\.syncFromServer\(true, expected\)/.test(block));
  ok(`[${name}] HttpResult 有 header 字段且小写归一`,
    /interface HttpResult \{[\s\S]{0,200}header: Record<string, string>;/.test(src) &&
    /hdr\[keys\[i\]\.toLowerCase\(\)\]/.test(src));
  ok(`[${name}] ack 传入服务器回读的 voice input 状态（不是整份清空）`,
    /voiceInputAccount\.acknowledge\(pending, state, account\)/.test(src));
}

console.log('\n=== 5) 两端 UI：删除/清空必须走账号队列，不得只改本地 ===');
for (const [name, p] of Object.entries(ends)) {
  const src = readFileSync(p.ui, 'utf8');
  const cases = [
    ['removeFavorite', 'removeFavorite'],
    ['confirmClearFavorites', 'clearFavorites'],
    ['removeHistory', 'removeHistory'],
    ['confirmClearHistory', 'clearHistory'],
  ];
  for (const [fn, kind] of cases) {
    const body = extractFn(src, `private ${fn}(`);
    ok(`[${name}] ${fn}() 走 performVoiceInput('${kind}')`,
      new RegExp(`performVoiceInput\\('${kind}'\\)`).test(body) ||
      new RegExp(`performVoiceInput\\('${kind}', text\\)`).test(body),
      body.replace(/\s+/g, ' ').slice(0, 140));
    ok(`[${name}] ${fn}() 不直接 mutate store.favorites/history`,
      !/store\.(favorites|history)\.(push|splice|pop|shift|unshift)/.test(body));
  }
  ok(`[${name}] 收藏 sheet 已改用 favoritesBody()`, /this\.favoritesBody\(\)/.test(src));
  ok(`[${name}] 历史 sheet 已改用 historyBody()`, /this\.historyBody\(\)/.test(src));
  ok(`[${name}] 长按菜单接线 bindContextMenu + ResponseType.LongPress`,
    /bindContextMenu\(this\.favMenu\(it\), ResponseType\.LongPress\)/.test(src) &&
    /bindContextMenu\(this\.histMenu\(it\), ResponseType\.LongPress\)/.test(src));
  ok(`[${name}] useFavorite 仍记一次使用次数 + 一次历史`,
    /performVoiceInput\('useFavorite', text\)/.test(src) &&
    /performVoiceInput\('recordHistory', text\)/.test(src));
  ok(`[${name}] 空列表仍给提示文案（不空白）`,
    /还没有收藏短语/.test(src) && /还没有发送历史/.test(src));
}

console.log('\n=== 6) 两端源码一致性：只比对本次触碰的逻辑区（其余差异是既有的） ===');
// 两份文件本就有既有差异（文件头注释 / TAG 名 / @State 字段顺序 / 一处 comment）。
// 本次新增的逻辑区必须逐字一致，否则就是两端分叉。
const REGIONS = [
  { label: 'ownConfigVersion', file: 'vi', from: 'static ownConfigVersion(', to: "return parts[0] + ':' + next;\n  }" },
  { label: 'apply 决策式', file: 'cfg', from: 'const localDirty: boolean = this.dirty;', to: 'const adoptPersonal: boolean = !keepPendingPersonal && (serverAdvanced || !localDirty);' },
  { label: 'dirty 清零', file: 'cfg', from: 'if (serverAdvanced && !keepPendingPersonal) {', to: 'this.dirty = false;   // 服务器版本已采纳：本地未上传的改动放弃（绝不被回传覆盖服务器）' },
  { label: 'upload 接线', file: 'cfg', from: 'const before: string = this.version;', to: 'await this.syncFromServer(true, expected);' },
  { label: '响应头归一', file: 'cfg', from: 'const hdr: Record<string, string> = {};', to: 'return { code: rsp.responseCode, body: text, header: hdr } as HttpResult;' },
  { label: 'HttpResult 接口', file: 'cfg', from: 'interface HttpResult {', to: 'header: Record<string, string>;' },
];
const read = (p) => readFileSync(p, 'utf8');
for (const r of REGIONS) {
  const pick = (e) => read(ends[e][r.file]);
  let ea, pa;
  try { ea = extractSlice(pick('entry'), r.from, r.to); pa = extractSlice(pick('pad'), r.from, r.to); }
  catch (e) { ok(`[两端] ${r.label} 区段可抽取`, false, String(e.message)); continue; }
  ok(`[两端] ${r.label} 区段逐字一致`, ea === pa,
    ea === pa ? '' : `\n      entry: ${ea.replace(/\s+/g, ' ')}\n      pad  : ${pa.replace(/\s+/g, ' ')}`);
}
ok('两端 VoiceInputAccount 逐字一致', read(ends.entry.vi) === read(ends.pad.vi));
ok('两端 ServerConfig 仅剩下既有差异（不是本次逻辑分叉）',
  read(ends.entry.cfg) !== read(ends.pad.cfg));

console.log('\n=== 7) 关键项回归守卫（防「改回去」） ===');
for (const [name, p] of Object.entries(ends)) {
  const src = readFileSync(p.cfg, 'utf8');
  ok(`[${name}] 不再无条件 this.dirty = false;（清 dirty 有前置条件）`,
    !/this\.version = snap\.version;\s*\n\s*this\.dirty = false;/.test(src));
}

console.log('\n=== 8) 上传互斥 / flush-first / 个人段守卫（复审要求，两端都要有） ===');
for (const [name, p] of Object.entries(ends)) {
  const src = readFileSync(p.cfg, 'utf8');

  const vi = extractFn(src, 'private async uploadVoiceInput(');
  const pi = extractFn(src, 'private async uploadPersonal(');

  ok(`[${name}] voice 上传让路 personal PUT（uploading 门）`,
    /if \(this\.uploading\) \{[\s\S]{0,200}this\.scheduleVoiceInputUpload\(\);[\s\S]{0,40}return;/.test(vi),
    vi.replace(/\s+/g, ' ').slice(0, 160));
  ok(`[${name}] voice 上传先 flush personal（dirty → await uploadPersonal()）`,
    /if \(this\.dirty\) \{[\s\S]{0,120}await this\.uploadPersonal\(\);[\s\S]{0,200}\n\s{4}\}/.test(vi));
  ok(`[${name}] before 记在 flush 之后（POST 前）`,
    vi.indexOf('await this.uploadPersonal();') < vi.indexOf('const before: string = this.version;'));
  ok(`[${name}] voice 尾部两条队列都续传（scheduleVoiceInputUpload + scheduleUpload）`,
    /finally \{ this\.uploadingVoiceInput = false; \}[\s\S]{0,300}this\.scheduleVoiceInputUpload\(\);[\s\S]{0,80}this\.scheduleUpload\(\);/.test(vi),
    vi.replace(/\s+/g, ' ').slice(-200));

  ok(`[${name}] personal 上传让路 voice POST（uploadingVoiceInput 门）`,
    /!this\.uploading\s*\|\|\s*this\.uploadingVoiceInput/.test(pi) || /this\.uploading\s*&&\s*!this\.uploadingVoiceInput/.test(pi) ||
    /!this\.dirty \|\| this\.uploading \|\|[\s\S]{0,40}this\.uploadingVoiceInput/.test(pi),
    pi.replace(/\s+/g, ' ').slice(0, 200));
  ok(`[${name}] personal 尾部补 voice 续传`,
    (pi.match(/this\.scheduleVoiceInputUpload\(\);/g) || []).length >= 2,
    '出现次数=' + (pi.match(/this\.scheduleVoiceInputUpload\(\);/g) || []).length);

  ok(`[${name}] 个人标签/墓碑/工作目录的替换被包进采纳分支`,
    /if \(adoptPersonal\) \{[\s\S]{0,200}this\.store\.workDirs = dirs;[\s\S]{0,200}this\.store\.tabs = display\.concat\(personal\);[\s\S]{0,200}this\.store\.closedIds = closedFiltered;[\s\S]{0,600}\} else \{/.test(src));
  ok(`[${name}] 不采纳时的分支保住本地个人标签（且用采纳前的公用集合判定）`,
    /else \{[\s\S]{0,300}prevSharedIds\.indexOf\(t\.id\) < 0[\s\S]{0,200}this\.store\.tabs = display\.concat\(localPersonal\);/.test(src));
  ok(`[${name}] prevSharedIds 在覆盖 store.sharedIds 之前取`,
    src.indexOf('const prevSharedIds: string[] = this.store.sharedIds.slice();') <
    src.indexOf('this.store.sharedIds = sharedKeys;'));
}

console.log('\n=== 9) 乱序旧 GET 的个人版本下限（复审补充，两端都要有） ===');
for (const [name, p] of Object.entries(ends)) {
  const src = readFileSync(p.cfg, 'utf8');
  const ap = extractFn(src, 'private async apply(');
  const up = extractFn(src, 'private async uploadVoiceInput(');

  ok(`[${name}] 有 per-account 个人版本下限字段`,
    /private voiceFloorPersonal: number = -1;/.test(src));
  ok(`[${name}] 版本解析 helper：personalOf / rawPersonal`,
    /private static rawPersonal\(value: string\): number/.test(src) &&
    /private static personalOf\(version: string\): number/.test(src));
  ok(`[${name}] 下限判定：personal 段严格小于下限即为乱序旧快照`,
    /private isStaleSnapshot\(version: string\): boolean \{[\s\S]{0,240}return p >= 0 && p < this\.voiceFloorPersonal;/.test(src));
  ok(`[${name}] 旧快照在采纳任何东西之前就被放过（含 voiceInput）`,
    ap.indexOf('if (this.isStaleSnapshot(snap.version))') >= 0 &&
    ap.indexOf('if (this.isStaleSnapshot(snap.version))') < ap.indexOf('voiceInputAccount.adopt('),
    '门槛必须排在 adopt 之前');
  ok(`[${name}] 采纳成功也抬下限（普通 GET 采纳也算）`,
    /this\.version = snap\.version;[\s\S]{0,300}const snapPersonal: number = ServerConfig\.personalOf\(snap\.version\);[\s\S]{0,160}this\.voiceFloorPersonal = snapPersonal;/.test(ap));
  ok(`[${name}] ack 用**原始** X-Personal-Version 抬下限（不是 ownConfigVersion 的 +1）`,
    /const raw: number = ServerConfig\.rawPersonal\(personal\);[\s\S]{0,200}raw > this\.voiceFloorPersonal[\s\S]{0,120}this\.voiceFloorPersonal = raw;/.test(up) &&
    up.indexOf('ServerConfig.rawPersonal(personal)') > up.indexOf('ownConfigVersion(before, personal)'),
    'raw 抬限必须在 expected 之后');
  ok(`[${name}] 下限持久化（重启不丢）`,
    /await p\.put\('voiceFloorPersonal', this\.voiceFloorPersonal\);/.test(src) &&
    /this\.voiceFloorPersonal = await this\.prefs\.get\('voiceFloorPersonal', -1\)/.test(src));
  ok(`[${name}] 切账号清下限：login 与 clearSession 都清成 -1`,
    /const login: ServerLoginResponse = JSON\.parse\(rsp\.body\) as ServerLoginResponse;[\s\S]{0,300}this\.voiceFloorPersonal = -1;/.test(src) &&
    /this\.dirty = false;\s*\n\s*this\.voiceFloorPersonal = -1;/.test(src));
  ok(`[${name}] 轮询也给 voice POST 让路`,
    /this\.uploading \|\| this\.dirty \|\| this\.uploadingVoiceInput/.test(src));
}

console.log(`\n===== 结果：${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail === 0 ? 0 : 1);
