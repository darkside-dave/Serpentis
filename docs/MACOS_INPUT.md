# macOS pointer and scrolling preferences

These preferences are separate from the mouse's onboard settings. They are
opt-in, saved in Serpentis's user defaults, and applied while the app runs.
They do not change the global macOS mouse/trackpad preferences or send a firmware
settings command to the mouse. They also appear in the menu bar and can be
configured while the mouse is disconnected or asleep.

## Pointer sensitivity and acceleration

Sensitivity has a slider, numeric entry and Reset beside the acceleration
checkbox. Values are clamped to 0–2000. This is Serpentis's own scale, not a
guaranteed numerical match to SteerMouse: 1000 means normal sensitivity; with
acceleration disabled, 2000 applies 2× constant pointer gain. Zero maps to the
minimum gain of 0.01× so the pointer can still move. Slider increments are 10;
numeric entry allows single-unit adjustments. Hardware DPI is untouched.

Serpentis dynamically resolves `IOHIDEventSystemClientCreate` to obtain the full
device client, then uses `IOHIDServiceClient` properties. The public simple client
rejects the linear-tracking and resolution properties on the tested Mac. If the
full client is unavailable, custom sensitivity is disabled and the earlier
negative-acceleration override remains available through the simple client.
This creation function is undocumented and may change in future macOS versions.

Only services with vendor `0x1532`, product `0x00E7` or `0x00E8`, mouse/pointer
usage and acceleration type `HIDMouseAcceleration` are changed. Both cable and
receiver services are handled. With acceleration disabled, the service receives
`HIDUseLinearScalingMouseAcceleration = 1` and `HIDMouseAcceleration = gain` in
16.16 fixed point. Apple's linear filter uses this as a constant gain. A negative
acceleration value bypasses that filter and cannot provide adjustable gain.

When retaining an existing acceleration curve, sensitivity changes the effective
`HIDPointerResolution` inversely, then reapplies the acceleration value to rebuild
the filter. In that mode, actual speed also depends on the existing curve and
movement speed. If the baseline already used linear tracking or bypassed
acceleration, constant gain is preserved and scaled instead. At sensitivity
1000 with the checkbox off, all overrides are removed.

Original effective values and per-property ownership are journaled before writes.
Absent linear-tracking and resolution properties use macOS's effective defaults
(0 and 400 in 16.16 representation). Normalization may leave an explicit default
where the property was previously absent. Resetting the slider and disabling
acceleration, or quitting the app, restores prior pointer behavior. The journal
includes the boot session UUID and registry service ID for crash recovery without
reusing an earlier boot's IDs. Failed/unconfirmed writes keep their attempted and
previously applied values, so accepted portions remain reversible. A partially
rejected configuration is rolled back immediately and a failure is displayed.
Later external property changes are preserved on restoration.

The earlier acceleration-only restore journal is recovered before taking new
baselines, so upgrading does not save `-65536` as a replacement for the user's
original acceleration. Sensitivity changes are coalesced over 80 ms while dragging.

Services are checked every three seconds while an override, scroll inversion or
pending restoration is active, and after wake or connection changes. The periodic
check stops when all options are off and restoration is complete. This reapplies a saved
override after reconnection or a macOS settings change. Normal Quit and SIGTERM
(used by the installer and uninstaller) both run the restoration path. Force Quit
cannot run cleanup: reopen Serpentis, then reset sensitivity and disable the
acceleration option or quit normally;
disconnecting/reconnecting the mouse also recreates its services.

## Inverted scrolling

An Accessibility-authorized Quartz session event tap receives only scroll
events. Inversion negates the line, fixed-point and pixel deltas on all three
axes, preserving event metadata, modifiers and phases. The embedded HID scroll
deltas are also reversed for apps that read those values. No synthetic event is
posted, so the app cannot reprocess its own posted events.

Quartz's public API does not expose the physical source of a scroll event.
Serpentis resolves `CGEventCopyIOHIDEvent`, `IOHIDEventGetSenderID`,
`IOHIDEventGetFloatValue` and `IOHIDEventSetFloatValue` dynamically. These are
undocumented system interfaces; they may change in future macOS versions.
The sender must match a live supported Naga service registry ID. There is no
fallback that reverses every mouse or guesses from recent activity.

If a symbol is unavailable, scroll inversion is unavailable and the page explains
why. If a specific event has no recognizable Naga sender, that event passes
through unchanged. In particular, software that re-emits the mouse as a virtual
device can hide its origin. Quit SteerMouse or similar utilities before using
these settings. Accessibility permission is requested only when inversion is
first enabled; the app retries the tap after permission is granted and recovers
from event-tap timeouts. macOS may require reopening the app after permission
changes or a locally signed rebuild.

## Device drawing

`MouseIllustration.swift` draws an original vector diagram with SwiftUI paths,
gradients, and system symbols. It contains no embedded product photograph or
Razer logo. It is used on the Buttons and Lighting pages. The two top-left DPI
controls, both center controls and the ring-finger control have active selection
targets. Their physical IDs and factory bytes are documented in `PROTOCOL.md`.

## Validation

Run `bash app/Tests/run-tests.sh` for input-behavior checks covering device scope,
restoration, crash recovery, reconnects, partially rejected writes, external changes,
sensitivity bounds and gain, acceleration-filter refresh, scroll precision/metadata,
and unidentified-source passthrough. Optional renders:
`bash app/Tests/run-tests.sh --render /tmp/serpentis-preview`.

`bash app/Tests/run-tests.sh --hardware` explicitly opts into brief live property
changes followed by restoration. It checks sensitivity 1500 with acceleration
both disabled and retained, then verifies restoration of the original effective
pointer properties. Before a
release, with other mouse utilities quit, verify wheel and tilt direction in
multiple apps, unchanged trackpad scrolling, cable/receiver switching, wake,
normal Quit, and disabling each checkbox. Physical scroll-source matching still
requires live mouse input and Accessibility authorization.

References: [Apple's service-client API](https://developer.apple.com/documentation/iokit/2269511-iohideventsystemclientcopyservic),
[Apple's acceleration filter implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.cpp),
[Apple's constant-gain implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDEventSystemPlugIns/IOHIDAcceleration.cpp),
and [Scroll Reverser's description of device-source identification](https://github.com/pilotmoon/Scroll-Reverser#how-it-works).
