import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { base64, ByteWriter } from './SshBytes';

// HUKS owns the private key. Only the X.509 public key leaves the keystore.
const ALIAS: string = 'com.douwantech.blink.ssh.ed25519.v1';
const PUB_PREFIX: number[] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];

export class SshIdentity {
  private static publicBytes: Uint8Array | null = null;

  static async publicKeyBytes(): Promise<Uint8Array> {
    if (SshIdentity.publicBytes !== null) {
      return SshIdentity.publicBytes;
    }
    const empty: huks.HuksOptions = { properties: [] };
    let exists: boolean = false;
    try {
      exists = await huks.isKeyItemExist(ALIAS, empty);
    } catch (e) {
      const error = e as BusinessError;
      if (error.code !== 12000011) {
        throw new Error('查询 SSH 密钥失败：' + error.code + ' ' + error.message);
      }
    }
    if (!exists) {
      const options: huks.HuksOptions = { properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ED25519 },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE }
      ] };
      try {
        await huks.generateKeyItem(ALIAS, options);
      } catch (e) {
        const error = e as BusinessError;
        throw new Error('生成 SSH 密钥失败：' + error.code + ' ' + error.message);
      }
    }
    let exported: huks.HuksReturnResult;
    try {
      exported = await huks.exportKeyItem(ALIAS, empty);
    } catch (e) {
      const error = e as BusinessError;
      throw new Error('导出 SSH 公钥失败：' + error.code + ' ' + error.message);
    }
    const encoded = exported.outData;
    if (encoded === undefined) {
      throw new Error('SSH 公钥为空');
    }
    if (encoded.length === 32) {
      // HarmonyOS on CLS-AL00 exports the Ed25519 public material directly.
      SshIdentity.publicBytes = encoded;
    } else if (encoded.length === PUB_PREFIX.length + 32) {
      // Other HUKS providers use the documented X.509 SubjectPublicKeyInfo DER.
      for (let i = 0; i < PUB_PREFIX.length; i++) {
        if (encoded[i] !== PUB_PREFIX[i]) {
          throw new Error('SSH 公钥 DER 格式不支持');
        }
      }
      SshIdentity.publicBytes = encoded.slice(PUB_PREFIX.length);
    } else {
      throw new Error('SSH 公钥格式不支持（' + encoded.length + ' 字节）');
    }
    return SshIdentity.publicBytes;
  }

  static async authorizedKey(): Promise<string> {
    const raw = await SshIdentity.publicKeyBytes();
    const blob = new ByteWriter().str('ssh-ed25519').strBytes(raw).toBytes();
    return 'ssh-ed25519 ' + base64(blob) + ' blink-harmony';
  }

  static async sign(data: Uint8Array): Promise<Uint8Array> {
    await SshIdentity.publicKeyBytes();
    const options: huks.HuksOptions = { properties: [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ED25519 },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE }
    ], inData: data };
    const session = await huks.initSession(ALIAS, options);
    try {
      const result = await huks.finishSession(session.handle, options);
      if (result.outData === undefined || result.outData.length !== 64) {
        throw new Error('SSH 签名失败');
      }
      return result.outData;
    } catch (e) {
      await huks.abortSession(session.handle, { properties: [] }).catch((): void => {});
      throw new Error(`${e}`);
    }
  }
}
