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

// DeepSeek 的 Anthropic 兼容端点与模型（/models 实测可用的两个 id）

const BLINK_CLAUDE_STATUS_B64: string = 'aW1wb3J0IGpzb24sIG9zLCBzdWJwcm9jZXNzLCBzeXMKdHJ5OgogICAgZCA9IGpzb24ubG9hZChzeXMuc3RkaW4pCmV4Y2VwdCBFeGNlcHRpb246CiAgICBkID0ge30KZGVmIGdldCgqcGF0aCk6CiAgICB2ID0gZAogICAgZm9yIGtleSBpbiBwYXRoOgogICAgICAgIHYgPSB2LmdldChrZXksIHt9KSBpZiBpc2luc3RhbmNlKHYsIGRpY3QpIGVsc2Uge30KICAgIHJldHVybiB2CmRlZiBwY3Qodik6CiAgICB0cnk6IHJldHVybiBtYXgoMCwgbWluKDEwMCwgcm91bmQoZmxvYXQodikpKSkKICAgIGV4Y2VwdCBFeGNlcHRpb246IHJldHVybiBOb25lCmRlZiBtZXRlcihsYWJlbCwgdmFsdWUpOgogICAgbiA9IHBjdCh2YWx1ZSkKICAgIGlmIG4gaXMgTm9uZTogcmV0dXJuIGYie2xhYmVsfSAtLSIKICAgIGJsb2NrcyA9IHJvdW5kKG4gKiA3IC8gMTAwKQogICAgcmV0dXJuIGYie2xhYmVsfSB7J+KWsCcqYmxvY2tzfXsn4paxJyooNy1ibG9ja3MpfSB7bn0lIgptb2RlbCA9IGdldCgnbW9kZWwnLCAnZGlzcGxheV9uYW1lJykgb3IgJ0NsYXVkZScKY3dkID0gZ2V0KCd3b3Jrc3BhY2UnLCAnY3VycmVudF9kaXInKSBvciBvcy5nZXRjd2QoKQp0cnk6IGJyYW5jaCA9IHN1YnByb2Nlc3MuY2hlY2tfb3V0cHV0KFsnZ2l0JywgJy1DJywgY3dkLCAnYnJhbmNoJywgJy0tc2hvdy1jdXJyZW50J10sIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsIHRleHQ9VHJ1ZSwgdGltZW91dD0xKS5zdHJpcCgpCmV4Y2VwdCBFeGNlcHRpb246IGJyYW5jaCA9ICcnCnByaW50KGYi8J+RviB7b3MudW5hbWUoKS5ub2RlbmFtZS5zcGxpdCgnLicpWzBdfTp7b3MucGF0aC5iYXNlbmFtZShjd2QpfSAgIPCfp6Age21vZGVsfSIgKyAoZiIgICDwn4y/IHticmFuY2h9IiBpZiBicmFuY2ggZWxzZSAnJykpCnByaW50KCcgICAnLmpvaW4oW21ldGVyKCdDVFgnLCBnZXQoJ2NvbnRleHRfd2luZG93JywgJ3VzZWRfcGVyY2VudGFnZScpKSwgbWV0ZXIoJzVIJywgZ2V0KCdyYXRlX2xpbWl0cycsICdmaXZlX2hvdXInLCAndXNlZF9wZXJjZW50YWdlJykpLCBtZXRlcignN0QnLCBnZXQoJ3JhdGVfbGltaXRzJywgJ3NldmVuX2RheScsICd1c2VkX3BlcmNlbnRhZ2UnKSldKSk=';
const BLINK_CODEWHALE_STATUS_B64: string = 'aW1wb3J0IG9zLCBwYXRobGliLCByZQpob21lID0gcGF0aGxpYi5QYXRoLmhvbWUoKQpzb3VyY2UgPSBwYXRobGliLlBhdGgob3MuZW52aXJvbi5nZXQoJ0NPREVXSEFMRV9DT05GSUdfUEFUSCcpIG9yIG9zLmVudmlyb24uZ2V0KCdERUVQU0VFS19DT05GSUdfUEFUSCcpIG9yIHN0cihob21lIC8gJy5jb2Rld2hhbGUvY29uZmlnLnRvbWwnKSkKaWYgbm90IHNvdXJjZS5leGlzdHMoKTogc291cmNlID0gaG9tZSAvICcuZGVlcHNlZWsvY29uZmlnLnRvbWwnCnRleHQgPSBzb3VyY2UucmVhZF90ZXh0KCkgaWYgc291cmNlLmV4aXN0cygpIGVsc2UgJycKaXRlbXMgPSAnc3RhdHVzX2l0ZW1zID0gWyJtb2RlbCIsICJ0b2tlbnMiLCAiY29zdCJdJwptZXRyaWNzID0gJ21ldHJpY3NfbGluZSA9ICJmdWxsIicKbWF0Y2ggPSByZS5zZWFyY2gocicoP20pXlxbdHVpXF1bIFx0XSooPzojLiopPyQnLCB0ZXh0KQppZiBtYXRjaDoKICAgIGVuZF9tYXRjaCA9IHJlLnNlYXJjaChyJyg/bSleXFsnLCB0ZXh0W21hdGNoLmVuZCgpOl0pCiAgICBlbmQgPSBtYXRjaC5lbmQoKSArIGVuZF9tYXRjaC5zdGFydCgpIGlmIGVuZF9tYXRjaCBlbHNlIGxlbih0ZXh0KQogICAgYm9keSA9IHRleHRbbWF0Y2guZW5kKCk6ZW5kXQogICAgZm9yIGtleSwgbGluZSBpbiBbKCdzdGF0dXNfaXRlbXMnLCBpdGVtcyksICgnbWV0cmljc19saW5lJywgbWV0cmljcyldOgogICAgICAgIHBhdHRlcm4gPSByJyg/bSleWyBcdF0qJyArIGtleSArIHInWyBcdF0qPVsgXHRdKig/OlxbW15cXV0qXF18W15cbl0qKScKICAgICAgICBib2R5LCBjb3VudCA9IHJlLnN1Ym4ocGF0dGVybiwgbGluZSwgYm9keSwgY291bnQ9MSkKICAgICAgICBpZiBub3QgY291bnQ6IGJvZHkgKz0gJ1xuJyArIGxpbmUgKyAnXG4nCiAgICB0ZXh0ID0gdGV4dFs6bWF0Y2guZW5kKCldICsgYm9keSArIHRleHRbZW5kOl0KZWxzZToKICAgIHRleHQgKz0gJ1xuW3R1aV1cbicgKyBpdGVtcyArICdcbicgKyBtZXRyaWNzICsgJ1xuJwp0YXJnZXQgPSBob21lIC8gJy5ibGluay9jb2Rld2hhbGUtc3RhdHVzLnRvbWwnCnRhcmdldC5wYXJlbnQubWtkaXIobW9kZT0wbzcwMCwgZXhpc3Rfb2s9VHJ1ZSkKZmQgPSBvcy5vcGVuKHRhcmdldCwgb3MuT19XUk9OTFkgfCBvcy5PX0NSRUFUIHwgb3MuT19UUlVOQywgMG82MDApCndpdGggb3MuZmRvcGVuKGZkLCAndycpIGFzIG91dDogb3V0LndyaXRlKHRleHQp';

