////////////////////////////////////////////////////////////////////////////////
//
// ServerConfig — 手机版的服务器配置同步（issue #77，照 iOS
// Blink/SmarterKeys/ServerConfigSync.swift 的口径）。
//
// 服务器是配置的唯一权威：登录拿 token → GET /v1/config 拿整份快照
// （machines / tabs / selection / agents）→ 无条件采纳、清 dirty；
// 本地个人状态（选中的机器、当前 tab、agents、休息名单）改动后 PUT 回服务器。
// 老的「各机器 ~/.blink/sync/blink_config.json 双向文件同步」已彻底停掉：
// 这里不读、不写任何机器上的文件。
//
// token 只进系统安全存储（@kit.AssetStoreKit），绝不打印、绝不进 preferences；
// 账号名/canWrite/版本号/dirty 是配置而非机密，放 preferences；
// 上一次 GET 的原始响应落 filesDir 下的缓存文件（含机器 token，不打印），
// 网络抖动时用它继续展示，界面不会被清空。
//
////////////////////////////////////////////////////////////////////////////////

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { asset } from '@kit.AssetStoreKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BlinkStore, Machine, WorkDir, TabModel, PinnedTab } from './BlinkStores';

const DOMAIN: number = 0x0B11;
const TAG: string = 'ServerConfig';

// 服务器地址（iOS ServerConfigSync.baseURL 同值）
const BASE: string = 'https://blink-api.douwantech.com';
// token 在系统安全存储里的别名（服务名 + 账号，iOS 用的是 keychain service/account）
const TOKEN_ALIAS: string = 'com.douwantech.blink.config-server|session';
const P_KEY: string = 'blink_server';   // preferences 文件名（只放非机密）
const POLL_MS: number = 15000;          // 回前台 + 15s 定时刷新；版本未变时服务器回 304

// ---- 服务器响应形状（字段名与 iOS ServerSnapshot 一致） ----

export interface ServerUser {
  id: number;
  username: string;
  isAdmin: boolean;
  canWrite: boolean;
}

/** 快照里的原始标签条目；`shared:true` 的是服务器注入的全局公用标签。 */
export interface ServerTabRaw {
  id: string;
  machineId?: string;
  tmuxSession?: string;
  workDir?: string;
  shared?: boolean;
}

export interface ServerTabsState {
  version?: number;
  tabs: ServerTabRaw[];
  closedIds?: string[];
}

/** 快照里的原始书签条目（服务器 /v1/config 的 pinned）：position 是显示顺序。 */
export interface ServerPinnedRaw {
  id?: string;
  title?: string;
  url?: string;
  authUser?: string;
  authPassword?: string;
  position?: number;
}

export interface ServerSnapshot {
  version: string;
  machines: Machine[];
  pinned?: ServerPinnedRaw[];
  tabs: ServerTabsState;
  recentSelection?: Record<string, string>;
  agents?: Record<string, string>;
  user: ServerUser;
}

interface ServerLoginResponse {
  token: string;
  user: ServerUser;
}

/** 快照里的公用标签在应用层的只读影子：不落盘成个人标签、不回传。 */
export interface SharedTab {
  id: string;
  machineId: string;
  tmuxSession: string;
  workDir: string;
}

// PUT /v1/config/tabs 的 body（只含个人标签）
interface PutTab {
  id: string;
  machineId: string;
  tmuxSession: string;
  workDir?: string;
}

interface PutTabsBody {
  version: number;
  tabs: PutTab[];
  closedIds: string[];
}

/** 一次 HTTP 往返的结果：只暴露状态码与字符串体。 */
interface HttpResult {
  code: number;
  body: string;
}

