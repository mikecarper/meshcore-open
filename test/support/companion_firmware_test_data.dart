import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:meshcore_open/services/usb_nrf_dfu.dart';
import 'package:meshcore_open/services/companion_target_catalog.dart';

Uint8List testEndf(
  Uint8List body,
  String hardwareId, {
  String? targetEnv,
  int? targetId,
}) {
  final image = Uint8List(body.length + 56)..setAll(0, body);
  final tail = Uint8List.sublistView(image, body.length);
  final data = ByteData.sublistView(tail);
  tail.setAll(0, ascii.encode('EndF'));
  data.setUint32(4, body.length, Endian.little);
  tail.setAll(8, sha256.convert(body).bytes.take(8));
  data.setUint32(16, 0x01110109, Endian.little);
  final prefix = hardwareId == 'RAK4631' ? 'RAK_4631' : hardwareId;
  data.setUint32(
    20,
    targetId ??
        (hardwareId == 'TEST_BOARD'
            ? 0x11223344
            : CompanionTargetCatalog.targetIdForEnvironment(
                targetEnv ?? '${prefix}_companion_radio_ble',
              )),
    Endian.little,
  );
  tail.setAll(24, ascii.encode(hardwareId));
  return image;
}

Uint8List testNrfApplication({
  String hardwareId = 'Heltec_t096',
  bool marked = true,
  int size = 1024,
  int applicationAddress = 0x26000,
  String? targetEnv,
  int? targetId,
}) {
  final body = Uint8List(size);
  final vector = ByteData.sublistView(body);
  vector.setUint32(0, 0x20040000, Endian.little);
  vector.setUint32(4, applicationAddress + 0x81, Endian.little);
  return marked
      ? testEndf(body, hardwareId, targetEnv: targetEnv, targetId: targetId)
      : body;
}

Uint8List testNrfDfuZip({
  Uint8List? image,
  int softdevice = 0xb6,
  String component = 'application',
  String binName = 'application.bin',
  bool omitDat = false,
  bool corruptCrc = false,
}) {
  image ??= testNrfApplication();
  final init = Uint8List(14);
  final data = ByteData.sublistView(init);
  data.setUint16(0, 82, Endian.little);
  data.setUint16(2, 65535, Endian.little);
  data.setUint32(4, 0xffffffff, Endian.little);
  data.setUint16(8, 1, Endian.little);
  data.setUint16(10, softdevice, Endian.little);
  data.setUint16(12, nrfDfuCrc16(image) ^ (corruptCrc ? 1 : 0), Endian.little);
  final archive = Archive()
    ..add(
      ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(
          jsonEncode({
            'manifest': {
              'dfu_version': 0.5,
              component: {'bin_file': binName, 'dat_file': 'application.dat'},
            },
          }),
        ),
      ),
    )
    ..add(ArchiveFile.bytes(binName, image));
  if (!omitDat) archive.add(ArchiveFile.bytes('application.dat', init));
  return ZipEncoder().encodeBytes(archive);
}

Uint8List testEspApplication({
  String hardwareId = 'heltec_v4',
  int chip = 9,
  bool marked = true,
  bool appendedHash = true,
  int dataBytes = 1024,
  String? targetEnv,
  int? targetId,
}) {
  final checksumOffset = ((32 + dataBytes) ~/ 16 + 1) * 16 - 1;
  final hashOffset = checksumOffset + 1;
  final body = Uint8List(hashOffset + (appendedHash ? 32 : 0));
  body[0] = 0xe9;
  body[1] = 1;
  body[2] = 2;
  body[3] = 0x20;
  final fields = ByteData.sublistView(body);
  fields.setUint16(12, chip, Endian.little);
  body[23] = appendedHash ? 1 : 0;
  fields.setUint32(24, 0x3c000020, Endian.little);
  fields.setUint32(28, dataBytes, Endian.little);
  body[32] = 0x55;
  body[checksumOffset] = 0xef ^ 0x55;
  if (appendedHash) {
    body.setAll(hashOffset, sha256.convert(body.sublist(0, hashOffset)).bytes);
  }
  return marked
      ? testEndf(body, hardwareId, targetEnv: targetEnv, targetId: targetId)
      : body;
}
