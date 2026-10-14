# MeshCore Open

Open-source Flutter client for MeshCore LoRa mesh networking devices.

## Overview

MeshCore Open is a cross-platform mobile application for communicating with MeshCore LoRa mesh network devices via Bluetooth Low Energy (BLE). The app enables long-range, off-grid communication through peer-to-peer messaging, public channels, and mesh networking capabilities.

**Website:** [meshcoreopen.org](https://meshcoreopen.org/)

<a href="http://apps.obtainium.imranr.dev/redirect.html?r=obtainium://add/https://github.com/zjs81/meshcore-open">
        <img src="assets/badges/badge_obtainium.png" height="80" align="center" alt="Get it on Obtainium"/>
</a>

## Screenshots

<table>
  <tr>
    <td><img src="docs/screenshots/contacts.jpg" width="200"/><br/><p align="center"><b>Contacts</b></p></td>
    <td><img src="docs/screenshots/chat1.jpg" width="200"/><br/><p align="center"><b>Chat</b></p></td>
    <td><img src="docs/screenshots/chat2.jpg" width="200"/><br/><p align="center"><b>Reactions</b></p></td>
    <td><img src="docs/screenshots/map.jpg" width="200"/><br/><p align="center"><b>Map</b></p></td>
    <td><img src="docs/screenshots/channels.jpg" width="200"/><br/><p align="center"><b>Channels</b></p></td>
  </tr>
</table>

## Features

### Core Functionality

- **Direct Messaging**: Private encrypted conversations with individual contacts
- **Public Channels**: Broadcast messages to channel subscribers on the mesh network
- **Contact Management**: Organize contacts, track last seen times, and manage conversation history
- **Contact Groups**: Create custom groups to organize your mesh network contacts
- **Message Reactions**: React to messages with emoji responses
- **Message Replies**: Thread conversations with inline reply functionality

### Native image messages

The native AEIC FT2 phone model encodes and reconstructs images at **128, 192,
256, 320, 384, 448, 512, and 576 pixels**. The send preview starts at 128 pixels,
uses a centered square crop, and displays the actual compressed file size before
sending. Native wire code 2 carries dimensions in the bitstream header; existing
FT32/FT16 wire formats remain unchanged.

Model weights install separately and use about **2 GB of storage**. Graphs load
one at a time to keep the full model out of RAM. Reconstruction is lossy and can
take several minutes on older phones; the tiny compressed files depend on the
photo and do not include the trained model. Strict decoding is the default.
Failed native images offer an explicit **Recover image** retry; recovered
pictures say “Recovered image. Some detail may be missing.”

Image reconstruction offers **Fast** and **Accurate** in image settings.
An unset preference defaults to Fast when the loaded backend has no usable GPU
acceleration; the current native backend runs on the CPU. Accurate keeps the
conservative decoder kernels. Fast uses bounded CPU optimizations up to 256 pixels
(validated at 128 and 256); larger sizes currently use the same memory-safe kernels as Accurate.
Encoding, entropy decoding, and the compressed file format are unchanged.

The final shipped ARMv7 binary passed an actual 128-pixel app-service Fast
cycle: 137 compressed bytes, 2.024 seconds service encoding, and 89.325 seconds
service reconstruction, including the deliberate test pause. The native
decoder took 88.928 seconds and peaked at 232.7 MiB. Accurate pause/cancel
returned no image and reaped its worker; Fast pause/resume completed with no
active jobs left. The normal full app was installed and checked for the Fast
default and a saved Accurate selection. These timings used four test threads;
the normal app keeps its two-thread default. The final 256-pixel Fast CLI run
took 258.846 seconds, peaked at 238.3 MiB, and passed all 19 integer checks with
the exact 407-byte stream. Its PNG matched the preceding Fast trial byte for byte.

In the paired trial **before the subsequent weight-buffer allocation fix**,
the Android 5.1 ARMv7 benchmark phone decoded the same 128-pixel photo in
93.465 seconds with Fast versus 123.298 seconds with Accurate (24% less time).
At 256 pixels, it took 261.850 versus 410.207 seconds (36% less time), with
similar peak memory and exact entropy results. Fast changed 16 of the decoded RGB
components by at most one 8-bit level at 128 pixels, and 42 components at 256
pixels. These are paired pre-fix measurements of this photo, not timings for
the final shipped binary or guarantees for every image or phone.
The earlier 576-pixel app measurement below used conservative
kernels; no accelerated 576-pixel run is claimed.

All eight benchmark phone encodings match the original CPU codec byte for byte.
Earlier native CLI reconstruction passed at 128, 256, and 512 pixels. App-service
cycles have passed at 128 and 576 pixels. The supervised 576-pixel app run
encoded the exact 1,783-byte stream and reconstructed a 755,951-byte PNG without
recovery. Native decoding took 2,465.188 seconds (about 41 minutes) and peaked at
287.2 MiB; service decoding took 2,465.714 seconds. Both decode measurements
include a deliberate 1.249-second pause. Pause/resume and cancellation were
verified on the Android 5.1 phone, with workers reaped and no active jobs left.
Reconstruction remains lossy, and supported dimensions do not imply completed
phone validation at every size.

The separate [Android 5.1 build profile](build_profiles/README.md) supports API21
ARMv7 while keeping the modern dependency profile. Optional translation and
older ONNX image runtimes are unavailable in that legacy build; native FT2 remains
available. See [native packaging and validation](android/app/NATIVE_CODEC.md)
and the [AEIC mobile port on main](https://github.com/mikecarper/AEIC/tree/main/mobile)
for exporters, native source, and CC0 examples.

### Mesh Network

- **Path Visualization**: View routing paths and signal quality for each contact
- **Route Management**: Manual path overriding and automatic route rotation
- **Signal Metrics**: Real-time SNR (Signal-to-Noise Ratio) tracking
- **Node Discovery**: Automatic detection of nearby mesh nodes
- **Repeater Support**: Connect to and manage repeater nodes for extended range

### Map & Location

- **Live Map View**: Real-time visualization of mesh network nodes on an interactive map
- **Node Filtering**: Filter by node type (chat, repeater, sensor) and time range
- **Location Sharing**: Share GPS coordinates and custom markers with contacts
- **Offline Maps**: Download map tiles for offline use in remote areas (with [StadiaMaps](https://stadiamaps.com/pricing/) Free Subscription API-Key)
- **MGRS Coordinates**: Support for Military Grid Reference System coordinate format

### Device Management

- **BLE, USB, TCP Connection**: Scan and connect to MeshCore devices via Bluetooth, USB or TCP
- **Device Settings**: Configure radio parameters, power settings, and network options
- **Battery Monitoring**: Real-time battery status with chemistry-specific voltage curves
- **Repeater Firmware Updates**: Serve verified `.mota` files from a phone over
  encrypted BLE, then pull and install them on a remote LoRa OTA repeater.
  See the [screenshot walkthrough](docs/LORA_OTA_REPEATER_TUTORIAL.md).

### Repeater Hub

- **CLI Access**: Full command-line interface to repeater nodes
- **Settings Management**: Configure repeater behavior, power limits, and network settings
- **Statistics Dashboard**: View repeater traffic, connected clients, and system health
- **Remote Management**: Administer repeaters from anywhere on the mesh network

### Node monitoring dashboard

Open **Contacts > Node dashboard > Select nodes** to build a searchable
watchlist. Selections and refresh intervals are saved separately for each
Companion's full public key. Choose manual refresh or automatic 12, 24, or 48
hour cycles; the minimum and default are 12 hours. Older shorter saved intervals
are migrated to 12 hours; manual-only settings are preserved. Opening a saved
watchlist or saving a selection does not send a request. Use **Refresh all** or
**Refresh node** for an immediate read. Each refresh finishes before the next
full interval starts, including after a manual read. Pause and Stop refresh
are available.

Repeater and room cards show battery voltage when greater than zero, uptime,
last-received signal, packet counters, queue/errors, route hops, last response,
and last advertisement. Chat and sensor cards show allowed telemetry, including
battery voltage and temperature when supplied. Readings are kept in memory
while the dashboard is open; the watchlist persists after restarting the app.
Unavailable contacts remain removable from the picker.

Monitoring is read-only and sequential, with no automatic request retries.
It stops when the dashboard closes, the app goes into the background, or the
Companion changes/disconnects. There are no background alerts. Login from
Contacts first when a repeater/room requires it; other nodes must allow
telemetry. A missed response is not proof that a node is offline. Older values
remain visible with their response age and become marked stale. Unknown or
ambiguous six-byte contact prefixes are not queried or attributed to a node.

The Android 5.1.1 phone selected and read the Pi-connected Heltec Tower
repeater using the dashboard, without changing node configuration. Screenshots:
[node selection](docs/screenshots/firmware-controls/android-5.1-monitor-selection.png)
and [live dashboard](docs/screenshots/firmware-controls/android-5.1-node-dashboard.png).
Multi-node sequencing, telemetry decoding, zero-voltage suppression, scoped
watchlists, stale readings after a timeout, cancellation, Companion changes,
foreground-only automatic refresh, and small-screen layout have automated tests.

### Private-channel fleet management

Open **Contacts > Fleet management**. This uses the signed private-channel
protocol in the local MeshCore head (`f62cc7b5`), not repeated chat commands or
the filter playground. Both the publishing Companion and infrastructure
receivers must include fleet support; released firmware without those commands
is not assumed compatible. Fixed-size STM32 builds omit fleet control.

Choose an existing private random-key channel, or explicitly create one using a
secure random key generated on the phone. Channel creation waits for a complete
channel-slot read and never overwrites an occupied slot. Check publisher support
explicitly; opening the screen sends nothing. The Companion signs with its own
identity, so the signing private key is never exported to the phone or receivers.

Log into receivers as admin from Contacts, then **Read enrollment** before
enrolling or removing them. Enrollment uses individually authenticated commands
to save the channel key and publisher public key. Separate writes may partially
succeed; read enrollment again after success or a lost reply. Channel state and
publisher identity are readable, but the receiver does not reveal its channel
key. A channel-hash summary is not proof of the complete key. Guest logins,
ambiguous contact prefixes, unhealthy stores, disconnects, and changed Companion
identities cannot authorize enrollment writes.

Target selected nodes by full public identity (default), optionally use compact
12-character prefixes, choose configured regions/home ancestry, select a GPS
center and radius, or explicitly choose all enrolled nodes. Prefixes can match
unknown nodes with the same prefix. Regions are receiver-side selectors, not
routing scopes, and unknown regions never become an all-fleet request. Oversized
target lists are rejected as a whole under both the two-packet firmware budget
and the app's correlated command-frame limit; they are never silently truncated
or split into broader broadcasts.

The GUI exposes the firmware's filtering, blacklist, channel moderation, scope,
hop-limit, Radio 2, scheduled primary/secondary radio, and forward-only clock
controls. **Packet filters > Send rule over fleet channel** copies a validated
rule as an unnumbered insert, without its node-local slot. The Radio 2 editor can
copy saved or temporary profile drafts into fleet review. No draft is sent until
the targets, private channel, control, and packet count are confirmed. Receivers
still validate their own supported settings. Use absolute UTC timestamps for
coordinated schedules; relative starts vary with receiver acceptance time.

There are no automatic sends, background polls, or write retries. Sends are
limited to at most one per second per Companion, including uncertain queue
attempts. A queue acknowledgement only means the Companion queued the command.
Matching receiver reports are shown as **unverified channel reports**: ordinary
channel text, sender names, and identity prefixes are not authenticated receipts.
Confirm critical results through existing individual admin access. Preserve a
recovery route before deploying filters or radio schedules.

Firmware installation/OTA, reboot, credentials, identity export, ACL edits,
filesystem operations, arbitrary CLI, authenticated fleet inventory, background
alerts, and multi-day history collection are not supplied by this channel.
Continue using the existing individual-node tools for those operations.

Protocol reference: [MeshCore fleet management](https://github.com/mikecarper/MeshCore/blob/f62cc7b52759e4cfa52f8b739e9fecea3a6deeb2/docs/fleet_management.md).

### Native firmware controls

The app now provides controls for firmware features that previously required
typing commands. These screens read support and saved values from the device;
opening a screen never changes the radio.

- **Settings > Node alerts** edits the radio's programmable notifications, not
  Android notifications. Configure supported hardware outputs, all-message,
  contact/room, or channel rules, connection conditions, pulse patterns, RTTTL
  sound, repeat/gap/stop behavior, and approved GPIOs. Presets, a local duration
  preview, saved-rule hardware tests, and Stop are included. Remote `!notify`
  permission is opt-in for an individual contact/room, never a channel. Turning
  the engine off restores legacy alerts; it is not an all-alert mute.
- **Settings > Radio 2 and channel routing**, or a channel's action menu,
  configures the permanent/temporary second LoRa profile and saved per-channel
  automatic, primary, Radio 2, both, or disabled transmit routing. Active routing,
  crossing, and timing are read back. There is still only one time-shared radio;
  a Radio 2-only channel cannot send while that profile is off or receive-only.
- **Repeater/room admin hub > Packet filters** reads individual compact FPF7
  forwarding rows and edits payload, hop, channel, path, incoming scope, action,
  rate, priority, retry, stop, timing, and temporary-radio conditions. Repeaters
  also expose separate scope-rewrite, shared blacklist, and sender-moderation
  editors. Full room-server builds expose forwarding rows only. Unknown/legacy
  row formats are not rewritten, and an empty table alone is not treated as
  proof that the firmware supports generalized FPF7 fields.
- **Contacts > Repeater filters** lists repeaters with an observed admin login
  for the current Companion. Open a filter editor, build or load a forwarding
  rule, then choose **Apply to selected repeaters**. Select nodes, check their
  compact-filter support, and confirm the named destinations. Each receives an
  unnumbered insert into a free slot or an identical existing row; another
  node's slot number is never copied and different saved rules are not replaced.
  Each result distinguishes acknowledged, unconfirmed, and unsent operations.
  A failed node does not hide the others' results. Stop waits for the current
  node, then skips the remaining ones. Read-only checks can be cancelled.
  Remote controls wait at least 30 seconds for delayed replies, or longer when
  the calculated route timeout requires it. There are no automatic write retries.
  Logins are remembered in app memory across reconnects to the same Companion;
  changing Companions or restarting the app requires logging in again. Guest
  logins and saved passwords do not qualify. Permission changes and ambiguous
  contact-key prefixes invalidate selection. Remote permissions may still
  change, so checks and acknowledgements remain necessary.
  Shared blacklist contents and region definitions remain local to each node;
  inserting a rule does not copy those definitions.

Writes require confirmation, fit the Companion/LoRa frame limits, bind to the
connected device (and the selected channel key), and stop a single-node save at
the first failure. Selected-repeater batches report each node independently.
Multi-setting saves are not an atomic transaction: earlier acknowledgements
remain saved, and a timed-out write may have applied. Remote inserts are not
automatically retried. Read the device before retrying. Scope/moderation saves
without an explicit slot can update an existing matching row, as the firmware
specifies; the confirmation explains this. A scope getter does not distinguish
direct scope from region targets, so editing requires an explicit target-kind
choice. Path hashes and sender labels are not authenticated identities.

The [filter playground](https://mikecarper.github.io/MeshCore/filter_tool/) is a
design/simulation tool. Its readable policy language, JSON, and Base64 bundle
are not accepted by current firmware. This app uses the actual `notify`,
`radio2`/`tx.channel`, `fr`, `flood.channel.scope`, `flood.filter.blacklist`, and
`flood.moderation` command families instead. It does not claim to implement
prototype shadow-mode, burst, or proposed whole-policy features.

References: [node notifications](https://mikecarper.github.io/MeshCore/notifications/),
[Radio 2](https://mikecarper.github.io/MeshCore/radio_profiles/), and
[firmware filtering](https://mikecarper.github.io/MeshCore/flood_filtering/).

Phone verification used the connected LG Android 5.1.1 handset: live notification
capabilities and approved GPIOs, Radio 2 diagnostics, and saving/read-back of
Public's existing Automatic route. The phone also authenticated directly over
LoRa to the Pi-connected Heltec Tower repeater and read its compact forwarding
rule and other filter tables. The selected-repeater flow checked its firmware,
confirmed the destination, and received an acknowledgement for inserting its
identical existing OTA rule. Read-back verified the same two saved rows, with
no extra slot and no change to the filtering policy. Alert hardware was not
triggered. This live batch test used one repeater; multi-node selection, setter
failures, partial results, cancellation, permission changes, and no automatic
write retries are covered by automated tests.

Phone screenshots: [node alerts](docs/screenshots/firmware-controls/android-5.1-node-alerts.png),
[channel routing](docs/screenshots/firmware-controls/android-5.1-radio2.png),
[filter inventory](docs/screenshots/firmware-controls/android-5.1-filters.png),
[loaded forwarding rule](docs/screenshots/firmware-controls/android-5.1-filter-rule.png),
[logged-in repeater list](docs/screenshots/firmware-controls/android-5.1-repeater-filter-list.png),
[selected repeater check](docs/screenshots/firmware-controls/android-5.1-repeater-filter-ready.png),
[apply confirmation](docs/screenshots/firmware-controls/android-5.1-repeater-filter-confirm.png), and
[acknowledged result](docs/screenshots/firmware-controls/android-5.1-repeater-filter-result.png).

### Packet tools

Open **Packet tools** from the scanner toolbar or **Settings > Debug**. These
native tools work without a radio or a browser, including on Android 5.1.1:

- Decode raw `TTB1`, `TVB1`, and `IVB1` telemetry snapshots, or CLI Base64
  temperature, battery, I2C voltage, and GPS history pages. Compatible pages merge
  by timestamp; **Copy CSV** exports the decoded samples to the clipboard.
- Inspect raw MeshCore packet headers, routes, hop hashes, transport fields, and
  payload bytes. Encrypted content is not guessed or silently treated as plaintext.
- Decode `MGR1` management reports. Public fields are explicitly unauthenticated
  until a management password verifies the AES-SIV tag. Multi-page ACLs and an
  optional candidate administrator public key can be checked locally.
- Select an analyzer IATA region code (for example `SEA`), then **Pull packets**
  to request up to 50 recent packets from the Let's Mesh API. This selection
  is separate from a radio's LoRa flood scope. Tap a packet to select its decoder.
  If API access is blocked, **Open analyzer** and paste its Raw Data instead.
- **Radio packets** opens recent companion RX captures. Companion and repeater CLI
  replies expose **Decode reply** when they contain supported data; history command
  shortcuts are available in both CLI screens.

Reports, management passwords, and candidate keys are never uploaded by these
tools. Only the selected analyzer region is saved; management credentials are
memory-only and cleared by **Clear local data** or by leaving the tool.

Wire-format references: [telemetry decoder](https://mikecarper.github.io/MeshCore/telemetry_decoder/)
and [management decoder](https://mikecarper.github.io/MeshCore/management_decoder/).
Tests include checked-in golden samples generated by the MeshCore JavaScript
decoders, authenticated multi-page ACLs, tampering/wrong-password rejection,
API failure handling, and compact-screen layouts.

Verification on an LG LGL51AL running Android 5.1.1 covered telemetry samples,
raw packet headers, authenticated management reports, region selection, and the
CLI entry point. Wrong management passwords were rejected on the phone. Both
Android profile test suites passed 909 tests (two optional
fixture tests skipped per profile). The phone's live analyzer request returned
HTTP 401; automatic retrieval still needs permitted API access. No challenge or
authentication bypass is used. Browser/paste import remains available.
The phone connected to companion `C93F220A`, executed `ver`, and decoded a live
RX packet with nine hops and two-byte path hashes. That companion's installed
firmware returned `Unknown command` for temperature/battery history; the app
does not add history support to firmware that lacks it.

Phone screenshots: [telemetry](docs/screenshots/packet-tools/telemetry-android-5.1.1.png),
[raw packet](docs/screenshots/packet-tools/raw-android-5.1.1.png), and
[management](docs/screenshots/packet-tools/management-android-5.1.1.png),
[authenticated report](docs/screenshots/packet-tools/management-auth-android-5.1.1.png),
[password rejection](docs/screenshots/packet-tools/management-rejected-android-5.1.1.png),
and [CLI](docs/screenshots/packet-tools/cli-android-5.1.1.png).
Live checks: [CLI replies](docs/screenshots/packet-tools/cli-live-android-5.1.1.png),
[radio packet](docs/screenshots/packet-tools/radio-raw-android-5.1.1.png), and
[analyzer access failure](docs/screenshots/packet-tools/analyzer-access-android-5.1.1.png).

## Technical Details

### Architecture

- **Framework**: Flutter 3.38.5 / Dart 3.10.4
- **State Management**: Provider pattern with ChangeNotifier
- **BLE Protocol**: Nordic UART Service (NUS) over Bluetooth Low Energy
- **Storage**: Local SQLite database for messages and contact data
- **Encryption**: End-to-end encryption for private messages using the MeshCore protocol

### Platform Support

| Feature            | Android (API 21+) | iOS (12+) | Linux | Windows | macOS |                Web                |
|--------------------|:-----------------:|:---------:|:-----:|:-------:|:-----:|:---------------------------------:|
| BLE companion      | ✅                | ✅        | ✅   | ✅      | ✅    | ✅                                |
| USB companion      | ✅                | 🚧        | ✅   | ✅      | ✅    | ✅                                |
| TCP companion      | ✅                | 🚧        | ✅   | ✅      | ✅    | ❌<br>(requires websocket bridge) |
| Core Functionality | ✅                | ✅        | ✅   | ✅      | ✅    | ✅                                |
| Mesh Network       | ✅                | ✅        | ✅   | ✅      | ✅    | ✅                                |
| Map & Location     | ✅                | ✅        | ✅   | ✅      | ✅    | ✅                                |
| Device Management  | ✅                | ✅        | ✅   | ✅      | ✅    | ✅                                |
| Repeater Hub       | ✅                | ✅        | ✅   | ✅      | ✅    | ✅                                |

### Dependencies

| Package | Purpose |
|---------|---------|
| flutter_blue_plus | Bluetooth Low Energy communication |
| provider | State management |
| shared_preferences | Local key-value storage (scoped per device) |
| flutter_map | Interactive map display |
| latlong2 | Geographic coordinate handling |
| flutter_local_notifications | Background notification support |
| pointycastle | Cryptographic operations |
| llamadart | On-device LLM message translation |
| intl | Internationalization and date formatting |

## Getting Started

### Prerequisites

- Flutter SDK 3.38.5 or later
- Android Studio / Xcode (for mobile development)
- A MeshCore-compatible LoRa device

### Installation

1. **Clone the repository**

   ```bash
   git clone https://github.com/zjs81/meshcore-open.git
   cd meshcore-open
   ```

2. **Install dependencies**

   ```bash
   flutter pub get
   ```

3. **Run the app**

   ```bash
   flutter run
   ```

### Building for Release

**Android APK:**

```bash
flutter build apk --release
```

**iOS:**

```bash
flutter build ios --release
```

Signed TestFlight releases can be uploaded with the manual GitHub Actions
workflow described in [documentation/testflight.md](documentation/testflight.md).

## Project Structure

```
lib/
├── main.dart                    # App entry point
├── connector/
│   ├── meshcore_connector.dart  # BLE communication & state management
│   ├── meshcore_protocol.dart   # Protocol definitions & frame parsing
│   └── meshcore_uuids.dart      # Device names and IDs (add prefixes here!)
├── screens/
│   ├── scanner_screen.dart      # Device scanning (home screen)
│   ├── contacts_screen.dart     # Contact list
│   ├── chat_screen.dart         # Direct messaging
│   ├── channels_screen.dart     # Public channels
│   ├── map_screen.dart          # Network visualization map
│   ├── settings_screen.dart     # Device settings
│   └── repeater_hub_screen.dart # Repeater management
├── models/
│   ├── contact.dart             # Contact data model
│   ├── message.dart             # Message data structure
│   └── channel.dart             # Channel definitions
├── services/
│   ├── notification_service.dart      # Push notifications
│   ├── message_retry_service.dart     # Automatic message retry
│   ├── background_service.dart        # Background BLE connection
│   └── map_tile_cache_service.dart    # Offline map storage
└── storage/
    ├── message_store.dart       # Message persistence
    ├── contact_store.dart       # Contact database
    └── unread_store.dart        # Unread message tracking
```

## BLE Protocol

### Nordic UART Service (NUS)

- **Service UUID**: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- **RX Characteristic**: `6e400002-b5a3-f393-e0a9-e50e24dcca9e` (Write to device)
- **TX Characteristic**: `6e400003-b5a3-f393-e0a9-e50e24dcca9e` (Notify from device)

### Device Discovery

Devices are discovered by scanning for BLE advertisements with known MeshCore device name prefixes. These are currently:
    - `MeshCore-`
    - `Whisper-`
    - `WisCore-`
    - `HT-`
    - `LowMesh_MC_`
    - `NRF52`

New device prefixes can be added in `lib/connector/meshcore_uuids.dart`.


### Message Format

Messages are transmitted as binary frames using a custom protocol optimized for LoRa transmission. See `meshcore_protocol.dart` for frame structure definitions.

## Configuration

### App Settings

- **Theme**: System default, light, or dark mode
- **Language**: Use one of 15 languages (English, Chinese, French, Spanish, Portuguese, German, Dutch, Polish, Swedish, Italian, Slovak, Slovene, Bulgarian, Russian, Ukrainian)
- **Notifications**: Configurable for messages, channels, and node advertisements
- **Battery Chemistry**: Support for NMC, LiFePO4, and LiPo battery types
- **Message Retry**: Automatic retry with configurable path clearing

### Device Settings

- **Radio Power**: Transmit power adjustment (10-30 dBm)
- **Frequency**: LoRa frequency configuration
- **Bandwidth**: Channel bandwidth selection
- **Spreading Factor**: Range vs. speed trade-off
- **Network ID**: Mesh network identifier

## Contributing

This is an open-source project. Contributions are welcome!

## SWHID and Archive badge
[![SWH](https://archive.softwareheritage.org/badge/origin/https://github.com/zjs81/meshcore-open/)](https://archive.softwareheritage.org/browse/origin/?origin_url=https://github.com/zjs81/meshcore-open)
[![SWH](https://archive.softwareheritage.org/badge/swh:1:dir:d37a80b06359730864150ad2aeadd46cce9abd55/)](https://archive.softwareheritage.org/swh:1:dir:d37a80b06359730864150ad2aeadd46cce9abd55;origin=https://github.com/zjs81/meshcore-open;visit=swh:1:snp:47656c4b55ab40a689ff8d2f045196725f05096b;anchor=swh:1:rev:0fe250230905fdd05dbedc0f546736990beacf53)

### Development Guidelines

- Follow the Flutter style guide
- Use Material 3 design components
- Write clear commit messages
- Test on both Android and iOS before submitting PRs

### Code Style

- Prefer `StatelessWidget` with `Consumer` for reactive UI
- Use `const` constructors where possible
- Keep functions small and focused
- Avoid premature abstractions
- Run dart format on all changes before submitting

## Support

For issues, questions, or feature requests, please open an issue on GitHub:
<https://github.com/zjs81/meshcore-open/issues>

## Donate

If you find MeshCore Open useful and would like to support development, you can donate Solana or other Solana tokens:

**Solana Address:** `F15YanjZj96YTBtKJYgNa8RLQLCZkx5CEwogPWkqXeoQ`


**Monero Address:** `453TxnpUqjkJtXxzdjMsrgERNkBRXEGamPbpC45ENrvKAk9tH7kZbxWF82Hz66etgDZyXFPEBU2JUEqhLeJyWt9kBvTVy5m`

**Bitcoin Address:** `bc1qh45x28v8dslcg4v4upmqd9g0mvc3lnyffmyzr5`

Your support helps maintain and improve this open-source project!

## Acknowledgments

- Built with [Flutter](https://flutter.dev/)
- Map tiles from [OpenStreetMap](https://www.openstreetmap.org/)
