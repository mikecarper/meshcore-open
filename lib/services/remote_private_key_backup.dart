import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'meshcore_expanded_identity.dart';

class PrivateKeyBackupReply {
  const PrivateKeyBackupReply(this.nonce, this.key);

  final String nonce;
  final Uint8List key;
}

/// The marker lets the connector divert a sensitive CLI response before its
/// generic message persistence and raw-frame debug logging paths run.
PrivateKeyBackupReply? parsePrivateKeyBackupReply(String text) {
  final match = RegExp(
    r'^(?:[0-9A-Fa-f]{2}\|)?KEYBACKUP ([0-9A-Fa-f]{16}) ([0-9A-Fa-f]{128})$',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final keyHex = match.group(2)!;
  return PrivateKeyBackupReply(
    match.group(1)!.toUpperCase(),
    Uint8List.fromList(
      List<int>.generate(
        64,
        (i) => int.parse(keyHex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    ),
  );
}

bool looksLikePrivateKeyBackupReply(String text) {
  final body = text.trim().replaceFirst(RegExp(r'^[0-9A-Fa-f]{2}\|'), '');
  return body.startsWith('KEYBACKUP');
}

String generatePrivateKeyBackupNonce() {
  final random = Random.secure();
  return List<int>.generate(8, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// Portable encrypted JSON: PBKDF2-HMAC-SHA256 + AES-256-GCM. No plaintext
/// key is written to storage. The public key binds recovery to the target.
class RemotePrivateKeyBackup {
  static const iterations = 210000;

  static Future<Uint8List> encrypt({
    required Uint8List privateKey,
    required Uint8List publicKey,
    required String passphrase,
  }) async {
    if (privateKey.length != 64 || publicKey.length != 32) {
      throw const FormatException(
        'MeshCore identity keys must be 64 private and 32 public bytes.',
      );
    }
    if (passphrase.length < 12) {
      throw const FormatException(
        'Use at least 12 characters for the backup passphrase.',
      );
    }
    final derivedPublic = deriveMeshCoreExpandedPublicKey(privateKey);
    if (!_equal(derivedPublic, publicKey)) {
      throw const FormatException(
        'The received private key does not match this target.',
      );
    }
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
    final algorithm = Pbkdf2.hmacSha256(iterations: iterations, bits: 256);
    final derived = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final box = await AesGcm.with256bits().encrypt(
      privateKey,
      secretKey: derived,
      nonce: nonce,
      aad: publicKey,
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
        'format': 'meshcore-private-key-backup-v1',
          'public_key': _hex(publicKey),
          'kdf': 'pbkdf2-hmac-sha256',
          'iterations': iterations,
          'salt': base64Encode(salt),
          'cipher': 'aes-256-gcm',
          'nonce': base64Encode(nonce),
          'ciphertext': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        }),
      ),
    );
  }

  static Future<Uint8List> decrypt(
    Uint8List contents,
    String passphrase,
  ) async {
    final data = jsonDecode(utf8.decode(contents));
    if (data is! Map ||
        data['format'] != 'meshcore-private-key-backup-v1' ||
        data['kdf'] != 'pbkdf2-hmac-sha256' ||
        data['cipher'] != 'aes-256-gcm' ||
        data['iterations'] != iterations) {
      throw const FormatException('Unsupported private-key backup format.');
    }
    final publicHex = data['public_key'];
    if (publicHex is! String ||
        !RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(publicHex)) {
      throw const FormatException('Backup public key is invalid.');
    }
    final publicKey = Uint8List.fromList(
      List<int>.generate(
        32,
        (i) => int.parse(publicHex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
    final salt = base64Decode(data['salt'] as String);
    final nonce = base64Decode(data['nonce'] as String);
    final cipherText = base64Decode(data['ciphertext'] as String);
    final mac = base64Decode(data['mac'] as String);
    if (salt.length != 16 ||
        nonce.length != 12 ||
        mac.length != 16 ||
        cipherText.length != 64) {
      throw const FormatException('Backup parameters are invalid.');
    }
    final key = await Pbkdf2.hmacSha256(
      iterations: iterations,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: publicKey,
    );
    final privateKey = Uint8List.fromList(clear);
    if (!_equal(deriveMeshCoreExpandedPublicKey(privateKey), publicKey)) {
      privateKey.fillRange(0, privateKey.length, 0);
      throw const FormatException('Backup target identity does not match.');
    }
    return privateKey;
  }

  static bool _equal(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }

  static String _hex(List<int> bytes) => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}
