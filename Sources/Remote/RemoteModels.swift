import Foundation

struct RemoteApprovalPrompt: Identifiable, Equatable {
    enum Kind: String {
        case command, fileChange, permissions
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
}

struct RemoteUserInputPrompt: Identifiable, Equatable {
    struct Option: Identifiable, Equatable {
        let label: String
        let description: String
        var id: String { label }
    }

    struct Question: Identifiable, Equatable {
        let id: String
        let header: String
        let question: String
        let options: [Option]
        let isOther: Bool
        let isSecret: Bool
    }

    let id = UUID()
    let questions: [Question]
}

enum RemoteMcpElicitationValue: Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case strings([String])

    var jsonValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .integer(let value): value
        case .boolean(let value): value
        case .strings(let value): value
        }
    }
}

struct RemoteMcpElicitationPrompt: Identifiable, Equatable {
    struct Choice: Identifiable, Equatable {
        let value: String
        let label: String
        var id: String { value }
    }

    enum FieldKind: Equatable {
        case string(format: String?, minLength: Int?, maxLength: Int?)
        case number(integer: Bool, minimum: Double?, maximum: Double?)
        case boolean
        case singleSelect([Choice])
        case multiSelect([Choice], minItems: Int?, maxItems: Int?)
    }

    struct Field: Identifiable, Equatable {
        let key: String
        let title: String
        let description: String?
        let required: Bool
        let kind: FieldKind
        let defaultValue: RemoteMcpElicitationValue?
        var id: String { key }
    }

    let id = UUID()
    let serverName: String
    let message: String
    let fields: [Field]