export class ServerConfig {
  /** 当前账号名（'' = 未登录）。非机密，设置页要显示。 */
  username: string = '';
  /** 服务器下发的写权限（isAdmin && canWrite）。 */
  canWrite: boolean = false;
  /** 最近一次服务器交互是否成功（失败=离线，用缓存继续展示）。 */
  isOnline: boolean = false;
  /** 上次完整采纳进来的服务器版本，上传前用它对齐（对齐后 304 才继续 PUT）。 */
  version: string = '';
  /** 本地是否有缓存快照（离线只读展示用）。 */
  hasCachedSnapshot: boolean = false;
  /** 服务器注入的全局公用标签，服务器顺序。只读影子：不落盘、不回传。 */
  sharedTabs: SharedTab[] = [];

  private ctx: common.UIAbilityContext;
  private store: BlinkStore;
  private prefs: preferences.Preferences | null = null;
  private token: string = '';
  private dirty: boolean = false;          // 本地个人状态未上传
  private applying: boolean = false;       // 正在采纳服务器快照（期间的落盘不算本地改动）
  private uploading: boolean = false;
  private tabVersion: number = 0;          // tabs PUT 的自增版本计数（服务器形状需要）
  private uploadTimer: number = -1;
  private pollTimer: number = -1;
  onApplied: (() => void) | null = null;
  // 「在岗名单是否已物化」的在岗状态统一放在 store（restLoaded / restActive），
  // 这里不再另存一份，避免两处不同步。**没物化就绝不上传**——传空集会把服务器
  // 「默认只有 tom 在岗」的规则清掉。

  constructor(ctx: common.UIAbilityContext, store: BlinkStore) {
    this.ctx = ctx;
    this.store = store;
  }

  // ---- 启动 / 会话 ----

  /** 读 token（安全存储）+ 账号名/版本/dirty（preferences）。返回是否有 session。 */
  async hasSession(): Promise<boolean> {
    this.prefs = await preferences.getPreferences(this.ctx, P_KEY);
    this.username = await this.prefs.get('username', '') as string;
    this.canWrite = await this.prefs.get('canWrite', false) as boolean;
    this.version = await this.prefs.get('appliedVersion', '') as string;
    this.dirty = await this.prefs.get('dirty', false) as boolean;
    this.tabVersion = await this.prefs.get('tabsVersion', 0) as number;
    this.hasCachedSnapshot = this.readCache() !== null;
    this.token = await this.readToken();
    return this.token.length > 0;
  }

  /**
   * 登录：POST /v1/login。成功即落袋（token 存安全存储 + 立刻拉一次全量快照）。
   * 失败 throw Error，message 就是登录页要显示的文案（401/429/其它三种，同 iOS）。
   */
  async login(username: string, password: string): Promise<void> {
    const body: Record<string, string> = {};
    body['username'] = username;
    body['password'] = password;
    const rsp: HttpResult = await this.send('POST', '/v1/login', JSON.stringify(body), '');
    if (rsp.code !== 200) {
      if (rsp.code === 401) {
        throw new Error('用户名或密码错误');
      }
      if (rsp.code === 429) {
        throw new Error('尝试次数过多，请等 5 分钟后再登录');
      }
      throw new Error('服务器暂不可用（HTTP ' + rsp.code + '）');
    }
    const login: ServerLoginResponse = JSON.parse(rsp.body) as ServerLoginResponse;
    // 换账号：清掉上一个账号的缓存与采纳版本，避免把别人的机器/标签当自己的
    const cached: ServerSnapshot | null = this.readCache();
    if (cached !== null && cached.user !== undefined && cached.user.id !== login.user.id) {
      this.removeCache();
      this.version = '';
      this.dirty = false;
    }
    await this.saveToken(login.token);
    this.token = login.token;
    this.username = login.user.username;
    this.canWrite = login.user.isAdmin && login.user.canWrite;
    if (this.prefs !== null) {
      await this.prefs.put('username', this.username);
      await this.prefs.put('canWrite', this.canWrite);
      await this.prefs.flush();
    }
    // 登录成功即拉全量（force：不带 version，拿整份快照无条件采纳）。
    // 这里失败了也绝不回滚 session —— token 已在安全存储里，下次启动/轮询会重拉。
    await this.syncFromServer(true);
  }

