import Foundation

/// Kleines JSON-Schema für strukturierte Antworten. Jeder Anbieter übersetzt es in sein Format (Ollama `format`,
/// OpenAI `json_schema`, Anthropic-Werkzeug, Foundation Models `DynamicGenerationSchema`); die App prüft die Antwort
/// danach selbst, weil sich nicht jedes Modell daran hält.
public indirect enum JSONSchema: Sendable, Equatable {
    case object(name: String, description: String?, properties: [Property])
    case array(description: String?, items: JSONSchema, minimum: Int?, maximum: Int?)
    case string(description: String?, choices: [String]?)
    case number(description: String?)

    public struct Property: Sendable, Equatable {
        public var name: String
        public var schema: JSONSchema
        public var required: Bool

        public init(_ name: String, _ schema: JSONSchema, required: Bool = true) {
            self.name = name
            self.schema = schema
            self.required = required
        }
    }

    public static func string(_ description: String, choices: [String]? = nil) -> JSONSchema {
        .string(description: description, choices: choices)
    }

    public var description: String? {
        switch self {
        case .object(_, let description, _), .array(let description, _, _, _), .string(let description, _),
            .number(let description):
            description
        }
    }

    /// Als JSON-Schema-Objekt (Draft 2020-12, nur die Teile, die alle Anbieter verstehen).
    public var dictionary: [String: Any] {
        var result: [String: Any]
        switch self {
        case .object(_, _, let properties):
            result = [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema.dictionary) }),
                "required": properties.filter(\.required).map(\.name),
                "additionalProperties": false,
            ]
        case .array(_, let items, let minimum, let maximum):
            result = ["type": "array", "items": items.dictionary]
            if let minimum { result["minItems"] = minimum }
            if let maximum { result["maxItems"] = maximum }
        case .string(_, let choices):
            result = ["type": "string"]
            if let choices { result["enum"] = choices }
        case .number:
            result = ["type": "number"]
        }
        if let description { result["description"] = description }
        return result
    }

    /// Lesbare Feldbeschreibung für Anbieter ohne Schema-Unterstützung (im Prompt).
    public func outline(indent: String = "") -> String {
        switch self {
        case .object(_, _, let properties):
            return properties.map { property in
                let detail = property.schema.description.map { " – \($0)" } ?? ""
                switch property.schema {
                case .object:
                    return "\(indent)\(property.name): Objekt\(detail)\n"
                        + property.schema.outline(indent: indent + "  ")
                case .array(_, let items, _, _):
                    if case .object = items {
                        return "\(indent)\(property.name): Liste von Objekten\(detail), je Objekt:\n"
                            + items.outline(indent: indent + "  ")
                    }
                    return "\(indent)\(property.name): Liste von Texten\(detail)"
                case .string(_, let choices):
                    let options = choices.map { " (genau einer von: \($0.joined(separator: ", ")))" } ?? ""
                    return "\(indent)\(property.name): Text\(detail)\(options)"
                case .number:
                    return "\(indent)\(property.name): Zahl\(detail)"
                }
            }.joined(separator: "\n")
        default:
            return indent + (description ?? "")
        }
    }

    /// Prüft eine Antwort gegen das Schema; liefert die Abweichungen (leer heißt gültig).
    public func violations(of value: Any, path: String = "Antwort") -> [String] {
        switch self {
        case .object(_, _, let properties):
            guard let object = value as? [String: Any] else { return ["\(path) ist kein Objekt"] }
            var problems: [String] = []
            for property in properties {
                if let child = object[property.name], !(child is NSNull) {
                    problems += property.schema.violations(of: child, path: "\(path).\(property.name)")
                } else if property.required {
                    problems.append("\(path).\(property.name) fehlt")
                }
            }
            return problems
        case .array(_, let items, let minimum, let maximum):
            guard let array = value as? [Any] else { return ["\(path) ist keine Liste"] }
            var problems: [String] = []
            if let minimum, array.count < minimum { problems.append("\(path) hat weniger als \(minimum) Einträge") }
            if let maximum, array.count > maximum { problems.append("\(path) hat mehr als \(maximum) Einträge") }
            for (index, element) in array.enumerated() {
                problems += items.violations(of: element, path: "\(path)[\(index)]")
            }
            return problems
        case .string(_, let choices):
            guard let text = value as? String else { return ["\(path) ist kein Text"] }
            if let choices, !choices.contains(text) { return ["\(path) „\(text)“ ist keiner von \(choices)"] }
            return []
        case .number:
            return value is NSNumber && !(value is Bool) ? [] : ["\(path) ist keine Zahl"]
        }
    }
}

/// Holt das JSON-Objekt aus einer Modellantwort: ohne Code-Zäune, ab der ersten `{` bis zur passenden `}`.
public enum JSONExtraction {
    /// Wie `strictObject`; schlägt das fehl, noch einmal mit geraden statt typografischen Anführungszeichen (die
    /// Textfelder und manche Chat-Oberflächen beim Kopieren einsetzen).
    public static func object(in text: String) -> Any? {
        if let object = strictObject(in: text) { return object }
        let straightened = text.replacingOccurrences(of: "[„“”″]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‚‘’]", with: "'", options: .regularExpression)
        return straightened == text ? nil : strictObject(in: straightened)
    }

    static func strictObject(in text: String) -> Any? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let candidate = String(text[start...index])
                    return try? JSONSerialization.jsonObject(with: Data(candidate.utf8))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
