import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';

void main() {
  final path = Platform.environment['NRFDFU_TOWER_FIXTURE'];
  test(
    'accepts the real board-matched Tower Full Companion release',
    () async {
      final package = NrfDfuPackage.inspect(await File(path!).readAsBytes());
      // This fixture was independently built and exercised on the physical
      // Tower. Never synthesize production provenance from an arbitrary file.
      const expected =
          '4aaf6104340ce474117653280e95ae5847539cddb73c00aabdafd1cce7acc445';
      expect(package.sha256, expected);
      package.validateForBoard(
        'Heltec Tower V2',
        provenance: CompanionFirmwareProvenance(
          boardId: CompanionBoardCatalog.lookup('Heltec Tower V2')!.id,
          sha256: expected,
          profile: 'full',
        ),
      );
      expect(package.components, ['application']);
      expect(package.applicationIdentity?.hardwareId, 'Heltec_tower_v2');
      expect(package.applicationBaseHash, matches(r'^[0-9a-f]{16}$'));
    },
    skip: path == null
        ? 'Set NRFDFU_TOWER_FIXTURE to the qualified release ZIP'
        : false,
  );
}
