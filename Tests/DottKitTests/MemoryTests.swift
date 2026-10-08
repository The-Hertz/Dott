import XCTest
@testable import DottKit

final class MemoryStoreTests: XCTestCase {
    func testRoundTripAndUpdate() {
        let store = MemoryStore(dir: T.tempDir())
        XCTAssertTrue(store.load("forma", name: "Forma").notes.isEmpty)
        let note = MemoryNote(kind: .decision, text: "Usiamo SwiftData", created: T.at())
        store.update("forma", name: "Forma") { $0.notes.append(note) }
        let loaded = store.load("forma")
        XCTAssertEqual(loaded.notes, [note])
        XCTAssertEqual(loaded.name, "Forma")
        XCTAssertEqual(store.all().map(\.key), ["forma"])
    }

    func testKeysWithOddCharactersDoNotCollide() {
        let a = DottPaths.fileName(for: "/Users/me/Forma")
        let b = DottPaths.fileName(for: "/Users/me/Forma ")
        let c = DottPaths.fileName(for: "/Users/me/Forma")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertFalse(a.contains("/"))
    }

    func testEraseAll() {
        let store = MemoryStore(dir: T.tempDir())
        store.update("a") { $0.briefEnabled = false }
        store.eraseAll()
        XCTAssertTrue(store.all().isEmpty)
    }
}

final class BriefTests: XCTestCase {
    private func memory(notes: [MemoryNote] = [], inbox: [InboxItem] = [], handoff: Handoff? = nil) -> ProjectMemory {
        var m = ProjectMemory(key: "forma", name: "Forma")
        m.notes = notes
        m.inbox = inbox
        m.handoff = handoff
        return m
    }

    func testNothingToSayMeansNoBrief() {
        XCTAssertNil(BriefBuilder.build(memory(), now: T.at(), format: T.format))
    }

    func testDisabledProjectGetsNothing() {
        var m = memory(notes: [MemoryNote(kind: .fact, text: "x")])
        m.briefEnabled = false
        XCTAssertNil(BriefBuilder.build(m, now: T.at(), format: T.format))
    }

    func testBriefHasSectionsAndOwner() throws {
        let m = memory(
            notes: [MemoryNote(kind: .preference, text: "Commenti in italiano", created: T.at(-100), pinned: true)],
            inbox: [InboxItem(text: "Controlla il crash all'avvio", created: T.at(-50))],
            handoff: Handoff(savedAt: T.at(-86_400), lastPrompt: "Aggiungi il grafico", lastOutcome: "Fatto, test verdi",
                             openTodos: ["Legenda"], files: ["Chart.swift"], branch: "grafico"))
        let b = try XCTUnwrap(BriefBuilder.build(m, now: T.at(), options: BriefOptions(ownerName: "Francesco"), format: T.format))
        XCTAssertTrue(b.text.contains("scritto da Francesco"))
        XCTAssertTrue(b.text.contains("Da ricordare:"))
        XCTAssertTrue(b.text.contains("(preferenza) Commenti in italiano"))
        XCTAssertTrue(b.text.contains("Dove eravamo (ieri alle 12:00):"))
        XCTAssertTrue(b.text.contains("Ultima richiesta: «Aggiungi il grafico»"))
        XCTAssertTrue(b.text.contains("Ancora aperto: Legenda"))
        XCTAssertTrue(b.text.contains("Appunti lasciati mentre non c'eri:"))
        XCTAssertEqual(b.deliveredInbox, m.inbox.map(\.id))
        XCTAssertEqual(b.droppedNotes, 0)
        XCTAssertEqual(b.estimatedTokens, TokenEstimate.of(b.text))
    }

    func testBudgetIsRespectedAndPinnedNotesWin() throws {
        let pinned = MemoryNote(kind: .gotcha, text: "Non toccare mai il file Secrets.swift", created: T.at(-1000), pinned: true)
        var notes = [pinned]
        for i in 0..<40 {
            notes.append(MemoryNote(kind: .fact, text: "Nota numero \(i) con un po' di testo per occupare spazio", created: T.at(TimeInterval(-i))))
        }
        let options = BriefOptions(tokenBudget: 200, ownerName: "Fra")
        let b = try XCTUnwrap(BriefBuilder.build(memory(notes: notes), now: T.at(), options: options, format: T.format))
        XCTAssertLessThanOrEqual(b.estimatedTokens, 200)
        XCTAssertTrue(b.includedNotes.contains(pinned.id))
        XCTAssertGreaterThan(b.droppedNotes, 0)
        XCTAssertEqual(b.includedNotes.count + b.droppedNotes, 41)
    }

