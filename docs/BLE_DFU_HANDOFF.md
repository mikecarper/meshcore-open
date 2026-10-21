# Bluetooth firmware handoff

An nRF52 application and its bootloader can use different Bluetooth addresses.
The application can use a custom or rotating address while a freshly enabled
SoftDevice in the bootloader uses the chip's factory identity. A retained bond
record preserves information about the phone, not the peripheral's custom
address. Incrementing the application address is only a legacy scan hint.

After the native SDK reports an application handoff for the original radio,
or an explicit bootloader recovery, Open
performs bounded fresh Legacy DFU discovery. It requires the expected board
name and service, rejects application NUS advertisements, and reads the
selected connection's actual bootloader model and revision 0.8 before starting
the recovery transfer. Revision 0.1 is an application handoff service, including
the DFU-only service exposed by repeaters in updater mode; NUS is not required
for a repeater updater. Android GATT cache refresh preserves the existing bond.

One compatible updater proceeds automatically. Several matching updaters need
an explicit selection; cancelling sends no firmware. The model and name are
shared by radios of the same type, so this is operational continuity from the
selected radio's handoff, not cryptographic peripheral identity. The user
should leave only the intended radio in update mode when unsure. A bootloader
hidden by its retained peer whitelist can also be checked at a separately known
address, available in the collapsed advanced address control. The app does not
contain bench factory addresses or derive one from a USB serial number.

The application-recovery coordinator still permits at most one additional
transfer before any payload/validation progress. It does not retry file or
remote validation errors. The RAK migration fallback also requires fresh
bootloader discovery and connected identity checks before a forced stage; it
does not blindly transfer to an incremented address after a lost reply.

Bootloader labels are transport-specific. The physical INFO label
`TEST_0x02040B7E` and runtime CLI label `OTAFIX2.4.11-preview.126` describe the
same packed test version. Open does not use equality between these labels as
an application DFU gate. It checks the actual Legacy DFU revision and model;
these tests do not establish support for every bootloader or Secure DFU build.

## Pairing repair

An explicit missing-key or authentication failure can mean the phone's saved
pairing no longer matches the radio. With the intended radio physically
available, forget only that radio in the phone's Bluetooth settings, return it
to its normal application, and pair again through the app before restarting
the update. Follow the radio's pairing controls if it requires a new pairing
window. Do not remove other devices' pairings or erase the radio's identity.

A generic GATT 133, disconnect, or timeout does not establish a stale bond.
Check the radio's updater state and connection first. Open preserves valid
bonds and does not delete pairings automatically. A radio that cannot return
to its application may need the documented recovery procedure for that board.

Host tests cover changed factory addresses, missing protocol evidence, wrong
model/revision, multiple/cancelled selections, and transfer ordering. They do
not replace a phone-to-radio transfer and post-reboot version verification.
