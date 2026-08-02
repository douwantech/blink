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

var terms = {};       // id -> hterm.Terminal
var layers = {};      // id -> layer div
var _pending = {};    // id -> [binary-string chunks] queued before that term is ready
var _ready = {};      // id -> bool (onTerminalReady fired)
var activeId = null;
var libInited = false;
var _createQueue = [];  // ids requested before lib.init finished

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
function term_wheel(dyPx) {
  var t = activeId ? terms[activeId] : null;
  if (!t || !t.scrollPort_ || !t.scrollPort_.screen_) { return; }
  var onAlt = (typeof t.isPrimaryScreen === 'function') && !t.isPrimaryScreen();
  var ch = (t.scrollPort_.characterSize && t.scrollPort_.characterSize.height) || 16;
  var lines = Math.max(1, Math.round(Math.abs(dyPx) / ch));
  if (onAlt) {
    // hterm's io is NOT wired to blinkd (harmony captures keys in ArkTS, not hterm),
    // so t.io.sendString would go nowhere. Hand the wheel to ArkTS to send the SGR
    // mouse bytes over the blinkd connection instead. btn 64 = up (older), 65 = down.
    var btn = dyPx > 0 ? 64 : 65;
    _post('wheel', { btn: btn, lines: lines });
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
