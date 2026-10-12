import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mesh_packet_decoder.dart';

class AnalyzerPacket {
  const AnalyzerPacket({required this.raw, required this.label});
  final String raw;
  final String label;
}

class AnalyzerPacketService {
  AnalyzerPacketService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;
  void dispose() {
    if (_ownsClient) _client.close();
  }

  static String regionCode(String input) {
    final code = input.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
      throw const FormatException(
        'Select a three-letter analyzer region code, for example SEA.',
      );
    }
    return code;
  }

  static Uri website(String region) => Uri.https(
    'analyzer.letsmesh.net',
    '/packets',
    {'region': regionCode(region)},
  );

  /// Read-only API used by analyzer clients. Never uploads radio data,
  /// management passwords, or identity keys. No unrestricted global polling.
  Future<List<AnalyzerPacket>> fetchPackets(
    String region, {
    int limit = 50,
  }) async {
    final uri = Uri.https('api.letsmesh.net', '/api/packets', {
      'region': regionCode(region),
      'limit': '${limit.clamp(1, 100)}',
    });
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'application/json';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401) {
      await response.stream.listen(null).cancel();
      throw const FormatException(
        'Analyzer API requires access (HTTP 401). Open the analyzer, sign in if prompted, and paste its Raw Data here.',
      );
    }
    if (response.statusCode == 403) {
      await response.stream.listen(null).cancel();
      throw const FormatException(
        'Analyzer access was blocked (HTTP 403). Open the analyzer and paste its Raw Data here.',
      );
    }
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw FormatException('Analyzer returned HTTP ${response.statusCode}.');
    }
    var size = 0;
    final chunks = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      size += chunk.length;
      if (size > 2 * 1024 * 1024) {
        throw const FormatException('Analyzer response exceeded 2 MiB.');
      }
      chunks.addAll(chunk);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(chunks));
    } on FormatException {
      throw const FormatException(
        'Analyzer did not return JSON. Open it in a browser and paste Raw Data.',
      );
    }
    final records = decoded is List
        ? decoded
        : decoded is Map
        ? decoded['packets']
        : null;
    if (records is! List) {
      throw const FormatException('Analyzer packet list was missing.');
    }
    final unique = <String, AnalyzerPacket>{};
    for (final item in records.take(limit.clamp(1, 100))) {
      if (item is! Map) continue;
      final raw =
          item['raw'] ??
          item['raw_hex'] ??
          item['raw_data'] ??
          (item['data'] is Map ? item['data']['raw'] : null);
      if (raw is! String || raw.length > 2048) continue;
      try {
        final bytes = packetHexBytes(raw);
        final packet = decodeMeshPacket(bytes);
        final normalized = packetHex(bytes);
        unique[normalized] = AnalyzerPacket(
          raw: normalized,
          label:
              '${packet.typeName} - ${packet.hops} hops${item['timestamp'] != null ? ' - ${item['timestamp']}' : ''}',
        );
      } on FormatException {
        /* Skip malformed captures without hiding valid packets. */
      }
    }
    return unique.values.toList();
  }
}
