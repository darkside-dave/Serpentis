# Background work

All feature-report reads and setting writes run on the model's serial I/O queue.
Menu construction uses cached values. The protocol's reply delays and retry limits
remain unchanged; they never run as part of menu construction or a menu action.

Refresh requests specify the fields and button IDs they need. Requests arriving
during a read are merged into one pending request. A button save refreshes that
button; lighting, power and DPI actions refresh their corresponding fields.
A full refresh is available from the window's Refresh button. Results from an
old device session are discarded after a connection change.

When Mouse Dock Pro is connected, a separate three-second timer reads its local paired-device table. This does not query the mouse over RF. The timer stops when the dock settings interface is removed.

Pointer monitoring uses a three-second timer while an override, scroll inversion
or pending restoration needs it. The timer stops at default settings. Connection
changes and wake notifications also refresh the input service state. Timers have
tolerance so the system can group wakeups. Published status values are only
assigned when they change.

The main device manager opens only supported settings interfaces. The
Troubleshooting button test opens Naga input interfaces on request, stops after
15 seconds, and closes them when leaving the page. It ignores pointer motion and
does not save key input or typed text. Diagnostic checks run only on opening the
page or selecting Check mouse.

## Validation

`bash app/Tests/run-tests.sh` checks request merging, partial refresh scope,
monitoring policy, diagnostic export fields and input filtering alongside the
pointer restoration tests. Native view previews are available with `--render`.
`--benchmark-menu` times menu construction with cached fixture data and no device
I/O. The optional `--benchmark` flag times a full settings read and cached menu
construction against a connected, awake mouse. It makes no settings writes.

For a runtime check, compare CPU use and memory with the window closed, with
pointer options enabled, while scrolling, and while changing settings. Check that
the menu opens promptly during a full refresh and that a button save leaves other
assignments intact. Performance claims should include the connection type and
measurement method.

## Report-rate check

The Performance pane offers an explicit five-second raw-input check. It opens only the selected mouse's primary mouse collection, matches the USB location, and uses a non-seizing HID manager. Timestamped input callbacks update counters on a dedicated queue; the interface updates twice per second. No report payloads, cursor positions or device identifiers are stored or exported.

The result is the highest sustained rate over a window of at least 250 ms. Duplicate and reversed timestamps are ignored, and gaps over 50 ms start a new window. Short bursts do not establish a sustained rate. The check stops after five seconds, on device changes, when changing the polling setting, leaving Performance, closing the window or quitting. It creates no timer or input listener during normal operation.

Configured Hz is read back from the mouse. Observed Hz measures input reports delivered to macOS while the mouse moves; it does not count empty USB polls or prove application-level delivery at that rate. For a useful comparison, repeat the same continuous motion at 1000 Hz and at the higher configured rate. Low observed rates can also reflect motion, idle periods, transport behavior or scheduling.

Reference: [Apple timestamped HID report callback](https://developer.apple.com/documentation/iokit/3042788-iohidmanagerregisterinputreportw).

## Battery lighting

Battery Level is an opt-in dock effect. It reuses the existing battery refresh and adds no timer. The background timer runs every 65 seconds with five seconds of tolerance, leaving room beyond the telemetry cache interval. Successful battery/charging telemetry is cached for at least 60 seconds per connected device session, including requests from menus and manual refreshes. Failed reads retry no more often than once every five seconds so a waking mouse can recover. A new connection starts with an empty cache.

The default palette is red at 0–24%, orange at 25–49%, yellow at 50–74% and green at 75–100%. Established bands use a two-percentage-point hysteresis margin: yellow enters green at 77%, and green returns to yellow at 73%. The same margin applies to the other boundaries, so values such as 74/75 cannot alternate colors. Larger changes can cross several bands at once.

Colors and brightness are stored locally. Reset Colors to Default preserves the mode and brightness. Custom colors are staged until Apply to Dock; resetting the palette applies defaults immediately if battery mode is active. Unknown battery readings keep the last dock color.

Only a changed target color or brightness queues a write. Matching fresh dock readback avoids a startup rewrite; duplicate pending targets are coalesced. Jobs run on the existing serial I/O queue, and a later manual lighting choice cancels stale queued work. Failed confirmation invalidates the write cache and retries after a later battery reading. There are no flashing effects or per-frame updates.