    func testStaleHandoffIsLeftOut() {
        let old = Handoff(savedAt: T.at(-90 * 86_400), lastPrompt: "vecchia richiesta")
        XCTAssertNil(BriefBuilder.build(memory(handoff: old), now: T.at(), format: T.format))
    }

    func testDisabledNotesAreNotDelivered() throws {
        let off = MemoryNote(kind: .fact, text: "spenta", enabled: false)
        let on = MemoryNote(kind: .fact, text: "accesa")
        let b = try XCTUnwrap(BriefBuilder.build(memory(notes: [off, on]), now: T.at(), format: T.format))
        XCTAssertFalse(b.text.contains("spenta"))
        XCTAssertTrue(b.text.contains("accesa"))
    }

    func testMultilineNotesStayOnOneLine() throws {
        let b = try XCTUnwrap(BriefBuilder.build(memory(notes: [MemoryNote(kind: .fact, text: "riga uno\nriga due")]), now: T.at(), format: T.format))
        XCTAssertTrue(b.text.contains("riga uno riga due"))
    }
}

final class HandoffTests: XCTestCase {
    private func event(_ s: TimeInterval, _ kind: JournalKind, text: String? = nil) -> JournalEvent {
        JournalEvent(at: T.at(s), project: "forma", name: "Forma", session: "s1", kind: kind, text: text)
    }

    func testBuildsFromEvents() throws {
        let events = [event(0, .prompt, text: "prima"), event(10, .edit, text: "A.swift"), event(20, .prompt, text: "seconda"),
                      event(30, .edit, text: "B.swift"), event(40, .edit, text: "A.swift"), event(50, .stop, text: "Fatto")]
        let h = try XCTUnwrap(Handoff.make(from: events, openTodos: ["x"], branch: "main", outcome: nil, now: T.at(60)))
        XCTAssertEqual(h.lastPrompt, "seconda")
        XCTAssertEqual(h.lastOutcome, "Fatto")
        XCTAssertEqual(h.files, ["B.swift", "A.swift"], "l'ultimo file toccato e' in fondo, senza doppioni")
        XCTAssertEqual(h.branch, "main")
    }

    func testNoPromptNoHandoff() {
        XCTAssertNil(Handoff.make(from: [event(0, .sessionStart)], openTodos: [], branch: nil, outcome: nil, now: T.at()))
    }
}

final class CaptureParserTests: XCTestCase {
    func testPlainTextIsAnInboxItem() {
        XCTAssertEqual(CaptureParser.parse("  controlla il crash  "), CaptureIntent(project: nil, action: .inbox, text: "controlla il crash"))
    }

    func testProjectAndCommandInEitherOrder() {
        let expected = CaptureIntent(project: "Workout", action: .note(.decision), text: "usiamo SwiftData")
        XCTAssertEqual(CaptureParser.parse("@Workout /decisione usiamo SwiftData"), expected)
        XCTAssertEqual(CaptureParser.parse("/decisione @Workout usiamo SwiftData"), expected)
    }

    func testQuotedProjectNameWithSpaces() {
        XCTAssertEqual(CaptureParser.parse("@\"Il mio progetto\" ricordati la scadenza"),
                       CaptureIntent(project: "Il mio progetto", action: .inbox, text: "ricordati la scadenza"))
    }

    func testRejectsEmptyAndUnknown() {
        XCTAssertNil(CaptureParser.parse("   "))
        XCTAssertNil(CaptureParser.parse("@Workout"))
        XCTAssertNil(CaptureParser.parse("/boh qualcosa"))
        XCTAssertNil(CaptureParser.parse("@\"aperto senza chiusura"))
        XCTAssertEqual(CaptureParser.parse("/ricorda il compleanno")?.action, .note(.fact))
    }
}

