////////////////////////////////////////////////////////////////////////////////
//
// BlinkStores — the HarmonyOS twin of the iOS fork's config stores
// (BlinkMachineStore / BlinkWorkDirStore / BlinkSessionPresetStore /
//  BlinkPeopleStore / TabStateStore / TabRestStore / AITextPolisher storage).
//
// 配置的权威是**服务器**（issue #77，见 ServerConfig.ets）：登录后 machines /
// workDirs / tabs / agents / 休息名单由服务器快照写入，preferences 只是本机落盘的
// 副本（离线展示用）+ 纯本机偏好（主题、语音学习数据等）。老的 seed_config.json
// 播种与 ~/.blink/sync 双向文件同步都已删除。
//
// execForTab() reproduces the iOS sshCommand/blinkdCommand remote script
// byte-for-byte (BlinkMachineStore.swift:180-260): the same cc-<TITLE> outer
// tmux session names, the same claude resume-by-customTitle inner script —
// so a tab opened on this phone attaches to the *same* tmux session and the
// *same* claude conversation as the iOS app.
//
////////////////////////////////////////////////////////////////////////////////

import { VoiceInputAccount, AccountVoiceInput, AccountVoiceOperation } from './VoiceInputAccount';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { buffer } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0B11;
const TAG: string = 'BlinkStores';

// ---- models (field names match the iOS JSON exactly) ----

export interface Machine {
  id: string;
  name: string;
  user: string;
  transport: string;      // 'blinkd' | 'ssh'
  host: string;           // tailscale IP / hostname
  host2?: string;
  lanHost?: string;
  blinkdHost?: string;    // blinkd daemon address (transport=blinkd)
  blinkdPort?: number;
  blinkdToken?: string;
  rustdeskId?: string;
  rustdeskPassword?: string;
}

export interface WorkDir {
  id: string;
  name: string;
  path: string;
  hasIcon?: boolean;      // rawfile/avatars/<id>.png exists
}

export interface TabModel {
  id: string;
  machineId: string;
  workDirId: string;
  tmuxSession: string;
  useTmux: boolean;
}

export interface SessionPreset {
  id: string;
  machineId: string;
  workDirId: string;
  baseName: string;
}

export interface PinnedTab {
  url: string;
  title: string;
  authUser?: string;
  authPassword?: string;
}

export interface VoiceConfig {
  enabled: boolean;
  baseURL: string;
  apiKey: string;
  model: string;
  debounce: number;
}

// ---- store ----

const P_KEY: string = 'blink_store';   // preferences file name

// 默认在岗的员工段（iOS SharedTabLayout.dockEmployee，单一常量来源）。
// 没物化过在岗名单时（从未切过开关、服务器也没给 restSessions）= 「只有 tom 在岗」。
const DOCK_EMPLOYEE: string = 'tom';

// DeepSeek 的 Anthropic 兼容端点与模型（/models 实测可用的两个 id）

export class BlinkStore {
  machines: Machine[] = [];
  workDirs: WorkDir[] = [];
  people: string[] = [];
  presets: SessionPreset[] = [];
  tabs: TabModel[] = [];
  currentTabId: string = '';
  filterMachineId: string = '';        // '' = all machines
  pinned: PinnedTab[] = [];
  // 每个员工（机器 × tab）开会话进哪个 CLI；只存非默认的那几个，默认 claude
  agents: Record<string, string> = {};
  favorites: string[] = [];
  favoriteCounts: Record<string, number> = {};
  history: string[] = [];
  corrections: string[][] = [];        // [asrRaw, final] pairs
  terms: Record<string, Record<string, number>> = {};  // wrong -> {correct: count}
  // 在岗集合：**tmuxSession**（与服务器 selection.restSessions 同形）。
  // restLoaded=false（从未物化）时走默认规则：员工段 == 'tom' 在岗（iOS SharedRestStore 口径）。
  restActive: string[] = [];
  restLoaded: boolean = false;
  // 公用标签 id（服务器注入的只读影子）。坞只铺这些，自有标签退出坞（iOS _sharedKeys 口径）。
  sharedIds: string[] = [];
  closedIds: string[] = [];            // 关过的 tab 墓碑（同 iOS TabState.closedIds）
  workMode: boolean = false;           // "只显示工作中"
  autoReconnect: boolean = true;       // BlinkAutoReconnect
  locale: string = 'zh-CN';            // 识别语言
  voice: VoiceConfig = {
    enabled: true,
    baseURL: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    apiKey: '',
    model: 'glm-4-flashx',
    debounce: 1.5,
  };

  private prefs: preferences.Preferences | null = null;
  voiceInputAccount: VoiceInputAccount | null = null;
  onVoiceInputChange: (() => void) | null = null;

  syncVoiceInputCache(): void {
    if (this.voiceInputAccount === null) { return; }
    const state: AccountVoiceInput = this.voiceInputAccount.state;
    this.favorites = state.favorites;
    this.favoriteCounts = state.favoriteCounts;
    this.history = state.history;
  }

  performVoiceInput(kind: string, text: string = ''): void {
    if (this.voiceInputAccount === null) { return; }
    this.voiceInputAccount.perform(kind, text);
    this.syncVoiceInputCache();
    if (this.onVoiceInputChange !== null) { this.onVoiceInputChange(); }
  }

  voiceInputPending(username: string): AccountVoiceOperation[] {
    return this.voiceInputAccount !== null ? this.voiceInputAccount.pending(username) : [];
  }


