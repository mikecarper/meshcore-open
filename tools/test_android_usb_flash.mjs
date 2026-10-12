// Hermetic tests of the Android WebView shim. No USB device is opened and no
// firmware is written. Run: node --experimental-vm-modules tools/test_android_usb_flash.mjs
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const assets = new URL('../android/app/src/main/assets/esptool/', import.meta.url);
const source = await fs.readFile(new URL('bridge.js', assets), 'utf8');
const bootstrap = await fs.readFile(new URL('bootstrap.js', assets), 'utf8');
test('legacy WebView capability failure is actionable before USB engine startup', () => {
  const messages = [];
  const context = vm.createContext({
    document: { createElement: () => ({}) },
    MeshUsb: { incompatible: message => messages.push(message) },
  });
  context.window = context;
  vm.runInContext(bootstrap, context);
  assert.equal(context.meshUsbEngineReady, false);
  assert.equal(messages.length, 1);
  assert.match(messages[0], /Update WebView/);
});
test('updated Lollipop WebView passes capability check and awaits actual module ready', () => {
  const messages = [];
  const context = vm.createContext({
    document: { createElement: () => ({ noModule: false }) },
    TextDecoder,
    MeshUsb: { incompatible: message => messages.push(message) },
  });
  context.window = context;
  vm.runInContext(bootstrap, context);
  assert.equal(context.meshUsbEngineReady, false);
  assert.equal(messages.length, 0);
  context.onerror();
  assert.equal(messages.length, 1);
});
const mac = '1234567890ab';
async function engine(options = {}) {
  const io = [], registers = [], writes = [];
  let reply;
  let identity = mac;
  const hash = 'f1d3ff8443297732862df21dc4e57262'; // MD5 of four zero bytes
  class Loader {
    constructor(config) {
      this.transport = config.transport;
      this.IS_STUB = false;
      this.secureDownloadMode = !!options.secureDownload;
      this.chip = {
        IMAGE_CHIP_ID: options.chip ?? 9,
        CHIP_NAME: 'ESP32-S3',
        readMac: async () => identity,
      };
    }
    async detectChip(mode) { io.push({ op: 'detect', mode }); await this.transport.device.open({ baudRate: 115200 }); }
    async getSecurityInfo() {
      return { parsedFlags: options.flags ?? {}, flashCryptCnt: options.crypt ?? 0 };
    }
    async readReg(address) { registers.push({ read: address }); return options.legacyRegs?.[address] ?? 0; }
    async writeReg(address, value, mask) { registers.push({ address, value, mask }); }
    async runStub() { io.push({ op: 'stub' }); this.IS_STUB = true; }
    async detectFlashSize() { return options.flashSize ?? '8MB'; }
    flashSizeBytes() { return options.unknownSize ? -1 : 8 * 1024 * 1024; }
    async readFlash(offset, length) { io.push({ op: 'readFlash', offset, length }); return new Uint8Array(length); }
    async flashMd5sum() { return options.hash ?? hash; }
    async writeFlash(args) { writes.push(args); }
  }
  class Transport {
    constructor(device) { this.device = device; }
    async disconnect() { await this.device.close(); }
  }
  const context = vm.createContext({
    console, Uint8Array, Map, Promise, Error, Number, String,
    setTimeout: callback => setTimeout(callback, 0),
    btoa: data => Buffer.from(data, 'binary').toString('base64'),
    atob: data => Buffer.from(data, 'base64').toString('binary'),
  });
  context.window = context;
  context.MeshUsb = {
    ready() {},
    result(encoded) { reply(JSON.parse(encoded)); },
    request(encoded) {
      const request = JSON.parse(encoded);
      io.push(request);
      context.meshUsbNativeReply({ id: request.id, value: request.op === 'read' ? '' : null });
    },
  };
  const bundle = new vm.SyntheticModule(['ESPLoader', 'Transport'], function () {
    this.setExport('ESPLoader', Loader); this.setExport('Transport', Transport);
  }, { context });
  const module = new vm.SourceTextModule(source, { context });
  await module.link(() => bundle);
  await module.evaluate();
  let id = 100;
  const dispatch = async (op, args = {}) => {
    const completed = new Promise(resolve => { reply = resolve; });
    context.meshUsbDispatch({ id: id++, op, args });
    return completed;
  };
  const connect = () => dispatch('connect', {
    reset: false, vendorId: options.vendorId ?? 0x303a, productId: 0x1001,
    driver: 'CdcAcmSerialDriver', deviceName: 'mock',
  });
  return { io, registers, writes, dispatch, connect, hash, setIdentity: value => { identity = value; } };
}

