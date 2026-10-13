import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android codec releases its busy slot before posting either reply', () {
    final source = File(
      'android/app/src/main/kotlin/com/meshcore/meshcore_open/'
      'MeshcoreImageCodec.kt',
    ).readAsStringSync();
    final worker = source.substring(
      source.indexOf('val generation = native.token()'),
      source.indexOf('private fun complete('),
    );
    // Source guard for Android scheduling, which Flutter's host test binding
    // cannot execute: the UI callback can run immediately after handler.post.
    // Both success and error must be captured before finally clears the slot.
    expect(worker, contains('val delivery: () -> Unit = try {'));
    expect(worker, contains('val success: () -> Unit = { result.success('));
    expect(worker, contains('val failure: () -> Unit = { result.error('));
    expect(worker, matches(RegExp(r'finally\s*\{\s*busy\.set\(false\)\s*\}')));
    final release = worker.indexOf('busy.set(false)');
    final reply = worker.indexOf('complete(delivery)');
    expect(release, greaterThanOrEqualTo(0));
    expect(reply, greaterThan(release));
    expect(worker.substring(0, release), isNot(contains('complete(')));
    expect(worker.substring(reply), isNot(contains('busy.set(false)')));
  });
}