final class FormatTests: XCTestCase {
    func testAgoAndDuration() {
        let f = T.format
        XCTAssertEqual(f.ago(T.at(-30), now: T.at()), "adesso")
        XCTAssertEqual(f.ago(T.at(-20 * 60), now: T.at()), "20 minuti fa")
        XCTAssertEqual(f.ago(T.at(-3 * 3600), now: T.at()), "oggi alle 09:00")
        XCTAssertEqual(f.ago(T.at(-86_400), now: T.at()), "ieri alle 12:00")
        XCTAssertEqual(f.ago(T.at(-5 * 86_400), now: T.at()), "5 giorni fa")
        XCTAssertEqual(f.ago(T.at(-21 * 86_400), now: T.at()), "3 settimane fa")
        XCTAssertEqual(DayFormat.duration(20), "meno di un minuto")
        XCTAssertEqual(DayFormat.duration(45 * 60), "45 min")
        XCTAssertEqual(DayFormat.duration(80 * 60), "1 h 20 min")
        XCTAssertEqual(DayFormat.duration(2 * 3600), "2 h")
    }
}

final class HealthTests: XCTestCase {
    private func makeHome() throws -> (URL, DottPaths) {
        let home = T.tempDir()
        let paths = DottPaths(root: home.appendingPathComponent("Library/Application Support/Dott"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        return (home, paths)
    }

    private func settings(_ home: URL, events: [String]) throws {
        var hooks: [String: Any] = [:]
        for e in events { hooks[e] = [["hooks": [["type": "command", "command": "\"/x/dott-hook\""]]]] }
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try data.write(to: home.appendingPathComponent(".claude/settings.json"))
    }

    func testMissingSettingsIsAProblem() throws {
        let (home, paths) = try makeHome()
        let item = HealthChecker(home: home, paths: paths).claudeHooks()
        XCTAssertEqual(item.status, .problem)
        XCTAssertNotNil(item.fix)
    }

    func testAllHooksPresent() throws {
        let (home, paths) = try makeHome()
        try settings(home, events: HealthChecker.requiredEvents)
        XCTAssertEqual(HealthChecker(home: home, paths: paths).claudeHooks().status, .ok)
    }

    func testSomeHooksMissingIsAWarningListingThem() throws {
        let (home, paths) = try makeHome()
        try settings(home, events: Array(HealthChecker.requiredEvents.dropLast(2)))
        let item = HealthChecker(home: home, paths: paths).claudeHooks()
        XCTAssertEqual(item.status, .warning)
        XCTAssertTrue(item.detail.contains("PreCompact"))
        XCTAssertTrue(item.detail.contains("PostCompact"))
    }

    func testOtherPeoplesHooksDoNotCount() throws {
        let (home, paths) = try makeHome()
        let data = try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/altro/script"]]]]]])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try data.write(to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(HealthChecker(home: home, paths: paths).claudeHooks().status, .problem)
    }

    func testBrokenJSON() throws {
        let (home, paths) = try makeHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "{ non json".write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        let item = HealthChecker(home: home, paths: paths).claudeHooks()
        XCTAssertEqual(item.status, .problem)
        XCTAssertTrue(item.detail.contains("JSON"))
    }

    func testHookScriptStates() throws {
        let (home, paths) = try makeHome()
        let checker = HealthChecker(home: home, paths: paths)
        XCTAssertEqual(checker.hookScript().status, .problem)
        try "#!/bin/sh\n".write(to: paths.hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.hookScript.path)
        XCTAssertEqual(checker.hookScript().status, .problem)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hookScript.path)
        XCTAssertEqual(checker.hookScript().status, .ok)
    }

    func testSocketMissingIsWarningNotProblem() throws {
        let (home, paths) = try makeHome()
        XCTAssertEqual(HealthChecker(home: home, paths: paths).socket().status, .warning)
    }

    func testClaudeDataFolder() throws {
        let (home, paths) = try makeHome()
        let checker = HealthChecker(home: home, paths: paths)
        XCTAssertEqual(checker.claudeData().status, .warning)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/p"), withIntermediateDirectories: true)
        XCTAssertEqual(checker.claudeData().status, .ok)
    }
}
