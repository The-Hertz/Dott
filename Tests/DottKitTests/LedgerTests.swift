import XCTest
@testable import DottKit

final class UsageParsingTests: XCTestCase {
    func testParsesAssistantLine() throws {
        let line = T.assistantLine(id: "m1", input: 5, output: 7, cacheWrite: 11, cacheRead: 13)
        let e = try XCTUnwrap(TranscriptParser.parse(line: Data(line.utf8)))
        XCTAssertEqual(e.totals, UsageTotals(input: 5, output: 7, cacheWrite: 11, cacheRead: 13, messages: 1))
        XCTAssertEqual(e.totals.total, 36)
        XCTAssertEqual(e.totals.fresh, 23)
        XCTAssertEqual(e.model, "claude-opus-5-5")
        XCTAssertEqual(e.dedupeKey, "m1:req1")
        XCTAssertEqual(e.timestamp, T.at(0))
        XCTAssertFalse(e.sidechain)
    }

    func testIgnoresSyntheticAndUserAndEmpty() {
        let synthetic = T.assistantLine(id: "m1", model: "<synthetic>")
        XCTAssertNil(TranscriptParser.parse(line: Data(synthetic.utf8)))
        let user = #"{"type":"user","timestamp":"2026-10-08T12:00:00Z","message":{"role":"user","content":"ciao","usage":{"input_tokens":1}}}"#
        XCTAssertNil(TranscriptParser.parse(line: Data(user.utf8)))
        let zero = T.assistantLine(id: "m2", input: 0, output: 0, cacheWrite: 0, cacheRead: 0)
        XCTAssertNil(TranscriptParser.parse(line: Data(zero.utf8)))
        XCTAssertNil(TranscriptParser.parse(line: Data("non e' json \"usage\"".utf8)))
    }

    func testTimestampWithoutFraction() throws {
        let line = T.assistantLine(id: "m1", timestamp: "2026-10-08T12:00:30Z")
        XCTAssertEqual(try XCTUnwrap(TranscriptParser.parse(line: Data(line.utf8))).timestamp, T.at(30))
    }

    func testRateCardPicksLongestMatchAndRefusesUnknownModels() {
        let card = RateCard(rates: [
            "opus": ModelRate(input: 10, output: 50, cacheWrite: 12, cacheRead: 1),
            "opus-5-5": ModelRate(input: 5, output: 25, cacheWrite: 6, cacheRead: 0.5),
        ])
        XCTAssertEqual(card.rate(for: "claude-opus-5-5")?.input, 5)
        XCTAssertEqual(card.rate(for: "claude-opus-4")?.input, 10)
        XCTAssertNil(card.rate(for: "claude-haiku-5"))
        let t = UsageTotals(input: 1_000_000, output: 1_000_000, cacheWrite: 0, cacheRead: 2_000_000)
        XCTAssertEqual(card.cost(byModel: ["claude-opus-5-5": t]) ?? -1, 5 + 25 + 1, accuracy: 0.0001)
        XCTAssertNil(card.cost(byModel: ["claude-opus-5-5": t, "claude-haiku-5": t]), "senza prezzo per un modello nessuna cifra")
    }
}

final class LedgerScannerTests: XCTestCase {
    private func makeScanner(_ root: URL) -> LedgerScanner {
        LedgerScanner(projectsDir: root.appendingPathComponent("projects"), stateFile: root.appendingPathComponent("ledger.json"), format: T.format)
    }

    func testCountsOnceAndResumesWhereItStopped() throws {
        let root = T.tempDir()
        let file = root.appendingPathComponent("projects/-Users-me-Forma/s1.jsonl")
        try T.write([T.assistantLine(id: "m1"), T.assistantLine(id: "m2", request: "req2")], to: file)

        let scanner = makeScanner(root)
        var r = scanner.scan(now: T.at())
        XCTAssertEqual(r.messagesAdded, 2)
        XCTAssertEqual(scanner.rows.reduce(0) { $0 + $1.totals.messages }, 2)

        r = scanner.scan(now: T.at())
        XCTAssertEqual(r.messagesAdded, 0, "una seconda lettura senza novita' non aggiunge niente")
        XCTAssertEqual(r.filesRead, 0)

        try T.append(T.assistantLine(id: "m3", request: "req3") + "\n", to: file)
        r = scanner.scan(now: T.at())
        XCTAssertEqual(r.messagesAdded, 1)
        XCTAssertEqual(scanner.rows.reduce(0) { $0 + $1.totals.messages }, 3)
    }