const BLINK_CODEX_RESUME_B64: string = 'aW1wb3J0IGpzb24sIG9zLCBwYXRobGliLCBzeXMsIHV1aWQKaWYgbGVuKHN5cy5hcmd2KSAhPSAzOiBzeXMuZXhpdCgwKQpuYW1lLCBjd2QgPSBzeXMuYXJndlsxOl0KY3dkID0gb3MucGF0aC5yZWFscGF0aChjd2QpCnJvb3QgPSBwYXRobGliLlBhdGgob3MuZW52aXJvbi5nZXQoJ0NPREVYX0hPTUUnKSBvciBwYXRobGliLlBhdGguaG9tZSgpIC8gJy5jb2RleCcpCm1hdGNoZXMgPSB7fQpmb3IgZmlsZSBpbiAocm9vdCAvICdzZXNzaW9ucycpLmdsb2IoJyovKi8qL3JvbGxvdXQtKi5qc29ubCcpOgogICAgdHJ5OgogICAgICAgIHdpdGggZmlsZS5vcGVuKCkgYXMgc3RyZWFtOiBtZXRhID0ganNvbi5sb2FkcyhzdHJlYW0ucmVhZGxpbmUoKSkKICAgICAgICBwYXlsb2FkID0gbWV0YS5nZXQoJ3BheWxvYWQnKSBvciB7fQogICAgICAgIHNpZCA9IHN0cih1dWlkLlVVSUQocGF5bG9hZFsnaWQnXSkpCiAgICAgICAgaWYgbWV0YS5nZXQoJ3R5cGUnKSA9PSAnc2Vzc2lvbl9tZXRhJyBhbmQgb3MucGF0aC5yZWFscGF0aChwYXlsb2FkWydjd2QnXSkgPT0gY3dkOgogICAgICAgICAgICBtYXRjaGVzW3NpZF0gPSBmaWxlCiAgICBleGNlcHQgKE9TRXJyb3IsIEtleUVycm9yLCBWYWx1ZUVycm9yLCBUeXBlRXJyb3IpOiBwYXNzCmluZGV4ID0gcm9vdCAvICdzZXNzaW9uX2luZGV4Lmpzb25sJwpuYW1lZCA9IFtdCmlmIGluZGV4LmV4aXN0cygpOgogICAgdHJ5OgogICAgICAgIHdpdGggaW5kZXgub3BlbigpIGFzIHN0cmVhbTogbGluZXMgPSBzdHJlYW0ucmVhZGxpbmVzKCkKICAgICAgICBzZWVuID0gc2V0KCkKICAgICAgICBmb3IgbGluZSBpbiByZXZlcnNlZChsaW5lcyk6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIGl0ZW0gPSBqc29uLmxvYWRzKGxpbmUpCiAgICAgICAgICAgICAgICBzaWQgPSBzdHIodXVpZC5VVUlEKGl0ZW1bJ2lkJ10pKQogICAgICAgICAgICAgICAgaWYgc2lkIGluIHNlZW46IGNvbnRpbnVlCiAgICAgICAgICAgICAgICBzZWVuLmFkZChzaWQpCiAgICAgICAgICAgICAgICBpZiBpdGVtLmdldCgndGhyZWFkX25hbWUnKSA9PSBuYW1lOiBuYW1lZC5hcHBlbmQoc2lkKQogICAgICAgICAgICBleGNlcHQgKEtleUVycm9yLCBWYWx1ZUVycm9yLCBUeXBlRXJyb3IpOiBwYXNzCiAgICBleGNlcHQgT1NFcnJvcjogcGFzcwpzYW1lX2RpciA9IFtzaWQgZm9yIHNpZCBpbiBuYW1lZCBpZiBzaWQgaW4gbWF0Y2hlc10KaWYgc2FtZV9kaXI6CiAgICAjIOWQjeWtl+WFqOWxgOWUr+S4gOaXtuebtOaOpeaMieWQjeWtl+aBouWkje+8m+mHjeWQjeaXtueUqCBJRCDplIHlrprlvZPliY3nm67lvZXjgIIKICAgIHByaW50KCdOOicgKyBuYW1lIGlmIGxlbihuYW1lZCkgPT0gMSBlbHNlICdJOicgKyBzYW1lX2RpclswXSkKICAgIHN5cy5leGl0KDApCiMg5Y+q6K+75pen54mI5pig5bCE5Lul6L+B56e75bey57uR5a6a55qE5Lya6K+d77yb5paw54mI5pys5LiN5YaN5YaZ5pig5bCE5paH5Lu244CCCnRyeToKICAgIHdpdGggKHBhdGhsaWIuUGF0aC5ob21lKCkgLyAnLmJsaW5rL2NvZGV4LXNlc3Npb25zLmpzb24nKS5vcGVuKCkgYXMgc3RyZWFtOiBtYXBwaW5nID0ganNvbi5sb2FkKHN0cmVhbSkKICAgIGlmIG5vdCBpc2luc3RhbmNlKG1hcHBpbmcsIGRpY3QpOiBtYXBwaW5nID0ge30KZXhjZXB0IChPU0Vycm9yLCBWYWx1ZUVycm9yKTogbWFwcGluZyA9IHt9CnJlY29yZCA9IG1hcHBpbmcuZ2V0KG5hbWUpIG9yIHt9CmlmIGlzaW5zdGFuY2UocmVjb3JkLCBkaWN0KSBhbmQgcmVjb3JkLmdldCgnY3dkJykgPT0gY3dkIGFuZCByZWNvcmQuZ2V0KCdpZCcpIGluIG1hdGNoZXM6CiAgICBwcmludCgnSTonICsgcmVjb3JkWydpZCddKQogICAgc3lzLmV4aXQoMCkKcmVzZXJ2ZWQgPSB7ZW50cnkuZ2V0KCdpZCcpIGZvciB0aXRsZSwgZW50cnkgaW4gbWFwcGluZy5pdGVtcygpCiAgICAgICAgICAgIGlmIHRpdGxlICE9IG5hbWUgYW5kIGlzaW5zdGFuY2UoZW50cnksIGRpY3QpIGFuZCBlbnRyeS5nZXQoJ2N3ZCcpID09IGN3ZH0KIyDml6fkvJror53ku4XlnKjlvZPliY3nm67lvZXllK/kuIDjgIHkuJTmnKrnu5Hlrprlhbbku5bmoIfnrb7ml7bmjqXlm57lubblkb3lkI3jgIIKaWYgbGVuKG1hdGNoZXMpID09IDE6CiAgICBzaWQgPSBuZXh0KGl0ZXIobWF0Y2hlcykpCiAgICBpZiBzaWQgbm90IGluIHJlc2VydmVkOiBwcmludCgnSTonICsgc2lkKQ==';

