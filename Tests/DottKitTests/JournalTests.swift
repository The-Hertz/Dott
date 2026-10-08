import XCTest
@testable import DottKit

final class JournalTests: XCTestCase {
    private func event(_ s: TimeInterval, _ kind: JournalKind, project: String = "forma", name: String = "Forma",
                       text: String? = nil, ok: Bool? = nil, seconds: Double? = nil) -> JournalEvent {
        JournalEvent(at: T.at(s), project: project, name: name, session: "s1", kind: kind, text: text, ok: ok, seconds: seconds)
    }

    func testWriteThenReadBackInOrder() {
        let dir = T.tempDir()
        let w = JournalWriter(dir: dir, format: T.format)
        w.append(event(60, .prompt, text: "secondo"))
        w.append(event(0, .prompt, text: "primo"))
        let events = JournalReader(dir: dir, format: T.format).events(on: T.at())
        XCTAssertEqual(events.map(\.text), ["primo", "secondo"])
    }

    func testBrokenLineIsSkipped() throws {
        let dir = T.tempDir()
        let w = JournalWriter(dir: dir, format: T.format)
        w.append(event(0, .prompt, text: "ok"))
        try T.append("{questa riga e' rotta\n", to: dir.appendingPathComponent("2026-10-08.jsonl"))
        w.append(event(10, .prompt, text: "ancora ok"))
        XCTAssertEqual(JournalReader(dir: dir, format: T.format).events(on: T.at()).count, 2)
    }

    func testEventsLastDaysSpansFiles() {
        let dir = T.tempDir()
        let w = JournalWriter(dir: dir, format: T.format)
        w.append(event(-86_400, .prompt, text: "ieri"))
        w.append(event(0, .prompt, text: "oggi"))
        let r = JournalReader(dir: dir, format: T.format)
        XCTAssertEqual(r.events(lastDays: 2, endingAt: T.at()).map(\.text), ["ieri", "oggi"])
        XCTAssertEqual(r.events(lastDays: 1, endingAt: T.at()).map(\.text), ["oggi"])
    }

    func testPruneRemovesOldDaysOnly() {
        let dir = T.tempDir()
        let w = JournalWriter(dir: dir, format: T.format)
        w.append(event(-40 * 86_400, .prompt, text: "vecchio"))
        w.append(event(0, .prompt, text: "nuovo"))
        w.prune(keepDays: 30, now: T.at())
        let r = JournalReader(dir: dir, format: T.format)
        XCTAssertTrue(r.events(on: T.at(-40 * 86_400)).isEmpty)
        XCTAssertEqual(r.events(on: T.at()).count, 1)
    }

    func testActiveTimeIgnoresLongPauses() {
        let times = [0, 60, 120, 120 + 3600, 120 + 3600 + 30].map { T.at(TimeInterval($0)) }
        XCTAssertEqual(Digester.activeTime(times, idleGap: 300), 120 + 30)
        XCTAssertEqual(Digester.activeTime([T.at()], idleGap: 300), 0)
    }

