# Phone-driven LoRa OTA

## What It Does

The LoRa OTA screen lets a phone act as the firmware-file source for a remote
repeater. The phone reads `.mota` containers lazily over an encrypted Bluetooth
connection to the local Companion. The Companion advertises those files over
LoRa, and the selected repeater downloads, verifies, stages, and installs one.

This updates the remote repeater. It does not flash the Companion connected to
the phone.

## Requirements

- An admin login to the target repeater
- A target repeater build with LoRa OTA receive support
- A paired nRF52 **Full Companion** exposing the protocol-v14 encrypted
  Bluetooth mOTA service
- A Bluetooth connection from the app to that Companion; USB and TCP Companion
  connections cannot be the phone-side file source
- One or more `.mota` files stored on the phone
- A normal-radio control path to the target
- A temporary-radio OTA path to the target; it may be different from the
  normal path
- Admin passwords for intermediate repeaters the app must switch, if any
- Any intermediate repeater you cannot administer already placed on the same
  temporary radio tuple by its owner for long enough to finish the update

The Bluetooth bond must meet the firmware's encrypted, authenticated pairing
requirement. If it does not, the app continues to work as a normal Companion
client but reports that the mOTA channel is unavailable.

## Starting a Session

1. Open the target repeater in **Repeater Management** and log in as admin.
2. Open **LoRa OTA**.
3. Choose the `.mota` files to offer. The app fully validates each container
   before it can be advertised.
4. Set the target's **Normal control path** and **Temporary OTA path**. These
   are intentionally independent so a prepared passive relay can change which
   route works after the radio handoff.
5. Add every intermediate repeater whose radio the app must control. Enter its
   admin password and set both its normal setup path and temporary restore
   path. Do not add passive repeaters whose owner has already put them on
   TempRadio; include those repeaters only as hops in the applicable temporary
   paths.
6. Enter the temporary frequency, bandwidth, spreading factor, coding rate,
   and bounded duration. The requested duration must be at least three minutes.
   Use a frequency legal for your region.
7. Tap **Test radios and start source**.

Before changing a radio, the app validates every normal and temporary route and
logs into every controlled intermediate. It sends `tempradio` to the target,
then to controlled intermediates in dependency order, waiting for the connected
Companion to report each packet sent and for each controlled node to accept the
command before moving the next relay. A node is moved before every controlled
relay named in that node's route; independent branches use longest-route-first.
This is calculated separately for normal setup paths and temporary restore
paths, so the two networks can differ. It changes the local Companion last. A
nearer controlled hop therefore cannot cut off a setup command still headed to
a farther hop. Passive hops receive no command or login attempt. This ordering
does not depend on synchronized clocks.

The OTA target must remain the endpoint: do not use it as a relay in a
controlled intermediate's setup or restore path. The app rejects that topology
because installing the target reboots it before the other nodes can be restored.

The first handoff always uses a fixed three-minute safety window, regardless of
the longer duration entered on screen. Once every selected radio has changed,
the app confirms that the Companion reports TempRadio active, requires an
`ota status` round trip from the target over its temporary path, and requires a
`ver` round trip from every controlled intermediate over its temporary path.
The target round trip also proves that owner-prepared passive hops in that path
can carry traffic. If any check fails, the firmware source is never attached
and the app immediately attempts the ordered `normalradio` recovery; the
three-minute timers remain the final fallback.

Only after every check succeeds does the app extend the target, controlled
intermediates, and Companion to the requested duration. It then attaches the
phone catalog and asks the repeater to discover it with `ota ls`.

## Downloading and Installing

- Tap **Refresh updates** if the first discovery does not list the new files.
- Tap **Pull** next to the desired manifest. The repeater stages it in OTA
  flash; it is not installed yet.
- Keep the app in the foreground and the Bluetooth connection alive for the
  entire download. The screen can poll `ota status` every 60 seconds.
- **Sent / queued by source** counts complete payload blocks read by the
  Companion from the phone. **Confirmed by target** comes independently from
  the repeater's verified-block count, so retries and an interrupted path are
  visible instead of being mistaken for target progress.
- **LoRa source packets** is the exact per-session number of OTA packets the
  Companion accepted for radio transmission, including discovery, manifests,
  data, proofs, and retries. Older protocol-v14 preview firmware returns the
  seven-byte status without this counter and is shown as unavailable.
- **Install and reboot** remains disabled until the repeater reports that the
  staged image is ready.
- For an application package, confirm **Install and reboot** to run the
  repeater's own final verification, approval, installation, and reboot
  sequence.
- For a bootloader package, the app first reads `ota bootloader` from the
  remote repeater and requires the reported staged manifest ID and first eight
  image-hash bytes to exactly match the selected, locally validated `.mota`.
  Only then does it send the explicit
  `ota bootloader install <MID8> <HASH16>` approval command. A missing or
  different value stops installation without writing the bootloader.

The phone checks container magic and size, manifest geometry, every block leaf,
the Merkle root, full-image hashes, and Ed25519 signature consistency. The
repeater remains authoritative for hardware compatibility, trusted-signer
policy, approval, and safe installation.

## Stopping and Recovery

Use **Stop and restore controlled radios** before leaving an active session.
The app detaches the catalog, sends `normalradio` to the target, restores every
controlled intermediate over its temporary path in dependency order, and
restores the Companion last. Each accepted reply is allowed to leave on the
temporary channel before the next dependent relay is restored. It then puts
the Companion's contact table back on the normal paths. Passive repeaters are
never changed. The screen blocks normal navigation while a source is active
and asks before stopping it.

If setup or the three-minute reachability test fails after any radio may have
switched, the app joins the temporary channel if needed and attempts the same
ordered cleanup automatically. Before the test passes, every app-controlled
participant still has only the three-minute window, so a failed temporary path
cannot strand it for the full transfer duration. Every temporary-radio command
is time-bounded, so a controlled node returns to its configured radio even if
the phone disconnects before manual restore reaches it. An owner-prepared
passive relay has its own timer; make sure that timer covers setup, transfer,
retries, installation, and recovery margin.

## Security Boundaries

- Only fixed application-generated `tempradio`, `normalradio`, and `ota`
  command families are sent through the local firmware control command.
- Control characters, shell separators, quoting, substitutions, and the
  persistent `ota folder` command are rejected before transmission.
- The file service is available only over the firmware's encrypted mOTA GATT
  characteristics and only while a validated catalog is attached.
- File reads are range checked, capped by the protocol, serialized, and
  rejected if the underlying file size changes after validation.
