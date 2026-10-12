/* ES5 syntax deliberately: stock Android 5.1 WebView must fail before USB. */
(function () {
  window.meshUsbEngineReady = false;
  var message = 'ESP32 USB flashing needs an updated Android System WebView ' +
    '(ES modules, WebView 61 or newer; WebView 95 works on Android 5.1). ' +
    'Update WebView before continuing. Backup and nRF52 USB DFU remain available.';
  if (!('noModule' in document.createElement('script')) ||
      typeof Promise !== 'function' || typeof Map !== 'function' ||
      typeof Uint8Array.from !== 'function' ||
      typeof Object.values !== 'function' ||
      typeof String.prototype.padStart !== 'function' ||
      typeof String.prototype.padEnd !== 'function' ||
      typeof Array.prototype.includes !== 'function' ||
      typeof Uint8Array.prototype.slice !== 'function' ||
      typeof Uint8Array.prototype.fill !== 'function' ||
      typeof Number.isSafeInteger !== 'function' ||
      typeof TextDecoder !== 'function') {
    MeshUsb.incompatible(message);
    return;
  }
  window.onerror = function () {
    if (!window.meshUsbEngineReady) MeshUsb.incompatible(message);
  };
}());
