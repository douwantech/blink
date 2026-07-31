'use strict';

hterm.defaultStorage = new lib.Storage.Memory();

window.fontSizeDetectionMethod = 'canvas';

function _postMessage(op, data) {
  window.webkit.messageHandlers.interOp.postMessage({op, data});
}

hterm.notify = function(params) {
  var def = (curr, fallback) => curr !== undefined ? curr : fallback;
  if (params === undefined || params === null) {
    params = {};
  }


  var title = def(params.title, window.document.title);
  if (!title)
    title = 'hterm';

  _postMessage('notify', {title, body: params.body})
}

hterm.Terminal.prototype.ringBell = function() {
  // Blink cursor on BEL character
  this.cursorNode_.style.backgroundColor = this.scrollPort_.getForegroundColor();
    
  setTimeout(() => this.restyleCursor_(), 200);
  
  _postMessage('ring-bell', null);
};

hterm.Terminal.prototype.copyStringToClipboard = function(content) {
  if (this.prefs_.get('enable-clipboard-notice')) {
    setTimeout(this.showOverlay.bind(this, hterm.notifyCopyMessage, 500), 200);
  }

  document.getSelection().removeAllRanges();
  _postMessage('copy', {content});
};

document.addEventListener('selectionchange', function() {
  _postMessage('selectionchange', term_getCurrentSelection());
});

hterm.Terminal.IO.prototype.sendString = function(string) {
  _postMessage('sendString', {string});
};

hterm.msg = function() {}; // TODO: show messages

function _colorComponents(colorStr) {
  if (!colorStr) {
    return [0, 0, 0]; // Default is black
  }

  return colorStr
    .replace(/[^0-9,]/g, '')
    .split(',')
    .map(s => parseInt(s));
}

// Before we fully load hterm. We set options here.
var _prefs = new hterm.PreferenceManager('blink');
var t = {prefs_: _prefs}; // <- `t` will become actual hterm instance after decorate.

function term_set(key, value) {
  _prefs.set(key, value);
}

function term_get(key) {
  return _prefs.get(key);
}

function term_setupDefaults() {
  term_set('copy-on-select', false);
  term_set('audible-bell-sound', '');
  term_set('receive-encoding', 'raw'); // we are UTF8
  term_set('allow-images-inline', true); // need to make it work
  term_set('scroll-wheel-may-send-arrow-keys', false)
}

function term_processKB(str) {
  if (!t.prompt) {
    return;
  }
  if (str) {
    t.prompt.processInput(str);
  }
}

function term_displayInput(str, display) {
  if (!t || !t.accessibilityReader_) {
    return;
  }
  
  t.accessibilityReader_.hasUserGesture = true;
  
  if (!display) {
    return;
  }
  
  if (str && !t.prompt._secure) {
    window.KeystrokeVisualizer.processInput(str);
  }
}


function term_setup(accessibilityEnabled) {
  t = new hterm.Terminal('blink');

  t.onTerminalReady = function() {
    window.installKB(t, t.scrollPort_.screen_);
    term_setAutoCarriageReturn(true);
    term_setClipboardWrite(false);

    t.setCursorVisible(true);
    t.io.onTerminalResize = function(cols, rows) {
      _postMessage('sigwinch', {cols, rows});
      if (t.prompt) {
        t.prompt.resize();
      }
    };

    var size = {
      cols: t.screenSize.width,
      rows: t.screenSize.height,
    };
    
    document.body.style.backgroundColor =
      t.scrollPort_.screen_.style.backgroundColor;
    var bgColor = _colorComponents(t.scrollPort_.screen_.style.backgroundColor);
    
    t.keyboard.characterEncoding = 'raw'; // we are UTF8. Fix for #507
    t.uninstallKeyboard();
    
    _postMessage('terminalReady', {size, bgColor});

    if (window.KeystrokeVisualizer) {
      window.KeystrokeVisualizer.enable();
    }
    t.setAccessibilityEnabled(accessibilityEnabled);
  };

  t.decorate(document.getElementById('terminal'));
}

