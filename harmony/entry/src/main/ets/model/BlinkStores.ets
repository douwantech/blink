////////////////////////////////////////////////////////////////////////////////
//
// BlinkStores — the HarmonyOS twin of the iOS fork's config stores
// (BlinkMachineStore / BlinkWorkDirStore / BlinkSessionPresetStore /
//  BlinkPeopleStore / TabStateStore / TabRestStore / AITextPolisher storage).
//
// On first run the stores are seeded from rawfile/seed_config.json, which is a
// direct export of the user's real iOS config (pulled from the iPhone app
// container), so the HarmonyOS app opens with the exact same machines, work
// dirs, tabs, favorites and voice-AI data as iOS. After that, preferences are
// the source of truth (same JSON schemas as iOS so a future iCloud-KV-style
// sync can merge them).
//
// execForTab() reproduces the iOS sshCommand/blinkdCommand remote script
// byte-for-byte (BlinkMachineStore.swift:180-260): the same cc-<TITLE> outer
// tmux session names, the same claude resume-by-customTitle inner script —
// so a tab opened on this phone attaches to the *same* tmux session and the
// *same* claude conversation as the iOS app.
//
////////////////////////////////////////////////////////////////////////////////

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util, buffer } from '@kit.ArkTS';
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

export interface SeedConfig {
  machines: Machine[];
  workDirs: WorkDir[];
  people: string[];
  presets: SessionPreset[];
  tabs: TabModel[];
  currentId: string;
  pinned: PinnedTab[];
  favorites: string[];
  history: string[];
  terms: Record<string, Record<string, number>>;
  corrections: string[][];
  favoriteCounts: Record<string, number>;
  voice: VoiceConfig;
  filterMachineId: string;
  locale: string;
  resting: string[];
  workMode: boolean;
  autoReconnect?: boolean;
  updatedAt?: number;   // iOS 推送时的 epoch 秒，配置同步用 last-writer-wins
}

// ---- store ----

const P_KEY: string = 'blink_store';   // preferences file name

export class BlinkStore {
  machines: Machine[] = [];
  workDirs: WorkDir[] = [];
  people: string[] = [];
  presets: SessionPreset[] = [];
  tabs: TabModel[] = [];
  currentTabId: string = '';
  filterMachineId: string = '';        // '' = all machines
  pinned: PinnedTab[] = [];
  favorites: string[] = [];
  favoriteCounts: Record<string, number> = {};
  history: string[] = [];
  corrections: string[][] = [];        // [asrRaw, final] pairs
  terms: Record<string, Record<string, number>> = {};  // wrong -> {correct: count}
  resting: string[] = [];              // resting tab ids (TabRestStore)
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

  async load(ctx: common.UIAbilityContext): Promise<void> {
    this.prefs = await preferences.getPreferences(ctx, P_KEY);
    // v2: v1 曾在 seed_config.json 缺失的包上跑过（播种失败也记了已播种），
    // 换 key 让那批安装重新播种一次真实 iOS 配置。
    const seeded: boolean = await this.prefs.get('seeded_v2', false) as boolean;
    if (!seeded) {
      await this.seedFromRawfile(ctx);
      await this.prefs.put('seeded_v2', true);
      await this.persistAll();
      return;
    }
    this.machines = this.readJson<Machine[]>('machines', []);
    this.workDirs = this.readJson<WorkDir[]>('workDirs', []);
    this.people = this.readJson<string[]>('people', []);
    this.presets = this.readJson<SessionPreset[]>('presets', []);
    this.tabs = this.readJson<TabModel[]>('tabs', []);
    this.pinned = this.readJson<PinnedTab[]>('pinned', []);
    this.favorites = this.readJson<string[]>('favorites', []);
    this.favoriteCounts = this.readJson<Record<string, number>>('favoriteCounts', {});
    this.history = this.readJson<string[]>('history', []);
    this.corrections = this.readJson<string[][]>('corrections', []);
    this.terms = this.readJson<Record<string, Record<string, number>>>('terms', {});
    this.resting = this.readJson<string[]>('resting', []);
    const v = this.readJson<VoiceConfig | null>('voice', null);
    if (v !== null) {
      this.voice = v;
    }
    this.currentTabId = (await this.prefs!.get('currentTabId', '') as string);
    this.filterMachineId = (await this.prefs!.get('filterMachineId', '') as string);
    this.workMode = (await this.prefs!.get('workMode', false) as boolean);
    this.autoReconnect = (await this.prefs!.get('autoReconnect', true) as boolean);
    this.locale = (await this.prefs!.get('locale', 'zh-CN') as string);
  }