  /**
   * 退出登录：清 token + 账号名 + 采纳版本（不动缓存快照与已采纳的机器/标签，
   * 重新登录会被服务器快照覆盖回来）。调用方负责切回登录页。
   */
  async logout(): Promise<void> {
    this.stopPolling();
    await this.clearSession();
  }

  // ---- 拉取 / 采纳 ----

  /** 回前台 + 定时轮询走这里：版本未变时服务器回 304，什么都不做。 */
  async refresh(): Promise<void> {
    if (this.token.length === 0) {
      return;
    }
    try {
      await this.syncFromServer(false);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh: %{public}s', `${e}`);
    }
  }

  /**
   * GET /v1/config 并采纳。304 = 服务器版本未变（不动本地）；200 = 版本前进/本机首次，
   * 整份快照无条件生效并清 dirty；401 = 清 session 回登录页；网络失败 → 用缓存继续展示。
   */
  private async syncFromServer(force: boolean): Promise<void> {
    if (this.token.length === 0) {
      return;
    }
    let path: string = '/v1/config';
    if (!force && this.version.length > 0) {
      path = path + '?version=' + encodeURIComponent(this.version);
    }
    let rsp: HttpResult;
    try {
      rsp = await this.send('GET', path, '', this.token);
    } catch (e) {
      // 网络抖动：不清界面，退回上一次缓存（已登录时才有意义）
      this.isOnline = false;
      await this.restoreCache();
      throw new Error(`${e}`);
    }
    if (rsp.code === 304) {
      this.isOnline = true;
      return;
    }
    if (rsp.code === 401) {
      this.isOnline = false;
      await this.clearSession();
      throw new Error('登录已过期，请重新登录');
    }
    if (rsp.code !== 200) {
      this.isOnline = false;
      await this.restoreCache();
      throw new Error('服务器暂不可用（HTTP ' + rsp.code + '）');
    }
    // 缓存写的是服务器响应的原始字节（含公用标签与机器 token，所以绝不打印）
    this.writeCache(rsp.body);
    const snap: ServerSnapshot = JSON.parse(rsp.body) as ServerSnapshot;
    await this.apply(snap);
    this.isOnline = true;
  }

