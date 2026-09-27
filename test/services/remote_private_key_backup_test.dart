import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/meshcore_expanded_identity.dart';
import 'package:meshcore_open/services/remote_private_key_backup.dart';

Future<Uint8List> expandedPrivateKey(Uint8List seed) async {
  final key = Uint8List.fromList((await Sha512().hash(seed)).bytes);
  key[0] &= 248;
  key[31] &= 63;
  key[31] |= 64;
  return key;
}

void main() {
  test('recognizes only bounded key backup replies', () {
    const nonce = '0011223344556677';
    const key =
        'AABBCCDDEEFF00112233445566778899'
        'AABBCCDDEEFF00112233445566778899'
        'AABBCCDDEEFF00112233445566778899'
        'AABBCCDDEEFF00112233445566778899';
    final reply = parsePrivateKeyBackupReply('KEYBACKUP $nonce $key');
    expect(reply?.nonce, nonce);
    expect(reply?.key.length, 64);
    expect(parsePrivateKeyBackupReply('KEYBACKUP $nonce ${key}00'), isNull);
    expect(looksLikePrivateKeyBackupReply('KEYBACKUP bad'), isTrue);
    expect(looksLikePrivateKeyBackupReply('hello KEYBACKUP'), isFalse);
    expect(generatePrivateKeyBackupNonce(), matches(RegExp(r'^[0-9A-F]{16}$')));
  });

  test(
    'encrypts a matching identity and restores only with passphrase',
    () async {
      final seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final expanded = await expandedPrivateKey(seed);
      final public = Uint8List.fromList(
        (await (await Ed25519().newKeyPairFromSeed(
          seed,
        )).extractPublicKey()).bytes,
      );
      expect(deriveMeshCoreExpandedPublicKey(expanded), public);
      final encrypted = await RemotePrivateKeyBackup.encrypt(
        privateKey: expanded,
        publicKey: public,
        passphrase: 'strong test passphrase',
      );
      final json = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
      expect(json['format'], 'meshcore-private-key-backup-v1');
      expect(json.values.join(), isNot(contains(seed.join(','))));
      final restored = await RemotePrivateKeyBackup.decrypt(
        encrypted,
        'strong test passphrase',
      );
      expect(restored, expanded);
      await expectLater(
        RemotePrivateKeyBackup.decrypt(encrypted, 'incorrect passphrase'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      restored.fillRange(0, restored.length, 0);
      expanded.fillRange(0, expanded.length, 0);
      seed.fillRange(0, seed.length, 0);
    },
  );

  test('rejects key from a different target', () async {
    final seed = Uint8List(32)..[0] = 1;
    final other = Uint8List(32)..[0] = 2;
    final expanded = await expandedPrivateKey(seed);
    final wrongPublic = Uint8List.fromList(
      (await (await Ed25519().newKeyPairFromSeed(
        other,
      )).extractPublicKey()).bytes,
    );
    await expectLater(
      RemotePrivateKeyBackup.encrypt(
        privateKey: expanded,
        publicKey: wrongPublic,
        passphrase: 'strong test passphrase',
      ),
      throwsFormatException,
    );
    expanded.fillRange(0, expanded.length, 0);
  });
}
