// Multi-session hterm driver for Blink-HarmonyOS. hterm does the real VT
// rendering (colors, cursor, alt-screen — so vim/tmux/claude render correctly).
// One WebView hosts N hterm.Terminal instances (one per session tab), each in
// its own absolutely-positioned layer div; switching tabs just flips which
// layer is visible, so every session keeps its own live screen state exactly
// like iOS Blink keeps a TermController per tab.
//
// Output is pushed in from ArkTS via term_write_b64(id, b64); keyboard input
// does NOT go through hterm (the app captures it with a transparent TextInput),
// so no hterm keyboard is installed. Resize is reported back so the app sends
// blinkd resize frames.
//
// Bridge: ArkTS -> JS uses webController.runJavaScript("term_xxx(...)").
//         JS -> ArkTS uses window.arkBridge.post(op, jsonData) (javaScriptProxy).

// 切 tab / 转屏触发 resize 时 hterm 会在屏幕中间闪一个 "列x行" 的尺寸提示，
// iOS 版是靠 hterm_all.patches.js 干掉的（这里没加载那个文件），同样 stub 掉。
hterm.Terminal.prototype.overlaySize = function() {};

var terms = {};       // id -> hterm.Terminal
var layers = {};      // id -> layer div
var _pending = {};    // id -> [binary-string chunks] queued before that term is ready
var _ready = {};      // id -> bool (onTerminalReady fired)
var activeId = null;
var libInited = false;
var _createQueue = [];  // ids requested before lib.init finished
var _hist = null;       // 本地滚动图层（历史）状态；null = 没在本地滚动
var _histQueue = [];    // 图层就绪前先攒着的历史数据
var _histFailedAt = 0;  // 最近一次拉历史失败的时间（冷却期内退回远程滚轮）

// current appearance (applied to every terminal, new ones included)
var _colors = { bg: '#000000', fg: '#D4D4D4', cur: 'rgba(61, 217, 196, 0.65)' };
var _fontSize = 13;

function _post(op, data) {
  try {
    if (window.arkBridge && window.arkBridge.post) {
      window.arkBridge.post(op, JSON.stringify(data));
    }
  } catch (e) {}
}

function term_init() {
  try {
    if (typeof hterm === 'undefined' || typeof lib === 'undefined') {
      console.error('BLINK term: hterm/lib NOT loaded (script load failed)');
      _post('error', { message: 'hterm/lib not loaded' });
      return;
    }
    lib.init(function () {
      hterm.defaultStorage = new lib.Storage.Memory();
      libInited = true;
      document.body.style.backgroundColor = _colors.bg;
      _post('ready', {});
      var q = _createQueue; _createQueue = [];
      for (var i = 0; i < q.length; i++) { term_create(q[i]); }
    });
  } catch (e) {
    _post('error', { message: String(e) });
  }
}

function _applyPrefs(t) {
  var p = t.getPrefs();
  p.set('background-color', _colors.bg);
  p.set('foreground-color', _colors.fg);
  p.set('cursor-color', _colors.cur);
  p.set('font-size', _fontSize);
  p.set('font-family', '"JetBrains Mono", "Menlo", "Courier New", monospace');
  p.set('scrollbar-visible', false);
  p.set('enable-bold', true);
  p.set('cursor-blink', true);
  p.set('audible-bell-sound', '');
  // In a full-screen app (alt-screen + application-cursor: vim/less/man/tmux copy-mode)
  // a scroll-wheel turns into ↑/↓ arrow keys, so a drag scrolls those apps. A plain
  // shell still scrolls the hterm scrollback; an app that enabled mouse reporting still
  // gets the wheel forwarded. Mirrors Blink/iTerm behaviour.
  p.set('scroll-wheel-may-send-arrow-keys', true);
}

// Create a terminal layer for session `id` (no-op if it exists).
function term_create(id) {
  try {
    if (terms[id]) { return; }
    if (!libInited) { _createQueue.push(id); return; }
    var div = document.createElement('div');
    div.id = 'layer_' + id;
    div.style.cssText = 'position:absolute;inset:0;visibility:hidden;';
    document.getElementById('terminal').appendChild(div);
    layers[id] = div;

    var t = new hterm.Terminal();
    terms[id] = t;
    _ready[id] = false;
    t.onTerminalReady = function () {
      _applyPrefs(t);
      t.setCursorVisible(true);
      t.io.onTerminalResize = function (cols, rows) {
        // all layers share the same geometry; report with the id so ArkTS can
        // resize every connected session PTY.
        _post('sigwinch', { id: id, cols: cols, rows: rows });
      };
      _ready[id] = true;
      var q = _pending[id] || [];
      delete _pending[id];
      for (var i = 0; i < q.length; i++) { t.interpret(q[i]); }
      if (activeId === id || activeId === null) { term_show(id); }
      _post('term_ready', { id: id, cols: t.screenSize.width, rows: t.screenSize.height });
    };
    t.decorate(div);
  } catch (e) {
    _post('error', { message: 'create ' + id + ': ' + String(e) });
  }
}

