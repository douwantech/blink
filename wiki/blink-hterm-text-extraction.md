---
title: hterm 文本抓取：alt screen vs primary + scrollback
type: concept
created: 2026-05-12
updated: 2026-05-12
---

# hterm 文本抓取：alt screen vs primary + scrollback

抓"当前终端里 Claude 那段输出"看似简单（`Array.from(document.querySelectorAll('x-row')).map(r => r.textContent)`），但 Claude Code / vim / less / tmux 这类 TUI 切到 **alternate screen** 后，hterm 内部状态会很反直觉。这页记下踩过的坑和能跑的策略。

## 先搞清 `window.t`

- `SmarterTermInput` **同时**是键盘 web view 和终端 web view：它继承 `KBWebView`（默认 `didMoveToSuperview` 加载 `kb.html`），但 `TermView.m:159/440` 显式 `[_webView loadFileURL:term.html]` 覆盖了这次加载。所以 `evaluateJavaScript` 在 SmarterTermInput 上运行的就是 hterm 那个 web view。
- `term.js:66` 顶层有 `var t = {prefs_: _prefs}` 占位，`term.js:111` 在 `term_setup` 里 `t = new hterm.Terminal('blink')` 重新赋值。`'use strict'` 在 classic script 里不阻止顶层 `var` 挂到 `window`，所以 **`window.t` 就是 hterm 实例**。
- `_gestureInteraction` 也用到 `t.scrollPort_.scroller_`（TermView.m:167），可作 `t` 全局可用性的旁证。

## Alt screen 时 hterm 内部的怪状态

实测诊断（Claude Code 跑在 TUI alt 模式下）：

```json
{
  "hasT": true,
  "url": "term.html",
  "xrowCount": 31,
  "altScreen": "alt",           // term.screen_ === term.alternateScreen_
  "priLen": 48,                 // term.primaryScreen_.rowsArray.length
  "altLen": 31,                 // term.alternateScreen_.rowsArray.length
  "totalRows": 0                // sb.length + screen_.rowsArray.length
}
```

也就是说：

- `term.screen_ === term.alternateScreen_` 为 true（确实在 alt）
- 但 **`term.screen_.rowsArray.length === 0`**，而**通过对象路径** `term.alternateScreen_.rowsArray.length === 31`
- `term.scrollbackRows_.length === 0`（alt screen 无 scrollback —— 设计如此）
- DOM `document.querySelectorAll('x-row').length === 31` —— **真实可见内容只在 DOM**

`screen_ === alternateScreen_` 但两侧 `rowsArray.length` 不一致这个具体现象没继续深挖（可能 hterm 内部对 alt 模式的 `rowsArray` 有特殊读路径），结论是 **alt screen 下不要依赖 `term.screen_.rowsArray` / `term.scrollbackRows_`**。

## 能跑的策略

```js
var term = window.t;
var inAlt = !!(term && term.alternateScreen_ && term.screen_ === term.alternateScreen_);
var rows;
if (inAlt) {
  // alt screen: 只信 DOM
  rows = Array.from(document.querySelectorAll('x-row'))
    .map(r => (r.textContent || '').replace(/ /g, ' ').replace(/\s+$/, ''));
} else {
  // primary screen: scrollback + 当前可见 rowsArray
  rows = [];
  (term.scrollbackRows_ || []).forEach(n => rows.push((n.textContent || '').replace(/ /g, ' ').replace(/\s+$/, '')));
  (term.screen_.rowsArray || []).forEach(n => rows.push((n.textContent || '').replace(/ /g, ' ').replace(/\s+$/, '')));
}
```

裁剪启发式也要分场景：

- **primary screen**：从尾部往前裁装饰行（spinner / permission banner / box-drawing），起点找最近一行 `^>\s+\S`（用户最近一次 prompt），从下一行开始取。
- **alt screen**：只从底部往上裁掉 Claude Code 输入框（`╭─...─╮` / `│ ... │` / `╰─...─╯`）和 `? for ... bypass permissions...` status banner。**中间**任何 `│` `─` 都可能是表格分隔符，不要无脑裁。
- 不要再用 `> ` 找起点：alt screen 里 `> ` 出现在输入框内、不是历史 prompt 行。

实现见 `SmarterTermInput.swift:656` 的 `voiceInputDidRequestCopyLastResponse`。

## 边界

- Alt screen 一屏就是一屏。超过可见区被 TUI 重绘滚掉的内容**无法找回**——hterm 没保留。
- Claude Code 一段长回复（比如长 diff、长 commit message）如果超过一屏，按"复制"只能拿到当前可见的尾部分。这不是 bug，是 alt screen 的设计约束。

## 调试套路

抓不到内容时塞个返回诊断对象的 JS（`hasT` / `altScreen` / `priLen` / `altLen` / `xrowCount` / `totalRows`），让按钮回调把它写到剪贴板看，比靠 console 强 —— WKWebView 的 console 在 release/真机上不方便看。
