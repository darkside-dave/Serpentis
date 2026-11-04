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
