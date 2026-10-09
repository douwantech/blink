import { BusinessError } from '@kit.BasicServicesKit';
import { connection, socket } from '@kit.NetworkKit';
import {
  ByteReader, ByteWriter, concatBytes, eqBytes, utf8Encode, Utf8Decoder
} from './SshBytes';
import {
  X25519Key, addCounter, aes128Ctr, ed25519Verify, ensureSshCrypto, errText,
  fingerprint, hmacSha256, randomBytes, rsaPkcs1Verify, sha256
} from './SshCrypto';
import { beFromBytes } from './SshBytes';
import { SshIdentity } from './SshIdentity';

function socketError(error: Object): Error {
  let e: BusinessError = error as BusinessError;
  return new Error(`sync error, ${e.code}, ${e.message}`);
}

const CLIENT_ID: string = 'SSH-2.0-TermArk_1.0';
const LOCAL_WINDOW: number = 2 * 1024 * 1024;
const MAX_PACKET: number = 32768;
const DATA_CHUNK: number = 16384;
const MAC_LEN: number = 32;
const BLOCK: number = 16;

const MSG_DISCONNECT: number = 1;
const MSG_IGNORE: number = 2;
const MSG_UNIMPLEMENTED: number = 3;
const MSG_DEBUG: number = 4;
const MSG_SERVICE_REQUEST: number = 5;
const MSG_SERVICE_ACCEPT: number = 6;
const MSG_EXT_INFO: number = 7;
const MSG_KEXINIT: number = 20;
const MSG_NEWKEYS: number = 21;
const MSG_KEX_ECDH_REPLY: number = 31;
const MSG_USERAUTH_REQUEST: number = 50;
const MSG_USERAUTH_FAILURE: number = 51;
const MSG_USERAUTH_SUCCESS: number = 52;
const MSG_USERAUTH_BANNER: number = 53;
const MSG_GLOBAL_REQUEST: number = 80;
const MSG_REQUEST_FAILURE: number = 82;
const MSG_CHANNEL_OPEN: number = 90;
const MSG_CHANNEL_OPEN_CONFIRMATION: number = 91;
const MSG_CHANNEL_OPEN_FAILURE: number = 92;
const MSG_CHANNEL_WINDOW_ADJUST: number = 93;
const MSG_CHANNEL_DATA: number = 94;
const MSG_CHANNEL_EXTENDED_DATA: number = 95;
const MSG_CHANNEL_EOF: number = 96;
const MSG_CHANNEL_CLOSE: number = 97;
const MSG_CHANNEL_REQUEST: number = 98;
const MSG_CHANNEL_SUCCESS: number = 99;
const MSG_CHANNEL_FAILURE: number = 100;

class DirKeys {
  iv: Uint8Array = new Uint8Array(BLOCK);
  enc: Uint8Array = new Uint8Array(BLOCK);
  mac: Uint8Array = new Uint8Array(32);
  seq: number = 0;
  on: boolean = false;
}

export class SshTarget {
  host: string = '';
  port: number = 22;
  username: string = '';
  command: string = '';
}

export class SshSession {
  onOutput: (text: string) => void = () => {};
  onDataBytes: (data: Uint8Array) => void = () => {};
  onClosed: (reason: string) => void = () => {};
  onReady: () => void = () => {};
  onHostKey: (hostKey: Uint8Array, fingerprint: string) => Promise<boolean> =
    (_hostKey: Uint8Array, _fingerprint: string): Promise<boolean> => Promise.resolve(false);

  private target: SshTarget = new SshTarget();
  private tcp: socket.TCPSocket | null = null;
  private sendChain: Promise<void> = Promise.resolve();
  private closed: boolean = false;
  private bannerDone: boolean = false;
  private serverId: string = '';
  private phase: string = 'banner';
  private rekey: boolean = false;
  private rx: Uint8Array = new Uint8Array(0);
  private outKeys: DirKeys = new DirKeys();
  private inKeys: DirKeys = new DirKeys();
  private clientKex: Uint8Array = new Uint8Array(0);
  private serverKex: Uint8Array = new Uint8Array(0);
  private ecdh: X25519Key | null = null;
  private nextOut: DirKeys = new DirKeys();
  private nextIn: DirKeys = new DirKeys();
  private kMpint: Uint8Array = new Uint8Array(0);
  private exchangeHash: Uint8Array = new Uint8Array(0);
  private sessionId: Uint8Array = new Uint8Array(0);
  private hostKeyAlg: string = '';
  private serverChan: number = -1;
  private remoteWindow: number = 0;
  private remoteMaxPacket: number = MAX_PACKET;
  private localWindow: number = LOCAL_WINDOW;
  private pendingData: Uint8Array = new Uint8Array(0);
  private decoder: Utf8Decoder = new Utf8Decoder();
  cols: number = 80;
  rows: number = 24;
  private ptyCols: number = 80;
  private ptyRows: number = 24;

