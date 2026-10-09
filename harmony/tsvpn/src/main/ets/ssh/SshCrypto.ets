import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { base64, eqBytes, leToBigint, leToFixed } from './SshBytes';

const AES_BLOCK: number = 16;
const X25519_LEN: number = 32;
const ED25519_LEN: number = 32;
const ED25519_SIG_LEN: number = 64;
const CRYPTO_SYSCAP: string = 'SystemCapability.Security.CryptoFramework';

let hmacMacAlg: string = '';
let hmacKeyAlg: string = '';
let edVerifyAlg: string = '';
let cryptoReady: boolean = false;

function requireCryptoFramework(): void {
  if (!canIUse(CRYPTO_SYSCAP)) {
    throw new Error('CryptoFramework unsupported on this device');
  }
}

function blob(data: Uint8Array): cryptoFramework.DataBlob {
  return { data: data };
}

function copyOut(src: cryptoFramework.DataBlob): Uint8Array {
  return new Uint8Array(src.data);
}

function cryptoError(error: Object): Error {
  let e: BusinessError = error as BusinessError;
  return new Error(`sync error, ${e.code}, ${e.message}`);
}

export function errText(e: Object): string {
  try {
    const err = e as Error;
    if (err.message.length > 0) {
      return err.message;
    }
  } catch (_ignored) {
  }
  return '未知错误';
}

export function randomBytes(n: number): Uint8Array {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    let rand: cryptoFramework.Random;
    try {
      rand = cryptoFramework.createRandom();
    } catch (error) {
      throw cryptoError(error);
    }
    let randData: cryptoFramework.DataBlob | null = null;
    try {
      randData = rand.generateRandomSync(n);
    } catch (error) {
      throw cryptoError(error);
    }
    if (randData != null) {
      return copyOut(randData);
    }
    throw new Error('get rand result fail');
  }
  throw new Error('CryptoFramework unsupported on this device');
}

export function sha256(data: Uint8Array): Uint8Array {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    try {
      const md = cryptoFramework.createMd('SHA256');
      if (data.length > 0) {
        md.updateSync(blob(data));
      }
      return copyOut(md.digestSync());
    } catch (error) {
      throw cryptoError(error);
    }
  }
  throw new Error('CryptoFramework unsupported on this device');
}

function hmacOnce(macAlg: string, keyAlg: string, key: Uint8Array, data: Uint8Array): Uint8Array {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    try {
      const mac = cryptoFramework.createMac(macAlg);
      const gen = cryptoFramework.createSymKeyGenerator(keyAlg);
      const sym = gen.convertKeySync(blob(key));
      mac.initSync(sym);
      mac.updateSync(blob(data));
      return copyOut(mac.doFinalSync());
    } catch (error) {
      throw cryptoError(error);
    }
  }
  throw new Error('CryptoFramework unsupported on this device');
}

export function hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
  if (hmacMacAlg.length === 0) {
    throw new Error('HMAC 未初始化');
  }
  return hmacOnce(hmacMacAlg, hmacKeyAlg, key, data);
}

function aesCtrOnce(key: Uint8Array, iv: Uint8Array, data: Uint8Array): Uint8Array {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    try {
      const cipher = cryptoFramework.createCipher('AES128|CTR|NoPadding');
      const gen = cryptoFramework.createSymKeyGenerator('AES128');
      const sym = gen.convertKeySync(blob(key));
      const params: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: blob(iv)
      };
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, sym, params);
      return copyOut(cipher.doFinalSync(blob(data)));
    } catch (error) {
      throw cryptoError(error);
    }
  }
  throw new Error('CryptoFramework unsupported on this device');
}

/** AES-128-CTR. IV is the initial counter and is not modified. */
export function aes128Ctr(key: Uint8Array, iv: Uint8Array, data: Uint8Array): Uint8Array {
  return aesCtrOnce(key, iv, data);
}

export function addCounter(iv: Uint8Array, blocks: number): Uint8Array {
  const out = new Uint8Array(iv);
  let carry = blocks;
  for (let i = AES_BLOCK - 1; i >= 0 && carry > 0; i--) {
    const sum = out[i] + (carry & 0xFF);
    out[i] = sum & 0xFF;
    carry = (carry >>> 8) + (sum >>> 8);
  }
  return out;
}