  /**
   * 采纳服务器快照。服务器数组顺序权威：machines/workDirs/tabs 整份替换。
   * `shared:true` 的标签只进 sharedTabs（只读影子），不落盘、不回传。
   */
  private async apply(snap: ServerSnapshot): Promise<void> {
    this.applying = true;
    try {
      // 机器：字段名与 Machine 一致，直接整份采纳
      this.store.machines = snap.machines !== undefined ? snap.machines : [];

      const rawTabs: ServerTabRaw[] = (snap.tabs !== undefined && snap.tabs.tabs !== undefined)
        ? snap.tabs.tabs : [];
      const closedIds: string[] = (snap.tabs !== undefined && snap.tabs.closedIds !== undefined)
        ? snap.tabs.closedIds : [];
      const personal: TabModel[] = [];
      const display: TabModel[] = [];   // 公用标签在前（服务器顺序）——标签坞铺的就是它
      const shared: SharedTab[] = [];
      const dirs: WorkDir[] = [];
      const dirSeen: Set<string> = new Set();
      for (let i = 0; i < rawTabs.length; i++) {
        const t: ServerTabRaw = rawTabs[i];
        const abs: string = t.workDir !== undefined ? t.workDir : '';
        // 快照里没有 workDirs：工作目录用 tab 自带的绝对路径合成，
        // id 就用路径本身（同一路径的多个 tab 共用一个 WorkDir）。
        let wdId: string = '';
        if (abs.length > 0) {
          wdId = abs;
          if (!dirSeen.has(abs)) {
            dirSeen.add(abs);
            dirs.push({ id: abs, name: ServerConfig.baseName(abs), path: abs } as WorkDir);
          }
        }
        const model: TabModel = {
          id: t.id,
          machineId: t.machineId !== undefined ? t.machineId : '',
          workDirId: wdId,
          tmuxSession: t.tmuxSession !== undefined ? t.tmuxSession : '',
          useTmux: true,
        } as TabModel;
        if (t.shared === true) {
          // 全局公用标签：服务器注入的只读影子（不回传、不落当成个人标签）。
          // iOS #49 口径：标签坞铺的就是服务端这些公用标签（自有标签已退场），
          // 所以它既要进 sharedTabs，也要进 store.tabs 让 UI 真的能渲染。
          if (t.machineId !== undefined && t.tmuxSession !== undefined) {
            shared.push({ id: t.id, machineId: t.machineId, tmuxSession: t.tmuxSession, workDir: abs } as SharedTab);
            display.push(model);
          }
          continue;
        }
        personal.push(model);
      }
      this.sharedTabs = shared;
      const sharedKeys: string[] = [];
      for (let i = 0; i < shared.length; i++) {
        sharedKeys.push(shared[i].id);
      }
      this.store.sharedIds = sharedKeys;
      this.store.workDirs = dirs;
      this.store.tabs = display.concat(personal);
      // 公用标签不进个人墓碑（本地关一次不能把它记成「已关」回传）
      const closedFiltered: string[] = [];
      for (let i = 0; i < closedIds.length; i++) {
        let isShared: boolean = false;
        for (let k = 0; k < shared.length; k++) {
          if (shared[k].id === closedIds[i]) { isShared = true; break; }
        }
        if (!isShared) { closedFiltered.push(closedIds[i]); }
      }
      this.store.closedIds = closedFiltered;

      // selection.machineId → 机器筛选；键不在就保持原样（对齐 iOS 只在有值时覆盖）
      const sel: Record<string, string> | undefined = snap.recentSelection;
      if (sel !== undefined) {
        const mid: string | undefined = sel['machineId'];
        if (mid !== undefined) {
          this.store.filterMachineId = mid;
        }
        // restSessions = 在岗的 tmuxSession 集合（逗号拼接）。**键不在就不物化**，
        // 保持「默认只有 tom 在岗」的规则；键在了才以服务器为准。
        // 集合按 **tmuxSession** 记并套在**公用标签**上（iOS SharedRestStore 口径）。
        // 旧写法只把 personal 标休息 → 公用标签永远不休息 → 坞里全铺，与 iOS 不一致。
        const joined: string | undefined = sel['restSessions'];
        if (joined !== undefined) {
          const active: string[] = [];
          const parts: string[] = joined.split(',');
          for (let i = 0; i < parts.length; i++) {
            const p: string = parts[i].trim();
            if (p.length > 0) {
              active.push(p);
            }
          }
          this.store.restActive = active;
          this.store.restLoaded = true;
        }
      }
      if (snap.agents !== undefined) {
        this.store.agents = snap.agents;
      }
      // 书签（浏览器「后台」）：快照带 pinned 就是权威 —— 按 position 排序后整份替换本地，
      // 保留 authUser/authPassword，随即落盘（同 iOS ServerPinnedStore）。书签条本身是
      // 全局共享数据（不进 user_configs），所以这里不需要回传。
      // 快照里没有 pinned 键就保持本地不动（老快照 / 离线缓存）。
      if (snap.pinned !== undefined) {
        const rawPins: ServerPinnedRaw[] = snap.pinned.slice();
        rawPins.sort((a: ServerPinnedRaw, b: ServerPinnedRaw): number => {
          const pa: number = a.position !== undefined ? a.position : 0;
          const pb: number = b.position !== undefined ? b.position : 0;
          return pa - pb;
        });
        const pins: PinnedTab[] = [];
        for (let i = 0; i < rawPins.length; i++) {
          const p: ServerPinnedRaw = rawPins[i];
          const item: PinnedTab = {
            title: p.title !== undefined ? p.title : '',
            url: p.url !== undefined ? p.url : '',
          } as PinnedTab;
          if (p.authUser !== undefined) {
            item.authUser = p.authUser;
          }
          if (p.authPassword !== undefined) {
            item.authPassword = p.authPassword;
          }
          pins.push(item);
        }
        this.store.pinned = pins;
        this.store.savePinned();
      }
      // 当前 tab：服务器快照里没有这个概念，保住本机的（仍在列表里就留着）
      const visible: TabModel[] = this.store.visibleTabs();
      if (visible.findIndex((t: TabModel) => t.id === this.store.currentTabId) < 0) {
        this.store.currentTabId = visible.length > 0 ? visible[0].id : '';
      }
      this.version = snap.version;
      this.dirty = false;   // 服务器版本已采纳：本地未上传的改动放弃（绝不被回传覆盖服务器）
      if (snap.user !== undefined) {
        this.username = snap.user.username;
        this.canWrite = snap.user.isAdmin && snap.user.canWrite;
      }
      await this.store.persistAll();
      await this.persistMeta();
    } finally {
      this.applying = false;
    }
    if (this.onApplied !== null) {
      this.onApplied();
    }
  }

