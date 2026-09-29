import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/ble_mota_catalog.dart';
import 'package:meshcore_open/services/lora_ota_target_info.dart';

import '../support/mota_test_data.dart';

void main() {
  LoraOtaTargetInfo target({String keys = 'no trusted signer keys yet'}) {
    return LoraOtaTargetInfo.parse(
      status:
          'OTA | this fw C2CFC98C hw=Heltec_tower_v2 | '
          'target:0A9DBBF0 | bl:SD | keys:0 | '
          'env:Heltec_tower_v2_sdcard_repeat',
      self: 'self body=487288 base_hash=C2CFC98C42CBEFDB',
      bootloader:
          'BL board=239A0071 target=1150F50E '
          'name=TOWER_V2_OTA abi=3 caps=09',
      keys: keys,
    );
  }

  test('reads exact SD target identity and signer fingerprints', () {
    final info = target(keys: 'trusted signer keys (1): F9344B3A400221D1');
    expect(info.environment, 'Heltec_tower_v2_sdcard_repeat');
    expect(info.applicationTargetId, 0x0A9DBBF0);
    expect(info.bootloaderTargetId, 0x1150F50E);
    expect(info.baseHashPrefix, 'C2CFC98C42CBEFDB');
    expect(info.bootloaderStorageCaps, 0x09);
    expect(info.receiverStorage, 'external_sd');
    expect(info.trustedSignerFingerprints, contains('F9344B3A400221D1'));
  });

  test('rejects wrong application target before any LoRa transfer', () async {
    final file = await BleMotaFile.load(
      XFile.fromData(buildTestFullMotaContainer(), name: 'wrong-target.mota'),
    );
    expect(() => target().validatePackage(file), throwsStateError);
  });

  test('RAK application storage is independent of bootloader staging', () {
    for (final external in [false, true]) {
      final info = LoraOtaTargetInfo.parse(
        status: 'OTA target:05F5FFAE env:RAK_4631_repeater_unified_lora_ota',
        self:
            'self body=620000 base_hash=1809003428588E08 | '
            '${external ? 'QSPI store:2048K' : 'internal store:252K'}',
        bootloader:
            'BL board=239A0029 target=2D0DF000 name=4631_DFU abi=3 caps=0A',
        keys: '',
      );
      expect(info.bootloaderStorageCaps, 0x0A);
      expect(
        info.receiverStorage,
        external ? 'external_qspi' : 'internal_flash',
      );
    }
  });

  test(
    'rejects wrong bootloader storage even with matching target ID',
    () async {
      final bytes = await buildTestBootloaderMotaContainer(storageCaps: 0x0A);
      final file = await BleMotaFile.load(
        XFile.fromData(
          Uint8List.fromList(bytes),
          name: 'internal-bootloader.mota',
        ),
      );
      final info = LoraOtaTargetInfo(
        environment: 'TEST',
        applicationTargetId: 0x11223344,
        bootloaderTargetId: 0xD50D2D44,
        baseHashPrefix: '0000000000000000',
        bootloaderStorageCaps: 0x09,
        receiverStorage: 'external_sd',
        trustedSignerFingerprints: const <String>{},
      );
      expect(() => info.validatePackage(file), throwsStateError);
    },
  );

  test('refuses malformed target identity instead of guessing', () {
    expect(
      () => LoraOtaTargetInfo.parse(
        status: 'OTA | no download',
        self: 'self base_hash=C2CFC98C42CBEFDB',
        bootloader: 'BL target=1150F50E caps=09',
        keys: '',
      ),
      throwsFormatException,
    );
  });
}
