import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_firmware_inspector.dart';

void main() {
  test('catalog aliases uniquely identify one exact profile', () {
    final aliases = <String, String>{};
    final ids = <String>{};
    for (final spec in CompanionBoardCatalog.specs) {
      expect(ids.add(spec.id), isTrue, reason: spec.id);
      expect(spec.aliases, isNotEmpty, reason: spec.id);
      for (final alias in spec.aliases) {
        final name = CompanionBoardCatalog.normalize(alias);
        final previous = aliases[name];
        expect(
          previous == null || previous == spec.id,
          isTrue,
          reason: '$alias belongs to both $previous and ${spec.id}',
        );
        aliases[name] = spec.id;
        expect(CompanionBoardCatalog.lookup(alias), same(spec));
        expect(CompanionBoardCatalog.lookup(alias.toUpperCase()), same(spec));
      }
      if (spec.espChipId != null) {
        expect(spec.family, CompanionChipFamily.esp32, reason: spec.id);
      }
      if (spec.family != CompanionChipFamily.nrf52) {
        expect(spec.dfuNames, isEmpty, reason: spec.id);
      }
      for (final name in spec.dfuNames) {
        expect(name, name.toUpperCase(), reason: spec.id);
        if (name.length > 8) {
          expect(
            spec.dfuNames,
            contains(name.substring(0, 8)),
            reason: spec.id,
          );
        }
      }
    }
  });

  for (final spec in CompanionBoardCatalog.specs) {
    test(
      '${spec.id} format and wireless support are internally consistent',
      () {
        final expected = switch (spec.family) {
          CompanionChipFamily.nrf52 => 'zip',
          CompanionChipFamily.esp32 => 'bin',
          CompanionChipFamily.rp2040 => null,
        };
        expect(spec.updateExtension, expected);
        for (final alias in spec.aliases) {
          expect(
            CompanionFirmwareInspector.updateExtensionForBoard(alias),
            expected,
          );
        }
        if (spec.family == CompanionChipFamily.rp2040) {
          expect(spec.supportsWirelessUpdate, isFalse);
          expect(spec.supportsWifiOta, isFalse);
        }
      },
    );
  }

  test('ThinkNode mixed-MCU range never inherits a vendor-wide format', () {
    for (final model in [1, 3, 4, 6, 8]) {
      final spec = CompanionBoardCatalog.lookup('Elecrow ThinkNode M$model')!;
      expect(spec.family, CompanionChipFamily.nrf52);
      expect(spec.updateExtension, 'zip');
      expect(spec.espChipId, isNull);
    }
    for (final model in [2, 5, 7, 9]) {
      final spec = CompanionBoardCatalog.lookup('Elecrow ThinkNode M$model')!;
      expect(spec.family, CompanionChipFamily.esp32);
      expect(spec.updateExtension, 'bin');
      expect(spec.espChipId, 9);
      expect(spec.dfuNames, isEmpty);
    }
  });

  test('Xiao mixed-MCU range has exact types and chip identities', () {
    expect(CompanionBoardCatalog.lookup('Xiao C3')!.espChipId, 5);
    expect(CompanionBoardCatalog.lookup('Xiao C6')!.espChipId, 13);
    expect(CompanionBoardCatalog.lookup('Xiao S3')!.espChipId, 9);
    expect(CompanionBoardCatalog.lookup('Xiao S3 WIO')!.id, 'xiao-s3-wio');
    expect(
      CompanionBoardCatalog.lookup('Seeed Xiao-nrf52')!.family,
      CompanionChipFamily.nrf52,
    );
    expect(
      CompanionBoardCatalog.lookup('Xiao RP2040')!.family,
      CompanionChipFamily.rp2040,
    );
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('Xiao RP2040'),
      isNull,
    );
  });

  test(
    'known C6 Companion builds are wired-only, not Nordic ZIP or Wi-Fi OTA',
    () {
      for (final name in ['Xiao C6', 'Meshimi', 'WHY2025 Badge', 'Unit C6L']) {
        final spec = CompanionBoardCatalog.lookup(name)!;
        expect(spec.updateExtension, 'bin');
        expect(spec.supportsWifiOta, isFalse);
        expect(spec.supportsWirelessUpdate, isFalse);
        expect(spec.dfuNames, isEmpty);
      }
    },
  );

  test(
    'T-Echo variants do not share unrelated bootloader or asset identities',
    () {
      final standard = CompanionBoardCatalog.lookup('LilyGo T-Echo')!;
      final lite = CompanionBoardCatalog.lookup('LilyGo T-Echo Lite')!;
      final card = CompanionBoardCatalog.lookup('LilyGo T-Echo Card')!;
      expect(standard.dfuNames, ['LGTE_DFU']);
      expect(lite.dfuNames, ['LTEL_DFU']);
      expect(card.dfuNames, ['LTECARD_DFU', 'LTECARD_']);
      expect(lite.assetPrefixes, ['LilyGo_T-Echo-Lite']);
      expect(card.assetPrefixes, ['LilyGo_T-Echo_Card']);
      expect(
        lite.hardwareIds.toSet().intersection(card.hardwareIds.toSet()),
        isEmpty,
      );
    },
  );

  test('other long Nordic bootloader names retain exact shortened aliases', () {
    expect(CompanionBoardCatalog.lookup('Heltec MeshPocket')!.dfuNames, [
      'MESH_POCKET_OTA',
      'MESH_POC',
    ]);
    expect(CompanionBoardCatalog.lookup('Keepteen LT1')!.dfuNames, [
      'KEEPTEENLT1_OTA',
      'KEEPTEEN',
    ]);
    expect(CompanionBoardCatalog.lookup('Nano G2 Ultra')!.dfuNames, [
      'NANOG2_DFU',
      'NANOG2_D',
    ]);
    expect(CompanionBoardCatalog.lookup('Heltec Tower V2')!.dfuNames, [
      'TOWER_V2_OTA',
      'TOWER_V2',
    ]);
  });

  test('RAK optional storage profiles do not silently match base hardware', () {
    final basic = CompanionBoardCatalog.lookup('RAK 4631')!;
    final flash = CompanionBoardCatalog.lookup('RAK4631 + W25Q16')!;
    final slotC = CompanionBoardCatalog.lookup('RAK4631 + RAK15001 Slot C')!;
    expect(basic.hardwareIds, ['RAK4631']);
    expect(flash.hardwareIds, ['RAK4631_W25Q16']);
    expect(slotC.hardwareIds, ['RAK4631_RAK15001_C']);
    expect(flash.dfuNames, ['4631_W25Q16_DFU', '4631_W25']);
    expect(slotC.dfuNames, ['4631_15001C_DFU', '4631_150']);
    expect(
      basic.assetPrefixes.toSet().intersection(flash.assetPrefixes.toSet()),
      isEmpty,
    );
    expect(
      CompanionBoardCatalog.lookup('RAK3401 RAK13302 W25Q16')!.hardwareIds,
      ['RAK3401_RAK13302_W25Q16'],
    );
  });

  test('V4 radio revisions share only source-defined image aliases', () {
    expect(
      CompanionBoardCatalog.lookup('Heltec V4 OLED')!.hardwareIds,
      contains('heltec_v4_2_v4_3'),
    );
    expect(
      CompanionBoardCatalog.lookup('Heltec V4 OLED')!.assetPrefixes,
      contains('heltec_v4_2_v4_3'),
    );
    expect(
      CompanionBoardCatalog.lookup('Heltec V4.3 OLED'),
      same(CompanionBoardCatalog.lookup('Heltec V4 OLED')),
    );
    expect(
      CompanionBoardCatalog.lookup('Heltec V4.3 TFT'),
      same(CompanionBoardCatalog.lookup('Heltec V4 TFT')),
    );
    expect(CompanionBoardCatalog.lookup('Heltec V4.3 TFT')!.hardwareIds, [
      'heltec_v4_tft',
      'heltec_v4_3_tft',
    ]);
    expect(CompanionBoardCatalog.lookup('Heltec V4 R8')!.id, 'heltec-v4-r8');
    expect(
      CompanionBoardCatalog.lookup('Heltec V4 R8 TFT')!.id,
      'heltec-v4-r8-tft',
    );
  });

  test(
    'ambiguous T-Beam radio identity does not pick an application image',
    () {
      final spec = CompanionBoardCatalog.lookup('LilyGo T-Beam')!;
      expect(spec.updateExtension, 'bin');
      expect(spec.espChipId, isNull);
      expect(spec.assetPrefixes, isEmpty);
      expect(spec.hardwareIds, isEmpty);
    },
  );

  test('ambiguous Wio Tracker L1 revisions do not pick a base-board image', () {
    final spec = CompanionBoardCatalog.lookup('Seeed Wio Tracker L1')!;
    expect(spec.updateExtension, 'zip');
    expect(spec.dfuNames, ['WTL1_DFU']);
    expect(spec.assetPrefixes, isEmpty);
    expect(spec.hardwareIds, isEmpty);
  });

  test(
    'Nordic Companion layouts use their verified SoftDevice and flash base',
    () {
      for (final board in [
        'Heltec T096',
        'Heltec T114',
        'Heltec Tower V2',
        'RAK 4631',
        'LilyGo T-Echo Card',
        'Nano G2 Ultra',
      ]) {
        final spec = CompanionBoardCatalog.lookup(board)!;
        expect(spec.nrfApplicationAddress, 0x26000);
        expect(spec.nrfApplicationMaxSize, 0xae000);
        expect(spec.nrfSoftdeviceIds, [0xb6]);
      }
      for (final board in [
        'Seeed Xiao-nrf52',
        'Seeed Wio Tracker L1',
        'Seeed Tracker T1000-E',
        'Seeed SenseCap Solar',
        'SolarXiao 30S',
        'Ikoka Stick-E22-30dBm (Xiao_nrf52)',
      ]) {
        final spec = CompanionBoardCatalog.lookup(board)!;
        expect(spec.nrfApplicationAddress, 0x27000);
        expect(spec.nrfApplicationMaxSize, 0xad000);
        expect(spec.nrfSoftdeviceIds, [0x123]);
      }
      final meshtiny = CompanionBoardCatalog.lookup('Meshtiny')!;
      expect(meshtiny.nrfApplicationAddress, 0x26000);
      expect(meshtiny.nrfApplicationMaxSize, 0xc7000);
      expect(
        CompanionBoardCatalog.lookup('RAK4631 + W25Q16')!.nrfApplicationAddress,
        isNull,
      );
    },
  );

  test(
    'unknown vendors, revisions and custom labels never become guessed boards',
    () {
      for (final name in [
        null,
        '',
        'Unknown board',
        'Unknown Heltec Tower V2',
        'ESP32 Tower V2',
        'Heltec Tower V3',
        'tower_v2_custom',
        'Heltec V99',
        'Unknown ESP32',
        'ESP32',
        'Generic ESP32',
        'Custom nRF52840',
        'ThinkNode M10',
        'Xiao C7',
        'Xiao Custom',
        'LilyGo T-Echo Custom',
        'LilyGo T-Echo Card unofficial',
        'RAK4631 custom storage',
        'Custom T096',
        'T096-compatible',
      ]) {
        expect(CompanionBoardCatalog.lookup(name), isNull, reason: '$name');
        expect(
          CompanionFirmwareInspector.updateExtensionForBoard(name),
          isNull,
          reason: '$name',
        );
      }
    },
  );
}