  /** 离线/网络抖动兜底：把上次缓存快照填回界面，清空不了就继续展示。 */
  async restoreCache(): Promise<void> {
    const snap: ServerSnapshot | null = this.readCache();
    if (snap === null) {
      return;
    }
    if (snap.user !== undefined && this.username.length > 0 && snap.user.username !== this.username) {
      return;   // 缓存属于别的账号，不动
    }
    await this.apply(snap);
  }

  // ---- 上传（个人状态）----

  /**
   * 本地个人状态变了（选中的机器/当前 tab/agents/休息名单）：0.8s 合并后上传。
   * 采纳服务器快照期间的落盘不算本地改动。
   */
  markDirty(): void {
    if (this.applying) {
      return;
    }
    this.dirty = true;
    this.persistMeta();
    this.scheduleUpload();
  }

  /** 用户在本机动了休息开关：从此 restSessions 已物化，可以随 selection 上传。 */
  markRestLoaded(): void {
    if (this.store.restLoaded) {
      return;
    }
    this.store.restLoaded = true;
    this.store.saveResting();
  }

  private scheduleUpload(): void {
    if (this.token.length === 0 || !this.isOnline || !this.dirty) {
      return;
    }
    if (this.uploadTimer >= 0) {
      clearTimeout(this.uploadTimer);
    }
    this.uploadTimer = setTimeout(() => {
      this.uploadTimer = -1;
      this.uploadPersonal();
    }, 800);
  }