    init?(params: [String: Any]) {
        guard params["mode"] as? String == "form",
              let serverName = params["serverName"] as? String,
              let message = params["message"] as? String,
              let schema = params["requestedSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any]
        else { return nil }

        let requiredKeys = Set(schema["required"] as? [String] ?? [])
        guard requiredKeys.isSubset(of: Set(properties.keys)) else { return nil }

        var parsed: [Field] = []
        parsed.reserveCapacity(properties.count)
        for key in properties.keys.sorted() {
            guard let raw = properties[key] as? [String: Any],
                  let field = Self.parseField(key: key, raw: raw, required: requiredKeys.contains(key))
            else { return nil }
            parsed.append(field)
        }

        self.serverName = serverName
        self.message = message
        fields = parsed
    }

    private static func parseField(key: String, raw: [String: Any], required: Bool) -> Field? {
        guard let type = raw["type"] as? String else { return nil }
        let title = nonEmpty(raw["title"] as? String) ?? key
        let description = nonEmpty(raw["description"] as? String)

        switch type {
        case "string":
            let declaresChoices = raw["enum"] != nil || raw["oneOf"] != nil
            if declaresChoices {
                guard let choices = singleSelectChoices(raw), !choices.isEmpty else { return nil }
                if raw["default"] != nil, raw["default"] as? String == nil { return nil }
                let defaultValue = (raw["default"] as? String).map(RemoteMcpElicitationValue.string)
                if case .string(let value)? = defaultValue,
                   !choices.contains(where: { $0.value == value }) { return nil }
                return Field(
                    key: key,
                    title: title,
                    description: description,
                    required: required,
                    kind: .singleSelect(choices),
                    defaultValue: defaultValue
                )
            }
            let minLength = nonNegativeInt(raw["minLength"])
            let maxLength = nonNegativeInt(raw["maxLength"])
            if let minLength, let maxLength, minLength > maxLength { return nil }
            if raw["default"] != nil, raw["default"] as? String == nil { return nil }
            if let value = raw["default"] as? String {
                if let minLength, value.count < minLength { return nil }
                if let maxLength, value.count > maxLength { return nil }
            }
            return Field(
                key: key,
                title: title,
                description: description,
                required: required,
                kind: .string(
                    format: raw["format"] as? String,
                    minLength: minLength,
                    maxLength: maxLength
                ),
                defaultValue: (raw["default"] as? String).map(RemoteMcpElicitationValue.string)
            )
        case "number", "integer":
            let minimum = number(raw["minimum"])
            let maximum = number(raw["maximum"])
            if let minimum, let maximum, minimum > maximum { return nil }
            let defaultValue: RemoteMcpElicitationValue?
            if raw["default"] != nil {
                guard let rawDefault = number(raw["default"]) else { return nil }
                if let minimum, rawDefault < minimum { return nil }
                if let maximum, rawDefault > maximum { return nil }
                if type == "integer" {
                    guard rawDefault.rounded() == rawDefault else { return nil }
                    guard rawDefault >= Double(Int.min), rawDefault < Double(Int.max) else { return nil }
                    defaultValue = .integer(Int(rawDefault))
                } else {
                    defaultValue = .number(rawDefault)
                }
            } else {
                defaultValue = nil
            }
            return Field(
                key: key,
                title: title,
                description: description,
                required: required,
                kind: .number(integer: type == "integer", minimum: minimum, maximum: maximum),
                defaultValue: defaultValue
            )
        case "boolean":
            let defaultValue: RemoteMcpElicitationValue?
            if raw["default"] != nil {
                guard let value = raw["default"] as? Bool else { return nil }
                defaultValue = .boolean(value)
            } else {
                defaultValue = nil
            }
            return Field(
                key: key,
                title: title,
                description: description,
                required: required,
                kind: .boolean,
                defaultValue: defaultValue
            )
        case "array":
            guard let choices = multiSelectChoices(raw), !choices.isEmpty else { return nil }
            let minItems = nonNegativeInt(raw["minItems"])
            let maxItems = nonNegativeInt(raw["maxItems"])
            if let minItems, let maxItems, minItems > maxItems { return nil }
            if raw["default"] != nil, raw["default"] as? [String] == nil { return nil }
            let defaults = raw["default"] as? [String]
            if let defaults,
               defaults.contains(where: { value in !choices.contains(where: { $0.value == value }) }) {
                return nil
            }
            if let defaults, let minItems, defaults.count < minItems { return nil }
            if let defaults, let maxItems, defaults.count > maxItems { return nil }
            return Field(
                key: key,
                title: title,
                description: description,
                required: required,
                kind: .multiSelect(choices, minItems: minItems, maxItems: maxItems),
                defaultValue: defaults.map(RemoteMcpElicitationValue.strings)
            )
        default:
            return nil
        }
    }

    private static func singleSelectChoices(_ raw: [String: Any]) -> [Choice]? {
        if let values = raw["enum"] as? [String] {
            let labels = raw["enumNames"] as? [String]
            if let labels, labels.count != values.count { return nil }
            return uniqueChoices(zip(values, labels ?? values).map { Choice(value: $0.0, label: $0.1) })
        }
        if let options = raw["oneOf"] as? [[String: Any]] {
            let parsed = options.compactMap { option -> Choice? in
                guard let value = option["const"] as? String,
                      let label = option["title"] as? String else { return nil }
                return Choice(value: value, label: label)
            }
            guard parsed.count == options.count else { return nil }
            return uniqueChoices(parsed)
        }
        return nil
    }

    private static func multiSelectChoices(_ raw: [String: Any]) -> [Choice]? {
        guard let items = raw["items"] as? [String: Any] else { return nil }
        if let values = items["enum"] as? [String] {
            return uniqueChoices(values.map { Choice(value: $0, label: $0) })
        }
        if let options = items["anyOf"] as? [[String: Any]] {
            let parsed = options.compactMap { option -> Choice? in
                guard let value = option["const"] as? String,
                      let label = option["title"] as? String else { return nil }
                return Choice(value: value, label: label)
            }
            guard parsed.count == options.count else { return nil }
            return uniqueChoices(parsed)
        }
        return nil
    }

    private static func uniqueChoices(_ choices: [Choice]) -> [Choice]? {
        guard Set(choices.map(\.value)).count == choices.count else { return nil }
        return choices
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let number = number(value), number >= 0, number.rounded() == number else { return nil }
        return Int(number)
    }
}

struct RemoteThreadSummary: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let preview: String
    let model: String?
    let status: String?
    let source: String?
    let originator: String?
    let cwd: String?
    let projectID: String?
    let parentThreadID: String?
    let updatedAt: Date

    var title: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let firstLine = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Conversation" : trimmed
    }

    init?(object: [String: Any]) {
        guard let id = object["id"] as? String,
              let preview = object["preview"] as? String,
              let updatedAt = object["updatedAt"] as? NSNumber
        else { return nil }
        self.id = id
        name = object["name"] as? String
        self.preview = preview
        model = object["model"] as? String
        status = object["status"] as? String
        source = object["source"] as? String
        originator = object["originator"] as? String
        cwd = object["cwd"] as? String
        projectID = object["projectId"] as? String
        parentThreadID = object["parentThreadId"] as? String
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.doubleValue)
    }

    var projectLabel: String? {
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        if let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
            return projectID
        }
        return nil
    }
}

struct RemoteModelOption: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let model: String
    let displayName: String

    init?(object: [String: Any]) {
        guard let id = object["id"] as? String,
              let model = object["model"] as? String,
              let displayName = object["displayName"] as? String
        else { return nil }
        self.id = id
        self.model = model
        self.displayName = displayName
    }
}
