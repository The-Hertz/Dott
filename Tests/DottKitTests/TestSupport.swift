import Foundation
@testable import DottKit

enum T {
    /// Un calendario fisso: i collaudi non dipendono dal fuso del computer.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static var format: DayFormat { DayFormat(calendar: calendar) }

    /// 2026-10-08 12:00 UTC piu' `seconds`.
    static func at(_ seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_791_460_800 + seconds)
    }

    static func tempDir(_ name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dottkit-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Una riga di trascrizione di Claude Code con il suo consumo.
    static func assistantLine(id: String, request: String = "req1", session: String = "s1", cwd: String = "/Users/me/Forma",
                              model: String = "claude-opus-5-5", timestamp: String = "2026-10-08T12:00:00.000Z",
                              input: Int = 10, output: Int = 20, cacheWrite: Int = 100, cacheRead: Int = 1000,
                              sidechain: Bool = false) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"\(session)","cwd":"\(cwd)","requestId":"\(request)","isSidechain":\(sidechain),"message":{"id":"\(id)","role":"assistant","model":"\(model)","content":[{"type":"text","text":"ciao"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    static func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        _ = try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }
}
