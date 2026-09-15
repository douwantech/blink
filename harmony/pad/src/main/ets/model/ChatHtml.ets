////////////////////////////////////////////////////////////////////////////////
//
// ChatHtml — 对话记录页（D 卡片流，与 iOS TranscriptViewController 同一套体验）。
// 从手机版 entry/pages/BlinkTerminal.ets 原样移植，平板版复用。
//
////////////////////////////////////////////////////////////////////////////////

// 每 tab 一份的本地缓存:file/lines 是 jsonl 游标,body 是 "▶ You/◆ Claude" 全文
export interface TranscriptCacheH {
  file: string;
  lines: number;
  body: string;
}

// Web 里 JS 调 native(javaScriptProxy 注入为 window.blinkNative):复制 + 带账密抓图
export class ChatBridge {
  onCopy: (t: string) => void = (_t: string): void => {};
  onFetchImage: (url: string, id: string) => void = (_u: string, _i: string): void => {};

  copy(t: string): void {
    this.onCopy(t);
  }

  fetchImage(url: string, id: string): void {
    this.onFetchImage(url, id);
  }
}

// D 卡片流 HTML(iOS htmlFor 的移植):浅灰底,Claude 白卡片 + 名字 + 复制,
// user 右侧蓝胶囊;尾部 12 条先渲染秒显,老历史后台补插;隐藏→滚到底→显示防跳动。
export function buildChatHtml(payloadB64: string, avatarURI: string, claudeName: string): string {
  const safeName: string = claudeName.replace(new RegExp('["<>\\\\]', 'g'), '');
  const p1: string = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">' +
    '<style>' +
    'body{font-family:-apple-system,"PingFang SC","HarmonyOS Sans SC",sans-serif;padding:14px 14px 40px;' +
    'line-height:1.6;color:#1a1d21;background:#f4f5f7;font-size:14px;word-wrap:break-word;margin:0;}' +
    'h1,h2,h3{font-weight:600;margin:1em 0 .5em;}h1{font-size:1.3em}h2{font-size:1.18em}h3{font-size:1.08em}' +
    '.msg-block{margin:14px 0;display:flex;gap:8px;align-items:flex-start;}' +
    '.ava{width:30px;height:30px;border-radius:50%;flex:0 0 auto;display:flex;align-items:center;' +
    'justify-content:center;margin-top:2px;-webkit-user-select:none;user-select:none;}' +
    '.ava-claude{background:linear-gradient(135deg,#3fdc97,#2ea9e8);color:#fff;font-size:14px;font-weight:700;}' +
    '.ava-user{background:#4a5568;color:#fff;font-size:12px;font-weight:600;}' +
    '.ava.has-img{background:#e2e4e8;overflow:hidden;}' +
    '.ava-img{width:100%;height:100%;border-radius:50%;object-fit:cover;display:block;}' +
    '.mb-claude .card{flex:1 1 auto;min-width:0;background:#fff;border:1px solid #e2e4e8;' +
    'border-radius:5px 14px 14px 14px;overflow:hidden;box-shadow:0 1px 3px rgba(20,30,40,.05);}' +
    '.mb-claude .msg-head{display:flex;align-items:center;justify-content:space-between;' +
    'padding:7px 14px;background:#fafbfc;border-bottom:1px solid #eef0f3;}' +
    '.mb-claude .msg-body{padding:10px 14px 12px;}' +
    '.msg-block.mb-user{flex-direction:row-reverse;}' +
    '.mb-user .card{max-width:84%;background:#dce8ff;color:#1a3a6b;' +
    'border-radius:16px 5px 16px 16px;padding:8px 13px;}' +
    '.msg-body p:first-child{margin-top:0}.msg-body p:last-child{margin-bottom:0}' +
    '.role{font-weight:600;font-size:11px;letter-spacing:.1em;color:#7a828c;}' +
    '.copy-btn{font-size:12px;color:#1a73e8;background:transparent;border:1px solid #c8d7f5;' +
    'border-radius:6px;padding:3px 10px;}' +
    '.copy-btn.copied{color:#1e9e63;border-color:#b4e3cd;}' +
    '.meta{color:#9aa1aa;font-size:11px;font-family:monospace;margin:10px 2px;}' +
    'pre{background:#14181d;color:#c9d4de;padding:12px;border-radius:10px;overflow-x:auto;' +
    'font-family:monospace;font-size:12px;line-height:1.45;margin:.6em 0;}' +
    'code{background:#eef0f3;padding:2px 5px;border-radius:4px;font-family:monospace;font-size:.9em;color:#1a1d21;}' +
    'pre code{background:none;padding:0;color:#7ee2ad;}' +
    'table{border-collapse:collapse;margin:.8em 0;display:block;overflow-x:auto;font-size:.92em;}' +
    'th,td{border:1px solid #e2e4e8;padding:6px 10px;text-align:left;}th{background:#fafbfc;font-weight:600;}' +
    'ul,ol{padding-left:1.5em;margin:.5em 0;}li{margin:.2em 0;}' +
    'a{color:#1a73e8;text-decoration:none;}' +
    'blockquote{border-left:3px solid #e2e4e8;padding-left:12px;margin:.6em 0;color:#5f6670;}' +
    'hr{border:none;border-top:1px solid #e2e4e8;margin:1.5em 0;}p{margin:.5em 0;}' +
    'img{max-width:100%;border-radius:8px;}' +
    'img.md-img{margin:.5em 0;display:block;}' +
    'a.md-img-fallback{word-break:break-all;}' +
    '</style></head><body><div id="content"></div><script>' +
    'function escapeHTML(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}' +
    'function decodeB64(b){var bin=atob(b);var a=new Uint8Array(bin.length);' +
    'for(var i=0;i<bin.length;i++){a[i]=bin.charCodeAt(i);}return new TextDecoder("utf-8").decode(a);}' +
    'function utf8B64(s){return btoa(unescape(encodeURIComponent(s)));}' +
    'var imgSeq=0;var imgWaiting={};' +
    'function imgLink(el,u){var a=document.createElement("a");a.href=u;a.textContent=u;' +
    'a.className="md-img-fallback";el.replaceWith(a);}' +
    'function imgFail(el){var u=el.getAttribute("src")||"";' +
    'if(el.dataset.retried||u.indexOf("data:")===0){imgLink(el,u);return;}' +
    'el.dataset.retried="1";var id="gi"+(++imgSeq);imgWaiting[id]=el;el.dataset.origsrc=u;' +
    'el.removeAttribute("src");el.alt="载入中…";' +
    'try{window.blinkNative.fetchImage(u,id);}catch(e){imgLink(el,u);}}' +
    'function imgReady(id,uri){var el=imgWaiting[id];if(!el){return;}delete imgWaiting[id];' +
    'el.alt="";el.src=uri;}' +
    'function imgGiveUp(id){var el=imgWaiting[id];if(!el){return;}delete imgWaiting[id];' +
    'imgLink(el,el.dataset.origsrc||"");}' +
    'function inline(s){s=escapeHTML(s);' +
    's=s.replace(/`([^`\\n]+)`/g,"<code>$1</code>");' +
    's=s.replace(/\\*\\*([^*\\n]+)\\*\\*/g,"<strong>$1</strong>");' +
    's=s.replace(/(https?:\\/\\/[^\\s<>"\']+)/g,\'<a href="$1">$1</a>\');' +
    's=s.replace(/<a href="([^"]+\\.(?:jpe?g|png|gif|webp|bmp|heic)(?:\\?[^"]*)?)">[^<]*<\\/a>/gi,' +
    '\'<img class="md-img" src="$1" onerror="imgFail(this)">\');' +
    'return s;}' +
    'function copyMsg(btn){try{var t=decodeB64(btn.getAttribute("data-content"));' +
    'if(window.blinkNative&&window.blinkNative.copy){window.blinkNative.copy(t);}' +
    'btn.textContent="已复制";btn.classList.add("copied");' +
    'setTimeout(function(){btn.textContent="复制";btn.classList.remove("copied");},1200);}catch(e){}}' +
    'function renderBlocks(text){var lines=text.split("\\n");var html="";var i=0;' +
    'while(i<lines.length){var line=lines[i];' +
    'if(/^[▶◆]/.test(line)){var isUser=/^▶/.test(line);i++;var body=[];' +
    'while(i<lines.length&&!/^[▶◆]/.test(lines[i])&&!/^=== /.test(lines[i])){body.push(lines[i]);i++;}' +
    'while(body.length&&body[body.length-1].trim()===""){body.pop();}' +
    'var raw=body.join("\\n");var inner=renderBlocks(raw);' +
    'var head=isUser?"":(\'<div class="msg-head"><span class="role">\'+(CLAUDE_NAME||"CLAUDE")+"</span>"+' +
    '\'<button class="copy-btn" data-content="\'+utf8B64(raw)+\'" onclick="copyMsg(this)">复制</button></div>\');' +
    'var ava=isUser?\'<div class="ava ava-user">我</div>\'' +
    ':(AVA_CLAUDE?\'<div class="ava has-img"><img class="ava-img" src="\'+AVA_CLAUDE+\'"></div>\'' +
    ':\'<div class="ava ava-claude">\'+(CLAUDE_NAME?CLAUDE_NAME.charAt(0).toUpperCase():"C")+"</div>");' +
    'html+=\'<div class="msg-block \'+(isUser?"mb-user":"mb-claude")+\'">\'+ava+\'<div class="card">\'+head+' +
    '\'<div class="msg-body">\'+inner+"</div></div></div>";continue;}' +
    'if(/^```/.test(line)){var code=[];i++;' +
    'while(i<lines.length&&!/^```/.test(lines[i])){code.push(lines[i]);i++;}i++;' +
    'html+="<pre><code>"+escapeHTML(code.join("\\n"))+"</code></pre>";continue;}' +
    'if(/^=== /.test(line)){html+=\'<div class="meta">\'+escapeHTML(line)+"</div>";i++;continue;}' +
    'var h=line.match(/^(#{1,6})\\s+(.+)$/);' +
    'if(h){var lv=h[1].length;html+="<h"+lv+">"+inline(h[2])+"</h"+lv+">";i++;continue;}' +
    'if(/^\\|.*\\|\\s*$/.test(line)&&i+1<lines.length&&/^\\|[\\s\\-:|]+\\|\\s*$/.test(lines[i+1])){' +
    'var hc=line.split("|").slice(1,-1);i+=2;var rows=[];' +
    'while(i<lines.length&&/^\\|.*\\|\\s*$/.test(lines[i])){rows.push(lines[i].split("|").slice(1,-1));i++;}' +
    'var t="<table><thead><tr>";for(var a=0;a<hc.length;a++){t+="<th>"+inline(hc[a].trim())+"</th>";}' +
    't+="</tr></thead><tbody>";for(var r=0;r<rows.length;r++){t+="<tr>";' +
    'for(var c=0;c<rows[r].length;c++){t+="<td>"+inline(rows[r][c].trim())+"</td>";}t+="</tr>";}' +
    'html+=t+"</tbody></table>";continue;}' +
    'if(/^\\s*[-*]\\s+/.test(line)||/^\\s*\\d+\\.\\s+/.test(line)){' +
    'var ordered=/^\\s*\\d+\\.\\s+/.test(line);var items=[];' +
    'while(i<lines.length&&(/^\\s*[-*]\\s+/.test(lines[i])||/^\\s*\\d+\\.\\s+/.test(lines[i]))){' +
    'var mm=lines[i].match(/^\\s*(?:[-*]|\\d+\\.)\\s+(.*)$/);items.push(mm?mm[1]:lines[i]);i++;}' +
    'html+=(ordered?"<ol>":"<ul>");for(var k=0;k<items.length;k++){html+="<li>"+inline(items[k])+"</li>";}' +
    'html+=(ordered?"</ol>":"</ul>");continue;}' +
    'if(/^>\\s+/.test(line)){var q=[];' +
    'while(i<lines.length&&/^>\\s+/.test(lines[i])){q.push(lines[i].replace(/^>\\s+/,""));i++;}' +
    'html+="<blockquote>"+inline(q.join(" "))+"</blockquote>";continue;}' +
    'if(line.trim()===""){i++;continue;}' +
    'var para=line;i++;' +
    'while(i<lines.length&&lines[i].trim()!==""&&' +
    '!/^(```|▶|◆|=== |#{1,6}\\s|\\s*[-*]\\s|\\s*\\d+\\.\\s|>\\s|\\|.*\\|\\s*$)/.test(lines[i])){para+=" "+lines[i];i++;}' +
    'html+="<p>"+inline(para)+"</p>";}' +
    'return html;}' +
    'var RAW=decodeB64("';
  const p2: string = '");var AVA_CLAUDE="';
  const p3: string = '";var CLAUDE_NAME="';
  const p4: string = '";' +
    'document.documentElement.style.opacity="0";' +
    'function reveal(){document.documentElement.style.opacity="1";}' +
    'setTimeout(reveal,400);' +
    'function scrollToBottom(){window.scrollTo(0,document.documentElement.scrollHeight);}' +
    'function splitTail(raw,n){var lines=raw.split("\\n");var idxs=[];' +
    'for(var i=0;i<lines.length;i++){if(/^[▶◆]/.test(lines[i])){idxs.push(i);}}' +
    'if(idxs.length<=n){return {head:"",tail:raw};}' +
    'var cut=idxs[idxs.length-n];' +
    'return {head:lines.slice(0,cut).join("\\n"),tail:lines.slice(cut).join("\\n")};}' +
    'try{' +
    'var parts=splitTail(RAW,12);' +
    'document.getElementById("content").innerHTML=renderBlocks(parts.tail);' +
    'scrollToBottom();' +
    'requestAnimationFrame(function(){scrollToBottom();reveal();});' +
    'if(parts.head){setTimeout(function(){var div=document.createElement("div");' +
    'div.innerHTML=renderBlocks(parts.head);var c=document.getElementById("content");' +
    'var before=document.documentElement.scrollHeight;var y=window.scrollY;' +
    'while(div.lastChild){c.insertBefore(div.lastChild,c.firstChild);}' +
    'var delta=document.documentElement.scrollHeight-before;window.scrollTo(0,y+delta);},80);}' +
    'setTimeout(scrollToBottom,300);' +
    '}catch(e){reveal();document.getElementById("content").textContent="渲染失败: "+e.message;}' +
    '</script></body></html>';
  return p1 + payloadB64 + p2 + avatarURI + p3 + safeName + p4;
}