test('vendored esptool bundle matches pinned npm SHA256', async () => {
  const bundle = await fs.readFile(new URL('bundle.js', assets));
  const manifest = JSON.parse(await fs.readFile(new URL('PROVENANCE.json', assets), 'utf8'));
  assert.equal(crypto.createHash('sha256').update(bundle).digest('hex'), manifest.bundle_sha256);
  assert.equal(manifest.version, '0.7.0');
});
test('actual pinned Espressif Transport sends exact SLIP bytes through native shim', async () => {
  const calls = [];
  const context = vm.createContext({ console, Uint8Array, Map, Promise, Error,
    setTimeout, Date, TextDecoder,
    btoa: data => Buffer.from(data, 'binary').toString('base64'),
    atob: data => Buffer.from(data, 'base64').toString('binary') });
  context.window = context;
  context.MeshUsb = {
    ready() {}, result() {},
    request(encoded) {
      const request = JSON.parse(encoded); calls.push(request);
      context.meshUsbNativeReply({ id: request.id, value: null });
    },
  };
  const official = new vm.SourceTextModule(await fs.readFile(new URL('bundle.js', assets), 'utf8'), { context });
  await official.link(() => { throw new Error('Offline bundle unexpectedly imported a dependency'); });
  const bridge = new vm.SourceTextModule(source, { context });
  await bridge.link(() => official);
  await bridge.evaluate();
  const port = new bridge.namespace.NativeSerialPort({ vendorId: 0x1a86, productId: 0x7523 });
  const wire = new official.namespace.Transport(port, false);
  await wire.connect(115200);
  await wire.write(new Uint8Array([0xc0, 0xdb, 1]));
  assert.deepEqual([...Buffer.from(calls.find(call => call.op === 'write').args.data, 'base64')], [0xc0, 0xdb, 0xdc, 0xdb, 0xdd, 1, 0xc0]);
  assert.equal(calls.some(call => call.op === 'setSignals'), false);
  await wire.setSignals(false, true);
  assert.deepEqual(calls.at(-1).args, { dtr: false, rts: true });
  await wire.changeBaudrate(460800);
  assert.equal(calls.at(-1).args.baudRate, 460800);
  await wire.disconnect();
  assert.equal(calls.at(-1).op, 'close');
});
test('passive connect has no DTR/RTS, reports immutable identity and capacity', async () => {
  const e = await engine();
  assert.deepEqual((await e.connect()).value, { chip: 9, name: 'ESP32-S3', flashBytes: 8388608, mac });
  assert.equal(e.io.find(x => x.op === 'detect').mode, 'no_reset');
  assert.equal(e.io.some(x => x.op === 'setSignals'), false);
});
test('secure boot, secure download and disabled USB are rejected before stub/writes', async () => {
  for (const flag of ['SECURE_BOOT_EN', 'SECURE_DOWNLOAD_ENABLE', 'DIS_USB']) {
    const e = await engine({ flags: { [flag]: true } });
    assert.match((await e.connect()).error, /refusing plaintext/);
    assert.equal(e.io.some(x => x.op === 'stub'), false);
    assert.equal(e.writes.length, 0);
  }
});
test('flash encryption parity and secure download mode stop before RAM stub', async () => {
  for (const options of [{ crypt: 1 }, { crypt: 7 }, { secureDownload: true }]) {
    const e = await engine(options);
    assert.ok((await e.connect()).error);
    assert.equal(e.io.some(x => x.op === 'stub'), false);
  }
});
test('classic ESP32 uses its real eFuse protection fields', async () => {
  for (const legacyRegs of [{ 0x3ff5a000: 1 << 20 }, { 0x3ff5a018: 1 << 4 }]) {
    const e = await engine({ chip: 0, legacyRegs });
    assert.match((await e.connect()).error, /refusing plaintext/);
    assert.equal(e.io.some(x => x.op === 'stub'), false);
  }
});
test('unknown chip and flash capacity are fail-closed', async () => {
  const unsupported = await engine({ chip: 255 });
  assert.match((await unsupported.connect()).error, /not enabled/);
  const capacity = await engine({ unknownSize: true });
  assert.match((await capacity.connect()).error, /capacity is unknown/);
});
test('identity mismatch blocks erase/write/reset', async () => {
  const e = await engine(); await e.connect();
  e.setIdentity('aabbccddeeff');
  assert.match((await e.dispatch('writeFlash', { expectedMac: mac, offset: 0x10000, data: 'AAAAAA==', expectedMd5: e.hash })).error, /MAC changed/);
  assert.match((await e.dispatch('runApplication', { expectedMac: mac })).error, /MAC changed/);
  assert.equal(e.writes.length, 0);
  assert.equal(e.io.some(x => x.op === 'setSignals'), false);
});
test('verified write never erases full chip or changes image flash parameters', async () => {
  const e = await engine(); await e.connect();
  assert.deepEqual((await e.dispatch('writeFlash', { expectedMac: mac, offset: 0x10000, data: 'AAAAAA==', expectedMd5: e.hash })).value,
    { md5: e.hash, mac });
  assert.equal(e.writes.length, 1);
  assert.equal(e.writes[0].eraseAll, false);
  assert.equal(e.writes[0].flashSize, 'keep');
  assert.equal(e.writes[0].flashMode, 'keep');
  assert.equal(e.writes[0].compress, true);
});
test('unverified write stays in ROM; no automatic reboot', async () => {
  const e = await engine({ hash: 'bad' }); await e.connect();
  assert.match((await e.dispatch('writeFlash', { expectedMac: mac, offset: 0x10000, data: 'AAAAAA==', expectedMd5: e.hash })).error, /MD5 verification failed/);
  assert.equal(e.io.some(x => x.op === 'setSignals'), false);
});
test('unaligned writes and out-of-capacity reads fail before flash operation', async () => {
  const e = await engine(); await e.connect();
  assert.match((await e.dispatch('writeFlash', { expectedMac: mac, offset: 1, data: 'AAAAAA==', expectedMd5: e.hash })).error, /sector boundary/);
  assert.match((await e.dispatch('readFlash', { expectedMac: mac, offset: 8388607, length: 4 })).error, /outside/);
  assert.equal(e.writes.length, 0);
});
test('S3 launch clears only force-download bit, then verified watchdog reset', async () => {
  const e = await engine(); await e.connect();
  e.registers.length = 0;
  assert.equal((await e.dispatch('runApplication', { expectedMac: mac, migrationBridge: true })).error, undefined);
  assert.deepEqual(e.registers, [
    { address: 0x6000812c, value: 0, mask: 1 },
    { address: 0x600080b0, value: 0x50d83aa1, mask: undefined },
    { address: 0x6000809c, value: 2000, mask: undefined },
    { address: 0x60008098, value: 0xd0000102, mask: undefined },
    { address: 0x600080b0, value: 0, mask: undefined },
  ]);
  assert.equal(e.io.some(x => x.op === 'setSignals'), false);
  assert.equal(e.io.at(-1).op, 'close');
});
test('closing during passive migration makes no signal or reset requests', async () => {
  const e = await engine(); await e.connect();
  await e.dispatch('close');
  assert.equal(e.io.some(x => x.op === 'setSignals'), false);
  assert.equal(e.io.at(-1).op, 'close');
});
test('C3 launch clears its own OPTION1 forced-ROM bit before watchdog reset', async () => {
  const e = await engine({ chip: 5 }); await e.connect();
  e.registers.length = 0;
  assert.equal((await e.dispatch('runApplication', { expectedMac: mac, migrationBridge: false })).error, undefined);
  assert.deepEqual(e.registers, [
    { address: 0x600080f4, value: 0, mask: 1 },
    { address: 0x600080a8, value: 0x50d83aa1, mask: undefined },
    { address: 0x60008094, value: 2000, mask: undefined },
    { address: 0x60008090, value: 0xd0000102, mask: undefined },
    { address: 0x600080a8, value: 0, mask: undefined },
  ]);
  assert.equal(e.io.some(x => x.op === 'setSignals'), false);
});
test('C6 image chip ID13 is explicitly unsupported and cannot submit writes', async () => {
  const e = await engine({ chip: 13 });
  assert.match((await e.connect()).error, /not enabled/);
  assert.equal(e.io.some(op => op.op === 'stub'), false);
  const attempted = await e.dispatch('writeFlash', {
    expectedMac: mac, offset: 0x10000, data: 'AAAAAA==', expectedMd5: e.hash,
  });
  assert.match(attempted.error, /not connected/);
  assert.equal(e.writes.length, 0);
});
test('CDC USB-UART reset clears forced ROM first, never selects native watchdog', async () => {
  const e = await engine({ vendorId: 0x1a86 }); await e.connect();
  e.registers.length = 0;
  assert.equal((await e.dispatch('runApplication', { expectedMac: mac })).error, undefined);
  assert.deepEqual(e.registers, [{ address: 0x6000812c, value: 0, mask: 1 }]);
  const pins = e.io.filter(op => op.op === 'setSignals');
  assert.deepEqual(pins.map(op => op.args), [{ dtr: false, rts: true }, { dtr: false, rts: false }]);
});