const BLINK_CODEWHALE_RESUME_B64: string = 'aW1wb3J0IGpzb24sIG9zLCBwYXRobGliLCBzeXMsIHV1aWQKaWYgbGVuKHN5cy5hcmd2KSAhPSAzOiBzeXMuZXhpdCgwKQpuYW1lLCBjd2QgPSBzeXMuYXJndlsxOl0KY3dkID0gb3MucGF0aC5yZWFscGF0aChjd2QpCmhvbWUgPSBwYXRobGliLlBhdGguaG9tZSgpCnNlc3Npb25zID0ge30KZm9yIHJvb3QgaW4gKGhvbWUgLyAnLmRlZXBzZWVrL3Nlc3Npb25zJywgaG9tZSAvICcuY29kZXdoYWxlL3Nlc3Npb25zJyk6CiAgICBmb3IgZmlsZSBpbiByb290Lmdsb2IoJyouanNvbicpOgogICAgICAgIHRyeToKICAgICAgICAgICAgc2lkID0gc3RyKHV1aWQuVVVJRChmaWxlLnN0ZW0pKQogICAgICAgICAgICB3aXRoIGZpbGUub3BlbigpIGFzIHN0cmVhbTogaGVhZCA9IHN0cmVhbS5yZWFkKDEzMTA3MikKICAgICAgICAgICAgc3RhcnQgPSBoZWFkLmluZGV4KCcibWV0YWRhdGEiJykgKyBsZW4oJyJtZXRhZGF0YSInKQogICAgICAgICAgICBzdGFydCA9IGhlYWQuaW5kZXgoJzonLCBzdGFydCkgKyAxCiAgICAgICAgICAgIG1ldGEsIF8gPSBqc29uLkpTT05EZWNvZGVyKCkucmF3X2RlY29kZShoZWFkW3N0YXJ0Ol0ubHN0cmlwKCkpCiAgICAgICAgICAgIGlmIHN0cih1dWlkLlVVSUQobWV0YVsnaWQnXSkpICE9IHNpZDogY29udGludWUKICAgICAgICAgICAgaWYgb3MucGF0aC5yZWFscGF0aChtZXRhWyd3b3Jrc3BhY2UnXSkgIT0gY3dkOiBjb250aW51ZQogICAgICAgICAgICBzZXNzaW9uc1tzaWRdID0gKG1ldGEuZ2V0KCd0aXRsZScpIG9yICcnLCBmaWxlLnN0YXQoKS5zdF9tdGltZSkKICAgICAgICBleGNlcHQgKE9TRXJyb3IsIEtleUVycm9yLCBWYWx1ZUVycm9yLCBUeXBlRXJyb3IpOiBwYXNzCm5hbWVkID0gWyhzaWQsIG10aW1lKSBmb3Igc2lkLCAodGl0bGUsIG10aW1lKSBpbiBzZXNzaW9ucy5pdGVtcygpIGlmIHRpdGxlID09IG5hbWVdCmlmIG5hbWVkOgogICAgcHJpbnQoJ046JyArIG1heChuYW1lZCwga2V5PWxhbWJkYSBpdGVtOiBpdGVtWzFdKVswXSkKZWxpZiBsZW4oc2Vzc2lvbnMpID09IDE6CiAgICAjIOWPquaOpeWbnuWwmuacquWRveWQjeeahOWUr+S4gOaXp+S8muivne+8jOmBv+WFjeWkmuS4qiBCbGluayDmoIfnrb7lhbHnlKjkuIDkuKrlt7Llkb3lkI3kvJror53jgIIKICAgIHNpZCA9IG5leHQoaXRlcihzZXNzaW9ucykpCiAgICBpZiBzZXNzaW9uc1tzaWRdWzBdIGluICgnJywgJ05ldyBTZXNzaW9uJyk6IHByaW50KCdJOicgKyBzaWQp';

