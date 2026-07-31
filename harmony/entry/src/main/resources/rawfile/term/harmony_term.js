// Slim hterm driver for Blink-HarmonyOS. hterm does the real VT rendering
// (colors, cursor, alt-screen — so vim/tmux/claude render correctly). Output is
// pushed in from ArkTS via term_write_b64(); keyboard input does NOT go through
// hterm (the app captures it with a transparent TextInput), so no hterm keyboard
// is installed. Resize is reported back so the app sends a blinkd resize frame.
//
// Bridge: ArkTS -> JS uses webController.runJavaScript("term_xxx(...)").
//         JS -> ArkTS uses window.arkBridge.post(op, jsonData) (javaScriptProxy).

var t = null;
var _pending = [];   // chunks that arrive before the terminal is ready

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
    _post('log', { msg: 'init start hterm=' + (typeof hterm) + ' lib=' + (typeof lib) });
    lib.init(function () {
      _post('log', { msg: 'lib.init done' });
      hterm.defaultStorage = new lib.Storage.Memory();
      t = new hterm.Terminal();
      t.onTerminalReady = function () {
        var p = t.getPrefs();
        p.set('background-color', '#000000');
        p.set('foreground-color', '#D4D4D4');
        p.set('cursor-color', 'rgba(61, 217, 196, 0.65)');
        p.set('font-size', 13);
        p.set('font-family', '"JetBrains Mono", "Menlo", "Courier New", monospace');
        p.set('scrollbar-visible', false);
        p.set('enable-bold', true);
        p.set('cursor-blink', true);
        p.set('audible-bell-sound', '');
        t.setCursorVisible(true);
        document.body.style.backgroundColor = '#000000';

        t.io.onTerminalResize = function (cols, rows) {
          _post('sigwinch', { cols: cols, rows: rows });
        };

        // flush anything that arrived before we were ready
        for (var i = 0; i < _pending.length; i++) {
          t.interpret(_pending[i]);
        }
        _pending = [];

        _post('ready', { cols: t.screenSize.width, rows: t.screenSize.height });
      };
      t.decorate(document.getElementById('terminal'));
    });
  } catch (e) {
    _post('error', { message: String(e) });
  }
}

// Feed a base64-encoded chunk of raw PTY bytes from blinkd into hterm.
function term_write_b64(b64) {
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
    if (t) {
      t.interpret(data);
    } else {
      _pending.push(data);
    }
  } catch (e) {
    _post('error', { message: String(e) });
  }
}

function term_clear() { if (t) { t.clear(); } }
function term_reset() { if (t) { t.reset(); } }
function term_setFontSize(n) { if (t) { t.getPrefs().set('font-size', parseInt(n)); } }
function term_scrollBottom() { if (t) { t.scrollEnd(); } }

// Live theme switch from the settings UI: recolor background / foreground / cursor.
function term_set_colors(bg, fg, cur) {
  try {
    if (t) {
      var p = t.getPrefs();
      p.set('background-color', bg);
      p.set('foreground-color', fg);
      p.set('cursor-color', cur);
      document.body.style.backgroundColor = bg;
    }
  } catch (e) { _post('error', { message: String(e) }); }
}