  /**
   * 上传个人状态。上传前先 syncFromServer() 对齐版本：只有服务器版本没动（304）才继续
   * PUT —— 服务器版本已前进时 apply() 会清掉 dirty，这里直接退出，本地旧快照永远不回传
   * 覆盖服务器。PUT 成功后回拉一次对齐 version（服务器 version 已被这轮 PUT 推进，
   * 不拉回来下一轮同步会误判「服务器前进」），竞态消除。
   */
  private async uploadPersonal(): Promise<void> {
    if (this.token.length === 0 || !this.isOnline || !this.dirty || this.uploading) {
      return;
    }
    this.uploading = true;
    try {
      await this.syncFromServer(false);   // 版本已前进 → apply() 清 dirty，下面直接退出
    } catch (e) {
      this.uploading = false;
      return;
    }
    if (!this.dirty) {
      this.uploading = false;
      return;
    }
    this.dirty = false;
    this.persistMeta();

    // tabs：只传个人标签（公用标签是服务器的，不回传）；workDirId 就是绝对路径
    const putTabs: PutTab[] = [];
    for (let i = 0; i < this.store.tabs.length; i++) {
      const t: TabModel = this.store.tabs[i];
      // 公用标签是服务器的只读影子：**绝不回传**（否则管理员维护的那份会被客户端覆盖）
      let isSharedTab: boolean = false;
      for (let k = 0; k < this.sharedTabs.length; k++) {
        if (this.sharedTabs[k].id === t.id) { isSharedTab = true; break; }
      }
      if (isSharedTab) {
        continue;
      }
      const wd: WorkDir | null = this.store.workDirById(t.workDirId);
      putTabs.push({
        id: t.id,
        machineId: t.machineId,
        tmuxSession: t.tmuxSession,
        workDir: wd !== null ? wd.path : undefined,
      } as PutTab);
    }
    this.tabVersion = this.tabVersion + 1;
    const tabsBody: PutTabsBody = {
      version: this.tabVersion,
      tabs: putTabs,
      closedIds: this.store.closedIds,
    };

    // selection：当前 tab；restSessions 只在已物化时带上。
    // **不上传 machineId**：本机机器筛选不再影响坞（见 BlinkStore.visibleTabs），传上去只会
    // 让别的客户端跟着收窄。iOS 手机上也不拿 selection 回读的 machineId 收窄坞
    // （SpaceController.swift:715 `let machineId = _macRail != nil ? _tabFilterMachineId : nil`）。
    const selection: Record<string, string> = {};
    selection['tabId'] = this.store.currentTabId;
    if (this.store.restLoaded) {
      selection['restSessions'] = this.joinedActive();
    }

    const bodies: string[] = [
      JSON.stringify(tabsBody),
      JSON.stringify(selection),
      JSON.stringify(this.store.agents),
    ];
    const paths: string[] = ['tabs', 'selection', 'agents'];
    for (let i = 0; i < paths.length; i++) {
      let rsp: HttpResult;
      try {
        rsp = await this.send('PUT', '/v1/config/' + paths[i], bodies[i], this.token);
      } catch (e) {
        this.dirty = true;
        this.isOnline = false;
        this.persistMeta();
        this.uploading = false;
        return;
      }
      if (rsp.code !== 204) {
        this.dirty = true;
        this.isOnline = false;
        this.persistMeta();
        this.uploading = false;
        return;
      }
    }
    try {
      await this.syncFromServer(false);   // 回拉一次：appliedVersion 跟上刚 PUT 出的版本
    } catch (e) {
    }
    this.uploading = false;
    this.scheduleUpload();
  }

  /** 在岗的 tmuxSession 集合（逗号拼接）。稳定排序，diff 友好（iOS joinedActive 同）。 */
  private joinedActive(): string {
    return this.store.restActive.slice().sort().join(',');
  }

  // ---- 轮询 ----