  private async seedFromRawfile(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const raw: Uint8Array = await ctx.resourceManager.getRawFileContent('seed_config.json');
      const dec = util.TextDecoder.create('utf-8');
      const s: SeedConfig = JSON.parse(dec.decodeToString(raw)) as SeedConfig;
      this.machines = s.machines;
      this.workDirs = s.workDirs;
      this.people = s.people;
      this.presets = s.presets;
      this.tabs = s.tabs;
      this.currentTabId = s.currentId;
      this.pinned = s.pinned;
      this.favorites = s.favorites;
      this.favoriteCounts = s.favoriteCounts;
      this.history = s.history;
      this.corrections = s.corrections;
      this.terms = s.terms;
      this.voice = s.voice;
      this.filterMachineId = s.filterMachineId;
      this.locale = s.locale;
      this.resting = s.resting;
      this.workMode = s.workMode;
      hilog.info(DOMAIN, TAG, 'seeded from iOS config: %{public}d machines %{public}d tabs',
        this.machines.length, this.tabs.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'seed failed: %{public}s', `${e}`);
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
  }

  private putVal(key: string, v: preferences.ValueType): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    p.put(key, v).then((): Promise<void> => p.flush()).catch(() => {});
  }

  // 方案一配置同步：整体采纳 iOS 推来的配置（形状同 seed），但当前 tab 若仍
  // 存在则保住不跳。调用方负责清理已消失 tab 的连接和刷新 UI。
  async applySync(s: SeedConfig): Promise<void> {
    const keep: string = this.currentTabId;
    this.machines = s.machines;
    this.workDirs = s.workDirs;
    this.people = s.people;
    this.presets = s.presets;
    this.tabs = s.tabs;
    this.pinned = s.pinned;
    this.favorites = s.favorites;
    this.favoriteCounts = s.favoriteCounts;
    this.history = s.history;
    this.corrections = s.corrections;
    this.terms = s.terms;
    this.voice = s.voice;
    this.filterMachineId = s.filterMachineId;
    this.locale = s.locale;
    this.resting = s.resting;
    this.workMode = s.workMode;
    if (s.autoReconnect !== undefined) {
      this.autoReconnect = s.autoReconnect;
    }
    this.currentTabId = this.tabs.findIndex((t: TabModel) => t.id === keep) >= 0 ? keep : s.currentId;
    await this.persistAll();
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
    await p.put('favorites', JSON.stringify(this.favorites));
    await p.put('favoriteCounts', JSON.stringify(this.favoriteCounts));
    await p.put('history', JSON.stringify(this.history));
    await p.put('corrections', JSON.stringify(this.corrections));
    await p.put('terms', JSON.stringify(this.terms));
    await p.put('resting', JSON.stringify(this.resting));
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
  saveFavorites(): void {
    this.putJson('favorites', this.favorites);
    this.putJson('favoriteCounts', this.favoriteCounts);
  }
  saveHistory(): void { this.putJson('history', this.history); }
  saveCorrections(): void { this.putJson('corrections', this.corrections); }
  saveTerms(): void { this.putJson('terms', this.terms); }
  saveResting(): void { this.putJson('resting', this.resting); }
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

  isResting(tabId: string): boolean {
    return this.resting.indexOf(tabId) >= 0;
  }

  toggleResting(tabId: string): boolean {
    const i: number = this.resting.indexOf(tabId);
    if (i >= 0) {
      this.resting.splice(i, 1);
    } else {
      this.resting.push(tabId);
    }
    this.saveResting();
    return i < 0;
  }

  // Explicit set (rest-panel switches): true = resting/hidden, false = on-duty/shown.
  setResting(tabId: string, resting: boolean): void {
    const i: number = this.resting.indexOf(tabId);
    if (resting && i < 0) {
      this.resting.push(tabId);
    } else if (!resting && i >= 0) {
      this.resting.splice(i, 1);
    }
    this.saveResting();
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

  // Tabs visible in the strip. Resting (😴) tabs are ALWAYS hidden — iOS keeps
  // _workModeOn constant-true (SpaceController.swift:525) — except the current tab,
  // which is never hidden (_hiddenByWorkMode:1616) so the strip is never left empty.
  visibleTabs(): TabModel[] {
    const out: TabModel[] = [];
    for (let i = 0; i < this.tabs.length; i++) {
      const t = this.tabs[i];
      if (this.filterMachineId.length > 0 && t.machineId !== this.filterMachineId) {
        continue;
      }
      if (this.isResting(t.id) && t.id !== this.currentTabId) {
        continue;
      }
      out.push(t);
    }
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
  private static innerScript(cdTarget: string, title: string): string {
    return 'cd ' + cdTarget + ' && { CUR=$(pwd | sed "s:[/.]:-:g"); PROJ="$HOME/.claude/projects/$CUR"; TITLE="' +
    title +
    '"; ID=""; if [ -d "$PROJ" ]; then M=$(find "$PROJ" -maxdepth 1 -name "*.jsonl" -type f -exec grep -lF "\\"customTitle\\":\\"$TITLE\\"" {} + 2>/dev/null | head -1); [ -n "$M" ] && ID=$(basename "$M" .jsonl); fi; if [ -n "$ID" ]; then claude --resume "$ID"; else if [ -n "$TMUX" ]; then (sleep 1.5; tmux send-keys "/rename $TITLE" Enter) >/dev/null 2>&1 & claude; else TN="cc-$TITLE"; (sleep 1.5; tmux send-keys -t "$TN" "/rename $TITLE" Enter) >/dev/null 2>&1 & tmux new-session -A -s "$TN" "$SHELL -ic \\"claude\\""; fi; fi; }';
  }

  // Full remote script for a (machine, workDir, session) triple — identical to
  // what iOS generates, so both devices attach the same cc-<TITLE> session.
  static remoteScript(workPath: string, session: string, fallbackUser: string, useTmux: boolean): string {
    const title: string = BlinkStore.titleFor(workPath, session, fallbackUser);
    const outerSession: string = 'cc-' + title;
    const pathArg: string = workPath.length > 0 ? workPath : '$HOME';
    const inner: string = BlinkStore.innerScript(pathArg, title);
    const tail: string = '; echo "[blink] claude 已退出，掉到 shell（上方有报错即原因，敲 claude 重试）"; exec $SHELL -il';
    if (!useTmux) {
      return "exec $SHELL -lic '" + inner + tail + "'";
    }
    const detectSock: string = "S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac";
    const migrate: string = 'if [ "' + session + '" != "' + outerSession + '" ] && tmux has-session -t "' + session +
      '" 2>/dev/null && ! tmux has-session -t "' + outerSession + '" 2>/dev/null; then tmux rename-session -t "' +
      session + '" "' + outerSession + '" 2>/dev/null; fi';
    return detectSock + '\n' +
      'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n' +
      migrate + '\n' +
      'exec tmux new-session -A -s ' + outerSession + " $SHELL -lic '" + inner + tail + "'";
  }

  // The exec frame payload for a tab (what blinkd's `bash -c` runs).
  // blinkd machine: unpack-and-run the script locally.
  // ssh machine:    run ssh FROM the relay with the same unpack-and-run remotely.
  execForTab(t: TabModel): string {
    const m = this.machineById(t.machineId);
    const w = this.workDirById(t.workDirId);
    const path: string = w !== null ? w.path : '';
    const user: string = m !== null ? m.user : '';
    const script: string = BlinkStore.remoteScript(path, t.tmuxSession, user, t.useTmux);
    const b64: string = buffer.from(script, 'utf-8').toString('base64');
    const tmpName: string = t.useTmux ? '/tmp/.blink-tmux-$$.sh' : '/tmp/.blink-cc-$$.sh';
    const unpack: string = 'echo ' + b64 + ' | base64 -d > ' + tmpName + ' && exec bash ' + tmpName;
    if (m === null || m.transport === 'blinkd') {
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