// Bring session `id`'s layer to front (creates it if missing).
function term_show(id) {
  try {
    if (!terms[id]) { term_create(id); }
    activeId = id;
    for (var k in layers) {
      layers[k].style.visibility = (k === id) ? 'visible' : 'hidden';
      layers[k].style.zIndex = (k === id) ? '1' : '0';
    }
    var t = terms[id];
    _histFailedAt = 0;   // 换 tab 后重新给本地滚动一次机会
    if (t && _ready[id]) {
      t.scrollEnd();
      _post('shown', { id: id, cols: t.screenSize.width, rows: t.screenSize.height });
    }
  } catch (e) {
    _post('error', { message: 'show ' + id + ': ' + String(e) });
  }
}

// Destroy session `id`'s terminal + layer (tab closed).
function term_dispose(id) {
  try {
    var div = layers[id];
    if (div && div.parentNode) { div.parentNode.removeChild(div); }
    delete layers[id];
    delete terms[id];
    delete _ready[id];
    delete _pending[id];
    if (activeId === id) { activeId = null; }
  } catch (e) {}
}

// Feed a base64-encoded chunk of raw PTY bytes for session `id` into its hterm.
function term_write_b64(id, b64) {
  try {
    var bytes = base64js.toByteArray(b64);
    // hterm.interpret() wants a "binary string" (one char per byte, 0–255) and does its
    // OWN UTF-8 decoding (lib.UTF8Decoder, characterEncoding='utf-8'). Feeding it a
    // TextDecoder'd Unicode string made hterm decode twice, mangling every multi-byte
    // glyph — ASCII was unaffected, which is exactly why only 中文/·/… turned to U+FFFD.
    var data = '';
    var CHUNK = 0x8000;
    for (var i = 0; i < bytes.length; i += CHUNK) {
      data += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    var t = terms[id];
    if (t && _ready[id]) {
      t.interpret(data);
    } else {
      if (!terms[id]) { term_create(id); }
      (_pending[id] = _pending[id] || []).push(data);
    }
  } catch (e) {
    _post('error', { message: String(e) });
  }
}

function term_clear(id) { if (terms[id]) { terms[id].clear(); } }
function term_reset(id) { if (terms[id]) { terms[id].reset(); } }

function term_setFontSize(n) {
  _fontSize = parseInt(n);
  for (var k in terms) { terms[k].getPrefs().set('font-size', _fontSize); }
}

function term_scrollBottom() { if (activeId && terms[activeId]) { terms[activeId].scrollEnd(); } }

// --- drag → scroll, routed by which screen the terminal is on ---
// term_wheel(dyPx): finger-down (dyPx>0) reveals older lines.
//  • Full-screen app (alt-screen: tmux/vim/less/claude-in-tmux): send SGR mouse-wheel
//    sequences straight to the app. blinkd restores the screen on reconnect but never
//    replays tmux's mouse-mode DECSET, so hterm's mouseReport reads stale 0 — we can't
//    rely on hterm forwarding. Sending the wheel ourselves lets a mouse-on app (tmux
//    mouse on) scroll its OWN history (copy-mode). btn 64 = wheel-up, 65 = wheel-down.
//  • Plain shell (primary screen): dispatch a real wheel event so hterm scrolls its
//    scrollback buffer.
var _wheelAccum = 0;
function term_wheel_reset() {
  _wheelAccum = 0;
  if (_hist) { _hist.acc = 0; }
}
function term_wheel(dyPx) {
  var t = activeId ? terms[activeId] : null;
  if (!t || !t.scrollPort_ || !t.scrollPort_.screen_) { return; }
  var onAlt = (typeof t.isPrimaryScreen === 'function') && !t.isPrimaryScreen();
  var ch = (t.scrollPort_.characterSize && t.scrollPort_.characterSize.height) || 16;
  if (onAlt) {
    // 全屏应用（alt-screen：tmux/vim/claude）——本地滚动（同 iOS #70）：
    // 手指下滑（dyPx>0，看更旧）＝离开底部时，请 ArkTS 用 blinkd 把 tmux 历史
    // 一次拉到本地图层，之后所有上下滑都在本地完成，不再每一下都等远程翻页
    // （brain RTT ~208ms → 原来掉帧）。
    if (_hist) {
      // 本地滚动中：还没拉到就攒着像素，拉到了就本地滚
      if (_hist.armed) { _hist.pendingPx += dyPx; } else { term_hist_scroll(dyPx); }
      return;
    }
    if (dyPx > 0 && (Date.now() - _histFailedAt) > 5000) {
      _hist = _histNew(activeId);
      _hist.armed = true;
      _hist.pendingPx = dyPx;
      _post('hist_need', {});
      return;
    }
    // 往新方向拖，或刚拉失败在冷却期内：维持原行为。
    // hterm's io is NOT wired to blinkd (harmony captures keys in ArkTS, not hterm),
    // so t.io.sendString would go nowhere. Hand the wheel to ArkTS to send the SGR
    // mouse bytes over the blinkd connection instead. btn 64 = up (older), 65 = down.
    // 跟手：累积像素位移，够一整行(ch)才发一个滚轮 —— 手指移动一行高＝滚一行，
    // 不过冲。旧代码每次 update 都 Math.max(1) 强发≥1行，一次拖动几十次 update
    // 就把滚动放大几倍，表现为「滑动不跟手、飞得比手指快」。
    _wheelAccum += dyPx;
    var lines = (_wheelAccum / ch) | 0;   // 向零取整（负数也对）
    if (lines === 0) { return; }
    _wheelAccum -= lines * ch;
    var btn = lines > 0 ? 64 : 65;
    _post('wheel', { btn: btn, lines: Math.abs(lines) });
  } else {
    // Plain shell: hterm owns the scrollback, so dispatch a real wheel locally.
    var el = t.scrollPort_.screen_;
    try {
      var ev = new WheelEvent('wheel', {
        deltaY: -dyPx, deltaMode: 0, clientX: 100, clientY: 200,
        bubbles: true, cancelable: true,
      });
      el.dispatchEvent(ev);
    } catch (e3) {}
  }
}

// --- local scroll (本地滚动) -------------------------------------------------
// 离开底部去看历史时，ArkTS 用一条独立连接跑 `tmux capture-pane -p -e -S -3000`
// 把当前 pane 的历史（带颜色）拉回来，这里把它喂进一个独立的 hterm 图层。
// 那个图层是 primary screen，所以有自己的 scrollback：之后的上下滑、惯性全在
// 本地滚，一帧都不用等远程。退出（滑回底部 / 点「回到底部」/ 开始打字）由
// ArkTS 判定后调 term_hist_end()。
function _histNew(id) {
  return { id: id, t: null, div: null, ready: false, armed: false, acc: 0,
           pendingPx: 0, atBottom: true, hasData: false, showPending: false };
}

// 建历史图层（ArkTS 拿到第一段历史时调）。
function term_hist_begin(id) {
  try {
    var px = (_hist && _hist.armed) ? _hist.pendingPx : 0;
    term_hist_end();
    _hist = _histNew(id);
    _hist.armed = true;      // 数据还在路上：这段拖动先攒着
    _hist.pendingPx = px;
    if (!libInited) { return; }
    var div = document.createElement('div');
    div.id = 'layer_hist';
    div.style.cssText = 'position:absolute;inset:0;visibility:hidden;';
    document.getElementById('terminal').appendChild(div);
    _hist.div = div;
    var t = new hterm.Terminal();
    _hist.t = t;
    t.onTerminalReady = function () {
      _applyPrefs(t);
      t.setCursorVisible(false);
      _hist.ready = true;
      var q = _histQueue;
      _histQueue = [];
      for (var i = 0; i < q.length; i++) { t.interpret(q[i]); }
      if (q.length > 0) { _hist.hasData = true; }
      t.scrollEnd();
      if (_hist.showPending) { _histFinishShow(); }
    };
    t.decorate(div);
  } catch (e) { _post('error', { message: 'hist_begin: ' + String(e) }); }
}

// 喂一段历史（base64 的原始字节，跟 term_write_b64 同一条路，所以颜色/中文都对）。
function term_hist_write_b64(b64) {
  try {
    if (!_hist) { return; }
    var bytes = base64js.toByteArray(b64);
    var data = '';
    var CHUNK = 0x8000;
    for (var i = 0; i < bytes.length; i += CHUNK) {
      data += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    if (_hist.ready && _hist.t) {
      _hist.t.interpret(data);
      _hist.t.scrollEnd();
      _hist.atBottom = true;
      _hist.hasData = true;
    } else {
      _histQueue.push(data);
    }
  } catch (e) { _post('error', { message: String(e) }); }
}

// 历史拉完：图层就绪且内容到手后才真正亮出来。
function term_hist_show() {
  if (!_hist) { return; }
  _hist.armed = false;
  _hist.showPending = true;
  if (_hist.ready) { _histFinishShow(); }
}

function _histFinishShow() {
  try {
    if (!_hist || !_hist.t) { return; }
    _hist.showPending = false;
    var sbRows = (_hist.t.scrollbackRows_ && _hist.t.scrollbackRows_.length) || 0;
    if (!_hist.hasData || sbRows === 0) {
      // 拉回来的内容一点历史都没有（pane 本身在 alt-screen，如 vim/less，tmux 只给现屏）：
      // 本地滚动没意义，交回原来的远程滚轮（老路径下 tmux/应用自己处理滚轮），
      // 别把用户卡在一个不会动的图层上。
      term_hist_abort();
      return;
    }
    _hist.t.scrollEnd();
    if (_hist.div) { _hist.div.style.visibility = 'visible'; _hist.div.style.zIndex = '2'; }
    _hist.atBottom = true;
    var px = _hist.pendingPx;
    _hist.pendingPx = 0;
    if (px > 0) { term_hist_scroll(px); }
  } catch (e) { _post('error', { message: String(e) }); }
}

// 拆掉历史图层，回到实时终端。
function term_hist_end() {
  try {
    if (_hist && _hist.div && _hist.div.parentNode) { _hist.div.parentNode.removeChild(_hist.div); }
  } catch (e) {}
  _hist = null;
  _histQueue = [];
}

// 拉历史失败（不是 tmux 会话 / 机器没连上）：把这段拖动按老路数补成远程滚轮，
// 冷却 5s 内不再尝试，免得每次都白等一个来回。
function term_hist_abort() {
  try {
    var t = activeId ? terms[activeId] : null;
    var px = _hist ? _hist.pendingPx : 0;
    if (t && t.scrollPort_ && px > 0) {
      var ch = (t.scrollPort_.characterSize && t.scrollPort_.characterSize.height) || 16;
      var lines = Math.min((px / ch) | 0, 8);
      if (lines > 0) { _post('wheel', { btn: 64, lines: lines }); }
    }
  } catch (e) {}
  term_hist_end();
  _histFailedAt = Date.now();
}

// 历史图层的视口是否已经到底（顶部行号进了 live screen 区就是到底）。
function _histAtBottom() {
  var t = _hist && _hist.t;
  if (!t || !t.scrollPort_) { return true; }
  var sb = (t.scrollbackRows_ && t.scrollbackRows_.length) || 0;
  return t.scrollPort_.getTopRowIndex() >= sb;
}

// 本地滚动：跟手（手指走一行高＝滚一行，不过冲），到底了回报给 ArkTS 退出本地滚动。
function term_hist_scroll(dyPx) {
  var t = _hist && _hist.t;
  if (!t || !t.scrollPort_) { return; }
  var ch = (t.scrollPort_.characterSize && t.scrollPort_.characterSize.height) || 16;
  _hist.acc += dyPx;
  var lines = (_hist.acc / ch) | 0;   // 向零取整（负数也对）
  if (lines === 0) { return; }
  _hist.acc -= lines * ch;
  var n = Math.abs(lines);
  for (var i = 0; i < n; i++) {
    if (lines > 0) { t.scrollLineUp(); } else { t.scrollLineDown(); }
  }
  var ab = _histAtBottom();
  if (ab !== _hist.atBottom) {
    _hist.atBottom = ab;
    _post('hist_pos', { atBottom: ab });
  }
}

// Live theme switch from the settings UI: recolor every session.
function term_set_colors(bg, fg, cur) {
  try {
    _colors = { bg: bg, fg: fg, cur: cur };
    document.body.style.backgroundColor = bg;
    for (var k in terms) {
      var p = terms[k].getPrefs();
      p.set('background-color', bg);
      p.set('foreground-color', fg);
      p.set('cursor-color', cur);
    }
  } catch (e) { _post('error', { message: String(e) }); }
}