  connect(target: SshTarget): void {
    if (this.tcp !== null || this.closed) {
      return;
    }
    this.target = target;
    this.say(`\r\n\x1b[36m正在连接 ${target.host}:${target.port} …\x1b[0m\r\n`);
    this.openSocket(target).catch((e: Object) => {
      this.fail(errText(e));
    });
  }

  send(text: string): void {
    if (this.closed || text.length === 0) {
      return;
    }
    this.pendingData = concatBytes([this.pendingData, utf8Encode(text)]);
    this.flushData();
  }

  sendBytes(data: Uint8Array): void {
    if (this.closed || data.length === 0) {
      return;
    }
    this.pendingData = concatBytes([this.pendingData, data]);
    this.flushData();
  }

  resize(cols: number, rows: number): void {
    if (cols < 1 || rows < 1) {
      return;
    }
    this.cols = cols;
    this.rows = rows;
    if (this.phase !== 'ready' || this.serverChan < 0) {
      return;
    }
    if (cols === this.ptyCols && rows === this.ptyRows) {
      return;
    }
    this.ptyCols = cols;
    this.ptyRows = rows;
    const w = new ByteWriter();
    w.u8(MSG_CHANNEL_REQUEST);
    w.u32(this.serverChan);
    w.str('window-change');
    w.u8(0);
    w.u32(cols);
    w.u32(rows);
    w.u32(0);
    w.u32(0);
    this.sendPayload(w.toBytes());
  }

  close(): void {
    if (this.closed) {
      return;
    }
    if (this.tcp !== null && this.bannerDone) {
      const w = new ByteWriter();
      w.u8(MSG_DISCONNECT);
      w.u32(11);
      w.str('closed');
      w.str('');
      try {
        this.sendPayload(w.toBytes());
      } catch (_e) {
      }
    }
    this.fail('已断开');
  }

  private say(text: string): void {
    this.onOutput(text);
  }

