# Naga V3 Pro protocol notes

Everything here was verified on a Naga V3 Pro (firmware 1.01) from macOS, or decoded from USB captures of Razer Synapse on Windows. It's shared so other projects (and other Naga models) can benefit.

## Transport

- Vendor ID `0x1532`. Product ID `0x00E7` = USB cable, `0x00E8` = wireless receiver.
- Settings use the HID interface with a **90-byte feature report** (usage page 0x01, usage 0x03), report ID 0.
- Send with SET_REPORT (feature), read the answer with GET_REPORT (feature). Retry while status is `0x01` (busy).
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
- Factory specials seen: type 0x0E (wheel tilt scroll, data `68/69 00 14`), type 0x0C (button behind the wheel), type 0x07, type 0x12.
- The mouse echoes the arguments on success. There's no separate "save" step.
- Note: Synapse's "reset to default" sends nothing for that button, so the old mapping stays in the mouse.

| Button | ID |
|---|---|
| Side buttons 1–12 (12-button plate) | 0x40–0x4B |
| Wheel click | 0x03 |
| Wheel tilt left / right | 0x34 / 0x35 |
| Button behind the wheel | 0x39 |
| Wheel up / down | 0x09 / 0x0A |
| Other IDs that answer (likely other side plates / bottom buttons) | 0x04, 0x05, 0x0B, 0x0C, 0x0E, 0x50–0x55, 0x6A |

Unverified: Hypershift (probably layer byte 0x01), onboard profile slots, scroll-wheel mode, calibration.
