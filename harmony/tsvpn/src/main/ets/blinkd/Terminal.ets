////////////////////////////////////////////////////////////////////////////////
//
// Terminal — a deliberately basic terminal model. It is enough to run line
// commands over blinkd and read their output cleanly: it handles \n \r \b \t and
// swallows ANSI/OSC escape sequences (so colours and simple prompt redraws read
// fine). It is NOT a full screen-cell emulator — full-screen TUIs (vim, tmux,
// htop) will not render correctly. That is future work (a real VT parser).
//
////////////////////////////////////////////////////////////////////////////////

import { util } from '@kit.ArkTS';

// Escape-parser states.
const ST_NORMAL: number = 0;
const ST_ESC: number = 1;   // saw ESC
const ST_CSI: number = 2;   // ESC [ … final
const ST_OSC: number = 3;   // ESC ] … BEL / ST
const ST_OSC_ESC: number = 4; // saw ESC inside OSC (maybe ST)

export class Terminal {
  private dec: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  private committed: string = '';   // scrollback: lines already terminated by \n
  private cur: string = '';         // the line currently being drawn
  private col: number = 0;          // cursor column within `cur`
  private esc: number = ST_NORMAL;
  private escBuf: string = '';       // params collected for the current CSI
  private readonly maxChars: number = 60000;

  // Feed a raw server chunk; returns the full display text.
  public feed(bytes: Uint8Array): string {
    const s: string = this.dec.decodeWithStream(bytes, { stream: true });
    for (let i = 0; i < s.length; i++) {
      this.putChar(s.charCodeAt(i), s[i]);
    }
    this.trim();
    return this.text();
  }

  public text(): string {
    return this.committed + this.cur;
  }

  public clear(): void {
    this.dec = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    this.committed = '';
    this.cur = '';
    this.col = 0;
    this.esc = ST_NORMAL;
    this.escBuf = '';
  }

  private putChar(code: number, ch: string): void {
    // --- escape-sequence handling ---
    if (this.esc === ST_ESC) {
      if (ch === '[') {
        this.esc = ST_CSI;
        this.escBuf = '';
      } else if (ch === ']') {
        this.esc = ST_OSC;
        this.escBuf = '';
      } else {
        this.esc = ST_NORMAL; // other 2-char escape: consume one char
      }
      return;
    }
    if (this.esc === ST_CSI) {
      if (code >= 0x40 && code <= 0x7e) { // final byte @…~
        this.applyCSI(ch, this.escBuf);
        this.esc = ST_NORMAL;
        this.escBuf = '';
      } else {
        this.escBuf += ch;
      }
      return;
    }
    if (this.esc === ST_OSC) {
      if (code === 0x07) {           // BEL ends OSC
        this.esc = ST_NORMAL;
      } else if (code === 0x1b) {    // maybe ST (ESC \)
        this.esc = ST_OSC_ESC;
      }
      return;
    }
    if (this.esc === ST_OSC_ESC) {
      this.esc = ST_NORMAL;          // end OSC regardless of the next char
      return;
    }

    // --- normal bytes ---
    if (code === 0x1b) {             // ESC
      this.esc = ST_ESC;
    } else if (code === 0x0a) {      // \n
      this.newline();
    } else if (code === 0x0d) {      // \r
      this.col = 0;
    } else if (code === 0x08) {      // backspace
      if (this.col > 0) {
        this.col--;
      }
    } else if (code === 0x09) {      // tab → spaces to next multiple of 8
      const next: number = this.col - (this.col % 8) + 8;
      while (this.col < next) {
        this.writeCh(' ');
      }
    } else if (code >= 0x20) {       // printable (drop remaining control chars)
      this.writeCh(ch);
    }
  }

  private writeCh(ch: string): void {
    if (this.col < this.cur.length) {
      this.cur = this.cur.substring(0, this.col) + ch + this.cur.substring(this.col + 1);
    } else {
      while (this.cur.length < this.col) {
        this.cur += ' ';
      }
      this.cur += ch;
    }
    this.col++;
  }

  private newline(): void {
    this.committed += this.cur + '\n';
    this.cur = '';
    this.col = 0;
  }

  // Erase-in-line only; other CSI (cursor moves, SGR colours) are ignored here.
  private applyCSI(final: string, params: string): void {
    if (final !== 'K') {
      return;
    }
    const p: number = params.length === 0 ? 0 : parseInt(params);
    if (p === 0) {                              // cursor → end of line
      this.cur = this.cur.substring(0, this.col);
    } else if (p === 1) {                       // start → cursor
      const tail: string = this.cur.substring(this.col);
      let pad: string = '';
      for (let i = 0; i < this.col; i++) {
        pad += ' ';
      }
      this.cur = pad + tail;
    } else if (p === 2) {                       // whole line
      this.cur = '';
      this.col = 0;
    }
  }

  private trim(): void {
    if (this.committed.length <= this.maxChars) {
      return;
    }
    this.committed = this.committed.substring(this.committed.length - this.maxChars);
    const nl: number = this.committed.indexOf('\n');
    if (nl >= 0) {
      this.committed = this.committed.substring(nl + 1);
    }
  }
}
