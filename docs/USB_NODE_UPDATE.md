# Native Android USB updater

Open **Settings > Update over USB**, or **USB connection > Update over USB**.
Use the native Android APK, a data-capable USB cable/OTG adapter, and stable
power. Browser Web Serial is not involved. Drivers include CH340/CH341,
CP210x, FTDI, Prolific and CDC/ACM; the serial driver's availability does not
prove which radio board is connected.

Both Android build profiles include the USB updater. Android 5.1.1 uses the
legacy ARMv7 APK; the modern ARM64 APK requires Android 9/API 28 or later.
ESP32 flashing requires an updated Android System WebView that can run the
bundled JavaScript module. Stock Android 5.1.1 WebView is too old; update it
before using ESP32 flashing. Runtime readiness is checked before bootloader
preparation, and failure stops with an explanation rather than resetting the
node. Backup/restore and nRF52 DFU do not use WebView.

## Updating an application

1. Select the physical USB node explicitly. Android asks for USB permission;
   permission may need to be granted again after a bootloader re-enumeration.
2. Choose an application file, a Keymind release asset, or an HTTPS URL.
   ESP32 uses an application-only BIN. nRF52 uses an application-only legacy
   Adafruit serial-DFU ZIP. Merged installs, UF2s, bootloaders, SoftDevices and
   full-chip erase are intentionally not offered by this updater.
3. Leave **Create and verify a backup first** enabled. This happens before
   bootloader preparation and final write confirmation. DFU cannot expose
   running MeshCore configuration; the app explains this and requires explicit
   consent to continue without a usable backup. Unsupported/missing private
   fields produce a partial archive, never a falsely complete one.
4. Confirm preparation. The app checks the real ESP32 chip MAC, flash capacity,
   partition table, OTA selection and live NVS. Unknown/mismatched board
   descriptions require a displayed exact one-time override token; Enter does
   not accept it. Overrides do not bypass integrity, chip, geometry or
   restoration checks.
5. Confirm the write. Ordinary updates write every app slot inactive-first,
   active-last. Images that fit do not fetch or run migration utilities.
6. Keep the cable connected until the running application answers and its
   firmware version and previously known public identity verify. Transfer ACKs
   or reaching 100% alone are not success.

The app disconnects its normal Companion session before obtaining the exclusive
raw USB session. Native TinyUSB bootloader touch is explicit; hardware USB/JTAG
and UART reset use their appropriate mechanisms. If a stable USB identity is
unavailable, the app stops for explicit selection of the original physical
node. Matching VID/PID or a recycled Android bus address is not proof.

## Automatic partition expansion

Only reviewed ESP32/ESP32-C3/ESP32-S3 4/8/16 MiB board/role plans qualify. The
selected final image must match the exact Full migration package, including
EndF identity, release, hardware, target, capacity and SHA-256. An embedded
verified USB bridge takes precedence. A qualified old Wi-Fi-only package can
fetch the separately published, versioned USB bridge set with a pinned archive
checksum. Malformed embedded metadata does not silently fall back.

The app requires a separate expansion confirmation and durably saves a public
MAC/image-bound recovery journal before its first bridge write. Native USB
recovery waits for automatic ROM return with passive probes, without resetting
a bridge that could still be restoring settings. Classic USB-UART requires a
fresh newline-complete, matching-MAC settled status before host reset. USB
reappearance or a timer alone never permits the final app write.

The final app is written only after exact target-table and CRC-valid live NVS
restored/no-pending flags verify. Retries remain bound to the original final
image, public identity and cached artifact hashes; a different firmware cannot
bypass an unfinished migration. Recovery ZIPs must remain inside the private
artifact cache. Optional offline Full/USB ZIPs get the same package validation;
their original qualification and hashes are preserved on resume.

Keep stable power. Partition-sector replacement is **not power-loss atomic**;
power loss can still require physical recovery. Unsupported stored files and
logs may not survive. This is not a replacement for a complete filesystem dump.

## Backup and restore

**Backup only** works without selecting firmware. Archives use the existing
`org.meshfirmware.meshcore-backup/v1` schema and canonical JSON checksum, so
desktop meshfirmware can validate them. They are saved under the Android app's
private `usb-updater/backups/` directory; the screen displays the exact path.
They can contain expanded private identity and channel keys: export only by
explicitly tapping **Export private backup**, and keep exported files secure.

Companion restore checks the checksum and verifies supported writes. Moving
configuration to different hardware requires explicit approval and does not
blindly copy board calibration or power limits. Moving private identity is a
separate exact-token approval; never operate the old and new nodes with the
same private identity. Firmware metadata is never restored. Full Companion
logging is restored to the saved state; BLE is cycled only if enabled.
The destination choice and identity choice are separate. **Keep node identity**
allows settings-only migration to different hardware. **Import backup identity**
is also available for an erased original node and requires the exact private-key
approval token. **Cancel restore** stops without restoring settings.

CommonCLI repeater/room snapshots are explicitly partial. They are useful for
manual recovery, but automatic CommonCLI restore is not supported without a
versioned bulk configuration API. No logical USB archive is claimed safe for a
whole-chip wipe or to contain every unread message/filesystem file.

## Verification status and dependencies

Software tests cover raw transport, true pinned serial drivers, actual
Espressif transport APIs, legacy nRF HCI/SLIP vectors, canonical backup
interoperability, exact real release packages, malformed inputs and interrupted
migration gates. Physical tablet/radio flashing remains to be validated.

Android uses pinned `usb-serial-for-android` 3.11.0 and an offline, licensed,
checksum-recorded Espressif esptool-js 0.7.0 bundle. It never downloads and
executes browser code at runtime. Secure boot, encryption and unsupported
recovery modes are refused before flashing. The new screen is Android-only;
Windows/Linux still use their normal meshfirmware scripts.
The Android backend currently supports ordinary ESP32, ESP32-S2, ESP32-C2,
ESP32-C3 and ESP32-S3 application updates. ESP32-C6 and other unreviewed chip
families are refused before any flash write. Migration is narrower: only the
reviewed ESP32/C3/S3 board/role packages qualify.

## Building and installing

Use the pinned legacy and modern profiles in [Android builds](ANDROID_BUILDS.md).
Both release APKs share the normal application ID, app version and signing
identity; they cannot be installed side by side. Install the APK matching the
device architecture and Android version. Do not uninstall an existing app to
bypass a signing mismatch: that removes its private data and backups.

These are explicit sideload candidates, not production-store releases. Each
release includes build manifests and checksums identifying the exact source,
SDK, signing mode and APK. Native AI remains unavailable in the legacy build;
ordinary messaging, USB backups and supported firmware workflows remain present.
