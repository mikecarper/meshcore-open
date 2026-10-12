import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/analyzer_packet_service.dart';

const raw = '3E00545642311122334455667788800092651E000800010264C8FEFFDC';
void main() {
  test(
    'region required and queries are read-only, bounded, without credentials',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.host, 'api.letsmesh.net');
        expect(request.url.path, '/api/packets');
        expect(request.url.queryParameters, {'region': 'SEA', 'limit': '100'});
        expect(request.body, isEmpty);
        expect(request.headers.containsKey('authorization'), false);
        return http.Response(
          jsonEncode({
            'packets': [
              {'raw': raw},
              {'raw': raw},
              {'raw': 'invalid'},
            ],
          }),
          200,
        );
      });
      final service = AnalyzerPacketService(client: client);
      expect(() => service.fetchPackets(''), throwsFormatException);
      expect((await service.fetchPackets(' sea ', limit: 900)).single.raw, raw);
      client.close();
    },
  );
  test(
    'accepts list responses and explains access errors or non-JSON',
    () async {
      for (final status in [200, 401, 403, 429]) {
        final client = MockClient(
          (_) async => http.Response(
            status == 200
                ? jsonEncode([
                    {'raw_hex': raw},
                  ])
                : '<html>blocked</html>',
            status,
          ),
        );
        final service = AnalyzerPacketService(client: client);
        if (status == 200) {
          expect(await service.fetchPackets('SEA'), hasLength(1));
        } else if (status == 401) {
          await expectLater(
            service.fetchPackets('SEA'),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                contains('requires access (HTTP 401)'),
              ),
            ),
          );
        } else {
          await expectLater(service.fetchPackets('SEA'), throwsFormatException);
        }
        client.close();
      }
      final client = MockClient(
        (_) async => http.Response('<html>challenge</html>', 200),
      );
      await expectLater(
        AnalyzerPacketService(client: client).fetchPackets('SEA'),
        throwsFormatException,
      );
      client.close();
    },
  );
}
