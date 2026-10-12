import { ESPLoader, Transport } from './bundle.js';

// This page is never visible, never navigates, and cannot fetch network data.
// Only packaged code can access the narrow native raw-serial interface.
let nextId = 1;
const pending = new Map();
function native(op, args = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    MeshUsb.request(JSON.stringify({ id, op, args }));
  });
}
window.meshUsbNativeReply = reply => {
  const request = pending.get(reply.id);
  if (!request) return;
  pending.delete(reply.id);
  if (reply.error) request.reject(new Error(reply.error));
  else request.resolve(reply.value);
};
const encode = bytes => {
  let output = '';
  for (let i = 0; i < bytes.length; i += 16384) {
    output += String.fromCharCode(...bytes.subarray(i, i + 16384));
  }
  return btoa(output);
};
const decode = encoded => Uint8Array.from(atob(encoded), char => char.charCodeAt(0));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let loader, serial, wire, chipInfo;

export class NativeSerialPort {
  constructor(device) {
    this.device = device;
    this.signals = { dataTerminalReady: false, requestToSend: false };
    this.readable = null;
    this.writable = null;
  }
  getInfo() { return { usbVendorId: this.device.vendorId, usbProductId: this.device.productId }; }
  async open(options) {
    await native('setBaudRate', { baudRate: options.baudRate });
    const port = this;
    this.readable = {
      locked: false,
      getReader() {
        if (this.locked) throw new Error('USB reader is already locked');
        this.locked = true;
        const stream = this;
        let cancelled = false;
        return {
          async read() {
            while (!cancelled && port.readable) {
              const value = decode(await native('read', { maxBytes: 4096, timeoutMs: 50 }));
              if (value.length) return { value, done: false };
            }
            return { done: true };
          },
          async cancel() { cancelled = true; },
          releaseLock() { stream.locked = false; },
        };
      },
    };
    this.writable = {
      locked: false,
      getWriter() {
        if (this.locked) throw new Error('USB writer is already locked');
        this.locked = true;
        const stream = this;
        return {
          write: bytes => native('write', { data: encode(bytes) }),
          async close() {},
          releaseLock() { stream.locked = false; },
        };
      },
    };
  }
  async setSignals(signals) {
    for (const key of ['dataTerminalReady', 'requestToSend']) {
      if (typeof signals[key] === 'boolean') this.signals[key] = signals[key];
    }
    await native('setSignals', { dtr: this.signals.dataTerminalReady, rts: this.signals.requestToSend });
  }
  async setBaudRate(baudRate) { await native('setBaudRate', { baudRate }); }
  async close() {
    this.readable = null;
    this.writable = null;
    await native('close');
  }
}