    func testPartialLastLineWaitsForItsNewline() throws {
        let root = T.tempDir()
        let file = root.appendingPathComponent("projects/p/s1.jsonl")
        let second = T.assistantLine(id: "m2", request: "req2")
        try T.write([T.assistantLine(id: "m1")], to: file)
        try T.append(String(second.prefix(40)), to: file)

        let scanner = makeScanner(root)
        XCTAssertEqual(scanner.scan(now: T.at()).messagesAdded, 1, "la riga a meta' non si legge")
        try T.append(String(second.dropFirst(40)) + "\n", to: file)
        XCTAssertEqual(scanner.scan(now: T.at()).messagesAdded, 1, "completata, si legge una volta sola")
        XCTAssertEqual(scanner.rows.reduce(0) { $0 + $1.totals.messages }, 2)
    }

    func testResumedChatDoesNotDoubleCount() throws {
        let root = T.tempDir()
        // Riprendendo una chat, Claude Code copia i messaggi vecchi nel nuovo file.
        try T.write([T.assistantLine(id: "m1"), T.assistantLine(id: "m2", request: "req2")], to: root.appendingPathComponent("projects/p/a.jsonl"))
        try T.write([T.assistantLine(id: "m1"), T.assistantLine(id: "m2", request: "req2"), T.assistantLine(id: "m3", request: "req3")],
                    to: root.appendingPathComponent("projects/p/b.jsonl"))
        let scanner = makeScanner(root)
        let r = scanner.scan(now: T.at())
        XCTAssertEqual(r.messagesAdded, 3)
        XCTAssertEqual(r.duplicatesSkipped, 2)
    }

    func testStatePersistsAcrossLaunches() throws {
        let root = T.tempDir()
        try T.write([T.assistantLine(id: "m1")], to: root.appendingPathComponent("projects/p/s1.jsonl"))
        XCTAssertEqual(makeScanner(root).scan(now: T.at()).messagesAdded, 1)
        let again = makeScanner(root)
        XCTAssertEqual(again.rows.count, 1)
        XCTAssertEqual(again.scan(now: T.at()).messagesAdded, 0)
    }

    func testGroupingAndPerDayWithoutGaps() throws {
        let root = T.tempDir()
        try T.write([
            T.assistantLine(id: "m1", cwd: "/a", timestamp: "2026-10-08T09:00:00Z", input: 100, output: 0, cacheWrite: 0, cacheRead: 0),
            T.assistantLine(id: "m2", request: "r2", cwd: "/b", timestamp: "2026-10-06T09:00:00Z", input: 300, output: 0, cacheWrite: 0, cacheRead: 0),
            T.assistantLine(id: "m3", request: "r3", cwd: "/a", timestamp: "2026-10-06T10:00:00Z", input: 50, output: 0, cacheWrite: 0, cacheRead: 0),
        ], to: root.appendingPathComponent("projects/p/s1.jsonl"))
        let scanner = makeScanner(root)
        scanner.scan(now: T.at())

        let byCwd = LedgerQuery.group(scanner.rows, by: { $0.cwd })
        XCTAssertEqual(byCwd.map(\.key), ["/b", "/a"], "il piu' pesante per primo")
        XCTAssertEqual(byCwd.first(where: { $0.key == "/a" })?.totals.input, 150)

        let days = LedgerQuery.perDay(scanner.rows, last: 4, endingAt: T.at(), format: T.format)
        XCTAssertEqual(days.map(\.key), ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"])
        XCTAssertEqual(days.map { $0.totals.input }, [0, 350, 0, 100])

        let share = LedgerQuery.orchestrationShare(scanner.rows, isOrchestrated: { $0.cwd == "/b" })
        XCTAssertEqual(share.orchestrated.input, 300)
        XCTAssertEqual(share.other.input, 150)
    }

    func testOldRowsArePruned() throws {
        let root = T.tempDir()
        try T.write([T.assistantLine(id: "old", timestamp: "2024-01-01T09:00:00Z"), T.assistantLine(id: "new", request: "r2")],
                    to: root.appendingPathComponent("projects/p/s1.jsonl"))
        let scanner = LedgerScanner(projectsDir: root.appendingPathComponent("projects"), stateFile: root.appendingPathComponent("l.json"),
                                    format: T.format, keepDays: 30)
        scanner.scan(now: T.at())
        XCTAssertEqual(scanner.rows.map(\.day), ["2026-10-08"])
    }
}
