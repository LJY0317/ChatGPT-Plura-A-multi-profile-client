import Foundation

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    enum Role: String, Hashable, Codable, Sendable {
        case user
        case assistant
        case activity
    }

    enum Kind: String, Hashable, Codable, Sendable {
        case message
        case reasoningSummary
        case toolCall
        case commandExecution
        case fileChange
        case webSearch
        case imageView
        case approval
        case attachment
        case notice
        case unknown
    }

    let id: UUID
    var role: Role
    var text: String
    var kind: Kind
    var sourceID: String?
    var title: String?
    var status: String?
    var durationMilliseconds: Int?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        kind: Kind? = nil,
        sourceID: String? = nil,
        title: String? = nil,
        status: String? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.kind = kind ?? (role == .activity ? .notice : .message)
        self.sourceID = sourceID
        self.title = title
        self.status = status
        self.durationMilliseconds = durationMilliseconds
    }

    func withID(_ replacementID: UUID) -> ChatMessage {
        ChatMessage(
            id: replacementID,
            role: role,
            text: text,
            kind: kind,
            sourceID: sourceID,
            title: title,
            status: status,
            durationMilliseconds: durationMilliseconds
        )
    }
}