  /** 回前台（页面自己再调一次 refresh）+ 15s 定时刷新；版本未变是 304。 */
  startPolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => {
      if (this.token.length === 0 || this.uploading || this.dirty) {
        return;   // 本地有未上传改动 / 正在传：这一轮跳过，别和上传互相踩
      }
      this.refresh();
    }, POLL_MS);
  }

  stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.uploadTimer >= 0) {
      clearTimeout(this.uploadTimer);
      this.uploadTimer = -1;
    }
  }

  // ---- 持久化 ----

  /** 账号名/canWrite/版本/dirty/tabsVersion（全是非机密），token 绝不进这里。 */
  private async persistMeta(): Promise<void> {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    await p.put('username', this.username);
    await p.put('canWrite', this.canWrite);
    await p.put('appliedVersion', this.version);
    await p.put('dirty', this.dirty);
    await p.put('tabsVersion', this.tabVersion);
    await p.flush();
  }

  private async clearSession(): Promise<void> {
    this.token = '';
    this.username = '';
    this.sharedTabs = [];
    this.version = '';
    this.dirty = false;
    await this.removeToken();
    const p = this.prefs;
    if (p !== null) {
      await p.put('username', '');
      await p.put('appliedVersion', '');
      await p.put('dirty', false);
      await p.flush();
    }
  }

  // ---- 安全存储（token）----

  /** 读 token；不存在/读失败都返回 ''（调用方据 '' 当未登录，绝不把空 token 拼进请求头）。 */
  private async readToken(): Promise<string> {
    try {
      const q: asset.AssetMap = new Map();
      q.set(asset.Tag.ALIAS, this.aliasBytes());
      q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const rows: Array<asset.AssetMap> = await asset.query(q);
      if (rows.length === 0) {
        return '';
      }
      const sec: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
      if (sec instanceof Uint8Array) {
        return util.TextDecoder.create('utf-8').decodeToString(sec);
      }
      return '';
    } catch (e) {
      // 读不到当未登录，不打印任何内容（可能是机密）
      return '';
    }
  }

  private async saveToken(value: string): Promise<void> {
    await this.removeToken();
    const m: asset.AssetMap = new Map();
    m.set(asset.Tag.ALIAS, this.aliasBytes());
    m.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(value));
    // 首次解锁后可读：开机自动进主界面不要求用户再解一次锁
    m.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(m);
    } catch (e) {
      throw new Error('无法保存登录状态');
    }
  }

  private async removeToken(): Promise<void> {
    const q: asset.AssetMap = new Map();
    q.set(asset.Tag.ALIAS, this.aliasBytes());
    try {
      await asset.remove(q);
    } catch (e) {
    }
  }

  private aliasBytes(): Uint8Array {
    return new util.TextEncoder().encodeInto(TOKEN_ALIAS);
  }

  // ---- 离线缓存（filesDir 下的受保护文件；含机器 token，绝不打印）----

  private cachePath(): string {
    return this.ctx.filesDir + '/blink_server_config.json';
  }

  private writeCache(raw: string): void {
    try {
      const f = fs.openSync(this.cachePath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, raw);
      fs.closeSync(f);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cache write failed');
    }
  }

  private readCache(): ServerSnapshot | null {
    try {
      const raw: string = fs.readTextSync(this.cachePath());
      if (raw.length === 0) {
        return null;
      }
      return JSON.parse(raw) as ServerSnapshot;
    } catch (e) {
      return null;
    }
  }

  private removeCache(): void {
    try {
      fs.unlinkSync(this.cachePath());
    } catch (e) {
    }
  }

  // ---- HTTP（写法照 ProtoCatalog.get）----

  private send(method: string, path: string, body: string, token: string): Promise<HttpResult> {
    const header: Record<string, string> = {};
    header['Content-Type'] = 'application/json';
    if (token.length > 0) {
      // token 为空时绝不发请求：拼成 "Bearer " 只会被服务器 401，用户侧表现成登录过期
      header['Authorization'] = 'Bearer ' + token;
    }
    const m: http.RequestMethod = method === 'PUT' ? http.RequestMethod.PUT
      : (method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET);
    const options: http.HttpRequestOptions = {
      method: m,
      header: header,
      connectTimeout: 10000,
      readTimeout: 20000,
      expectDataType: http.HttpDataType.STRING,
    };
    if (body.length > 0) {
      options.extraData = body;
    }
    const req = http.createHttp();
    return req.request(BASE + path, options).then((rsp: http.HttpResponse): HttpResult => {
      req.destroy();
      const text: string = typeof rsp.result === 'string' ? rsp.result as string : '';
      return { code: rsp.responseCode, body: text } as HttpResult;
    }).catch((e: Object): HttpResult => {
      req.destroy();
      throw new Error(`网络错误：${JSON.stringify(e)}`);
    });
  }

  /** 路径最后一段作为工作目录显示名（快照只给绝对路径，没有名字）。 */
  private static baseName(path: string): string {
    let p: string = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    const i: number = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }
}
