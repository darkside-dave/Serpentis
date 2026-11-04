import AppKit
import Darwin

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// The installer/uninstaller sends SIGTERM. Restore the live input preferences on that path too.
signal(SIGTERM, SIG_IGN)
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSignal.setEventHandler { app.terminate(nil) }
terminationSignal.resume()
app.run()