  /// 本地个人状态（选中的机器 / agents / 休息开关…）真的变了（save* 落盘时触发）。
  /// PadHome 挂上防抖上传，把个人状态 PUT 回服务器（ServerConfig.markDirty）。
  /// 注意：ServerConfig 采纳服务器快照走 persistAll()，**不触发**这里。
  onLocalChange: (() => void) | null = null;

  /// 休息开关被用户动过（休息面板 / 团队页）：ServerConfig 据此把 restSessions「物化」
  /// 并允许随 selection 上传——没动过就绝不上传，别把服务器的默认在岗规则清掉。
  onRestChange: (() => void) | null = null;

  async load(ctx: common.UIAbilityContext): Promise<void> {
    this.prefs = await preferences.getPreferences(ctx, P_KEY);
    // 机器/工作目录/标签的权威在服务器：这里只读上次落盘的副本先展示（离线可用），
    // 服务器快照一到就整份覆盖。seed_config.json 播种那条老路已删。
    this.machines = this.readJson<Machine[]>('machines', []);
    this.workDirs = this.readJson<WorkDir[]>('workDirs', []);
    this.people = this.readJson<string[]>('people', []);
    this.presets = this.readJson<SessionPreset[]>('presets', []);
    this.tabs = this.readJson<TabModel[]>('tabs', []);
    this.pinned = this.readJson<PinnedTab[]>('pinned', []);
    this.agents = this.readJson<Record<string, string>>('agents', {});
    this.favorites = this.readJson<string[]>('favorites', []);
    this.favoriteCounts = this.readJson<Record<string, number>>('favoriteCounts', {});
    this.history = this.readJson<string[]>('history', []);
    const legacyVoice: AccountVoiceInput = {
      favorites: this.favorites, history: this.history, favoriteCounts: this.favoriteCounts
    };
    this.voiceInputAccount = new VoiceInputAccount(this.prefs!, legacyVoice);

    this.corrections = this.readJson<string[][]>('corrections', []);
    this.terms = this.readJson<Record<string, Record<string, number>>>('terms', {});
    this.restActive = this.readJson<string[]>('restActive', []);
    this.restLoaded = this.readJson<boolean>('restLoaded', false);
    this.closedIds = this.readJson<string[]>('closedIds', []);
    const v = this.readJson<VoiceConfig | null>('voice', null);
    if (v !== null) {
      this.voice = v;
    }
    this.currentTabId = (await this.prefs!.get('currentTabId', '') as string);
    this.filterMachineId = (await this.prefs!.get('filterMachineId', '') as string);
    this.workMode = (await this.prefs!.get('workMode', false) as boolean);
    this.autoReconnect = (await this.prefs!.get('autoReconnect', true) as boolean);
    this.locale = (await this.prefs!.get('locale', 'zh-CN') as string);
    // DeepSeek key 改成各机器自己在 ~/.zshrc 里配，App 以前存的那份删掉（幂等）
    if (await this.prefs!.has('deepseekKey')) {
      await this.prefs!.delete('deepseekKey');
      await this.prefs!.flush();
    }
  }

  // sync read helper (prefs loaded once at startup)
  private readJson<T>(key: string, fallback: T): T {
    try {
      const s: string = this.prefs!.getSync(key, '') as string;
      if (s.length === 0) {
        return fallback;
      }
      return JSON.parse(s) as T;
    } catch (e) {
      return fallback;
    }
  }

