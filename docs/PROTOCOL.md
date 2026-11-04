# Naga V3 Pro protocol notes

Everything here was verified on a Naga V3 Pro (firmware 1.01) from macOS, or decoded from USB captures of Razer Synapse on Windows. It's shared so other projects (and other Naga models) can benefit.

## Transport

- Vendor ID `0x1532`. Product ID `0x00E7` = USB cable, `0x00E8` = wireless receiver.
- Settings use the HID interface with a **90-byte feature report** (usage page 0x01, usage 0x03), report ID 0.
- Send with SET_REPORT (feature), read the answer with GET_REPORT (feature). Retry while status is `0x01` (busy).
- Mouse Dock Pro uses product ID `0x00A4` and a 90-byte feature report on usage page `0x01`, usage `0x02`. Mouse commands retain transaction `0x1F`; dock identity uses `00:BF`, size `0x1F`, transaction `0x3F`.
- The dock identity reply contains a slot count, then `[availability, PID high, PID low]` for each slot. Only the first slot is used as the relay target. Serpentis checks for a Naga V3 Pro PID before enabling controls, repeats this read every three seconds, and checks again before every settings write. A stored PID remains present while the mouse sleeps.
- Dock relay and slot-query references: [razerd protocol](https://github.com/GregDuhamel/razerd/blob/main/src/protocol.rs) and [OpenRazer dock relay implementation](https://github.com/openrazer/openrazer/pull/2817). Local read-only verification confirmed paired PID `0x00E8`, battery, DPI and button-assignment replies.
- If both the cable and the receiver are connected, talk to the cable (`0x00E7`); the receiver will reject commands.

## Report layout (90 bytes)

| Byte | Meaning |
|---|---|
| 0 | Status: 0x00 new, 0x01 busy, 0x02 OK, 0x03 failure, 0x04 timeout, 0x05 not supported |
| 1 | Transaction ID (0x1F works; Synapse cycles through values) |
| 2–3 | Remaining packets (0) |
| 4 | Protocol type (0) |
| 5 | Data size |
| 6 | Command class |
| 7 | Command ID (reads usually = write ID + 0x80) |
| 8–87 | Arguments |
| 88 | CRC: XOR of bytes 2–87 |
| 89 | Reserved |

## Commands

| What | Class | Write | Read | Size | Arguments |
|---|---|---|---|---|---|
| Firmware | 00 | — | 81 | 02 | reply: major, minor |
| Serial | 00 | — | 82 | 16 | reply: ASCII |
| Polling rate | 00 | 05 | 85 | 01 | 0x01 = 1000 Hz, 0x02 = 500, 0x08 = 125 |
| Battery | 07 | — | 80 | 02 | reply byte 9: 0–255 |
| Charging | 07 | — | 84 | 02 | reply byte 9: 1 = charging |
| Sleep timer | 07 | 03 | 83 | 02 | seconds, big-endian (60–900) |
| Low-power threshold | 07 | 01 | 81 | 01 | 0–255 (≈ percent × 2.55) |
| Current DPI | 04 | 05 | 85 | 07 | [storage 0x00, X hi, X lo, Y hi, Y lo, 0, 0] |
| DPI steps | 04 | 06 | 86 | 26 | [0x01, active step, count, then per step: index, X hi, X lo, Y hi, Y lo, 0, 0] |
| Brightness | 0F | 04 | 84 | 03 | [0x01, zone, value 0–255] |
| Effect | 0F | 02 | 82 | 0C | [0x01, zone, effect, …] — 0x01 static [.., 0, 0, 1, R, G, B]; 0x02 breathing [.., 1, 0, 1, R, G, B]; 0x03 color cycle |
| Button mapping | 02 | 0C | 8C | 0A | see below |

Lighting zones: 0x01 scroll wheel, 0x04 logo, 0x05 side panel.

## Button mapping (class 0x02, write 0x0C / read 0x8C)

Arguments: `[profile 0x01, button, layer 0x00, type, length, data…]`

- **Type 0x02 keyboard**, data `[modifiers, HID key code]`. Modifier bits: 0x01 Ctrl, 0x02 Shift, 0x04 Alt, 0x08 GUI (⌘/Windows). Factory entries use length 0x01, Synapse writes 0x02; both work.
- **Type 0x01 mouse button**, length 1, data `[button]`: 1 left, 2 right, 3 middle, 4 back, 5 forward, 9/10 wheel up/down.
- Factory specials seen: type 0x0E (wheel tilt scroll, data `68/69 00 14`), type 0x0C (ring/pinky button, data `39`), type 0x06 (DPI up/down), type 0x07 (underside profile button), type 0x12 (front wheel-mode button).
- The mouse echoes the arguments on success. There's no separate "save" step.
- Note: Synapse's "reset to default" sends nothing for that button, so the old mapping stays in the mouse.

| Button | ID |
|---|---|
| Side buttons 1–12 (12-button plate) | 0x40–0x4B |
| Wheel click | 0x03 |
| Wheel tilt left / right | 0x34 / 0x35 |
| Ring / pinky button | 0x39 |
| Top-left front / rear DPI buttons | 0x0B / 0x0C |
| Front button behind wheel (wheel mode) | 0x6A |
| Rear button behind wheel (disabled by default) | 0x80 |
| Wheel up / down | 0x09 / 0x0A |
| Other plate / underside IDs that answer | 0x04, 0x05, 0x0E, 0x50–0x55 |

### Physical controls

The ring/pinky control uses slot `0x39`; the front and rear controls behind the
wheel use `0x6A` and `0x80`. The factory function blocks are `0C 01 39`,
`12 01 01`, and `00 01 00`, respectively. The top-left DPI controls use
`06 01 01` and `06 01 02`. The function blocks are padded with zeros to seven
bytes when stored in the ten-byte assignment payload.

These assignments match the
[press-validated Naga V3 Pro button table published by OpenSnek](https://github.com/gh123man/OpenSnek/blob/main/captures/usb/2026-10-17-naga-v3-pro/README.md#button-table).
Profile `0` reads the effective assignment; the app reads and writes the stored
profile-1 bank. Saving a button requires both a matching command reply and a
separate assignment readback.

Unverified: Hypershift (probably layer byte 0x01), onboard profile slots, calibration.

## Mouse Dock Pro lighting

Dock lighting uses transaction `0xFF` on the same 90-byte control interface. It is separate from the paired mouse's `0x1F` commands and does not require a paired Naga. Effects use `0F:02` with storage `0x01`, LED `0x00`: off `0x00`, solid `0x01`, breathing `0x02`, spectrum `0x03`, and wave `0x04`. Wave directions are `0x01` and `0x02`, with speed `0x28`.

Brightness writes use `0F:04`, size `0x03`, arguments `[1, 0, brightness]`. Reads use `0F:84` with `[1, 0x0F]`; reading LED zero returns zero even when the dock is lit. Effect reads use `0F:82`, size `0x0C`, arguments `[1, 0]`. The dock echoes LED `0x0F` in effect replies. Serpentis compares the saved effect, color and brightness without treating that echo as a different zone.

Reference: [OpenSnek Mouse Dock Pro support notes](https://github.com/gh123man/OpenSnek/blob/main/docs/DEVICE_SUPPORT.md#razer-mouse-dock-pro). Dock changes refresh only dock lighting, and mouse lighting controls do not write to the dock.

## Mouse Dock Pro extended polling

For the paired Naga, `00:C0` (size `0x01`, transaction `0x1F`) reads the extended polling rate from reply byte 9. `00:40` (size `0x02`) writes `[0, rate code]` to the live slot. Codes are `0x40` = 125 Hz, `0x20` = 250 Hz, `0x10` = 500 Hz, `0x08` = 1000 Hz, `0x04` = 2000 Hz, `0x02` = 4000 Hz, and `0x01` = 8000 Hz.

Only an explicit unsupported response (`0x05`) falls back to the original `00:85` / `00:05` protocol. Timeouts and unknown codes remain unavailable. Serpentis offers high rates only after a valid extended read and verifies writes with a fresh rate read. This confirms device configuration; it does not measure the rate delivered to applications by macOS.

References: [OpenRazer protocol builders](https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c) and [Dock Pro high-polling support](https://github.com/openrazer/openrazer/pull/2937).

Battery Level is a software mode using the dock's solid-color command. It uses mouse battery telemetry and writes only when the palette target or brightness changes. Battery telemetry is cached for 60 seconds after successful reads, with five-second retry spacing after failure. See [battery lighting performance](PERFORMANCE.md#battery-lighting) for color hysteresis and update ownership.

## Naga V3 Pro wheel controls

The Naga V3 Pro uses `02:B0` / `02:30` for wheel-mode read/write, size `0x02`, arguments `[1, mode]`. Modes are `0` tactile, `1` free spin and `2` precision tactile. The older `02:94` / `02:14` family is not used.

Smart Reel reads use `02:97`, size `0x02`, arguments `[1]`. Writes use `02:17` with size `0x50` and the full 80-byte argument block: `[1, enabled]` followed by 78 zero bytes. Transaction ID remains `0x1F`, including relay through Mouse Dock Pro. Both setters require a fresh matching readback. Wheel-mode confirmation waits up to 2.5 seconds for the mechanism to settle and uses the observed mode even if the initial write reply was incomplete. The write is sent only once. Unknown or unavailable reads leave the corresponding control unavailable; opening the app does not change the selected mode.

Reference: [Naga-specific OpenRazer protocol builders](https://github.com/openrazer/openrazer/blob/dee083d68e64147849fb8832582fcda405084e22/driver/razerchromacommon.c). Wheel settings are separate from the front wheel-mode button's assignment and are not included in saved lighting/DPI profiles.

Wheel mode and Smart Reel are grouped under Pointer & Scrolling. Fixed wheel-mode selection is disabled while Smart Reel is enabled. The separate five-level Smart Reel responsiveness setting is not mapped and has no control in Serpentis.