function term_init(accessibilityEnabled, lockdownMode) {
  term_setupDefaults();
  try {
    applyUserSettings();
    //    var bgColor = term_get('background-color');
    //    document.body.style.backgroundColor = bgColor;
    //    document.body.parentNode.style.backgroundColor = bgColor;
    if (lockdownMode) {
      term_setup(accessibilityEnabled);
    } else {
      waitForFontFamily(term_setup);
    }
  } catch (e) {
    _postMessage('alert', {
      title: 'Error',
      message:
        'Failed to setup theme. Please check syntax of your theme.\n' +
        e.toString(),
    });
    term_setup(accessibilityEnabled);
  }
}

var _requestId = 0;
var _requestsMap = {};

class ApiRequest {
  constructor(name, request) {
    this.id = _requestId++;
    request.id = this.id;
    var self = this;
    this.promise = new Promise(function(resolve, reject) {
        self.resolve = resolve;
        self.reject = reject;
    });
    _requestsMap[this.id] = self
    _postMessage("api", {name, request: JSON.stringify(request)} );
    
    this.then = this.promise.then.bind(this.promise);
    this.catch = this.promise.catch.bind(this.promise);
  }
  
  cancel() {
    this.resolve(null);
    delete _requestsMap[this.id];
  }
}

function term_apiRequest(name, request) {
  return new ApiRequest(name, request)
}

function term_apiResponse(name, response) {
  var res = JSON.parse(response);
  var req = _requestsMap[res.requestId];
  if (!req) {
    return;
  }
  delete _requestsMap[req.id];
  req.resolve(res)
}


window.term_apiRequest = term_apiRequest;
window.term_apiResponse = term_apiResponse;

function term_write(data) {
  t.interpret(data);
}

function term_paste(str) {
  t.onPaste_({text: str || ''});
}

var _utf8TextDecoder = new TextDecoder('utf8');
function term_write_b64(b64str) {
  var bytes = base64js.toByteArray(b64str); // b64_to_uint8_array(b64str);
  var data = _utf8TextDecoder.decode(bytes);
  t.interpret(data);
};

function b64_to_uint8_array(b64Str) {
  var s = atob(b64Str);
  var len = s.length;
  var res = new Uint8Array(len);
  for (var i = 0; i < len; i++) {
    res[i] = s.charCodeAt(i);
  }
  return res;
}

function term_clear() {
  t.clear();
}

function term_reset() {
  t.reset();
}

function term_focus() {
  t.onFocusChange__(true);
}

function term_blur() {
  t.onFocusChange__(false);
}

function _setTermCoordinates(event, x, y) {
  // One based row/column stored on the mouse event.
  var ty = (y / t.scrollPort_.characterSize.height | 0) + 1;
  var tx = (x / t.scrollPort_.characterSize.width | 0) + 1;
//  console.log(`x:${x},y: ${y}, col:${tx}, row:${ty}`);
  event.terminalRow = ty;
  event.terminalColumn = tx;
}

function term_reportMouseClick(x, y, buttons, display) {
  if (!t.prompt) {
    return;
  }

  var event = new MouseEvent(name, {buttons});
  _setTermCoordinates(event, x, y);
  if (!t.prompt.processMouseClick(event)) {
    term_reportMouseEvent('mousedown', x, y, 1);
    term_reportMouseEvent('mouseup', x, y, 1);
  }
                                  
  if (display) {
     term_displayInput("👆", display);
  }
}

