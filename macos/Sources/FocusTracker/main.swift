import AppKit

if CommandLine.arguments.contains("--smoke-test") {
    MainActor.assumeIsolated {
        let timer = FocusTimerModel(defaultMinutes: 30)
        guard timer.phase == .idle,
              timer.remainingSeconds == 1_800,
              Bundle.main.bundleIdentifier == "com.brbousnguar.FocusTracker" else {
            fputs("FocusTracker smoke test failed\n", stderr)
            exit(EXIT_FAILURE)
        }
        print("FocusTracker smoke test passed")
    }
    exit(EXIT_SUCCESS)
}

// Window app with a companion menu-bar timer.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