  private putJson(key: string, v: Object): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    p.put(key, JSON.stringify(v)).then((): Promise<void> => p.flush()).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'put %{public}s: %{public}s', key, JSON.stringify(e));
    });
    if (this.onLocalChange !== null) {
      this.onLocalChange();
    }
  }

  private putVal(key: string, v: preferences.ValueType): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    p.put(key, v).then((): Promise<void> => p.flush()).catch(() => {});
    // 切当前 tab 不算配置变更（iOS 侧同样不为它刷新时间戳），别每次切 tab 都推一轮
    if (key !== 'currentTabId' && this.onLocalChange !== null) {
      this.onLocalChange();
    }
  }

  async persistAll(): Promise<void> {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    await p.put('machines', JSON.stringify(this.machines));
    await p.put('workDirs', JSON.stringify(this.workDirs));
    await p.put('people', JSON.stringify(this.people));
    await p.put('presets', JSON.stringify(this.presets));
    await p.put('tabs', JSON.stringify(this.tabs));
    await p.put('pinned', JSON.stringify(this.pinned));
    await p.put('agents', JSON.stringify(this.agents));
    await p.put('favorites', JSON.stringify(this.favorites));
    await p.put('favoriteCounts', JSON.stringify(this.favoriteCounts));
    await p.put('history', JSON.stringify(this.history));
    await p.put('corrections', JSON.stringify(this.corrections));
    await p.put('terms', JSON.stringify(this.terms));
    await p.put('restActive', JSON.stringify(this.restActive));
    await p.put('restLoaded', JSON.stringify(this.restLoaded));
    await p.put('closedIds', JSON.stringify(this.closedIds));
    await p.put('voice', JSON.stringify(this.voice));
    await p.put('currentTabId', this.currentTabId);
    await p.put('filterMachineId', this.filterMachineId);
    await p.put('workMode', this.workMode);
    await p.put('autoReconnect', this.autoReconnect);
    await p.put('locale', this.locale);
    await p.flush();
  }

  saveMachines(): void { this.putJson('machines', this.machines); }
  saveWorkDirs(): void { this.putJson('workDirs', this.workDirs); }
  savePresets(): void { this.putJson('presets', this.presets); }
  saveTabs(): void { this.putJson('tabs', this.tabs); }
  savePinned(): void { this.putJson('pinned', this.pinned); }
  saveAgents(): void { this.putJson('agents', this.agents); }

  // 这个员工（机器 × tab）配的 CLI；title 就是 cc-<TITLE> 去掉前缀那截
  agentFor(machineId: string, title: string): string {
    const v: string | undefined = this.agents[machineId + '|' + title.toLowerCase()];
    return v !== undefined ? v : 'claude';
  }

  setAgent(machineId: string, title: string, kind: string): void {
    const k: string = machineId + '|' + title.toLowerCase();
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.agents);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== k) {
        next[keys[i]] = this.agents[keys[i]];
      }
    }
    if (kind !== 'claude') {
      next[k] = kind;
    }
    this.agents = next;
    this.saveAgents();
  }
  saveFavorites(): void {
    this.putJson('favorites', this.favorites);
    this.putJson('favoriteCounts', this.favoriteCounts);
  }
  saveHistory(): void { this.putJson('history', this.history); }
  saveCorrections(): void { this.putJson('corrections', this.corrections); }
  saveTerms(): void { this.putJson('terms', this.terms); }
  saveResting(): void {
    this.putJson('restActive', this.restActive);
    this.putJson('restLoaded', this.restLoaded);
  }
  saveClosed(): void { this.putJson('closedIds', this.closedIds); }
  saveVoice(): void { this.putJson('voice', this.voice); }
  saveCurrent(): void { this.putVal('currentTabId', this.currentTabId); }
  saveFilter(): void { this.putVal('filterMachineId', this.filterMachineId); }
  saveWorkMode(): void { this.putVal('workMode', this.workMode); }
  saveAutoReconnect(): void { this.putVal('autoReconnect', this.autoReconnect); }
  saveLocale(): void { this.putVal('locale', this.locale); }

  // ---- lookups ----

  machineById(id: string): Machine | null {
    for (let i = 0; i < this.machines.length; i++) {
      if (this.machines[i].id === id) {
        return this.machines[i];
      }
    }
    return null;
  }

  workDirById(id: string): WorkDir | null {
    for (let i = 0; i < this.workDirs.length; i++) {
      if (this.workDirs[i].id === id) {
        return this.workDirs[i];
      }
    }
    return null;
  }

  tabById(id: string): TabModel | null {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === id) {
        return this.tabs[i];
      }
    }
    return null;
  }

  machineDisplayName(m: Machine): string {
    return m.name.length > 0 ? m.name : (m.user + '@' + m.host);
  }

  // Tab title, iOS style (SpaceController.swift:1722): "<workDirName>:<sessionPart>"
  // sessionPart = last '-' segment of tmuxSession; dropped if equal to dir name.
  tabTitle(t: TabModel): string {
    // iOS public tabs have no workDirId in the UI; their chip shows the full
    // employee-project session name even though the server provides workDir.
    if (this.isShared(t.id)) {
      return t.tmuxSession;
    }
    const w = this.workDirById(t.workDirId);
    const wn: string = w !== null ? w.name : '?';
    let sp: string = t.tmuxSession;
    const idx: number = sp.lastIndexOf('-');
    if (idx >= 0) {
      sp = sp.substring(idx + 1);
    }
    if (sp === wn) {
      return wn;
    }
    return wn + ':' + sp;
  }

  // ---- 在岗 / 休息 / 坞 ----
  // 对齐 iOS SharedRestStore + SharedTabLayout（老板报「鸿蒙和 iOS 标签不一样」）：
  //   • 在岗集合按 **tmuxSession** 记（服务器 selection.restSessions 同形）。
  //   • 未物化时走默认规则：员工段 == 'tom' 在岗（iOS SharedRestStore.isDefaultActive）。
  //   • 坞里只铺「在岗的公用标签」，自有标签退场（iOS _sharedKeys 一刀切口径）。
  /// 员工段：第一个 '-' 之前（`tom-ben` → `tom`，转小写）。
  /// 与 iOS SharedTabLayout.employee(ofTmuxSession:) 同一套拆法。
  static employeeOf(session: string): string {
    const i: number = session.indexOf('-');
    const head: string = i >= 0 ? session.substring(0, i) : session;
    return head.length > 0 ? head.toLowerCase() : '';
  }

  static isDefaultOnDuty(session: string): boolean {
    return session.length > 0 && BlinkStore.employeeOf(session) === DOCK_EMPLOYEE;
  }

  isShared(tabId: string): boolean {
    return this.sharedIds.indexOf(tabId) >= 0;
  }

  isOnDuty(t: TabModel): boolean {
    if (this.restLoaded) {
      return this.restActive.indexOf(t.tmuxSession) >= 0;
    }
    return BlinkStore.isDefaultOnDuty(t.tmuxSession);
  }

  /// 休息 = 公用标签且不在岗。自有标签不在坞里，也不叫「休息」。
  isResting(tabId: string): boolean {
    const t: TabModel | null = this.tabById(tabId);
    if (t === null || !this.isShared(tabId)) {
      return false;
    }
    return !this.isOnDuty(t);
  }

  /// 首次改动前把默认集合物化成显式集合（iOS SharedRestStore.materializeDefault）。
  /// 不先物化就记一条，会把「默认 tom 在岗」换成一份残缺的显式集合。
  private materializeDefaultOnDuty(): void {
    const out: string[] = [];
    for (let i = 0; i < this.tabs.length; i++) {
      const t: TabModel = this.tabs[i];
      if (this.isShared(t.id) && BlinkStore.isDefaultOnDuty(t.tmuxSession)) {
        out.push(t.tmuxSession);
      }
    }
    this.restActive = out;
    this.restLoaded = true;
  }

  toggleResting(tabId: string): boolean {
    const nowResting: boolean = !this.isResting(tabId);
    this.setResting(tabId, nowResting);
    return nowResting;
  }

  // Explicit set (rest-panel switches): true = resting/hidden, false = on-duty/shown.
  setResting(tabId: string, resting: boolean): void {
    const t: TabModel | null = this.tabById(tabId);
    if (t === null || t.tmuxSession.length === 0 || !this.isShared(tabId)) {
      return;
    }
    if (!this.restLoaded) {
      this.materializeDefaultOnDuty();
    }
    const i: number = this.restActive.indexOf(t.tmuxSession);
    if (resting && i >= 0) {
      this.restActive.splice(i, 1);
    } else if (!resting && i < 0) {
      this.restActive.push(t.tmuxSession);
    }
    this.restLoaded = true;
    this.saveResting();
    if (this.onRestChange !== null) {
      this.onRestChange();
    }
  }

  restingCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.isResting(this.tabs[i].id)) {
        n++;
      }
    }
    return n;
  }

  // 坞 = 在岗的公用标签（自有标签退场）。**不再按机器收窄** —— iOS 手机端同一口径：
  // `let machineId = _macRail != nil ? _tabFilterMachineId : nil`（SpaceController.swift:715），
  // 手机上恒为 nil，否则 selection 回读来的 machineId 会把坞锁死在一台机器上。
  // resting (😴) 的公用标签永不进坞；当前标签例外，坞不会空（iOS _hiddenByWorkMode 同）。
  visibleTabs(): TabModel[] {
    const out: TabModel[] = [];
    for (let i = 0; i < this.tabs.length; i++) {
      const t: TabModel = this.tabs[i];
      if (!this.isShared(t.id)) {
        continue;
      }
      if (!this.isOnDuty(t)) {
        continue;
      }
      out.push(t);
    }
    // iOS _sortTabsByMachineAndDir sorts public tabs by tmuxSession.
    out.sort((a: TabModel, b: TabModel): number => {
      const aa: string = a.tmuxSession.toLowerCase();
      const bb: string = b.tmuxSession.toLowerCase();
      return aa < bb ? -1 : (aa > bb ? 1 : 0);
    });
    return out;
  }

  // The blinkd endpoint every connection dials. transport=blinkd machines have
  // their own daemon; transport=ssh machines are reached by running ssh FROM
  // the blinkd relay (the mac) — the HarmonyOS app itself only speaks blinkd.
  relayMachine(): Machine | null {
    for (let i = 0; i < this.machines.length; i++) {
      if (this.machines[i].transport === 'blinkd') {
        return this.machines[i];
      }
    }
    return null;
  }

  // blinkd endpoint used for a given tab's machine.
  blinkdEndpoint(m: Machine | null): Machine | null {
    if (m !== null && m.transport === 'blinkd') {
      return m;
    }
    return this.relayMachine();
  }

  // ---- exec script generation (iOS BlinkMachineStore.swift:180-260 verbatim) ----

  // TITLE = <basename(workPath)>-<session>; if session already equals/prefixes
  // the basename it is used as-is. outer tmux session = "cc-<TITLE>".
  static titleFor(workPath: string, session: string, fallbackUser: string): string {
    let dirBasename: string;
    if (workPath.length > 0) {
      const parts: string[] = workPath.split('/');
      dirBasename = parts[parts.length - 1].toLowerCase();
    } else {
      dirBasename = fallbackUser.toLowerCase();
    }
    if (session === dirBasename || session.indexOf(dirBasename + '-') === 0) {
      return session;
    }
    return dirBasename + '-' + session;
  }

  // The inner claude resume-or-new script (iOS resumeOrNew, :205).
  // codex / deepseek 没有 ~/.claude/projects 那套 customTitle 档案，resume / rename 都无从谈起，
  // 直接在工作目录里裸起；tab 的身份仍由外层 tmux session 名 cc-<TITLE> 保证。
  static agentLabel(agent: string): string {
    if (agent === 'codex') {
      return 'Codex';
    }
    if (agent === 'deepseek') {
      return 'DeepSeek';
    }
    return 'Claude Code';
  }

  /// 三家的官方 mark（media/mark_*.svg，跟 iOS/macOS 的 AgentMark 是同一份路径数据）
  static agentMark(agent: string): Resource {
    if (agent === 'codex') {
      return $r('app.media.mark_codex');
    }
    if (agent === 'deepseek') {
      return $r('app.media.mark_deepseek');
    }
    return $r('app.media.mark_claude');
  }

  /// 品牌色（角标的实心底）
  static agentBrand(agent: string): string {
    if (agent === 'codex') {
      return '#FFFFFF';
    }
    if (agent === 'deepseek') {
      return '#4D6BFE';
    }
    return '#D97757';
  }

  /// 压在品牌色上的图形色
  static agentInk(agent: string): string {
    return agent === 'codex' ? '#0B0C0E' : '#FFFFFF';
  }

  // 起的时候统一带上的参数：三家都是「免确认 + 不进沙箱」，只是叫法不同。
  //
  // DeepSeek（Codewhale）这档故意不传 --approval-policy：
  // ① 它的 never 不是「不用批准」而是「只跑只读工具，其余一律挡」——2026-09-24
  //    jack 那台就是这么被卡死的，shell 通道整个没了，装机/部署/构建全做不了；
  // ② 只要在命令行上传了这个参数（never / auto 都一样），posture 就被锁死，
  //    进 TUI 后按 Alt+Y 也切不动（实测）。
  // 真正的「全允许」是 Full Access（内部叫 bypass），命令行和配置文件都给不了，
  // 只能在 TUI 里按 Alt+Y / Shift+Tab 切，而且不落盘——所以每次起都要靠
  // fullAccessNudge 补一下。
  static agentArgs(agent: string): string {
    if (agent === 'codex') {
      return ' --dangerously-bypass-approvals-and-sandbox --no-daemon';
    }
    if (agent === 'deepseek') {
      return ' --sandbox-mode danger-full-access';
    }
    return ' --dangerously-skip-permissions';
  }

  // Codewhale 起来之后把权限档切到 Full Access（Alt+Y）。
  // posture 既不落盘也不认命令行参数（见 agentArgs 的注释），只能进 TUI 后发键，
  // 所以每次启动都得补这一下。等 pane 的前台进程真是 codewhale 了再发，发完回读
  // 状态栏确认切到了没有，最多试 60 秒——盲等固定秒数会被启动画面吃掉。
  // 用 ( … & ) 起在子 shell 里，免得 zsh 的作业完成提示打到 TUI 画面上。
  private static fullAccessNudge(agent: string): string {
    if (agent !== 'deepseek') {
      return '';
    }
    const pane: string = '"$TMUX_PANE"';
    // issue #81：同一根因的另一面。`bash -lc "codewhale …; exec bash"` 起的会话里 tmux 报
    // bash、代理是子进程，只按命令名匹配永远打不中 → Alt+Y 一直发不出去。补一条「子进程里有
    // 代理」也算已就位（同一前台进程组，M-y 照样进 TUI）。
    const bins: string = BlinkStore.agentBins(agent).join('|');
    return '_fa() { [ -n ' + pane + ' ] || return 0; i=0; while [ $i -lt 60 ]; do sleep 1; i=$((i+1)); ' +
      'PC=$(tmux display-message -p -t ' + pane + ' "#{pane_current_command}" 2>/dev/null); ' +
      'PP=$(tmux display-message -p -t ' + pane + ' "#{pane_pid}" 2>/dev/null); ' +
      'case "$PC" in ' + bins + ') ;; zsh|bash|sh|dash|ksh|fish) ' +
      'pgrep -P "$PP" -x "' + bins + '" >/dev/null 2>&1 || continue ;; *) continue;; esac; ' +
      'case "$(tmux capture-pane -p -t ' + pane + ' 2>/dev/null)" in *"Full Access"*) return 0;; esac; ' +
      'tmux send-keys -t ' + pane + ' M-y 2>/dev/null; done; }; ( _fa >/dev/null 2>&1 & ); ';
  }

  static agentCommand(agent: string): string {
    return BlinkStore.agentBins(agent)[0] + BlinkStore.agentArgs(agent);
  }

  // 可执行名候选（按顺序 command -v，第一个找得到的就用它起）。
  // 「deepseek tui」实际是 Codewhale（github.com/Hmbown/Codewhale）：自己装了叫
  // deepseek 的就用它，否则用 codewhale。
  static agentBins(agent: string): string[] {
    if (agent === 'codex') {
      return ['codex'];
    }
    if (agent === 'deepseek') {
      return ['deepseek', 'codewhale'];
    }
    return ['claude'];
  }

  // 没装时自动装的命令；空串 = 不自动装
  static agentInstall(agent: string): string {
    if (agent === 'codex') {
      return 'if command -v npm >/dev/null 2>&1; then npm i -g @openai/codex; ' +
        'elif command -v brew >/dev/null 2>&1; then brew install codex; fi';
    }
    if (agent === 'deepseek') {
      // README 给的官方装法，装到 ~/.local/bin
      return 'if command -v curl >/dev/null 2>&1; then curl -fsSL https://codewhale.net/install.sh | sh; fi';
    }
    return '';
  }

  static agentHint(agent: string): string {
    if (agent === 'codex') {
      return '手动装：npm i -g @openai/codex 或 brew install codex';
    }
    if (agent === 'deepseek') {
      return '手动装：curl -fsSL https://codewhale.net/install.sh | sh';
    }
    return '装一下 claude code';
  }

  // 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
  // 外层是 `$SHELL -lic '...'`，里面只能用双引号——别引入单引号。
  static agentLaunch(agent: string, cdTarget: string): string {
    const bins: string[] = BlinkStore.agentBins(agent);
    const ins: string = BlinkStore.agentInstall(agent);
    let has: string = '';
    for (let i = 0; i < bins.length; i++) {
      has += (i > 0 ? ' || ' : '') + 'command -v ' + bins[i] + ' >/dev/null 2>&1';
    }
    // 官方安装脚本装到 ~/.local/bin，登录 shell 未必带它
    const path: string = 'case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac; ';
    const miss: string = ins.length === 0 ? '' :
      'if ! { ' + has + '; }; then echo "[blink] 这台机器没装 ' + bins[0] + '，正在装…"; ' +
      ins + '; hash -r 2>/dev/null; fi; ';
    let run: string = '';
    for (let i = 0; i < bins.length; i++) {
      const cmd: string = bins[i] + BlinkStore.agentArgs(agent);
      run += 'if command -v ' + bins[i] + ' >/dev/null 2>&1; then ' + cmd + '; el';
    }
    run += 'se echo "[blink] 没有 ' + bins.join('/') + '：' + BlinkStore.agentHint(agent) + '"; ';
    run += 'fi; ';   // elif 串起来的整条只收一个 fi
    // deepseekEnv 以 '&& ' 收尾，放 cd 前面：没配 key 时整条短路，不会往下把 TUI 起起来
    return BlinkStore.deepseekEnv(agent) + 'cd ' + cdTarget + ' && { ' + path + miss +
      BlinkStore.fullAccessNudge(agent) + run + '}';
  }

  // Codewhale 自己认 $DEEPSEEK_API_KEY（auth status 里 provider=deepseek、来源 env），
  // 所以只要确保这个变量在就行。
  // key 不由 App 下发，从那台机器自己的 ~/.zshrc 读：
  // 每台机器用自己的 key，App 里不存、不同步，也就不会再被哪一端的旧值盖回去。
  // 没配就不启动、把怎么配留在屏上。
  // 结尾是 '&& '，接在后面的 cd … && { … } 前面，没 key 时整条短路。
  private static deepseekEnv(agent: string): string {
    if (agent !== 'deepseek') {
      return '';
    }
    // 往现有 shell 里 source 启动文件时（会话还在的自愈路径），那个 shell 可能是
    // 在 ~/.zshrc 加 key 之前开的，没有这个变量——先自己去 ~/.zshrc 捞一次。
    return '[ -z "$DEEPSEEK_API_KEY" ] && [ -f "$HOME/.zshrc" ] && eval "$(grep "^export DEEPSEEK_API_KEY=" "$HOME/.zshrc" | tail -1)"; ' +
      'if [ -z "$DEEPSEEK_API_KEY" ]; then ' +
      'echo "[blink] 这台机器还没配 DeepSeek key：在 ~/.zshrc 里加一行 export DEEPSEEK_API_KEY=sk-…，再重开这个会话"; false; ' +
      'else export DEEPSEEK_API_KEY; fi && ';
  }

  private static innerScript(cdTarget: string, title: string, agent: string): string {
    // 只有 claude 有 customTitle → resume 那套；codex 和 DeepSeek（Codewhale）裸起。
    // DeepSeek 档不再用 claude 接 DeepSeek 后端：那样每轮都要把整段上下文重发，
    // 一天光缓存读就 5 亿 token，太费。
    if (agent !== 'claude') {
      return BlinkStore.agentLaunch(agent, cdTarget);
    }
    // 同名会话可能有好几个（/clear 过就会），resume 要挑最近修改的那个；以前 find | head -1 按目录顺序挑，会接回老对话（2026-09-22 adam-rc 接回了被 DeepSeek 审核拒掉的那段历史）
    return 'cd ' + cdTarget + ' && { CUR=$(pwd | sed "s:[/.]:-:g"); PROJ="$HOME/.claude/projects/$CUR"; TITLE="' +
    title +
    '"; ID=""; if [ -d "$PROJ" ]; then M=$(find "$PROJ" -maxdepth 1 -name "*.jsonl" -type f -exec grep -lF "\\"customTitle\\":\\"$TITLE\\"" {} + 2>/dev/null | while IFS= read -r f; do echo "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) $f"; done | sort -rn | head -1 | cut -d" " -f2-); [ -n "$M" ] && ID=$(basename "$M" .jsonl); fi; if [ -n "$ID" ]; then claude --dangerously-skip-permissions --resume "$ID"; else if [ -n "$TMUX" ]; then (sleep 1.5; tmux send-keys "/rename $TITLE" Enter) >/dev/null 2>&1 & claude --dangerously-skip-permissions; else TN="cc-$TITLE"; (sleep 1.5; tmux send-keys -t "$TN" "/rename $TITLE" Enter) >/dev/null 2>&1 & tmux new-session -A -s "$TN" "$SHELL -ic \\"claude --dangerously-skip-permissions\\""; fi; fi; }';
  }

  // Full remote script for a (machine, workDir, session) triple — identical to
  // what iOS generates, so both devices attach the same cc-<TITLE> session.
  static remoteScript(workPath: string, session: string, fallbackUser: string, useTmux: boolean,
                      agent: string = 'claude'): string {
    const title: string = BlinkStore.titleFor(workPath, session, fallbackUser);
    const outerSession: string = 'cc-' + title;
    const pathArg: string = workPath.length > 0 ? workPath : '$HOME';
    const inner: string = BlinkStore.innerScript(pathArg, title, agent);
    const tail: string = '; echo "[blink] ' + agent + ' 已退出，掉到 shell（上方有报错即原因，敲 ' +
      agent + ' 重试）"; exec $SHELL -il';
    if (!useTmux) {
      return "exec $SHELL -lic '" + inner + tail + "'";
    }
    const detectSock: string = "S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac";
    const migrate: string = 'if [ "' + session + '" != "' + outerSession + '" ] && tmux has-session -t "' + session +
      '" 2>/dev/null && ! tmux has-session -t "' + outerSession + '" 2>/dev/null; then tmux rename-session -t "' +
      session + '" "' + outerSession + '" 2>/dev/null; fi';
    // Boot file + self-heal (iOS BlinkMachineStore.swift useTmux branch, verbatim):
    // `-A` on an existing session only attaches — inner (cd + claude resume) never
    // reruns, so a broken session (bare shell in the wrong dir) stays broken forever.
    // Before attaching, if the pane's foreground process is a bare shell, send-keys
    // `source <boot>` to re-cd into the workdir and resume claude; leave claude alone
    // if it is still running. Refresh / auto-reconnect both go through this path.
    // 启动文件先写临时文件再 mv：几个客户端同时重连时 `cat >` 会互相截断交错，留下半截内容（parse error）
    const bootFile: string = '/tmp/.blink-boot-' + outerSession + '.sh';
    // issue #81：只看 pane_current_command 会把 `bash -lc "claude …; exec bash"` 这种会话
    // （tmux 报 bash、claude 是它的子进程且活着）当成裸 shell，往活着的 Claude 输入框里
    // send-keys `source …`，Claude 把它当用户消息收到。判「裸 shell」必须再加一条：
    // pane 进程没有子进程（pgrep -P pane_pid）。pgrep 不可用时退回旧行为，宁可清屏也别漏自愈。
    const heal: string = 'if tmux has-session -t ' + outerSession +
      ' 2>/dev/null; then PC=$(tmux display-message -p -t ' + outerSession +
      " '#{pane_current_command}' 2>/dev/null); PP=$(tmux display-message -p -t " + outerSession +
      " '#{pane_pid}' 2>/dev/null); case \"$PC\" in zsh|bash|sh|dash|ksh|fish) " +
      'pgrep -P "$PP" >/dev/null 2>&1 || { tmux send-keys -t ' + outerSession +
      ' C-u; tmux send-keys -t ' + outerSession + ' " source ' + bootFile + '" Enter; };; esac; fi';
    return detectSock + '\n' +
      'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n' +
      migrate + '\n' +
      "cat > " + bootFile + ".$$ <<'BLINKBOOT'\n" +
      inner + '\n' +
      'BLINKBOOT\n' +
      'mv -f ' + bootFile + '.$$ ' + bootFile + '\n' +
      heal + '\n' +
      'exec tmux new-session -A -s ' + outerSession + " $SHELL -lic 'source " + bootFile + tail + "'";
  }

  // The exec frame payload for a tab (what blinkd's `bash -c` runs).
  // blinkd machine: unpack-and-run the script locally.
  // ssh machine:    run ssh FROM the relay with the same unpack-and-run remotely.
  execForTab(t: TabModel, viaSSH: boolean = false, directSSH: boolean = false): string {
    const m = this.machineById(t.machineId);
    const w = this.workDirById(t.workDirId);
    const path: string = w !== null ? w.path : '';
    const user: string = m !== null ? m.user : '';
    const title: string = BlinkStore.titleFor(path, t.tmuxSession, user);
    const agent: string = this.agentFor(t.machineId, title);
    const script: string = BlinkStore.remoteScript(path, t.tmuxSession, user, t.useTmux, agent);
    const b64: string = buffer.from(script, 'utf-8').toString('base64');
    const tmpName: string = t.useTmux ? '/tmp/.blink-tmux-$$.sh' : '/tmp/.blink-cc-$$.sh';
    const unpack: string = 'echo ' + b64 + ' | base64 -d > ' + tmpName + ' && exec bash ' + tmpName;
    // directSSH：脚本由客户端自己里的 ssh 通道执行，不要再包一层 ssh -t（同手机端）
    if (directSSH) {
      return unpack;
    }
    if (m === null || (!viaSSH && m.transport === 'blinkd')) {
      return unpack;
    }
    return 'ssh -t ' + m.user + '@' + m.host + ' -- "' + unpack + '"';
  }

  // Command used by the transcript dump (dock 🕐 / panel 📄): capture the outer
  // tmux session's pane text on the tab's machine.
  transcriptCommandForTab(t: TabModel): string {
    const m = this.machineById(t.machineId);
    const w = this.workDirById(t.workDirId);
    const path: string = w !== null ? w.path : '';
    const user: string = m !== null ? m.user : '';
    const title: string = BlinkStore.titleFor(path, t.tmuxSession, user);
    const cap: string = 'tmux capture-pane -pt cc-' + title + ' -S -3000 2>&1';
    if (m === null || m.transport === 'blinkd') {
      return cap;
    }
    return 'ssh ' + m.user + '@' + m.host + ' -- ' + BlinkStore.shq(cap);
  }

  static shq(s: string): string {
    return "'" + s.replace(new RegExp("'", 'g'), "'\\''") + "'";
  }

  // 对话记录页原生增量拉取脚本(与 iOS transcriptDeltaScript 同一份 shell):
  // 输出 @TSB64@<b64(META\tfile\ttotal\tfull + \n + 正文)>@TSB64E@;
  // 缓存命中只解析游标之后的新行,换文件/无缓存整拉最后 100 条。
  transcriptDeltaScriptForTab(t: TabModel, cachedFile: string, cachedLines: number): string | null {
    const m = this.machineById(t.machineId);
    if (m === null) {
      return null;
    }
    const w = this.workDirById(t.workDirId);
    const path: string = (w !== null && w.path.length > 0) ? w.path : '/Users/' + m.user;
    const cwdEncoded: string = path.replace(new RegExp('/', 'g'), '-').replace(new RegExp('[.]', 'g'), '-');
    const title: string = BlinkStore.titleFor(path, t.tmuxSession, m.user);
    const safeFile: string = cachedFile.replace(new RegExp('[^A-Za-z0-9.-]', 'g'), '');
    const n: number = cachedLines > 0 ? cachedLines : 0;
    const lines: string[] = [
      'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH',
      'PROJ=~/.claude/projects',
      'DIR=$PROJ/' + cwdEncoded,
      'pick_latest_by_mtime() {',
      '  while read f; do',
      '    [ -z "$f" ] && continue',
      "    printf '%d\\t%s\\n' \"$(stat -f %m \"$f\" 2>/dev/null || stat -c %Y \"$f\" 2>/dev/null)\" \"$f\"",
      '  done | sort -rn | head -1 | cut -f2-',
      '}',
      "TITLE='" + title + "'",
      'F=$(grep -lF "\\"customTitle\\":\\"$TITLE\\"" "$DIR"/*.jsonl 2>/dev/null | pick_latest_by_mtime)',
      'if [ -z "$F" ]; then',
      '  F=$(grep -lF "\\"customTitle\\":\\"$TITLE\\"" "$DIR"*/*.jsonl 2>/dev/null | pick_latest_by_mtime)',
      'fi',
      'if [ -z "$F" ]; then',
      "  F=$(grep -rlF \"\\\"customTitle\\\":\\\"$TITLE\\\"\" \"$PROJ\" --include='*.jsonl' 2>/dev/null | pick_latest_by_mtime)",
      'fi',
      'WARN=""',
      'if [ -z "$F" ]; then',
      '  F=$(ls -t "$DIR"/*.jsonl 2>/dev/null | head -1)',
      '  [ -n "$F" ] && WARN="⚠️ customTitle $TITLE 未匹配，回退到同目录最新 jsonl"',
      'fi',
      'if [ -z "$F" ]; then',
      '  F=$(ls -t "$DIR"*/*.jsonl 2>/dev/null | head -1)',
      '  [ -n "$F" ] && WARN="⚠️ customTitle $TITLE 未匹配，回退到同前缀目录最新 jsonl"',
      'fi',
      "emit() { EB64=$(printf '%s' \"$1\" | base64 | tr -d '\\n'); printf '@TSB64@%s@TSB64E@\\n' \"$EB64\"; }",
      'if [ -z "$F" ]; then',
      "  emit \"$(printf 'META\\tNOTFOUND\\t0\\t1\\n没找到 %s 的会话记录（customTitle 未匹配）。在 cc 里跑一次 /title %s 即可。' \"$TITLE\" \"$TITLE\")\"",
      '  exit 0',
      'fi',
      'BASE=$(basename "$F")',
      "TOTAL=$(wc -l < \"$F\" | tr -d ' ')",
      'START=1',
      'if [ "$BASE" = "' + safeFile + '" ] && [ ' + n + ' -le "$TOTAL" ]; then',
      '  START=$(( ' + n + ' + 1 ))',
      'fi',
      'FULL=0',
      '[ "$START" -eq 1 ] && FULL=1',
      'BODY=""',
      'if [ "$START" -le "$TOTAL" ]; then',
      'BODY=$(sed -n "${START},${TOTAL}p" "$F" | jq -s -r --arg full "$FULL" \'',
      '  [.[]',
      '    | select(.type=="user" or .type=="assistant")',
      // #83：CronCreate 定时任务自动发的提示词带 turnOrigin:"scheduled" / scheduledTaskId，
      // 会以「我」的消息出现在记录页里刷屏。只滤这一类，别的不动。
      '    | select(.turnOrigin != "scheduled" and .scheduledTaskId == null)',
      '    | (if (.message.content | type) == "string" then',
      '         .message.content',
      '       else',
      '         [.message.content[]? | select(.type=="text") | .text] | join("\\n")',
      '       end) as $rawBody',
      '    | ($rawBody',
      '        | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")',
      '        | gsub("(?s)<task-notification>.*?</task-notification>"; "")',
      '        | gsub("(?s)<local-command-stdout>.*?</local-command-stdout>"; "")',
      '        | gsub("(?s)<local-command-stderr>.*?</local-command-stderr>"; "")',
      '        | gsub("(?s)<command-name>.*?</command-name>"; "")',
      '        | gsub("(?s)<command-message>.*?</command-message>"; "")',
      '        | gsub("(?s)<command-args>.*?</command-args>"; "")',
      '        | gsub("(?s)<user-prompt-submit-hook>.*?</user-prompt-submit-hook>"; "")',
      '        | gsub("(?s)<bash-input>.*?</bash-input>"; "")',
      '        | gsub("(?s)<bash-stdout>.*?</bash-stdout>"; "")',
      '        | gsub("(?s)<bash-stderr>.*?</bash-stderr>"; "")',
      '        | sub("^\\\\s+"; "")',
      '        | sub("\\\\s+$"; "")',
      '      ) as $body',
      '    | select(($body | length) > 0)',
      '    | select($body != "Continue from where you left off."',
      '             and $body != "No response requested."',
      '             and ($body | test("^\\\\[Request interrupted by user[^\\\\]]*\\\\]") | not))',
      '    | {type: .type, body: $body}',
      '  ] |',
      '  (if $full == "1" then .[-100:] else . end) |',
      '  .[] |',
      '  (if .type == "user" then "▶ You" else "◆ Claude" end), .body, ""',
      "')",
      'fi',
      'HEAD=""',
      'if [ "$FULL" = "1" ]; then',
      '  [ -n "$WARN" ] && HEAD="$WARN\\n"',
      '  HEAD="$HEAD=== $F ===\\n"',
      'fi',
      "emit \"$(printf 'META\\t%s\\t%s\\t%s\\n' \"$BASE\" \"$TOTAL\" \"$FULL\"; printf \"$HEAD\"; printf '%s' \"$BODY\")\"",
    ];
    return lines.join('\n');
  }

  static newId(): string {
    // UUID v4-ish from Math.random (config ids only, not crypto)
    let out: string = '';
    const hex: string = '0123456789ABCDEF';
    for (let i = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        out += '-';
      } else if (i === 14) {
        out += '4';
      } else {
        out += hex.charAt(Math.floor(Math.random() * 16));
      }
    }
    return out;
  }
}