function blink_url_at_point(x, y) {
  var URL_CHAR = "[\\w\\-._~:\\/?#\\[\\]@!$&'()*+,;=%]";
  var URL_RE = new RegExp("https?:\\/\\/" + URL_CHAR + "+", "g");
  var URL_HEAD_RE = new RegExp("^" + URL_CHAR + "+");
  var URL_TAIL_RE = new RegExp(URL_CHAR + "+$");

  function rowOf(node) {
    var p = node && node.parentNode;
    while (p) {
      if (p.nodeName === 'X-ROW') return p;
      p = p.parentNode;
    }
    return null;
  }

  function offsetWithinRow(doc, row, node, off) {
    if (!row) return off;
    var walker = doc.createTreeWalker(row, NodeFilter.SHOW_TEXT, null, false);
    var n, total = 0;
    while ((n = walker.nextNode())) {
      if (n === node) return total + off;
      total += (n.textContent || '').length;
    }
    return off;
  }

  function findIn(doc, lx, ly) {
    var range = doc.caretRangeFromPoint ? doc.caretRangeFromPoint(lx, ly) : null;
    if (!range) return '';
    var node = range.startContainer;
    if (!node || node.nodeType !== Node.TEXT_NODE) return '';
    var row = rowOf(node);
    var text = row ? (row.textContent || '') : (node.textContent || '');
    var off = row ? offsetWithinRow(doc, row, node, range.startOffset) : range.startOffset;
    var m;
    URL_RE.lastIndex = 0;
    while ((m = URL_RE.exec(text))) {
      if (off >= m.index && off <= m.index + m[0].length) {
        var url = m[0];
        // 终端折行：URL 一直到行末 → 看后续行是否以 URL 字符续起
        if (row && m.index + url.length >= text.length) {
          var nxt = row.nextElementSibling;
          while (nxt && nxt.nodeName === 'X-ROW') {
            var nt = nxt.textContent || '';
            var cont = nt.match(URL_HEAD_RE);
            if (!cont) break;
            url += cont[0];
            if (cont[0].length < nt.length) break;  // 该行没占满，URL 结束
            nxt = nxt.nextElementSibling;
          }
        }
        // URL 从行首开始 → 看前一行末尾是否是 URL 字符
        if (row && m.index === 0) {
          var prv = row.previousElementSibling;
          while (prv && prv.nodeName === 'X-ROW') {
            var pt = prv.textContent || '';
            var schemeHit = pt.match(/(https?:\/\/[\w\-._~:\/?#\[\]@!$&'()*+,;=%]*)$/);
            if (schemeHit) { url = schemeHit[0] + url; break; }
            var tail = pt.match(URL_TAIL_RE);
            if (!tail || tail[0].length < pt.length) break;  // 没占满或没字符 → 不连续
            url = tail[0] + url;
            prv = prv.previousElementSibling;
          }
        }
        return url;
      }
    }
    return '';
  }
  try {
    var r = findIn(document, x, y);
    if (r) return r;
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      try {
        var doc = frames[i].contentDocument;
        if (!doc) continue;
        var rect = frames[i].getBoundingClientRect();
        r = findIn(doc, x - rect.left, y - rect.top);
        if (r) return r;
      } catch (e) {}
    }
  } catch (e) {}
  return '';
}

function term_reportMouseEvent(name, x, y, buttons) {
  if (!t.prompt) {
    return;
  }

  var event = new MouseEvent(name, {buttons});
  _setTermCoordinates(event, x, y);
  t.onMouse(event);
}

function term_reportWheelEvent(name, x, y, deltaX, deltaY) {
  if (!t.prompt) {
    return;
  }

  var event = new WheelEvent(name, {clientX: x, clientY: y, deltaX, deltaY});
  t.onMouse_Blink(event);
}

function term_setWidth(cols) {
  t.setWidth(cols);
}

function term_increaseFontSize() {
  var size = t.getFontSize();
  term_setFontSize(size + 1 + 'px');
}

function term_decreaseFontSize() {
  var size = t.getFontSize();
  term_setFontSize(size - 1 + 'px');
}

function term_resetFontSize() {
  term_setFontSize();
}

function term_scale(scale) {
  var minScale = 0.3;
  var maxScale = 3.0;
  scale = Math.max(minScale, Math.min(maxScale, scale));
  var fontSize = t.getFontSize();
  var newFontSize = Math.round(fontSize * scale);
  if (fontSize == newFontSize) {
    return;
  }
  term_setFontSize(newFontSize);
}

function term_setFontSize(size) {
  term_set('font-size', size);
  _postMessage('fontSizeChanged', {size: parseInt(size)});
}

function term_setFontFamily(name, fontSizeDetectionMethod) {
  window.fontSizeDetectionMethod = fontSizeDetectionMethod;
  term_set('font-family', name + ', "DejaVu Sans Mono"');
}

function term_setClipboardWrite(state) {
  if (state === false) {
    t.vt.enableClipboardWrite = false;
  } else {
    t.vt.enableClipboardWrite = true;
  }
}

function term_appendUserCss(css) {
  var style = document.createElement('style');

  style.type = 'text/css';
  style.appendChild(document.createTextNode(css));

  document.head.appendChild(style);
}

function term_loadFontFromCss(url, name) {
  WebFont.load({
    custom: {
      families: [name],
      urls: [url],
    },
    active: function() {
      t.syncFontFamily();
    },
  });
  term_setFontFamily(name);
}

function term_getCurrentSelection() {
  const selection = document.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.type === 'Caret') {
    return {base: '', offset: 0, text: ''};
  }

  const r = selection.getRangeAt(0).getBoundingClientRect();

  const rect = `{{${r.x}, ${r.y}},{${r.width},${r.height}}}`;

  let base = selection.baseNode ? selection.baseNode.textContent : '';
  let offset = selection.baseOffset;

  // 跨行 URL 修正：长 URL 在行宽处会被截断到下一行，有两种成因——
  //  1) hterm 软换行（续行节点带 line-overflow 属性）；
  //  2) 上游程序（如 cc/Claude Code 用 Ink/wrap-ansi）把 URL 从中间硬折，插了真实 \n（在 / 处断）。
  // 两种情况 baseNode.textContent 都只拿到光标那一个可视行，URL 结尾（如 .../index.html）丢失，
  // 点击在浏览器里就打开被截断的地址。判定「边界贴死」= 上一行非空白结尾 且 下一行非空白开头
  // （或带 line-overflow），把这些行拼成一条逻辑串，再换算绝对 offset 给 NSDataDetector 识别。
  const isTight = (cur, next) => {
    if (!next || next.nodeName !== 'X-ROW') return false;
    if (cur.nodeName === 'X-ROW' && cur.hasAttribute('line-overflow')) return true;
    const a = cur.textContent, b = next.textContent;
    if (!a.length || !b.length) return false;
    return !/\s$/.test(a) && !/^\s/.test(b);
  };
  let xrow = selection.baseNode;
  while (xrow && xrow.nodeName !== 'X-ROW') xrow = xrow.parentNode;
  if (xrow) {
    const MAX_ROWS = 12;  // 防极端情况（整屏无空白）无限拼接
    // 回退到逻辑串起点
    let start = xrow, back = 0;
    while (back < MAX_ROWS && start.previousSibling && isTight(start.previousSibling, start)) {
      start = start.previousSibling; back++;
    }
    // 行内绝对偏移 = 起点行到当前行之间所有文本长度 + 当前行内光标前文本长度
    let before = 0;
    for (let n = start; n && n !== xrow; n = n.nextSibling) {
      before += n.textContent.length;
    }
    const within = document.createRange();
    within.selectNodeContents(xrow);
    try { within.setEnd(selection.baseNode, selection.baseOffset); } catch (e) {}
    offset = before + within.toString().length;
    // 向后拼接贴死的行
    let full = '', n = start, fwd = 0;
    while (n) {
      full += n.textContent;
      if (fwd++ < MAX_ROWS && isTight(n, n.nextSibling)) n = n.nextSibling; else break;
    }
    base = full;
  }

  return {
    base,
    offset,
    text: selection.toString() || "",
    rect,
  };
}

function _modifySelectionByLine(direction) {
  var selection = document.getSelection();
  var fNode = selection.focusNode;
  var fOffset = selection.focusOffset;
  var aNode = selection.anchorNode;
  var aOffset = selection.anchorOffset;

  var dy =
    direction === 'left'
      ? -t.scrollPort_.characterSize.height
      : t.scrollPort_.characterSize.height;
  var dx = t.scrollPort_.characterSize.width;
  var range = selection.getRangeAt(0);

  var topLeft = true;
  if (fNode === aNode) {
    topLeft = fOffset < aOffset;
  } else {
    topLeft = range.compareNode(selection.focusNode) !== Range.NODE_AFTER;
  }

  if (topLeft) {
    // top left
    var rect = _filteredRects(range)[0];
    var point = {x: rect.left, y: rect.top + Math.abs(dy) * 0.5};
    var newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    if (!newRange) {
      selection.modify('extend', direction, 'line');
    } else {
      if (newRange.startContainer.textContent.length <= newRange.startOffset) {
        if (
          newRange.startContainer.nodeName === 'X-ROW' &&
          newRange.startOffset === 0
        ) {
          selection.setBaseAndExtent(
            aNode,
            aOffset,
            newRange.startContainer,
            newRange.startOffset,
          );
          selection.modify('extend', 'left', 'character');
        } else {
          selection.setBaseAndExtent(
            aNode,
            aOffset,
            newRange.startContainer,
            Math.max(newRange.startOffset - 1, 0),
          );
        }
      } else {
        selection.setBaseAndExtent(
          aNode,
          aOffset,
          newRange.startContainer,
          newRange.startOffset,
        );
      }
    }
  } else {
    // bottom right
    var rects = _filteredRects(range);
    var rect = rects[rects.length - 1];
    var point = {x: rect.right, y: rect.bottom - Math.abs(dy) * 0.5};
    var newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    if (newRange == null) {
      point.x -= dx * 0.5;
    }
    newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    selection.setBaseAndExtent(
      aNode,
      aOffset,
      newRange.startContainer,
      newRange.startOffset,
    );
  }
}

function _filteredRects(range) {
  var res = [];
  var rects = range.getClientRects();
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    if (r.width > 0) {
      res.push(r);
    }
  }
  return res;
}