export class X25519Key {
  pub: Uint8Array = new Uint8Array(0);
  private pair: cryptoFramework.KeyPair | null = null;

  static generate(): X25519Key {
    requireCryptoFramework();
    if (canIUse(CRYPTO_SYSCAP)) {
      try {
        const gen = cryptoFramework.createAsyKeyGenerator('X25519');
        const pair = gen.generateKeyPairSync();
        const pk = pair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.X25519_PK_BN) as bigint;
        const key = new X25519Key();
        key.pair = pair;
        key.pub = leToFixed(pk, X25519_LEN);
        return key;
      } catch (error) {
        throw cryptoError(error);
      }
    }
    throw new Error('CryptoFramework unsupported on this device');
  }

  sharedSecret(peerPub: Uint8Array): Uint8Array {
    const localPair = this.pair;
    if (localPair === null || peerPub.length !== X25519_LEN) {
      throw new Error('X25519 公钥无效');
    }
    requireCryptoFramework();
    if (canIUse(CRYPTO_SYSCAP)) {
      const spec: cryptoFramework.X25519PubKeySpec = {
        algName: 'X25519',
        specType: cryptoFramework.AsyKeySpecType.PUBLIC_KEY_SPEC,
        pk: leToBigint(peerPub)
      };
      try {
        const peer = cryptoFramework.createAsyKeyGeneratorBySpec(spec).generatePubKeySync();
        const agree = cryptoFramework.createKeyAgreement('X25519');
        return copyOut(agree.generateSecretSync(localPair.priKey, peer));
      } catch (error) {
        throw cryptoError(error);
      }
    }
    throw new Error('CryptoFramework unsupported on this device');
  }
}

function edPubKey(pk: Uint8Array): cryptoFramework.PubKey {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    const spec: cryptoFramework.ED25519PubKeySpec = {
      algName: 'Ed25519',
      specType: cryptoFramework.AsyKeySpecType.PUBLIC_KEY_SPEC,
      pk: leToBigint(pk)
    };
    try {
      return cryptoFramework.createAsyKeyGeneratorBySpec(spec).generatePubKeySync();
    } catch (error) {
      throw cryptoError(error);
    }
  }
  throw new Error('CryptoFramework unsupported on this device');
}

export function ed25519Verify(pub: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean {
  if (pub.length !== ED25519_LEN || signature.length !== ED25519_SIG_LEN) {
    return false;
  }
  if (edVerifyAlg.length === 0) {
    throw new Error('Ed25519 未初始化');
  }
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    try {
      const verifier = cryptoFramework.createVerify(edVerifyAlg);
      verifier.initSync(edPubKey(pub));
      return verifier.verifySync(blob(message), blob(signature));
    } catch (error) {
      throw cryptoError(error);
    }
  }
  throw new Error('CryptoFramework unsupported on this device');
}

function rsaAlg(bits: number, hash: string): string {
  if (bits <= 2048) {
    return `RSA2048|PKCS1|${hash}`;
  }
  if (bits <= 3072) {
    return `RSA3072|PKCS1|${hash}`;
  }
  return `RSA4096|PKCS1|${hash}`;
}

export function rsaPkcs1Verify(n: bigint, e: bigint, message: Uint8Array, signature: Uint8Array,
  hash: string): boolean {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    const bits = n.toString(2).length;
    const params: cryptoFramework.RSACommonParamsSpec = {
      algName: 'RSA',
      specType: cryptoFramework.AsyKeySpecType.COMMON_PARAMS_SPEC,
      n: n
    };
    const spec: cryptoFramework.RSAPubKeySpec = {
      algName: 'RSA',
      specType: cryptoFramework.AsyKeySpecType.PUBLIC_KEY_SPEC,
      params: params,
      pk: e
    };
    try {
      const pub = cryptoFramework.createAsyKeyGeneratorBySpec(spec).generatePubKeySync();
      const verifier = cryptoFramework.createVerify(rsaAlg(bits, hash));
      verifier.initSync(pub);
      return verifier.verifySync(blob(message), blob(signature));
    } catch (error) {
      throw cryptoError(error);
    }
  }
  throw new Error('CryptoFramework unsupported on this device');
}

export function fingerprint(hostKey: Uint8Array): string {
  const dig = sha256(hostKey);
  return `SHA256:${base64(dig)}`;
}

