import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/phone_mota_signing_key.dart';

void main() {
  test('generates unique Ed25519 public keys and clears seeds', () async {
    final first = await PhoneMotaSigningKey.generate();
    final second = await PhoneMotaSigningKey.generate();
    expect(first.seed.length, 32);
    expect(first.publicKeyHex, matches(RegExp(r'^[0-9A-F]{64}$')));
    expect(first.publicKeyHex, isNot(second.publicKeyHex));
    expect(first.fingerprint, first.publicKeyHex.substring(0, 16));
    first.clear();
    second.clear();
    expect(first.seed, everyElement(0));
    expect(second.seed, everyElement(0));
  });

  test('matches only complete signer fingerprints in CLI reply', () {
    expect(
      PhoneMotaSigningKey.isListed(
        'trusted signer keys (2): 0011223344556677 AABBCCDDEEFF0011',
        'aabbccddeeff0011',
      ),
      isTrue,
    );
    expect(
      PhoneMotaSigningKey.isListed(
        'trusted signer keys (1): 0011223344556677',
        'AABBCCDDEEFF0011',
      ),
      isFalse,
    );
  });
}
