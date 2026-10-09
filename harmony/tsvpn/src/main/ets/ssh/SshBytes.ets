const UTF8_MAX: number = 0x10FFFF;

export function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], off);
    off += parts[i].length;
  }
  return out;
}

export function utf8Encode(text: string): Uint8Array {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let cp = text.charCodeAt(i);
    if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        cp = 0x10000 + ((cp - 0xD800) << 10) + (next - 0xDC00);
        i++;
      }
    }
    if (cp < 0x80) {
      bytes.push(cp);
    } else if (cp < 0x800) {
      bytes.push(0xC0 | (cp >>> 6));
      bytes.push(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      bytes.push(0xE0 | (cp >>> 12));
      bytes.push(0x80 | ((cp >>> 6) & 0x3F));
      bytes.push(0x80 | (cp & 0x3F));
    } else if (cp <= UTF8_MAX) {
      bytes.push(0xF0 | (cp >>> 18));
      bytes.push(0x80 | ((cp >>> 12) & 0x3F));
      bytes.push(0x80 | ((cp >>> 6) & 0x3F));
      bytes.push(0x80 | (cp & 0x3F));
    }
  }
  return new Uint8Array(bytes);
}

/** Incremental UTF-8 decoder. Incomplete tails are held until the next chunk. */
export class Utf8Decoder {
  private pending: Uint8Array = new Uint8Array(0);

  decode(chunk: Uint8Array, end: boolean): string {
    const data = this.pending.length === 0 ? chunk : concatBytes([this.pending, chunk]);
    this.pending = new Uint8Array(0);
    let i = 0;
    let out = '';
    while (i < data.length) {
      const b0 = data[i];
      let need = 1;
      let cp = 0;
      if (b0 < 0x80) {
        cp = b0;
      } else if ((b0 & 0xE0) === 0xC0) {
        need = 2;
        cp = b0 & 0x1F;
      } else if ((b0 & 0xF0) === 0xE0) {
        need = 3;
        cp = b0 & 0x0F;
      } else if ((b0 & 0xF8) === 0xF0) {
        need = 4;
        cp = b0 & 0x07;
      } else {
        out += String.fromCharCode(b0);
        i++;
        continue;
      }
      if (i + need > data.length) {
        if (end) {
          out += '\uFFFD';
          break;
        }
        this.pending = data.slice(i);
        break;
      }
      let ok = true;
      for (let k = 1; k < need; k++) {
        const bx = data[i + k];
        if ((bx & 0xC0) !== 0x80) {
          ok = false;
          break;
        }
        cp = (cp << 6) | (bx & 0x3F);
      }
      if (!ok || cp > UTF8_MAX) {
        out += String.fromCharCode(b0);
        i++;
        continue;
      }
      if (cp < 0x10000) {
        out += String.fromCharCode(cp);
      } else {
        const u = cp - 0x10000;
        out += String.fromCharCode(0xD800 + (u >>> 10), 0xDC00 + (u & 0x3FF));
      }
      i += need;
    }
    return out;
  }
}

export class ByteWriter {
  private parts: Uint8Array[] = [];
  private len: number = 0;

  u8(v: number): ByteWriter {
    const b = new Uint8Array(1);
    b[0] = v & 0xFF;
    return this.raw(b);
  }

  u32(v: number): ByteWriter {
    const b = new Uint8Array(4);
    b[0] = (v >>> 24) & 0xFF;
    b[1] = (v >>> 16) & 0xFF;
    b[2] = (v >>> 8) & 0xFF;
    b[3] = v & 0xFF;
    return this.raw(b);
  }

  raw(b: Uint8Array): ByteWriter {
    this.parts.push(b);
    this.len += b.length;
    return this;
  }

  strBytes(b: Uint8Array): ByteWriter {
    this.u32(b.length);
    return this.raw(b);
  }

  str(text: string): ByteWriter {
    return this.strBytes(utf8Encode(text));
  }

  /** SSH mpint from an unsigned big-endian integer. */
  mpint(be: Uint8Array): ByteWriter {
    let start = 0;
    while (start < be.length - 1 && be[start] === 0) {
      start++;
    }
    let body = be.slice(start);
    if (body.length === 1 && body[0] === 0) {
      body = new Uint8Array(0);
    } else if (body.length > 0 && (body[0] & 0x80) !== 0) {
      const padded = new Uint8Array(body.length + 1);
      padded.set(body, 1);
      body = padded;
    }
    return this.strBytes(body);
  }

  toBytes(): Uint8Array {
    return concatBytes(this.parts);
  }

  size(): number {
    return this.len;
  }
}

export class ByteReader {
  private data: Uint8Array;
  private off: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  remaining(): number {
    return this.data.length - this.off;
  }

  u8(): number {
    if (this.off >= this.data.length) {
      throw new Error('SSH 报文截断');
    }
    const v = this.data[this.off];
    this.off++;
    return v;
  }

  u32(): number {
    if (this.off + 4 > this.data.length) {
      throw new Error('SSH 报文截断');
    }
    const v = ((this.data[this.off] << 24) | (this.data[this.off + 1] << 16) |
      (this.data[this.off + 2] << 8) | this.data[this.off + 3]) >>> 0;
    this.off += 4;
    return v;
  }

  bool(): boolean {
    return this.u8() !== 0;
  }

  bytes(n: number): Uint8Array {
    if (n < 0 || this.off + n > this.data.length) {
      throw new Error('SSH 报文截断');
    }
    const out = this.data.slice(this.off, this.off + n);
    this.off += n;
    return out;
  }

  str(): Uint8Array {
    const n = this.u32();
    return this.bytes(n);
  }

  text(): string {
    const raw = this.str();
    const dec = new Utf8Decoder();
    return dec.decode(raw, true);
  }

  rest(): Uint8Array {
    return this.bytes(this.remaining());
  }
}

export function beFromBytes(data: Uint8Array): bigint {
  let n = 0n;
  for (let i = 0; i < data.length; i++) {
    n = (n << 8n) | BigInt(data[i]);
  }
  return n;
}

export function leToFixed(n: bigint, len: number): Uint8Array {
  const out = new Uint8Array(len);
  let x = n;
  for (let i = 0; i < len; i++) {
    out[i] = Number(x & 0xffn);
    x = x >> 8n;
  }
  return out;
}

export function leToBigint(data: Uint8Array): bigint {
  let n = 0n;
  for (let i = data.length - 1; i >= 0; i--) {
    n = (n << 8n) | BigInt(data[i]);
  }
  return n;
}

export function eqBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function base64(data: Uint8Array): string {
  let out = '';
  for (let i = 0; i < data.length; i += 3) {
    const b0 = data[i];
    const b1 = i + 1 < data.length ? data[i + 1] : 0;
    const b2 = i + 2 < data.length ? data[i + 2] : 0;
    out += B64.charAt(b0 >>> 2);
    out += B64.charAt(((b0 & 3) << 4) | (b1 >>> 4));
    if (i + 1 < data.length) {
      out += B64.charAt(((b1 & 15) << 2) | (b2 >>> 6));
    }
    if (i + 2 < data.length) {
      out += B64.charAt(b2 & 63);
    }
  }
  return out;
}