function tryHmac(): void {
  const macAlgs: string[] = ['SHA256', 'HMAC|SHA256', 'HMAC'];
  const keyAlgs: string[] = ['HMAC', 'HMAC|SHA256', 'SHA256'];
  const key = new Uint8Array([
    0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b
  ]);
  const data = new Uint8Array([0x48, 0x69, 0x20, 0x54, 0x68, 0x65, 0x72, 0x65]);
  const expect = new Uint8Array([
    0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53, 0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b, 0xf1, 0x2b,
    0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7, 0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7
  ]);
  let last = 'HMAC 不可用';
  for (let i = 0; i < macAlgs.length; i++) {
    for (let j = 0; j < keyAlgs.length; j++) {
      try {
        const got = hmacOnce(macAlgs[i], keyAlgs[j], key, data);
        if (eqBytes(got, expect)) {
          hmacMacAlg = macAlgs[i];
          hmacKeyAlg = keyAlgs[j];
          return;
        }
        last = `HMAC ${macAlgs[i]}/${keyAlgs[j]} 结果不对`;
      } catch (e) {
        last = errText(e);
      }
    }
  }
  throw new Error(last);
}

function tryAes(): void {
  const key = new Uint8Array([
    0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c
  ]);
  const iv = new Uint8Array([
    0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff
  ]);
  const plain = new Uint8Array([
    0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a
  ]);
  const expect = new Uint8Array([
    0x87, 0x4d, 0x61, 0x91, 0xb6, 0x20, 0xe3, 0x26, 0x1b, 0xef, 0x68, 0x64, 0x99, 0x0d, 0xb6, 0xce
  ]);
  const got = aes128Ctr(key, iv, plain);
  if (!eqBytes(got, expect)) {
    throw new Error('AES-128-CTR 结果不对');
  }
}

function tryEd25519(): void {
  requireCryptoFramework();
  if (canIUse(CRYPTO_SYSCAP)) {
    const names: string[] = ['Ed25519', 'ED25519'];
    let pair: cryptoFramework.KeyPair;
    let pub: Uint8Array;
    try {
      const gen = cryptoFramework.createAsyKeyGenerator('Ed25519');
      pair = gen.generateKeyPairSync();
      const pkBn = pair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ED25519_PK_BN) as bigint;
      pub = leToFixed(pkBn, ED25519_LEN);
    } catch (error) {
      throw cryptoError(error);
    }
    const msg = new Uint8Array([1, 2, 3, 4]);
    let last = 'Ed25519 不可用';
    for (let i = 0; i < names.length; i++) {
      try {
        const signer = cryptoFramework.createSign(names[i]);
        signer.initSync(pair.priKey);
        const sig = copyOut(signer.signSync(blob(msg)));
        if (sig.length !== ED25519_SIG_LEN) {
          last = `Ed25519 签名长度 ${sig.length}`;
          continue;
        }
        const verifier = cryptoFramework.createVerify(names[i]);
        verifier.initSync(edPubKey(pub));
        if (verifier.verifySync(blob(msg), blob(sig))) {
          edVerifyAlg = names[i];
          return;
        }
        last = 'Ed25519 自检未通过';
      } catch (e) {
        last = errText(e);
      }
    }
    throw new Error(last);
  }
  throw new Error('CryptoFramework unsupported on this device');
}

/** Fail closed if the device crypto stack cannot do the algorithms SSH needs. */
function step(name: string, fn: () => void): void {
  try {
    fn();
  } catch (e) {
    throw new Error(`${name}: ${errText(e)}`);
  }
}

export function ensureSshCrypto(): void {
  if (cryptoReady) {
    return;
  }
  requireCryptoFramework();
  step('SHA256', () => {
    const abc = sha256(new Uint8Array([0x61, 0x62, 0x63]));
    if (abc.length !== 32 || abc[0] !== 0xba) {
      throw new Error('结果不对');
    }
  });
  step('HMAC', () => {
    tryHmac();
  });
  step('AES', () => {
    tryAes();
  });
  step('Ed25519', () => {
    tryEd25519();
  });
  step('X25519', () => {
    const probe = X25519Key.generate();
    if (probe.pub.length !== X25519_LEN) {
      throw new Error('公钥长度不对');
    }
  });
  cryptoReady = true;
}