    func testDigestCountsWhatHappened() {
        let events = [
            event(0, .sessionStart),
            event(10, .prompt, text: "aggiungi il grafico"),
            event(60, .edit, text: "Chart.swift"),
            event(70, .edit, text: "Chart.swift"),
            event(80, .edit, text: "View.swift"),
            event(120, .test, ok: false),
            event(200, .test, ok: true),
            event(220, .commit, text: "Aggiunge il grafico"),
            event(230, .permission, ok: true, seconds: 4),
            event(240, .permission, ok: false, seconds: 8),
            event(250, .build, ok: false),
            event(260, .failure, text: "Bash"),
            event(100, .prompt, project: "forma-2", name: "Altro", text: "altro"),
        ]
        let d = Digester.digest(events, idleGap: 300)
        XCTAssertEqual(d.projects.count, 2)
        let forma = d.projects.first { $0.key == "forma" }!
        XCTAssertEqual(forma.prompts, 1)
        XCTAssertEqual(forma.files, ["Chart.swift", "View.swift"], "lo stesso file conta una volta")
        XCTAssertEqual(forma.commits, ["Aggiunge il grafico"])
        XCTAssertEqual(forma.testsPassed, 1)
        XCTAssertEqual(forma.testsFailed, 1)
        XCTAssertEqual(forma.buildsFailed, 1)
        XCTAssertEqual(forma.failures, 1)
        XCTAssertEqual(forma.permissionsAsked, 2)
        XCTAssertEqual(forma.permissionsDenied, 1)
        XCTAssertEqual(forma.activeSeconds, 260)
        XCTAssertEqual(forma.lastPrompt, "aggiungi il grafico")
        XCTAssertEqual(d.averagePermissionWait ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(d.activeSeconds, 260, "il tempo totale non e' la somma dei progetti")
        XCTAssertEqual(d.totalCommits, 1)
    }

    func testNarrative() {
        XCTAssertEqual(Digester.narrative(Digester.digest([])), ["Oggi non abbiamo ancora lavorato insieme."])
        let events = [event(0, .prompt, text: "x"), event(120, .edit, text: "A.swift"), event(240, .test, ok: true)]
        let lines = Digester.narrative(Digester.digest(events))
        XCTAssertEqual(lines.first, "Hai lavorato circa 4 min su 1 progetto.")
        XCTAssertTrue(lines[1].contains("Forma"))
        XCTAssertTrue(lines[1].contains("1 file modificato"))
        XCTAssertTrue(lines[1].contains("test sempre verdi"))
    }
}

final class CareTests: XCTestCase {
    private func stream(from start: TimeInterval, to end: TimeInterval, every step: TimeInterval = 120) -> [Date] {
        stride(from: start, through: end, by: step).map { T.at($0) }
    }

    func testNoNudgeForShortWork() {
        let engine = RhythmEngine(calendar: T.calendar)
        XCTAssertNil(engine.evaluate(now: T.at(30 * 60), activity: stream(from: 0, to: 30 * 60), lastNudges: [:]))
    }

    func testLongStretchNudgesAndThenStaysQuiet() {
        let engine = RhythmEngine(calendar: T.calendar)
        let now = T.at(100 * 60)
        let activity = stream(from: 0, to: 100 * 60)
        XCTAssertEqual(engine.evaluate(now: now, activity: activity, lastNudges: [:]), .longStretch(minutes: 100))
        XCTAssertNil(engine.evaluate(now: now, activity: activity, lastNudges: ["longStretch": T.at(90 * 60)]), "pausa gia' suggerita da poco")
        XCTAssertNotNil(engine.evaluate(now: T.at(190 * 60), activity: stream(from: 0, to: 190 * 60), lastNudges: ["longStretch": T.at(90 * 60)]))
    }

    func testABreakResetsTheStretch() {
        let engine = RhythmEngine(calendar: T.calendar)
        // 60 minuti di lavoro, mezz'ora di pausa, altri 60 minuti: nessuno dei due blocchi arriva a 90.
        let activity = stream(from: 0, to: 60 * 60) + stream(from: 90 * 60, to: 150 * 60)
        XCTAssertNil(engine.evaluate(now: T.at(150 * 60), activity: activity, lastNudges: [:]))
    }

    func testNoNudgeWhenNotWorkingRightNow() {
        let engine = RhythmEngine(calendar: T.calendar)
        let activity = stream(from: 0, to: 100 * 60)
        XCTAssertNil(engine.evaluate(now: T.at(130 * 60), activity: activity, lastNudges: [:]))
        XCTAssertNil(engine.evaluate(now: T.at(), activity: [], lastNudges: [:]))
    }

    func testLateNight() {
        let engine = RhythmEngine(calendar: T.calendar)
        // 12:00 UTC + 14h = 02:00
        let night = T.at(14 * 3600)
        XCTAssertEqual(engine.evaluate(now: night, activity: [T.at(14 * 3600 - 60), night], lastNudges: [:]), .lateNight)
        XCTAssertNil(engine.evaluate(now: night, activity: [T.at(14 * 3600 - 60), night], lastNudges: ["lateNight": T.at(13 * 3600)]))
    }
}
