import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// An update-only key. The seed stays in memory until the caller zeroes it;
/// only the public key is sent to the authenticated repeater CLI.
class PhoneMotaSigningKey {
  PhoneMotaSigningKey._(this.seed, this.publicKeyHex);

  final Uint8List seed;
  final String publicKeyHex;

  String get fingerprint => publicKeyHex.substring(0, 16).toUpperCase();

  static Future<PhoneMotaSigningKey> generate() async {
    final random = Random.secure();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final public = await pair.extractPublicKey();
    final hex = public.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return PhoneMotaSigningKey._(seed, hex);
  }

  static bool isListed(String reply, String fingerprint) {
    final expected = fingerprint.toUpperCase();
    return RegExp(r'\b[0-9A-Fa-f]{16}\b')
        .allMatches(reply)
        .any((match) => match.group(0)!.toUpperCase() == expected);
  }

  void clear() => seed.fillRange(0, seed.length, 0);
}
