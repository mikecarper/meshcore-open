# Offline partition preflight

The canonical LUT and generator live in the firmware fork:

- https://github.com/mikecarper/MeshCore/blob/keymindCascade/firmware/esp32_partition_catalog.json
- https://github.com/mikecarper/MeshCore/blob/keymindCascade/docs/esp32_partition_catalog.md

`assets/firmware/esp32_partition_catalog.json` is an identical bundled snapshot.
Refresh it with the firmware generator's `--copy-to` option, then run:

```sh
flutter test --dart-define=LEGACY_ARM32=true
flutter build apk --release --target-platform android-arm --dart-define=LEGACY_ARM32=true
```

`Esp32PartitionCatalog.check` first requests `get storage.layout` through the
existing authenticated management connection. Old firmware errors/timeouts
fall back to the local catalog using the reported board, role and version.
No terminal interaction or Internet connection is required on the phone.

Known oversized images are blocked before starting the regular updater. For a
repeater or room-server migration ZIP, the app checks the reported board, role,
optional exact OTA target, physical flash size when reported, and current slot
capacity. If the full image already fits, it loads that image into the normal
Wi-Fi updater and skips the bridge. If expansion is needed, it checks that the
bridge fits the old slot before offering the two-step route. Unknown or
single-app layouts stop the automatic migration. The bridge's on-device table
validation still gates the final upload. Version estimates never authorize
table rewrites by themselves.

Companion Wi-Fi uses the same preflight, but Companion partition migration is
not implemented on that screen. Single-app builds require a cable installation.
Unknown or conflicting version estimates remain visible in the confirmation;
normal OTA still relies on the device updater's capacity checks. Replacing the
selected image clears its previous capacity result and update endpoint.

The LUT includes published upstream MeshCore, EasySkyMesh/PowerSaving, and
mikecarper MeshCore images. It cannot reconstruct a custom or previously
migrated device table from its firmware version alone.
