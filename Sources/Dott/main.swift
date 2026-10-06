import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if args.contains("--selftest") {
        // Prova del riconoscimento di test e build su output tipici.
        let samples: [(String, String)] = [
            ("swift test", "Test Suite 'All tests' passed.\n\t Executed 13 tests, with 0 failures (0 unexpected) in 0.2 (0.2) seconds"),
            ("swift test", "Executed 13 tests, with 2 failures (1 unexpected) in 0.4 seconds"),
            ("swift test", "✔ Test run with 12 tests in 3 suites passed after 0.004 seconds."),
            ("swift test", "✘ Test run with 12 tests in 3 suites failed after 0.01 seconds with 2 issues."),
            ("xcodebuild test", "** TEST SUCCEEDED **"),
            ("xcodebuild build", "error: foo\nerror: bar\n** BUILD FAILED **"),
            ("xcodebuild build", "** BUILD SUCCEEDED **"),
            ("swift build", "Build complete! (4.21s)"),
            ("swift build", "x.swift:3:5: error: cannot find 'y' in scope\nerror: fatalError"),
            ("npm test", "Tests:       1 failed, 12 passed, 13 total"),
            ("npx vitest run", " Tests  1 failed | 12 passed (13)"),
            ("pytest", "===== 1 failed, 12 passed in 3.20s ====="),
            ("cargo test", "test result: ok. 12 passed; 0 failed; 0 ignored"),
            ("ls build", "file.txt"),
        ]
        for (cmd, out) in samples {
            let r = BuildParser.parse(command: cmd, output: out)
            print("\(cmd.padding(toLength: 16, withPad: " ", startingAt: 0)) → \(r?.text ?? "(non riconosciuto)")   [\(r?.short ?? "-")]")
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        _ = NSApplication.shared
        Snapshot.run(into: args[i + 1])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