function term_modifySelection(direction, granularity) {
  var selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return;
  }

  var fNode = selection.focusNode;
  var fOffset = selection.focusOffset;
  var aNode = selection.anchorNode;
  var aOffset = selection.anchorOffset;

  if (granularity === 'line') {
    _modifySelectionByLine(direction);
    if (selection.isCollapsed) {
      selection.setBaseAndExtent(fNode, fOffset, aNode, aOffset);
      _modifySelectionByLine(direction);
    }

    return;
  }

  selection.modify('extend', direction, granularity);

  // we collapse selection, so swap direction and rerun modification again
  if (selection.isCollapsed) {
    selection.setBaseAndExtent(fNode, fOffset, aNode, aOffset);
    selection.modify('extend', direction, granularity);
  }
}

function term_modifySideSelection() {
  var selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return;
  }

  selection.setBaseAndExtent(
    selection.focusNode,
    selection.focusOffset,
    selection.anchorNode,
    selection.anchorOffset,
  );
}

function term_cleanSelection() {
  document.getSelection().removeAllRanges();
}

function waitForFontFamily(callback) {
  const fontFamily = term_get('font-family');
  if (!fontFamily) {
    return callback();
  }

  const families = fontFamily.split(/\s*,\s*/);

  WebFont.load({
    custom: {families},
    active: callback,
    inactive: callback,
  });
}

function term_applySexyTheme(theme) {
  term_set('color-palette-overrides', theme.color);
  term_set('foreground-color', theme.foreground);
  term_set('background-color', theme.background);
}

function term_setAutoCarriageReturn(state) {
  t.setAutoCarriageReturn(state);
}

function term_restore() {
  t.primaryScreen_.textAttributes.reset();
  t.setVTScrollRegion(null, null);
  t.setCursorVisible(true);
}