const BLINK_DEEPSEEK_KEY_B64: string = 'c2stYmEwMjhmMmI2ZDNkNDI0MDg5ODQ4YjAyZmE0NThhOGM=';

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
  resting: string[] = [];              // resting tab ids (TabRestStore)
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

  /// 本地个人状态（选中的机器 / agents / 休息开关…）真的变了（save* 落盘时触发）。
  /// BlinkTerminal 挂上防抖上传，把个人状态 PUT 回服务器（ServerConfig.markDirty）。
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
    this.corrections = this.readJson<string[][]>('corrections', []);
    this.terms = this.readJson<Record<string, Record<string, number>>>('terms', {});
    this.resting = this.readJson<string[]>('resting', []);
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
    await p.put('resting', JSON.stringify(this.resting));
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
  saveResting(): void { this.putJson('resting', this.resting); }
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
    if (this.onRestChange !== null) {
      this.onRestChange();
    }
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

  // 三端统一约定（2026-10-05 服务器同步后明确，与 iOS ccTitle 一致）：
  // tab 带了 tmuxSession 就是权威会话名（服务器 tab / Mac blinkd 端都按 cc-<tmuxSession>
  // 命名），sanitize 后原样返回，不再拼目录/用户名前缀——曾经对带 tmuxSession 的 tab 也套
  // <basename>-<session>，workDirs 不随服务器快照下发时 basename 退化到 SSH 用户名，
  // 手机/平板连 brain 找 cc-app-tom-blink 而真会话是 cc-tom-blink，new-session -A 建空会话。
  // tmuxSession 为空（本地新建 tab）才走本地生成：<basename(workPath)>-<session>，
  // session 已是 basename 或 basename- 开头则不再 prepend。outer tmux session = "cc-<TITLE>"。
  static titleFor(workPath: string, session: string, fallbackUser: string): string {
    if (session.length > 0) {
      return session.toLowerCase().replace(/"/g, '').replace(/ /g, '-');
    }
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
  // Codex 通过 ~/.blink/codex-resume.py 查找同名会话，再由 Codex 按名称恢复；
  // DeepSeek 由外层 tmux session 名 cc-<TITLE> 保持标签身份。
  static agentLabel(agent: string): string {
    if (agent === 'codex') {
      return 'Codex';
    }
    if (agent === 'deepseek') {
      return 'DeepSeek';
    }
    if (agent === 'glm') {
      return 'GLM (Claude Code)';
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
    if (agent === 'glm') {
      return '#29A982';
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
      return ' -c "tui.status_line=[\\"model\\",\\"context-used\\",\\"five-hour-limit\\",\\"weekly-limit\\"]" --dangerously-bypass-approvals-and-sandbox';
    }
    if (agent === 'deepseek') {
      return ' --provider deepseek --model deepseek-flash --sandbox-mode danger-full-access';
    }
    if (agent === 'claude') {
      return ' --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions';
    }
    if (agent === 'glm') {
      return ' --settings ~/.blink/statusline-settings.json --dangerously-skip-permissions';
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
  // 优先使用新版 Codewhale；旧 deepseek 命令仅作兼容回退。
  static agentBins(agent: string): string[] {
    if (agent === 'codex') {
      return ['codex'];
    }
    if (agent === 'deepseek') {
      return ['codewhale', 'deepseek'];
    }
    return ['claude'];
  }

  // 没装时自动装的命令；空串 = 不自动装
  static agentInstall(agent: string): string {
    if (agent === 'codex') {
      return 'if command -v npm >/dev/null 2>&1; then npm i -g --prefix "$HOME/.local" @openai/codex; ' +
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
      return '手动装：npm i -g --prefix "$HOME/.local" @openai/codex';
    }
    if (agent === 'deepseek') {
      return '手动装：curl -fsSL https://codewhale.net/install.sh | sh';
    }
    return '装一下 claude code';
  }

  // 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
  // 外层是 `$SHELL -lic '...'`，里面只能用双引号——别引入单引号。
  static agentLaunch(agent: string, cdTarget: string, title: string): string {
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
      let cmd: string;
      if (agent === 'codex') {
        cmd = 'TITLE="' + title + '"; MATCH=""; if command -v python3 >/dev/null 2>&1; then MATCH=$(python3 "$HOME/.blink/codex-resume.py" "$TITLE" "$PWD" 2>/dev/null); fi; ' +
          '_cxren() { T="$1"; P="$2"; i=0; while [ $i -lt 60 ]; do sleep 0.5; C=$(tmux capture-pane -p -t "$P" 2>/dev/null); case "$C" in *"Ask Codex to do anything"*|*"Got something you want to try?"*|*"? for shortcuts"*) tmux send-keys -t "$P" "/rename $T" Enter; return 0;; esac; i=$((i+1)); done; }; ' +
          'case "$MATCH" in N:*) codex' + BlinkStore.agentArgs(agent) + ' resume "$TITLE";; I:*) if [ -n "$TMUX_PANE" ]; then ( _cxren "$TITLE" "$TMUX_PANE" >/dev/null 2>&1 & ); fi; codex' + BlinkStore.agentArgs(agent) + ' resume "${MATCH#I:}";; *) if [ -n "$TMUX_PANE" ]; then ( _cxren "$TITLE" "$TMUX_PANE" >/dev/null 2>&1 & ); fi; codex' + BlinkStore.agentArgs(agent) + ';; esac';
      } else if (agent === 'deepseek') {
        cmd = 'TITLE="' + title + '"; MATCH=""; if command -v python3 >/dev/null 2>&1; then MATCH=$(python3 "$HOME/.blink/codewhale-resume.py" "$TITLE" "$PWD" 2>/dev/null); fi; ' +
          '_cwren() { T="$1"; P="$2"; i=0; while [ $i -lt 60 ]; do sleep 0.5; C=$(tmux capture-pane -p -t "$P" 2>/dev/null); case "$C" in *"Full Access"*) break;; esac; i=$((i+1)); done; tmux send-keys -t "$P" "/rename $T" Enter; }; ' +
          'case "$MATCH" in N:*) ' + bins[i] + BlinkStore.agentArgs(agent) + ' resume "${MATCH#N:}";; I:*) if [ -n "$TMUX_PANE" ]; then ( _cwren "$TITLE" "$TMUX_PANE" >/dev/null 2>&1 & ); fi; ' + bins[i] + BlinkStore.agentArgs(agent) + ' resume "${MATCH#I:}";; *) if [ -n "$TMUX_PANE" ]; then ( _cwren "$TITLE" "$TMUX_PANE" >/dev/null 2>&1 & ); fi; ' + bins[i] + BlinkStore.agentArgs(agent) + ';; esac';
      } else if (agent === 'glm') {
        cmd = 'if [ "$BLINK_GLM_USE_USER_SETTINGS" = 1 ]; then claude' + BlinkStore.agentArgs(agent) + '; else claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions; fi';
      } else {
        cmd = bins[i] + BlinkStore.agentArgs(agent);
      }
      run += 'if command -v ' + bins[i] + ' >/dev/null 2>&1; then ' + cmd + '; el';
    }
    run += 'se echo "[blink] 没有 ' + bins.join('/') + '：' + BlinkStore.agentHint(agent) + '"; ';
    run += 'fi; ';   // elif 串起来的整条只收一个 fi
    // deepseekEnv 以 '&& ' 收尾，放 cd 前面：没配 key 时整条短路，不会往下把 TUI 起起来
    return BlinkStore.agentEnv(agent) + 'cd ' + cdTarget + ' && { ' + path + miss +
      BlinkStore.fullAccessNudge(agent) + run + '}';
  }

  // Codewhale 自己认 $DEEPSEEK_API_KEY（auth status 里 provider=deepseek、来源 env），
  // 所以只要确保这个变量在就行。
  // DeepSeek Key 由 App 内置并在启动 Codewhale 前注入远端进程环境。
  private static agentEnv(agent: string): string {
    const status: string = BlinkStore.statusEnv(agent);
    if (agent === 'codex') {
      return 'mkdir -p "$HOME/.blink"; printf %s "' + BLINK_CODEX_RESUME_B64 + '" | base64 -d > "$HOME/.blink/codex-resume.py"; ';
    }
    if (agent === 'claude') {
      return status + 'unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_REASONING_MODEL; ';
    }
    if (agent === 'glm') {
      return status + 'if [ -n "$ZHIPU_API_KEY" ]; then ' +
        'export ANTHROPIC_AUTH_TOKEN="$ZHIPU_API_KEY" ANTHROPIC_BASE_URL="https://open.bigmodel.cn/api/anthropic"; BLINK_GLM_USE_USER_SETTINGS=0; ' +
        'elif [ -n "$ZAI_API_KEY" ]; then ' +
        'export ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY" ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"; BLINK_GLM_USE_USER_SETTINGS=0; ' +
        'elif [ -f "$HOME/.claude/settings.json" ] && grep -Eq "open.bigmodel.cn|api.z.ai" "$HOME/.claude/settings.json" && grep -q "ANTHROPIC_AUTH_TOKEN" "$HOME/.claude/settings.json"; then ' +
        'BLINK_GLM_USE_USER_SETTINGS=1; unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_REASONING_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; ' +
        'else echo "[blink] 未找到 GLM Key：请在远端 ~/.zshrc 配置 ZHIPU_API_KEY 或 ZAI_API_KEY"; false; fi && ' +
        'if [ "$BLINK_GLM_USE_USER_SETTINGS" = 0 ]; then ' +
        'unset ANTHROPIC_API_KEY ANTHROPIC_MODEL ANTHROPIC_REASONING_MODEL; ' +
        'export ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash; fi && ';
    }
    if (agent !== 'deepseek') {
      return '';
    }
    return status + 'export DEEPSEEK_API_KEY="$(printf %s "' + BLINK_DEEPSEEK_KEY_B64 + '" | base64 -d)"; ';
  }

  private static statusEnv(agent: string): string {
    if (agent === 'claude' || agent === 'glm') {
      return 'mkdir -p "$HOME/.blink"; BLINK_STATUS_SETTINGS=""; ' +
        'if command -v jq >/dev/null 2>&1 && [ -f "$HOME/.claude/settings.json" ]; then ' +
        'BLINK_STATUS_SETTINGS=$(jq -c "select(.statusLine.type == \\"command\\") | {statusLine:.statusLine}" "$HOME/.claude/settings.json" 2>/dev/null); fi; ' +
        'if [ -z "$BLINK_STATUS_SETTINGS" ]; then ' +
        'printf %s "' + BLINK_CLAUDE_STATUS_B64 + '" | base64 -d > "$HOME/.blink/statusline.py"; ' +
        'BLINK_STATUS_SETTINGS="{\\"statusLine\\":{\\"type\\":\\"command\\",\\"command\\":\\"python3 ~/.blink/statusline.py\\"}}"; fi; ' +
        'printf %s "$BLINK_STATUS_SETTINGS" > "$HOME/.blink/statusline-settings.json"; chmod 600 "$HOME/.blink/statusline-settings.json"; ';
    }
    if (agent === 'deepseek') {
      return 'mkdir -p "$HOME/.blink"; printf %s "' + BLINK_CODEWHALE_RESUME_B64 + '" | base64 -d > "$HOME/.blink/codewhale-resume.py"; ' +
        'printf %s "' + BLINK_CODEWHALE_STATUS_B64 + '" | base64 -d > "$HOME/.blink/codewhale-status-config.py"; ' +
        'if command -v python3 >/dev/null 2>&1 && python3 "$HOME/.blink/codewhale-status-config.py"; then ' +
        'export CODEWHALE_CONFIG_PATH="$HOME/.blink/codewhale-status.toml" DEEPSEEK_CONFIG_PATH="$HOME/.blink/codewhale-status.toml"; fi; ';
    }
    return '';
  }

  private static innerScript(cdTarget: string, title: string, agent: string): string {
    // Claude 走 customTitle 恢复；Codex 和 Codewhale 在 agentLaunch 里按标签恢复。
    // DeepSeek 档不再用 claude 接 DeepSeek 后端：那样每轮都要把整段上下文重发，
    // 一天光缓存读就 5 亿 token，太费。
    if (agent !== 'claude') {
      return BlinkStore.agentLaunch(agent, cdTarget, title);
    }
    // 同名会话可能有好几个（/clear 过就会），resume 要挑最近修改的那个；以前 find | head -1 按目录顺序挑，会接回老对话（2026-09-22 adam-rc 接回了被 DeepSeek 审核拒掉的那段历史）
    return BlinkStore.agentEnv(agent) + 'cd ' + cdTarget + ' && { CUR=$(pwd | sed "s:[/.]:-:g"); PROJ="$HOME/.claude/projects/$CUR"; TITLE="' +
    title +
    '"; ID=""; if [ -d "$PROJ" ]; then M=$(find "$PROJ" -maxdepth 1 -name "*.jsonl" -type f -exec grep -lF "\\"customTitle\\":\\"$TITLE\\"" {} + 2>/dev/null | while IFS= read -r f; do echo "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) $f"; done | sort -rn | head -1 | cut -d" " -f2-); [ -n "$M" ] && ID=$(basename "$M" .jsonl); fi; if [ -n "$ID" ]; then claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions --resume "$ID"; else if [ -n "$TMUX" ]; then (sleep 1.5; tmux send-keys "/rename $TITLE" Enter) >/dev/null 2>&1 & claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions; else TN="cc-$TITLE"; (sleep 1.5; tmux send-keys -t "$TN" "/rename $TITLE" Enter) >/dev/null 2>&1 & tmux new-session -A -s "$TN" "$SHELL -ic \\"claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions\\""; fi; fi; }';
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
  execForTab(t: TabModel): string {
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
