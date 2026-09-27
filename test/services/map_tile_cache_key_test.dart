import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/map_tile_cache_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class _NoopCacheManager extends Fake implements BaseCacheManager {}

void main() {
  test('live tile requests identify the app, matching offline downloads', () {
    final settings = AppSettingsService();
    final service = MapTileCacheService(
      appSettingsService: settings,
      cacheManager: _NoopCacheManager(),
    );
    final provider = service.tileProvider as CachedNetworkTileProvider;
    expect(
      provider.headers['User-Agent'],
      service.defaultHeaders['User-Agent'],
    );
    expect(provider.headers['User-Agent'], contains('com.meshcore.open'));
    service.dispose();
    settings.dispose();
  });
  test('tile cache key drops api_key and keeps everything else', () {
    expect(
      MapTileCacheService.tileCacheKey(
        'https://tiles.stadiamaps.com/tiles/outdoors/10/1/2@2x.png?api_key=k1',
      ),
      'https://tiles.stadiamaps.com/tiles/outdoors/10/1/2@2x.png',
    );
    expect(
      MapTileCacheService.tileCacheKey('https://x/t/1/2/3.png?a=1&api_key=k2'),
      'https://x/t/1/2/3.png?a=1',
    );
    expect(
      MapTileCacheService.tileCacheKey(
        'https://tile.openstreetmap.org/1/2/3.png',
      ),
      'https://tile.openstreetmap.org/1/2/3.png',
    );
  });
}