const normalizeMac = mac => {
  const value = mac.replace(/[:-]/g, '').toLowerCase();
  if (!/^[0-9a-f]{12}$/.test(value)) throw new Error('ESP ROM returned an invalid MAC');
  return value;
};
async function assertIdentity(expectedMac) {
  if (!loader || !chipInfo) throw new Error('ESP ROM is not connected');
  const actual = normalizeMac(await loader.chip.readMac(loader));
  if (actual !== normalizeMac(expectedMac) || actual !== chipInfo.mac) {
    throw new Error('Connected chip MAC changed; refusing flash or reset');
  }
  return actual;
}
function checkRange(offset, length) {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) ||
      offset < 0 || length <= 0 || offset + length > chipInfo.flashBytes) {
    throw new Error('Flash region is outside detected flash capacity');
  }
}
async function checkSecurity() {
  if (loader.secureDownloadMode) throw new Error('Secure download mode is not supported');
  if (loader.chip.IMAGE_CHIP_ID === 0) {
    // ESP32 ROM lacks GET_SECURITY_INFO. These fields follow esptool v4.8.1
    // targets/esp32.py; protected flash must never accept a plaintext update.
    const crypt = (await loader.readReg(0x3ff5a000) >>> 20) & 0x7f;
    const secure = (await loader.readReg(0x3ff5a018)) & 0x30;
    if (secure || crypt.toString(2).replace(/0/g, '').length % 2) {
      throw new Error('Secure boot or flash encryption is enabled; refusing plaintext update');
    }
  } else {
    const info = await loader.getSecurityInfo();
    if (info.parsedFlags.SECURE_BOOT_EN || info.parsedFlags.SECURE_DOWNLOAD_ENABLE ||
        info.parsedFlags.DIS_USB ||
        info.flashCryptCnt.toString(2).replace(/0/g, '').length % 2) {
      throw new Error('Secure boot or flash encryption is enabled; refusing plaintext update');
    }
  }
}
async function connect(args) {
  serial = new NativeSerialPort(args);
  wire = new Transport(serial, false);
  loader = new ESPLoader({ transport: wire, baudrate: 115200, romBaudrate: 115200,
    debugLogging: false, enableTracing: false,
    terminal: { clean() {}, write() {}, writeLine() {} } });
  await loader.detectChip(args.reset ? 'default_reset' : 'no_reset', args.reset ? 7 : 2);
  if (![0, 2, 5, 9, 12].includes(loader.chip.IMAGE_CHIP_ID)) {
    throw new Error('This ESP chip is not enabled for verified USB flashing');
  }
  await checkSecurity();
  const mac = normalizeMac(await loader.chip.readMac(loader));
  // esptool-js postConnect does not yet disable the S3/C3 RTC watchdog on
  // USB-Serial/JTAG. Follow pinned esptool v5.1.0 before loading the RAM stub.
  if (args.vendorId === 0x303a && args.productId === 0x1001 && [5, 9].includes(loader.chip.IMAGE_CHIP_ID)) {
    const s3 = loader.chip.IMAGE_CHIP_ID === 9;
    const wdt = s3 ? 0x600080b0 : 0x600080a8;
    const config = s3 ? 0x60008098 : 0x60008090;
    const swd = s3 ? 0x600080b8 : 0x600080b0;
    const swdConfig = s3 ? 0x600080b4 : 0x600080ac;
    await loader.writeReg(wdt, 0x50d83aa1);
    await loader.writeReg(config, 0);
    await loader.writeReg(wdt, 0);
    await loader.writeReg(swd, 0x8f1d312a);
    await loader.writeReg(swdConfig, ((await loader.readReg(swdConfig)) | 0x80000000) >>> 0);
    await loader.writeReg(swd, 0);
  }
  if (loader.chip.postConnect) await loader.chip.postConnect(loader);
  await loader.runStub();
  if (!loader.IS_STUB) throw new Error('Verified flash reads require the official RAM stub');
  const size = await loader.detectFlashSize();
  const flashBytes = size ? loader.flashSizeBytes(size) : -1;
  if (flashBytes <= 0) throw new Error('Flash capacity is unknown');
  chipInfo = { chip: loader.chip.IMAGE_CHIP_ID, name: loader.chip.CHIP_NAME, flashBytes, mac };
  return chipInfo;
}
async function readFlash(args) {
  await assertIdentity(args.expectedMac);
  checkRange(args.offset, args.length);
  const bytes = await loader.readFlash(args.offset, args.length);
  if (bytes.length !== args.length) throw new Error('Incomplete flash read');
  const hash = (await loader.flashMd5sum(args.offset, args.length)).toLowerCase();
  return { data: encode(bytes), md5: hash };
}
async function writeFlash(args) {
  const mac = await assertIdentity(args.expectedMac);
  const bytes = decode(args.data);
  checkRange(args.offset, bytes.length);
  if (args.offset % 4096) throw new Error('Flash writes must start at a sector boundary');
  await loader.writeFlash({ fileArray: [{ address: args.offset, data: bytes }],
    flashSize: 'keep', flashMode: 'keep', flashFreq: 'keep', eraseAll: false, compress: true });
  const hash = (await loader.flashMd5sum(args.offset, bytes.length)).toLowerCase();
  if (hash !== args.expectedMd5) throw new Error('Flash MD5 verification failed; staying in ROM');
  await assertIdentity(args.expectedMac);
  return { md5: hash, mac };
}
async function runApplication(args) {
  await assertIdentity(args.expectedMac);
  const chip = loader.chip.IMAGE_CHIP_ID;
  // Bridges arm software download independently of the host adapter type.
  // Clear only this bit even on external UART before normal DTR/RTS reset.
  if (chip === 9) await loader.writeReg(0x6000812c, 0, 1);
  // C3 address from pinned ESP-IDF v4.4.7 soc/esp32c3/rtc_cntl_reg.h.
  if (chip === 5) await loader.writeReg(0x600080f4, 0, 1);
  if (chip === 2) await loader.writeReg(0x3f408128, 0, 1);
  // Native S3 needs FORCE_DOWNLOAD_BOOT cleared and a genuine watchdog reset,
  // rather than esptool-js's RTS-low-only after() implementation. This follows
  // pinned esptool v5.1.0, preserving all other OPTION1 bits via its mask.
  const nativeUsb = serial.device.driver === 'CdcAcmSerialDriver' &&
    ![0x1a86, 0x0403, 0x10c4, 0x067b].includes(serial.device.vendorId);
  if (nativeUsb && [2, 5, 9].includes(chip)) {
    const unlock = chip === 9 ? 0x600080b0 : chip === 5 ? 0x600080a8 : 0x3f4080ac;
    const timeout = chip === 9 ? 0x6000809c : chip === 5 ? 0x60008094 : 0x3f408098;
    const config = chip === 9 ? 0x60008098 : chip === 5 ? 0x60008090 : 0x3f408094;
    await loader.writeReg(unlock, 0x50d83aa1);
    await loader.writeReg(timeout, 2000);
    await loader.writeReg(config, 0xd0000102);
    await loader.writeReg(unlock, 0);
    await sleep(500);
  } else {
    await serial.setSignals({ dataTerminalReady: false, requestToSend: true });
    await sleep(100);
    await serial.setSignals({ dataTerminalReady: false, requestToSend: false });
  }
  // Do not touch the node again: the migration bridge may already be replacing
  // its partition table. Re-enumeration and restoration are the host's next step.
  await close();
  return null;
}
async function close() {
  try { if (wire) await wire.disconnect(); else await native('close'); }
  finally { loader = null; wire = null; serial = null; chipInfo = null; }
}
let busy = false;
window.meshUsbDispatch = async request => {
  if (busy) { MeshUsb.result(JSON.stringify({ id: request.id, error: 'ESP operation already in progress' })); return; }
  busy = true;
  try {
    const operations = { connect, readFlash, writeFlash, runApplication, close };
    if (!operations[request.op]) throw new Error('Unsupported ESP engine operation');
    const value = await operations[request.op](request.args);
    MeshUsb.result(JSON.stringify({ id: request.id, value }));
  } catch (error) {
    MeshUsb.result(JSON.stringify({ id: request.id, error: error.message || String(error) }));
  } finally { busy = false; }
};
window.meshUsbEngineReady = true;
MeshUsb.ready();
