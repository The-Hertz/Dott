import Foundation

/// L'esito di un comando di test o di build, letto dal suo output.
struct BuildOutcome: Equatable {
    enum Kind { case tests, build }
    let kind: Kind
    let ok: Bool
    let passed: Int?
    let failed: Int?
    let errors: Int?

    /// Una riga per l'isola.
    var text: String {
        switch kind {
        case .tests:
            if ok {
                if let p = passed { return "Test ok · \(p) \(p == 1 ? "passato" : "passati")" }
                return "Test ok"
            }
            if let f = failed, let p = passed { return "\(f) \(f == 1 ? "test fallito" : "test falliti") su \(f + p)" }
            if let f = failed { return "\(f) \(f == 1 ? "test fallito" : "test falliti")" }
            return "Test falliti"
        case .build:
            if ok { return "Build riuscita" }
            if let e = errors, e > 0 { return "Build fallita · \(e) \(e == 1 ? "errore" : "errori")" }
            return "Build fallita"
        }
    }

    /// Versione breve, per la riga di fine lavoro.
    var short: String {
        switch kind {
        case .tests: ok ? "test ok" : (failed.map { "\($0) \($0 == 1 ? "test fallito" : "test falliti")" } ?? "test falliti")
        case .build: ok ? "build riuscita" : "build fallita"
        }
    }
}

enum BuildParser {
    private static func ints(_ pattern: String, in text: String, last: Bool = true) -> [Int]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = last ? matches.last : matches.first else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? 0 : (Int(ns.substring(with: r)) ?? 0)
        }
    }

    private static func has(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Riconosce l'esito se il comando sembra un test o una build e l'output lo dice chiaramente.
    static func parse(command: String, output: String) -> BuildOutcome? {
        let cmd = command.lowercased()
        let looksLikeRun = ["test", "build", "xcodebuild", "pytest", "jest", "vitest", "cargo", "go ", "gradle", "make"]
            .contains { cmd.contains($0) }
        guard looksLikeRun, !output.isEmpty else { return nil }

        // Swift Testing: "Test run with 12 tests in 3 suites passed/failed"
        if let r = lastMatch(#"Test run with (\d+) tests?.*? (passed|failed)"#, in: output) {
            let n = Int(r[0]) ?? 0
            let ok = r[1] == "passed"
            let issues = ints(#"with (\d+) issues?"#, in: output)?.first
            return BuildOutcome(kind: .tests, ok: ok, passed: ok ? n : max(0, n - (issues ?? 1)), failed: ok ? 0 : (issues ?? 1), errors: nil)
        }
        // XCTest: "Executed 12 tests, with 1 failure"
        if let r = ints(#"Executed (\d+) tests?, with (\d+) failures?"#, in: output) {
            let total = r[0], failed = r[1]
            return BuildOutcome(kind: .tests, ok: failed == 0, passed: total - failed, failed: failed, errors: nil)
        }
        // xcodebuild
        if has(#"\*\* TEST SUCCEEDED \*\*"#, in: output) { return BuildOutcome(kind: .tests, ok: true, passed: nil, failed: 0, errors: nil) }
        if has(#"\*\* TEST FAILED \*\*"#, in: output) { return BuildOutcome(kind: .tests, ok: false, passed: nil, failed: nil, errors: nil) }
        if has(#"\*\* BUILD SUCCEEDED \*\*"#, in: output) { return BuildOutcome(kind: .build, ok: true, passed: nil, failed: nil, errors: 0) }
        if has(#"\*\* BUILD FAILED \*\*"#, in: output) {
            let e = output.components(separatedBy: "error:").count - 1
            return BuildOutcome(kind: .build, ok: false, passed: nil, failed: nil, errors: e)
        }
        // Jest: "Tests:       1 failed, 12 passed, 13 total"
        if let r = ints(#"Tests:\s+(?:(\d+) failed, )?(?:(\d+) skipped, )?(?:(\d+) passed, )?(\d+) total"#, in: output) {
            return BuildOutcome(kind: .tests, ok: r[0] == 0, passed: r[2], failed: r[0], errors: nil)
        }
        // Vitest: "Tests  1 failed | 12 passed (13)"
        if let r = ints(#"Tests\s+(?:(\d+) failed \| )?(\d+) passed"#, in: output) {
            return BuildOutcome(kind: .tests, ok: r[0] == 0, passed: r[1], failed: r[0], errors: nil)
        }
        // pytest: "=== 1 failed, 12 passed in 3.2s ==="
        if has(#"=+ .*(passed|failed).* in [\d.]+s"#, in: output) {
            let f = ints(#"(\d+) failed"#, in: output)?.first ?? 0
            let p = ints(#"(\d+) passed"#, in: output)?.first ?? 0
            return BuildOutcome(kind: .tests, ok: f == 0, passed: p, failed: f, errors: nil)
        }
        // cargo: "test result: ok. 12 passed; 0 failed"
        if let r = lastMatch(#"test result: (ok|FAILED)\. (\d+) passed; (\d+) failed"#, in: output) {
            return BuildOutcome(kind: .tests, ok: r[0] == "ok", passed: Int(r[1]), failed: Int(r[2]), errors: nil)
        }
        // swift build
        if has(#"Build complete!"#, in: output) { return BuildOutcome(kind: .build, ok: true, passed: nil, failed: nil, errors: 0) }
        if cmd.contains("build"), has(#"error: "#, in: output) {
            return BuildOutcome(kind: .build, ok: false, passed: nil, failed: nil, errors: output.components(separatedBy: "error: ").count - 1)
        }
        return nil
    }

    private static func lastMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
