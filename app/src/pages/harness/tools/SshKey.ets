// 设备自己的 ssh 密钥。
//
// 私钥在这里生成、在这里使用，全程不离开应用沙箱：走宿主生成再推入的路径，私钥就经过了一次
// 宿主机，而这台机器要拿它去登另一台。
//
// 公钥导出成 OpenSSH 的单行格式，因为那才是 authorized_keys 里能直接贴的一行；DER 里的
// SubjectPublicKeyInfo 尾部 32 字节就是 raw key，前面是算法标识。

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';

/** 密钥落脚处：沙箱 files 下自己的目录，与快照库并列。 */
export function keyDir(filesDir: string): string {
  return filesDir + '/ssh';
}

export function privateKeyPath(filesDir: string): string {
  return keyDir(filesDir) + '/id_ed25519';
}

export function publicKeyPath(filesDir: string): string {
  return keyDir(filesDir) + '/id_ed25519.pub';
}

/** 把字节切成 OpenSSH 的 wire 格式：每段先四字节大端长度，再内容。 */
function sshString(bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(4 + bytes.length);
  out[0] = (bytes.length >>> 24) & 0xFF;
  out[1] = (bytes.length >>> 16) & 0xFF;
  out[2] = (bytes.length >>> 8) & 0xFF;
  out[3] = bytes.length & 0xFF;
  out.set(bytes, 4);
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], at);
    at += parts[i].length;
  }
  return out;
}

function toUtf8(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

function base64(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

/**
 * 生成一对 Ed25519 密钥，写入沙箱，返回公钥那一行。
 *
 * 私钥优先用 PEM 导出：libssh2 认 PEM 与 OpenSSH 两种封装，而裸 DER（PKCS#8）它不认。
 * PEM 不可用时退回 DER 并把这件事报出来——宁可让人看见失败，也不静默写一个用不了的文件。
 */
export async function generateKeyPair(filesDir: string): Promise<string> {
  const dir = keyDir(filesDir);
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir);
  }
  const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
  const pair = await generator.generateKeyPair();

  const publicBlob = pair.pubKey.getEncoded();
  const der = publicBlob.data as Uint8Array;
  // SubjectPublicKeyInfo 的尾部就是 32 字节 raw key。
  const raw = der.slice(der.length - 32);
  const wire = concat([sshString(toUtf8('ssh-ed25519')), sshString(raw)]);
  const publicLine = 'ssh-ed25519 ' + base64(wire) + ' navi@hvolt-ide';

  let privateText = '';
  let privateForm = 'pem';
  try {
    privateText = pair.priKey.getEncodedPem('PKCS8');
  } catch (e) {
    privateText = '';
  }
  if (privateText.length === 0) {
    privateForm = 'der';
    const privateDer = pair.priKey.getEncoded();
    privateText = base64(privateDer.data as Uint8Array);
  }

  const privateFile = fs.openSync(privateKeyPath(filesDir),
    fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  fs.writeSync(privateFile.fd, privateText);
  fs.closeSync(privateFile);
  try {
    fs.chmodSync(privateKeyPath(filesDir), 0o600);
  } catch (e) {
    // 沙箱里权限本来就只有本应用，设置失败不影响可用性。
  }

  const publicFile = fs.openSync(publicKeyPath(filesDir),
    fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  fs.writeSync(publicFile.fd, publicLine + '\n');
  fs.closeSync(publicFile);

  return '{\"public\":\"' + publicLine + '\",\"private_form\":\"' + privateForm + '\",\"path\":\"'
    + privateKeyPath(filesDir) + '\"}';
}