  private async openSocket(target: SshTarget): Promise<void> {
    ensureSshCrypto();
    let addrs: connection.NetAddress[];
    try {
      addrs = await connection.getAddressesByName(target.host);
    } catch (error) {
      throw socketError(error);
    }
    if (addrs.length === 0) {
      throw new Error('无法解析主机');
    }
    let picked = addrs[0];
    for (let i = 0; i < addrs.length; i++) {
      if (addrs[i].family === 1 || addrs[i].family === undefined) {
        picked = addrs[i];
        break;
      }
    }
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onSocket(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.fail('连接已关闭');
    });
    tcp.on('error', () => {
      this.fail('网络错误');
    });
    try {
      await tcp.bind({ address: '0.0.0.0', port: 0, family: 1 });
    } catch (error) {
      throw socketError(error);
    }
    const family = picked.family !== undefined ? picked.family : 1;
    try {
      await tcp.connect({
        address: { address: picked.address, port: target.port, family: family },
        timeout: 10000
      });
    } catch (error) {
      throw socketError(error);
    }
    this.writeRaw(utf8Encode(`${CLIENT_ID}\r\n`));
  }

  private onSocket(chunk: Uint8Array): void {
    if (this.closed) {
      return;
    }
    try {
      this.rx = concatBytes([this.rx, chunk]);
      if (this.rx.length > 1024 * 1024) {
        this.fail('报文过大');
        return;
      }
      if (!this.bannerDone) {
        if (!this.consumeBanner()) {
          return;
        }
      }
      this.pump();
    } catch (e) {
      this.fail(errText(e));
    }
  }

  private consumeBanner(): boolean {
    while (true) {
      let nl = -1;
      const limit = Math.min(this.rx.length, 255);
      for (let i = 0; i < limit; i++) {
        if (this.rx[i] === 10) {
          nl = i;
          break;
        }
      }
      if (nl < 0) {
        if (this.rx.length > 255) {
          throw new Error('SSH 版本行过长');
        }
        return false;
      }
      let line = this.rx.slice(0, nl);
      this.rx = this.rx.slice(nl + 1);
      if (line.length > 0 && line[line.length - 1] === 13) {
        line = line.slice(0, line.length - 1);
      }
      const text = new Utf8Decoder().decode(line, true);
      if (text.indexOf('SSH-') === 0) {
        this.serverId = text;
        this.bannerDone = true;
        this.sendKexInit();
        this.phase = 'kexinit';
        return true;
      }
    }
  }

  private pump(): void {
    while (this.phase !== 'host-trust' && this.pullPacket()) {
    }
  }

  private pullPacket(): boolean {
    if (!this.inKeys.on) {
      if (this.rx.length < 4) {
        return false;
      }
      const packetLen = this.u32at(this.rx, 0);
      if (!this.validLen(packetLen, 8)) {
        throw new Error('SSH 明文包长度非法');
      }
      const total = 4 + packetLen;
      if (this.rx.length < total) {
        return false;
      }
      const packet = this.rx.slice(0, total);
      this.rx = this.rx.slice(total);
      this.dispatch(packet);
      this.inKeys.seq++;
      return true;
    }
    if (this.rx.length < BLOCK) {
      return false;
    }
    const first = aes128Ctr(this.inKeys.enc, this.inKeys.iv, this.rx.slice(0, BLOCK));
    const packetLen = this.u32at(first, 0);
    if (!this.validLen(packetLen, BLOCK)) {
      throw new Error('SSH 密文包长度非法');
    }
    const total = 4 + packetLen;
    if (this.rx.length < total + MAC_LEN) {
      return false;
    }
    const enc = this.rx.slice(0, total);
    const mac = this.rx.slice(total, total + MAC_LEN);
    this.rx = this.rx.slice(total + MAC_LEN);
    let plain = first;
    if (total > BLOCK) {
      const rest = aes128Ctr(this.inKeys.enc, addCounter(this.inKeys.iv, 1), enc.slice(BLOCK));
      plain = concatBytes([first, rest]);
    }
    this.inKeys.iv = addCounter(this.inKeys.iv, total / BLOCK);
    const macIn = new ByteWriter().u32(this.inKeys.seq).raw(plain).toBytes();
    if (!eqBytes(hmacSha256(this.inKeys.mac, macIn), mac)) {
      throw new Error('SSH MAC 校验失败');
    }
    this.dispatch(plain);
    this.inKeys.seq++;
    return true;
  }

  private validLen(packetLen: number, bs: number): boolean {
    if (packetLen < 5 || packetLen > 256 * 1024) {
      return false;
    }
    return ((4 + packetLen) % bs) === 0;
  }

  private u32at(b: Uint8Array, off: number): number {
    return ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) >>> 0;
  }

  private dispatch(packet: Uint8Array): void {
    const pad = packet[4];
    if (pad < 4 || 5 + pad > packet.length) {
      throw new Error('SSH padding 非法');
    }
    const payload = packet.slice(5, packet.length - pad);
    if (payload.length === 0) {
      throw new Error('SSH 空载荷');
    }
    const type = payload[0];
    if (type === MSG_IGNORE || type === MSG_UNIMPLEMENTED || type === MSG_DEBUG || type === MSG_EXT_INFO) {
      return;
    }
    if (type === MSG_DISCONNECT) {
      const r = new ByteReader(payload.slice(1));
      r.u32();
      const desc = r.text();
      throw new Error(desc.length > 0 ? desc : '对方断开');
    }
    if (type === MSG_KEXINIT) {
      this.onKexInit(payload);
      return;
    }
    if (type === MSG_KEX_ECDH_REPLY) {
      this.onKexReply(payload);
      return;
    }
    if (type === MSG_NEWKEYS) {
      this.onNewKeys();
      return;
    }
    if (type === MSG_SERVICE_ACCEPT) {
      this.onServiceAccept();
      return;
    }
    if (type === MSG_USERAUTH_BANNER) {
      const r = new ByteReader(payload.slice(1));
      this.say(r.text());
      return;
    }
    if (type === MSG_USERAUTH_FAILURE) {
      throw new Error('SSH 公钥认证失败，请将本机公钥加入服务器 authorized_keys');
    }
    if (type === MSG_USERAUTH_SUCCESS) {
      this.onAuthOk();
      return;
    }
    if (type === MSG_CHANNEL_OPEN_CONFIRMATION) {
      this.onOpenOk(payload);
      return;
    }
    if (type === MSG_CHANNEL_OPEN_FAILURE) {
      throw new Error('无法打开会话');
    }
    if (type === MSG_CHANNEL_WINDOW_ADJUST) {
      const r = new ByteReader(payload.slice(1));
      r.u32();
      this.remoteWindow += r.u32();
      this.flushData();
      return;
    }
    if (type === MSG_CHANNEL_DATA || type === MSG_CHANNEL_EXTENDED_DATA) {
      this.onData(payload);
      return;
    }
    if (type === MSG_CHANNEL_EOF || type === MSG_CHANNEL_CLOSE) {
      this.fail('会话结束');
      return;
    }
    if (type === MSG_CHANNEL_SUCCESS) {
      this.onChanOk();
      return;
    }
    if (type === MSG_CHANNEL_FAILURE) {
      throw new Error('远程拒绝了终端请求');
    }
    if (type === MSG_GLOBAL_REQUEST) {
      const r = new ByteReader(payload.slice(1));
      r.text();
      if (r.bool()) {
        this.sendPayload(new Uint8Array([MSG_REQUEST_FAILURE]));
      }
      return;
    }
    if (type === MSG_CHANNEL_REQUEST) {
      this.onChanRequest(payload);
      return;
    }
    if (type === MSG_CHANNEL_OPEN) {
      this.rejectOpen(payload);
      return;
    }
  }

  private sendKexInit(): void {
    const payload = this.buildKexInit();
    this.clientKex = payload;
    this.sendPayload(payload);
  }

  private buildKexInit(): Uint8Array {
    const w = new ByteWriter();
    w.u8(MSG_KEXINIT);
    w.raw(randomBytes(16));
    w.str('curve25519-sha256,curve25519-sha256@libssh.org');
    w.str('ssh-ed25519,rsa-sha2-512,rsa-sha2-256');
    w.str('aes128-ctr');
    w.str('aes128-ctr');
    w.str('hmac-sha2-256');
    w.str('hmac-sha2-256');
    w.str('none');
    w.str('none');
    w.str('');
    w.str('');
    w.u8(0);
    w.u32(0);
    return w.toBytes();
  }

  private onKexInit(payload: Uint8Array): void {
    if (this.phase !== 'kexinit' && this.phase !== 'ready') {
      throw new Error('意外的密钥交换');
    }
    this.serverKex = payload;
    const r = new ByteReader(payload.slice(1 + 16));
    const kex = this.pick('curve25519-sha256,curve25519-sha256@libssh.org', r.text());
    this.hostKeyAlg = this.pick('ssh-ed25519,rsa-sha2-512,rsa-sha2-256', r.text());
    const encOut = this.pick('aes128-ctr', r.text());
    const encIn = this.pick('aes128-ctr', r.text());
    const macOut = this.pick('hmac-sha2-256', r.text());
    const macIn = this.pick('hmac-sha2-256', r.text());
    const cmpOut = this.pick('none', r.text());
    const cmpIn = this.pick('none', r.text());
    r.text();
    r.text();
    if (kex.length === 0 || this.hostKeyAlg.length === 0 || encOut.length === 0 || encIn.length === 0 ||
      macOut.length === 0 || macIn.length === 0 || cmpOut.length === 0 || cmpIn.length === 0) {
      throw new Error('没有共同的 SSH 算法');
    }
    if (this.phase === 'ready') {
      this.rekey = true;
      this.sendKexInit();
    }
    this.ecdh = X25519Key.generate();
    const w = new ByteWriter();
    w.u8(30);
    w.strBytes(this.ecdh.pub);
    this.sendPayload(w.toBytes());
    this.phase = this.rekey ? 'rekey-reply' : 'kex-reply';
  }

  private onKexReply(payload: Uint8Array): void {
    if ((this.phase !== 'kex-reply' && this.phase !== 'rekey-reply') || this.ecdh === null) {
      throw new Error('意外的密钥交换响应');
    }
    const r = new ByteReader(payload.slice(1));
    const hostKey = r.str();
    const peerPub = r.str();
    const sigBlob = r.str();
    const secret = this.ecdh.sharedSecret(peerPub);
    const hashIn = new ByteWriter();
    hashIn.str(CLIENT_ID);
    hashIn.str(this.serverId);
    hashIn.strBytes(this.clientKex);
    hashIn.strBytes(this.serverKex);
    hashIn.strBytes(hostKey);
    hashIn.strBytes(this.ecdh.pub);
    hashIn.strBytes(peerPub);
    hashIn.mpint(secret);
    this.kMpint = new ByteWriter().mpint(secret).toBytes();
    this.exchangeHash = sha256(hashIn.toBytes());
    if (this.sessionId.length === 0) {
      this.sessionId = this.exchangeHash;
    }
    this.checkHostKey(hostKey, sigBlob);
    // Never authenticate against a key that has not been accepted by the user.
    this.phase = 'host-trust';
    this.onHostKey(hostKey, fingerprint(hostKey)).then((trusted: boolean): void => {
      if (this.closed) {
        return;
      }
      if (!trusted) {
        this.fail('服务器主机密钥未通过验证');
        return;
      }
      this.installKeys();
      // NEWKEYS itself still uses the previous outgoing keys.
      this.sendPayload(new Uint8Array([MSG_NEWKEYS]));
      this.nextOut.seq = this.outKeys.seq;
      this.outKeys = this.nextOut;
      this.outKeys.on = true;
      this.phase = this.rekey ? 'rekey-newkeys' : 'newkeys';
      this.pump();
    }).catch((e: Object): void => this.fail(errText(e)));
  }

  private checkHostKey(hostKey: Uint8Array, sigBlob: Uint8Array): void {
    const key = new ByteReader(hostKey);
    const keyType = key.text();
    const sig = new ByteReader(sigBlob);
    const sigType = sig.text();
    const sigBytes = sig.str();
    if (sigType === 'ssh-ed25519' && keyType === 'ssh-ed25519') {
      const pub = key.str();
      if (!ed25519Verify(pub, this.exchangeHash, sigBytes)) {
        throw new Error('主机密钥签名无效');
      }
      return;
    }
    if ((sigType === 'rsa-sha2-256' || sigType === 'rsa-sha2-512') && keyType === 'ssh-rsa') {
      const e = beFromBytes(key.str());
      const n = beFromBytes(key.str());
      const hash = sigType === 'rsa-sha2-512' ? 'SHA512' : 'SHA256';
      if (!rsaPkcs1Verify(n, e, this.exchangeHash, sigBytes, hash)) {
        throw new Error('主机密钥签名无效');
      }
      return;
    }
    throw new Error(`不支持的主机密钥 ${sigType}`);
  }

  private installKeys(): void {
    const a = this.derive(65);
    const b = this.derive(66);
    const c = this.derive(67);
    const d = this.derive(68);
    const e = this.derive(69);
    const f = this.derive(70);
    this.nextOut = new DirKeys();
    this.nextIn = new DirKeys();
    this.nextOut.iv = a.slice(0, BLOCK);
    this.nextIn.iv = b.slice(0, BLOCK);
    this.nextOut.enc = c.slice(0, BLOCK);
    this.nextIn.enc = d.slice(0, BLOCK);
    this.nextOut.mac = e;
    this.nextIn.mac = f;
  }

  private derive(letter: number): Uint8Array {
    const w = new ByteWriter();
    w.raw(this.kMpint);
    w.raw(this.exchangeHash);
    w.u8(letter);
    w.raw(this.sessionId);
    return sha256(w.toBytes());
  }

  private onNewKeys(): void {
    if (this.phase !== 'newkeys' && this.phase !== 'rekey-newkeys') {
      throw new Error('意外的 NEWKEYS');
    }
    this.nextIn.seq = this.inKeys.seq;
    this.inKeys = this.nextIn;
    this.inKeys.on = true;
    if (this.rekey) {
      this.rekey = false;
      this.phase = 'ready';
      this.flushData();
      return;
    }
    const w = new ByteWriter();
    w.u8(MSG_SERVICE_REQUEST);
    w.str('ssh-userauth');
    this.sendPayload(w.toBytes());
    this.phase = 'service';
  }

  private onServiceAccept(): void {
    if (this.phase !== 'service') {
      return;
    }
    SshIdentity.publicKeyBytes().then((pub: Uint8Array): Promise<Uint8Array> => {
      const keyBlob = new ByteWriter().str('ssh-ed25519').strBytes(pub).toBytes();
      const req = new ByteWriter().u8(MSG_USERAUTH_REQUEST).str(this.target.username)
        .str('ssh-connection').str('publickey').u8(1).str('ssh-ed25519').strBytes(keyBlob).toBytes();
      const signed = new ByteWriter().strBytes(this.sessionId).raw(req).toBytes();
      return SshIdentity.sign(signed).then((sig: Uint8Array): Uint8Array => {
        const sigBlob = new ByteWriter().str('ssh-ed25519').strBytes(sig).toBytes();
        return new ByteWriter().raw(req).strBytes(sigBlob).toBytes();
      });
    }).then((request: Uint8Array): void => {
      if (!this.closed) {
        this.sendPayload(request);
        this.phase = 'auth';
      }
    }).catch((e: Object): void => this.fail(errText(e)));
  }

  private onAuthOk(): void {
    if (this.phase !== 'auth') {
      return;
    }
    this.say('\x1b[32m已登录，正在打开终端…\x1b[0m\r\n');
    const w = new ByteWriter();
    w.u8(MSG_CHANNEL_OPEN);
    w.str('session');
    w.u32(0);
    w.u32(LOCAL_WINDOW);
    w.u32(MAX_PACKET);
    this.sendPayload(w.toBytes());
    this.phase = 'open';
  }

  private onOpenOk(payload: Uint8Array): void {
    if (this.phase !== 'open') {
      return;
    }
    const r = new ByteReader(payload.slice(1));
    r.u32();
    this.serverChan = r.u32();
    this.remoteWindow = r.u32();
    this.remoteMaxPacket = r.u32();
    this.ptyCols = this.cols;
    this.ptyRows = this.rows;
    const w = new ByteWriter();
    w.u8(MSG_CHANNEL_REQUEST);
    w.u32(this.serverChan);
    w.str('pty-req');
    w.u8(1);
    w.str('xterm-256color');
    w.u32(this.cols);
    w.u32(this.rows);
    w.u32(0);
    w.u32(0);
    w.strBytes(new Uint8Array(0));
    this.sendPayload(w.toBytes());
    this.phase = 'pty';
  }

  private onChanOk(): void {
    if (this.phase === 'pty') {
      const w = new ByteWriter();
      w.u8(MSG_CHANNEL_REQUEST);
      w.u32(this.serverChan);
      w.str(this.target.command.length > 0 ? 'exec' : 'shell');
      w.u8(1);
      if (this.target.command.length > 0) {
        w.str(this.target.command);
      }
      this.sendPayload(w.toBytes());
      this.phase = 'shell';
      return;
    }
    if (this.phase === 'shell') {
      this.phase = 'ready';
      this.onReady();
      this.flushData();
    }
  }

  private onData(payload: Uint8Array): void {
    const r = new ByteReader(payload.slice(1));
    r.u32();
    if (payload[0] === MSG_CHANNEL_EXTENDED_DATA) {
      r.u32();
    }
    const data = r.str();
    this.localWindow -= data.length;
    if (this.localWindow < LOCAL_WINDOW / 2 && this.serverChan >= 0) {
      const add = LOCAL_WINDOW - this.localWindow;
      this.localWindow = LOCAL_WINDOW;
      const w = new ByteWriter();
      w.u8(MSG_CHANNEL_WINDOW_ADJUST);
      w.u32(this.serverChan);
      w.u32(add);
      this.sendPayload(w.toBytes());
    }
    const text = this.decoder.decode(data, false);
    if (text.length > 0) {
      this.onOutput(text);
    }
    this.onDataBytes(data);
  }

  private onChanRequest(payload: Uint8Array): void {
    const r = new ByteReader(payload.slice(1));
    r.u32();
    r.text();
    if (r.bool() && this.serverChan >= 0) {
      const w = new ByteWriter();
      w.u8(MSG_CHANNEL_FAILURE);
      w.u32(this.serverChan);
      this.sendPayload(w.toBytes());
    }
  }

  private rejectOpen(payload: Uint8Array): void {
    const r = new ByteReader(payload.slice(1));
    r.text();
    const their = r.u32();
    const w = new ByteWriter();
    w.u8(MSG_CHANNEL_OPEN_FAILURE);
    w.u32(their);
    w.u32(3);
    w.str('unknown channel type');
    w.str('');
    this.sendPayload(w.toBytes());
  }

  private flushData(): void {
    if (this.phase !== 'ready' || this.serverChan < 0) {
      return;
    }
    while (this.pendingData.length > 0 && this.remoteWindow > 0) {
      let n = this.pendingData.length;
      if (n > this.remoteWindow) {
        n = this.remoteWindow;
      }
      if (n > DATA_CHUNK) {
        n = DATA_CHUNK;
      }
      if (this.remoteMaxPacket > 0 && n > this.remoteMaxPacket) {
        n = this.remoteMaxPacket;
      }
      const chunk = this.pendingData.slice(0, n);
      this.pendingData = this.pendingData.slice(n);
      const w = new ByteWriter();
      w.u8(MSG_CHANNEL_DATA);
      w.u32(this.serverChan);
      w.strBytes(chunk);
      this.sendPayload(w.toBytes());
      this.remoteWindow -= n;
    }
  }

  private pick(ours: string, theirs: string): string {
    const want = ours.split(',');
    const have = theirs.split(',');
    for (let i = 0; i < want.length; i++) {
      for (let j = 0; j < have.length; j++) {
        if (want[i] === have[j]) {
          return want[i];
        }
      }
    }
    return '';
  }

  private sendPayload(payload: Uint8Array): void {
    const plain = this.pad(payload, this.outKeys.on ? BLOCK : 8);
    let body = plain;
    let mac = new Uint8Array(0);
    if (this.outKeys.on) {
      body = aes128Ctr(this.outKeys.enc, this.outKeys.iv, plain);
      this.outKeys.iv = addCounter(this.outKeys.iv, plain.length / BLOCK);
      const macIn = new ByteWriter().u32(this.outKeys.seq).raw(plain).toBytes();
      mac = hmacSha256(this.outKeys.mac, macIn);
    }
    this.outKeys.seq++;
    this.writeRaw(mac.length === 0 ? body : concatBytes([body, mac]));
  }

  private pad(payload: Uint8Array, bs: number): Uint8Array {
    let padLen = bs - ((5 + payload.length) % bs);
    if (padLen < 4) {
      padLen += bs;
    }
    const packetLen = 1 + payload.length + padLen;
    const plain = new Uint8Array(4 + packetLen);
    plain[0] = (packetLen >>> 24) & 0xFF;
    plain[1] = (packetLen >>> 16) & 0xFF;
    plain[2] = (packetLen >>> 8) & 0xFF;
    plain[3] = packetLen & 0xFF;
    plain[4] = padLen;
    plain.set(payload, 5);
    plain.set(randomBytes(padLen), 5 + payload.length);
    return plain;
  }

  private writeRaw(data: Uint8Array): void {
    const tcp = this.tcp;
    if (tcp === null || this.closed) {
      return;
    }
    const copy = new Uint8Array(data);
    const buf = copy.buffer;
    this.sendChain = this.sendChain.then(() => {
      const sock = this.tcp;
      if (this.closed || sock === null) {
        return Promise.resolve();
      }
      return sock.send({ data: buf });
    }).catch((e: Object) => {
      this.fail(errText(e));
    });
  }

  private fail(reason: string): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.phase = 'closed';
    const tcp = this.tcp;
    this.tcp = null;
    if (tcp !== null) {
      try {
        tcp.off('message');
        tcp.off('close');
        tcp.off('error');
        tcp.close();
      } catch (_e) {
      }
    }
    this.onClosed(reason);
  }
}
