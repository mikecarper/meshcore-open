import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/usb_firmware_catalog.dart';

void main() {
  test(
    'lazy default IOClient imports bundled roots without a TLS bypass',
    () async {
      final publicRoots = await File(
        UsbFirmwareCatalog.legacyRootsAsset,
      ).readAsBytes();
      final assets = _TestAssetBundle(
        (_) async => ByteData.sublistView(publicRoots),
      );
      final nativeClient = _TrackingHttpClient();
      var clientsCreated = 0;
      SecurityContext? configuredContext;
      final catalog = UsbFirmwareCatalog(assetBundle: assets);
      expect(assets.requested, isEmpty);

      await HttpOverrides.runZoned(
        () async {
          for (var attempt = 0; attempt < 2; attempt++) {
            await expectLater(
              catalog.download(Uri.parse('https://example.test/app.bin')),
              throwsA(same(nativeClient.noNetwork)),
            );
          }
          expect(clientsCreated, 1);
          expect(configuredContext, isA<SecurityContext>());
          expect(assets.requested, [UsbFirmwareCatalog.legacyRootsAsset]);
          expect(nativeClient.rejectedCertificateCallbackSet, isFalse);
          catalog.dispose();
          catalog.dispose();
          expect(nativeClient.closes, 1);
        },
        createHttpClient: (context) {
          clientsCreated++;
          configuredContext = context;
          return nativeClient;
        },
      );
    },
  );

  test(
    'invalid bundled roots fail before creating a client or requesting data',
    () async {
      final invalidRoots = Uint8List.fromList(utf8.encode('not a certificate'));
      final assets = _TestAssetBundle(
        (_) async => ByteData.sublistView(invalidRoots),
      );
      final catalog = UsbFirmwareCatalog(assetBundle: assets);
      var clientsCreated = 0;
      await HttpOverrides.runZoned(
        () => expectLater(
          catalog.download(Uri.parse('https://example.test/app.bin')),
          throwsA(anyOf(isA<TlsException>(), isA<ArgumentError>())),
        ),
        createHttpClient: (_) {
          clientsCreated++;
          return _TrackingHttpClient();
        },
      );
      expect(assets.requested, [UsbFirmwareCatalog.legacyRootsAsset]);
      expect(clientsCreated, 0);
      catalog.dispose();
    },
  );

  test(
    'injected clients do not load roots or transfer close ownership',
    () async {
      final client = _TrackingMockClient();
      final assets = _TestAssetBundle((_) => throw StateError('must not load'));
      final catalog = UsbFirmwareCatalog(client: client, assetBundle: assets);
      expect(
        await catalog.download(Uri.parse('https://example.test/app.bin')),
        utf8.encode('application'),
      );
      catalog.dispose();
      expect(client.closes, 0);
      expect(assets.requested, isEmpty);
      expect(
        (await client.get(
          Uri.parse('https://example.test/app.bin'),
        )).statusCode,
        200,
      );
      client.close();
    },
  );

  test(
    'disposal during lazy asset loading prevents a late client leak',
    () async {
      final loaded = Completer<ByteData>();
      final assets = _TestAssetBundle((_) => loaded.future);
      final catalog = UsbFirmwareCatalog(assetBundle: assets);
      var clientsCreated = 0;
      await HttpOverrides.runZoned(
        () async {
          final pending = catalog.download(
            Uri.parse('https://example.test/app.bin'),
          );
          final rejected = expectLater(pending, throwsStateError);
          catalog.dispose();
          loaded.complete(ByteData(0));
          await rejected;
        },
        createHttpClient: (_) {
          clientsCreated++;
          return _TrackingHttpClient();
        },
      );
      expect(clientsCreated, 0);
      await expectLater(
        catalog.download(Uri.parse('https://example.test/app.bin')),
        throwsStateError,
      );
    },
  );

  test('firmware downloads are bounded and SHA/length verified', () async {
    final payload = utf8.encode('test application');
    final catalog = UsbFirmwareCatalog(
      client: MockClient((_) async => http.Response.bytes(payload, 200)),
    );
    final result = await catalog.download(
      Uri.parse('https://example.test/app.bin'),
      expectedSha256: sha256.convert(payload).toString(),
      expectedBytes: payload.length,
    );
    expect(result, payload);
    await expectLater(
      catalog.download(
        Uri.parse('https://example.test/app.bin'),
        expectedSha256: '0' * 64,
      ),
      throwsFormatException,
    );
    await expectLater(
      catalog.download(Uri.parse('https://example.test/app.bin'), limit: 3),
      throwsFormatException,
    );
    await expectLater(
      catalog.download(
        Uri.parse('https://example.test/app.bin'),
        expectedBytes: 1,
      ),
      throwsFormatException,
    );
  });

  test('HTTP and credentials are refused before requesting data', () async {
    var requests = 0;
    final catalog = UsbFirmwareCatalog(
      client: MockClient((_) async {
        requests++;
        return http.Response('not used', 200);
      }),
    );
    for (final url in [
      'http://example.test/app.bin',
      'https://secret@example.test/app.bin',
    ]) {
      await expectLater(
        catalog.download(Uri.parse(url)),
        throwsFormatException,
      );
    }
    expect(requests, 0);
  });

  test(
    'redirects cannot downgrade HTTPS and valid redirects are bounded',
    () async {
      final requested = <Uri>[];
      final catalog = UsbFirmwareCatalog(
        client: MockClient((request) async {
          requested.add(request.url);
          expect(request.followRedirects, false);
          return http.Response(
            '',
            302,
            headers: {'location': 'http://example.test/app.bin'},
          );
        }),
      );
      await expectLater(
        catalog.download(Uri.parse('https://example.test/app.bin')),
        throwsFormatException,
      );
      expect(requested.length, 1);
      var count = 0;
      final loop = UsbFirmwareCatalog(
        client: MockClient((_) async {
          count++;
          return http.Response('', 302, headers: {'location': '/again'});
        }),
      );
      await expectLater(
        loop.download(Uri.parse('https://example.test/app.bin')),
        throwsFormatException,
      );
      expect(count, 6);
    },
  );

  test('empty or failed downloads cannot become firmware', () async {
    for (final response in [
      http.Response('', 200),
      http.Response('failure', 404),
    ]) {
      final catalog = UsbFirmwareCatalog(
        client: MockClient((_) async => response),
      );
      await expectLater(
        catalog.download(Uri.parse('https://example.test/app.bin')),
        throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
      );
    }
  });

  test(
    'release choices exclude migration/bootloader and foreign assets',
    () async {
      const tag = 'v1.17.1.9-halo-keymind-cascade-dev-88c85108';
      Map<String, Object> asset(String name, {String? url}) => {
        'name': name,
        'size': 42,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url':
            url ??
            'https://github.com/mikecarper/MeshCore/releases/download/$tag/$name',
      };
      final body = jsonEncode([
        {
          'tag_name': 'utility-usb-partition-v1',
          'assets': [asset('esp32_repeater.bin')],
        },
        {
          'tag_name': tag,
          'draft': false,
          'assets': [
            asset('heltec_v4_repeater.bin'),
            asset('rak_companion.zip'),
            asset('rak_companion_bootloader.zip'),
            asset('heltec_repeater_migration.zip'),
            asset(
              'private_companion.bin',
              url: 'https://example.test/foreign.bin',
            ),
          ],
        },
      ]);
      final catalog = UsbFirmwareCatalog(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      final choices = await catalog.listKeymind();
      expect(choices.map((c) => c.name), [
        'heltec_v4_repeater.bin',
        'rak_companion.zip',
      ]);
      expect(choices.first.sha256Hex, 'a' * 64);
    },
  );
}

class _TestAssetBundle extends CachingAssetBundle {
  _TestAssetBundle(this.loader);

  final Future<ByteData> Function(String) loader;
  final requested = <String>[];

  @override
  Future<ByteData> load(String key) {
    requested.add(key);
    return loader(key);
  }
}

class _TrackingHttpClient implements HttpClient {
  final noNetwork = StateError('hermetic test does not open a network socket');
  int closes = 0;
  bool rejectedCertificateCallbackSet = false;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Future.error(noNetwork);

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) {
    rejectedCertificateCallbackSet = callback != null;
  }

  @override
  void close({bool force = false}) => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackingMockClient extends MockClient {
  _TrackingMockClient() : super((_) async => http.Response('application', 200));
  int closes = 0;

  @override
  void close() => closes++;
}
