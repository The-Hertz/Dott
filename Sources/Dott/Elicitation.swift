import Foundation

/// Un campo di un modulo che un server MCP chiede di compilare.
struct ElicField: Identifiable {
    enum Kind { case text, number, integer, bool, choice }
    let id: String            // chiave nello schema
    let title: String
    let help: String?
    let kind: Kind
    let options: [String]
    let required: Bool
    var initialText = ""
    var initialFlag = false
}

struct ElicState: Identifiable {
    let id = UUID()
    let sessionId: String
    let project: String
    let server: String
    let message: String
    let mode: String          // "form" | "url"
    let url: String?
    let fields: [ElicField]
    let connection: Connection

    var needsKeyboard: Bool { fields.contains { $0.kind == .text || $0.kind == .number || $0.kind == .integer } }

    /// Altezza della card (sotto il notch).
    var height: CGFloat {
        let shown = CGFloat(min(fields.count, 3))
        return 120 + (mode == "url" ? 40 : 52 * shown) + 24
    }

    static func parseFields(_ schema: [String: Any]?) -> [ElicField] {
        guard let schema, let props = schema["properties"] as? [String: Any] else { return [] }
        let required = Set(schema["required"] as? [String] ?? [])
        return props.keys.sorted().compactMap { key in
            guard let d = props[key] as? [String: Any] else { return nil }
            let title = d["title"] as? String ?? key
            let help = d["description"] as? String
            let type = d["type"] as? String ?? "string"
            let enumValues = (d["enum"] as? [Any])?.map { "\($0)" } ?? []
            var f: ElicField
            if !enumValues.isEmpty {
                f = ElicField(id: key, title: title, help: help, kind: .choice, options: enumValues, required: required.contains(key))
                f.initialText = (d["default"] as? String) ?? enumValues.first ?? ""
            } else {
                let kind: ElicField.Kind
                switch type {
                case "boolean": kind = .bool
                case "integer": kind = .integer
                case "number": kind = .number
                default: kind = .text
                }
                f = ElicField(id: key, title: title, help: help, kind: kind, options: [], required: required.contains(key))
                if let t = d["default"] as? String { f.initialText = t }
                if let n = d["default"] as? NSNumber, kind != .bool { f.initialText = n.stringValue }
                if let b = d["default"] as? Bool { f.initialFlag = b }
            }
            return f
        }
    }
}
