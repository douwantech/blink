//////////////////////////////////////////////////////////////////////////////
//
// WatchAssistant — Blink 腕上助手（鸿蒙手表 wearable）。
// 新消息先用系统 TTS 出声播报（谁·卡在哪·要你拍板），念完进「看消息」屏
// （C 方案：问题占屏 + 底部麦克风/快捷 + 快捷抽屉），点快捷或说一句把决定派回标签。
// 本版为模拟数据；真机指令可后续经 blinkd 发到正在跑的 claude 标签。
//
//////////////////////////////////////////////////////////////////////////////

import { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0BD2;

// 配色（表屏 OLED 恒黑 + 语义三色）
const C_BG = '#05060A';
const C_SURF = '#12151C';
const C_LINE = '#262C38';
const C_INK = '#EEF1F6';
const C_INK2 = '#98A1B2';
const C_INK3 = '#5C6472';
const C_TEAL = '#4FD6C4';
const C_AMBER = '#F5B24A';
const C_GREEN = '#54D583';

class Msg {
  emp: string;
  proj: string;
  color: string;
  assist: string;
  head: string;
  body: string;
  speak: string;
  chips: string[];
  voice: string;
  urgent: boolean;

  constructor(emp: string, proj: string, color: string, assist: string,
              head: string, body: string, speak: string, chips: string[], voice: string, urgent: boolean) {
    this.emp = emp; this.proj = proj; this.color = color; this.assist = assist;
    this.head = head; this.body = body; this.speak = speak; this.chips = chips; this.voice = voice; this.urgent = urgent;
  }
}

function seed(): Msg[] {
  return [
    new Msg('jack', 'blink', C_AMBER, 'jack 卡在一个取舍，等你拍板',
      '【员工新面板】', '休息的行也能长按唤回吗？',
      'jack 在 blink 卡住了。他在做员工新面板的休息态排序，拿不准休息的行要不要也能长按唤回，想请你拍个板。',
      ['可以，加长按唤回', '先不加，保持简单'], '休息的行也能长按唤回，但加个二次确认，别误触', false),
    new Msg('tom', 'sonusmac', '#7FB2FF', 'tom 想提交，先问你一句',
      '【转录匹配】', '先跑测试还是直接提交？',
      'tom 在 sonusmac 想提交转录匹配的改动，不过还有两个测试没跑。他问你，是先跑测试再提，还是直接提。',
      ['先跑测试再提', '直接提，我来测'], '先把两个测试跑绿了再提，顺手补个用例', false),
    new Msg('candy', 'english', C_GREEN, 'candy 做完了，问你要不要加料',
      '【单词复习】', '要顺手加发音吗？',
      'candy 把英语单词复习的网页做好了，问你要不要顺手把发音也加上。',
      ['加发音', '这版先不加'], '加发音，用系统 TTS 就行，点单词就读', false),
    new Msg('bella', 'printer', '#FF8FA0', 'bella 遇到报错，等你定方向',
      '【固件烧录】', '报签名错误，要重启 tmux 吗？',
      'bella 那边有点急。固件烧录报了个签名错误，errSecInternalComponent，她问要不要重启 tmux 服务再试一次。',
      ['重启 tmux server', '先看日志'], '先别重启，把烧录前后的日志拉给我看一眼', true)
  ];
}

@Entry
@Component
struct WatchAssistant {
  @State screen: string = 'home';          // home | bc | read | listen | transcript | sent
  @State queue: Msg[] = seed();
  @State cur: Msg = seed()[0];
  @State timeStr: string = '';
  @State bcTag: string = '助手播报中';
  @State speaking: boolean = false;
  @State orbScale: number = 1;
  @State sheetOpen: boolean = false;
  @State sentInstruction: string = '';

  private tts: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private clock: number = -1;
  private pulse: number = -1;
  private reqNo: number = 0;
  private advToken: number = 0;
  private extraIdx: number = 0;

  aboutToAppear(): void {
    this.updateTime();
    this.clock = setInterval(() => { this.updateTime(); }, 1000);
    this.initTts();
    // 主盘停一下，助手把第一条推上来
    setTimeout(() => { this.deliverNext(); }, 2200);
  }

  aboutToDisappear(): void {
    if (this.clock >= 0) { clearInterval(this.clock); }
    if (this.pulse >= 0) { clearInterval(this.pulse); }
    if (this.tts !== undefined) { try { this.tts.shutdown(); } catch (e) { } }
  }

  // ---- 时间 ----
  private two(n: number): string { return (n < 10 ? '0' : '') + n; }
  private updateTime(): void {
    const d = new Date();
    this.timeStr = this.two(d.getHours()) + ':' + this.two(d.getMinutes());
  }

  // ---- TTS ----
  private initTts(): void {
    const params: textToSpeech.CreateEngineParams = { language: 'zh-CN', person: 0, online: 1 };
    textToSpeech.createEngine(params).then((engine: textToSpeech.TextToSpeechEngine) => {
      this.tts = engine;
      const self = this;
      const listener: textToSpeech.SpeakListener = {
        onStart(requestId: string, response: textToSpeech.StartResponse): void { },
        onComplete(requestId: string, response: textToSpeech.CompleteResponse): void { self.onSpeakDone(); },
        onStop(requestId: string, response: textToSpeech.StopResponse): void { },
        onError(requestId: string, errorCode: number, errorMessage: string): void {
          hilog.warn(DOMAIN, 'watch', 'tts err %{public}d %{public}s', errorCode, errorMessage);
          self.onSpeakDone();
        }
      };
      engine.setListener(listener);
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, 'watch', 'createEngine failed: %{public}s', JSON.stringify(e));
    });
  }

  private speak(text: string): void {
    if (this.tts === undefined) { return; }
    try { this.tts.stop(); } catch (e) { }
    this.reqNo++;
    const p: textToSpeech.SpeakParams = { requestId: 'req-' + this.reqNo };
    try { this.tts.speak(text, p); } catch (e) {
      hilog.warn(DOMAIN, 'watch', 'speak failed: %{public}s', JSON.stringify(e));
    }
  }
  private stopSpeak(): void { if (this.tts !== undefined) { try { this.tts.stop(); } catch (e) { } } }

  private onSpeakDone(): void {
    if (this.screen !== 'bc') { return; }
    this.setSpeaking(false);
    this.bcTag = '播报完了 · 看看？';
    const my = this.advToken;
    setTimeout(() => { if (my === this.advToken && this.screen === 'bc') { this.openReading(); } }, 1400);
  }

  private setSpeaking(on: boolean): void {
    this.speaking = on;
    if (on) {
      if (this.pulse < 0) {
        this.pulse = setInterval(() => {
          animateTo({ duration: 480, curve: Curve.EaseInOut }, () => { this.orbScale = this.orbScale > 1 ? 1 : 1.08; });
        }, 480);
      }
    } else {
      if (this.pulse >= 0) { clearInterval(this.pulse); this.pulse = -1; }
      animateTo({ duration: 240 }, () => { this.orbScale = 1; });
    }
  }

  // ---- 流程 ----
  private pendingText(): string {
    return this.queue.length > 0 ? (this.queue.length + ' 个标签在等你 ›') : '都处理完了 ✓';
  }

  private goHome(): void {
    this.advToken++; this.stopSpeak(); this.setSpeaking(false); this.sheetOpen = false;
    this.screen = 'home';
  }

  private broadcast(item: Msg): void {
    this.cur = item;
    this.bcTag = item.urgent ? '助手播报 · 有点急' : '助手播报中';
    this.screen = 'bc';
    this.advToken++;
    this.setSpeaking(true);
    this.speak(item.speak);
  }

  private deliverNext(): void {
    if (this.queue.length === 0) { this.goHome(); return; }
    this.broadcast(this.queue[0]);
  }

  private openReading(): void {
    this.advToken++; this.stopSpeak(); this.setSpeaking(false); this.sheetOpen = false;
    this.screen = 'read';
  }

  private startListen(): void {
    this.sheetOpen = false;
    this.screen = 'listen';
    setTimeout(() => { if (this.screen === 'listen') { this.screen = 'transcript'; } }, 1600);
  }

  private dispatch(instruction: string): void {
    this.sentInstruction = instruction;
    const idx = this.queue.indexOf(this.cur);
    if (idx >= 0) { this.queue.splice(idx, 1); }
    this.sheetOpen = false;
    this.screen = 'sent';
    setTimeout(() => {
      if (this.queue.length > 0) { this.broadcast(this.queue[0]); }
      else { this.goHome(); }
    }, 2100);
  }

  private simNewMessage(): void {
    const more: Msg[] = [
      new Msg('dave', 'lottie', '#C89BFF', 'dave 想确认一个改法',
        '【开屏动画】', '时长 2s 砍到 1.2s 行吗？',
        'dave 想把开屏动画的时长从两秒砍到一点二秒，问你觉得行不行。',
        ['行，砍到1.2s', '保持2s'], '砍到 1.5 秒，留点呼吸感', false),
      new Msg('adam', 'infra', '#5FE0C6', 'adam 等你点头再动',
        '【配置同步】', '旧机脏数据，直接覆盖吗？',
        'adam 在配置同步里发现一条旧机器的脏数据，问你要不要直接覆盖，还是先备份。',
        ['覆盖它', '先备份再说'], '先备份一份再覆盖，改动记到日志', true)
    ];
    const item = more[this.extraIdx % more.length];
    this.extraIdx++;
    this.queue.push(item);
    if (this.screen === 'home') { this.broadcast(item); }
  }

  // ================= UI =================
  build() {
    Stack() {
      // 圆屏底色
      Circle().width('100%').height('100%').fill(C_BG)

      if (this.screen === 'home') { this.HomeView() }
      if (this.screen === 'bc') { this.BroadcastView() }
      if (this.screen === 'read') { this.ReadingView() }
      if (this.screen === 'listen') { this.ListenView() }
      if (this.screen === 'transcript') { this.TranscriptView() }
      if (this.screen === 'sent') { this.SentView() }
    }
    .width('100%').height('100%').backgroundColor(C_BG)
  }

  @Builder
  Dot(color: string) {
    Circle().width(6).height(6).fill(color)
  }

  // —— HOME ——
  @Builder
  HomeView() {
    Column({ space: 8 }) {
      Text('助手').fontSize(11).fontColor(C_INK3).letterSpacing(2).margin({ bottom: 2 })
      Circle().width(84).height(84).fill(C_TEAL)
        .shadow({ radius: 30, color: 'rgba(79,214,196,0.55)' })
      Text(this.timeStr).fontSize(44).fontWeight(FontWeight.Medium).fontColor(C_INK)
      Button(this.pendingText())
        .fontSize(13).fontColor(this.queue.length > 0 ? C_AMBER : C_GREEN).fontWeight(FontWeight.Medium)
        .backgroundColor(this.queue.length > 0 ? 'rgba(245,178,74,0.12)' : 'rgba(84,213,131,0.12)')
        .borderWidth(1).borderColor(this.queue.length > 0 ? 'rgba(245,178,74,0.34)' : 'rgba(84,213,131,0.34)')
        .borderRadius(999).padding({ left: 15, right: 15, top: 7, bottom: 7 }).margin({ top: 8 })
        .onClick(() => { if (this.queue.length > 0) { this.deliverNext(); } })
      Button('模拟新消息').fontSize(11).fontColor(C_INK2).backgroundColor(C_SURF)
        .borderRadius(999).padding({ left: 12, right: 12, top: 5, bottom: 5 }).margin({ top: 2 })
        .onClick(() => { this.simNewMessage(); })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  // —— BROADCAST ——
  @Builder
  BroadcastView() {
    Column({ space: 4 }) {
      Circle().width(74).height(74).fill(C_TEAL)
        .shadow({ radius: 28, color: 'rgba(79,214,196,0.6)' })
        .scale({ x: this.orbScale, y: this.orbScale })
      Text(this.bcTag).fontSize(11).fontColor(C_TEAL).letterSpacing(1.5).margin({ top: 10 })
      Text(this.cur.speak).fontSize(14).fontColor(C_INK).lineHeight(21)
        .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center).constraintSize({ maxWidth: 210 }).margin({ top: 10 })
      Row({ space: 9 }) {
        Button('重听').fontSize(12).fontColor(C_INK2).backgroundColor(C_SURF)
          .borderWidth(1).borderColor(C_LINE).borderRadius(999).padding({ left: 15, right: 15, top: 8, bottom: 8 })
          .onClick(() => { this.setSpeaking(true); this.bcTag = '助手播报中'; this.advToken++; this.speak(this.cur.speak); })
        Button('看消息 ›').fontSize(12).fontColor('#04120F').backgroundColor(C_TEAL)
          .borderRadius(999).padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .onClick(() => { this.openReading(); })
      }.margin({ top: 16 })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }

  // —— READING（C 方案）——
  @Builder
  ReadingView() {
    Stack() {
      // 消息主体
      Column({ space: 9 }) {
        Row({ space: 8 }) {
          Text(this.cur.emp.substring(0, 1).toUpperCase())
            .width(26).height(26).borderRadius(13).textAlign(TextAlign.Center)
            .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#08110F').backgroundColor(this.cur.color)
          Text(this.cur.emp).fontSize(14).fontWeight(FontWeight.Medium).fontColor(C_INK)
          Text(this.cur.proj).fontSize(10).fontColor(C_AMBER)
            .backgroundColor('rgba(245,178,74,0.14)').borderWidth(1).borderColor('rgba(245,178,74,0.3)')
            .borderRadius(999).padding({ left: 8, right: 8, top: 1, bottom: 1 })
        }
        Text() {
          Span(this.cur.head).fontColor(C_AMBER).fontWeight(FontWeight.Medium)
          Span('\n' + this.cur.body).fontColor(C_INK)
        }.fontSize(15).lineHeight(22).textAlign(TextAlign.Center).constraintSize({ maxWidth: 186 })
        Row({ space: 5 }) {
          Text('↺').fontSize(12).fontColor(C_INK3)
          Text('重听助手播报').fontSize(11).fontColor(C_INK3)
        }.margin({ top: 4 }).onClick(() => { this.speak(this.cur.speak); })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center).padding({ left: 34, right: 34, bottom: 96 })

      // 底部动作条：麦克风 + 快捷
      Row({ space: 12 }) {
        // 麦克风（青色圆钮，点了走语音）
        Stack() {
          Circle().width(52).height(52).fill(C_TEAL).shadow({ radius: 14, color: 'rgba(79,214,196,0.5)' })
          Text('说').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#04120F')
        }.onClick(() => { this.startListen(); })
        Button('快捷 ›').fontSize(13).fontColor(C_INK).fontWeight(FontWeight.Medium)
          .backgroundColor(C_SURF).borderWidth(1).borderColor(C_LINE).borderRadius(999)
          .padding({ left: 18, right: 18, top: 12, bottom: 12 })
          .onClick(() => { this.sheetOpen = true; })
      }
      .position({ x: 0, y: 0 }).width('100%').height('100%')
      .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Bottom).padding({ bottom: 30 })

      // 抽屉遮罩
      Column()
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.5)')
        .visibility(this.sheetOpen ? Visibility.Visible : Visibility.Hidden)
        .onClick(() => { this.sheetOpen = false; })

      // 快捷抽屉
      Column({ space: 9 }) {
        Row().width(34).height(4).borderRadius(3).backgroundColor(C_LINE).margin({ bottom: 3 })
        Text('快捷回复').fontSize(10).fontColor(C_INK3).letterSpacing(1.5)
        ForEach(this.cur.chips, (txt: string) => {
          Button(txt).fontSize(12).fontColor(C_INK).backgroundColor(C_SURF)
            .borderWidth(1).borderColor(C_LINE).borderRadius(14).width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => { this.dispatch(txt); })
        }, (txt: string) => txt)
      }
      .width('100%').padding({ left: 34, right: 34, top: 14, bottom: 34 })
      .backgroundColor('#0F131A').borderRadius({ topLeft: 28, topRight: 28 })
      .position({ x: 0, y: 0 }).alignRules({ bottom: { anchor: '__container__', align: VerticalAlign.Bottom } })
      .translate({ y: this.sheetOpen ? 0 : 320 })
      .animation({ duration: 300, curve: Curve.EaseOut })
    }
    .width('100%').height('100%')
  }

  // —— LISTEN ——
  @Builder
  ListenView() {
    Column({ space: 16 }) {
      Text('聆听中…').fontSize(14).fontColor(C_TEAL).fontWeight(FontWeight.Medium)
      Row({ space: 4 }) {
        Circle().width(4).height(4).fill(C_TEAL)
        Circle().width(4).height(4).fill(C_TEAL)
        Circle().width(4).height(4).fill(C_TEAL)
        Circle().width(4).height(4).fill(C_TEAL)
      }
      Text('对着手表说你的决定').fontSize(12).fontColor(C_INK3)
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  // —— TRANSCRIPT ——
  @Builder
  TranscriptView() {
    Column({ space: 12 }) {
      Row({ space: 7 }) { this.Dot(C_TEAL); Text('听到了，发给他？').fontSize(12).fontColor(C_TEAL) }
      Text('“' + this.cur.voice + '”').fontSize(16).fontColor(C_INK).lineHeight(24)
        .textAlign(TextAlign.Center).constraintSize({ maxWidth: 200 })
      Text('→ ' + this.cur.emp + ':' + this.cur.proj).fontSize(12).fontColor(C_INK2)
      Row({ space: 10 }) {
        Button('重说').fontSize(13).fontColor(C_INK2).backgroundColor(C_SURF)
          .borderWidth(1).borderColor(C_LINE).borderRadius(999).padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .onClick(() => { this.startListen(); })
        Button('发送').fontSize(13).fontColor('#04120F').backgroundColor(C_TEAL)
          .borderRadius(999).padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .onClick(() => { this.dispatch(this.cur.voice); })
      }.margin({ top: 6 })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }

  // —— SENT ——
  @Builder
  SentView() {
    Column({ space: 9 }) {
      Text('✓').fontSize(38).fontColor(C_GREEN)
        .width(72).height(72).borderRadius(36).textAlign(TextAlign.Center)
        .backgroundColor('rgba(84,213,131,0.14)').borderWidth(1).borderColor('rgba(84,213,131,0.4)')
      Text('已发给 ' + this.cur.emp + ':' + this.cur.proj).fontSize(15).fontWeight(FontWeight.Medium).fontColor(C_INK)
      Text('接下来：' + this.sentInstruction).fontSize(12).fontColor(C_INK2).lineHeight(18)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).constraintSize({ maxWidth: 200 })
      Row({ space: 8 }) {
        Row({ space: 5 }) { this.Dot(C_AMBER); Text('等你').fontSize(12).fontColor(C_INK2) }
        Text('→').fontSize(12).fontColor(C_INK3)
        Row({ space: 5 }) { this.Dot(C_GREEN); Text('干活中').fontSize(12).fontColor(C_INK2) }
      }.margin({ top: 6 })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).padding({ left: 30, right: 30 })
  }
}
