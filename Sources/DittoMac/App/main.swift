// main.swift — DittoMac entry point.

import AppKit

MainActor.assumeIsolated {
    // Developer tool: render UI proofs offscreen and exit (no windows shown, no user data touched).
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-ui-proofs"), i + 1 < args.count {
        exit(UIProofRenderer.run(outDir: URL(fileURLWithPath: args[i + 1], isDirectory: true)))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
