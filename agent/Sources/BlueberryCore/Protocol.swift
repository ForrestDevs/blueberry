import Foundation

// Mirror of server/src/domain/Protocol.ts — change both together.

public let protocolVersion = 1

public struct Account: Codable, Sendable, Equatable {
    public var service: String
    public var handle: String

    public init(service: String, handle: String) {
        self.service = service
        self.handle = handle
    }
}

public struct Attachment: Codable, Sendable, Equatable {
    public var guid: String
    public var filename: String?
    public var mimeType: String?
    public var uti: String?
    public var totalBytes: Int
    public var isSticker: Bool
}

public struct Message: Codable, Sendable, Equatable {
    public var rowId: Int64
    public var guid: String
    public var chatGuid: String?
    public var sender: String?
    public var isFromMe: Bool
    public var service: String?
    public var text: String?
    public var subject: String?
    public var replyToGuid: String?
    public var threadOriginatorGuid: String?
    public var associatedMessageGuid: String?
    public var associatedMessageType: Int
    public var expressiveSendStyleId: String?
    public var dateSent: String
    public var dateDelivered: String?
    public var dateRead: String?
    public var dateEdited: String?
    public var dateRetracted: String?
    public var error: Int
    public var attachments: [Attachment]

    // The fields that change after a message is first stored. Used to detect updates.
    var fingerprint: String {
        [dateDelivered, dateRead, dateEdited, dateRetracted, text, String(error)].map { $0 ?? "-" }.joined(separator: "|")
    }

    // Explicit nulls on the wire: the server schema uses NullOr, not optional keys.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rowId, forKey: .rowId)
        try c.encode(guid, forKey: .guid)
        try c.encode(chatGuid, forKey: .chatGuid)
        try c.encode(sender, forKey: .sender)
        try c.encode(isFromMe, forKey: .isFromMe)
        try c.encode(service, forKey: .service)
        try c.encode(text, forKey: .text)
        try c.encode(subject, forKey: .subject)
        try c.encode(replyToGuid, forKey: .replyToGuid)
        try c.encode(threadOriginatorGuid, forKey: .threadOriginatorGuid)
        try c.encode(associatedMessageGuid, forKey: .associatedMessageGuid)
        try c.encode(associatedMessageType, forKey: .associatedMessageType)
        try c.encode(expressiveSendStyleId, forKey: .expressiveSendStyleId)
        try c.encode(dateSent, forKey: .dateSent)
        try c.encode(dateDelivered, forKey: .dateDelivered)
        try c.encode(dateRead, forKey: .dateRead)
        try c.encode(dateEdited, forKey: .dateEdited)
        try c.encode(dateRetracted, forKey: .dateRetracted)
        try c.encode(error, forKey: .error)
        try c.encode(attachments, forKey: .attachments)
    }
}

public struct Chat: Codable, Sendable, Equatable {
    public var guid: String
    public var displayName: String?
    public var isGroup: Bool
    public var service: String?
    public var participants: [String]

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guid, forKey: .guid)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(isGroup, forKey: .isGroup)
        try c.encode(service, forKey: .service)
        try c.encode(participants, forKey: .participants)
    }
}

/// A command from the server. All kinds share one flat payload; each handler reads the fields it needs.
public struct Command: Decodable, Sendable {
    public var kind: String
    public var chatGuid: String?
    public var to: [String]?
    public var text: String?
    public var attachmentUrls: [String]?
    public var replyToGuid: String?
    public var effectId: String?
    public var subject: String?
    public var messageGuid: String?
    public var reaction: String?
    public var remove: Bool?
    public var partIndex: Int?
    public var typing: Bool?
    public var name: String?
    public var add: [String]?
    // `remove` is a Bool for reactions, so participant removal arrives under the same key as an array.
    public var removeHandles: [String]?
    public var handle: String?
    public var handles: [String]?
    public var audioOnly: Bool?
    public var callId: String?
    public var limit: Int?
    public var offset: Int?

    enum CodingKeys: String, CodingKey {
        case kind, chatGuid, to, text, attachmentUrls, replyToGuid, effectId, subject, messageGuid, reaction, remove,
             partIndex, typing, name, add, handle, handles, audioOnly, callId, limit, offset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        chatGuid = try c.decodeIfPresent(String.self, forKey: .chatGuid)
        to = try c.decodeIfPresent([String].self, forKey: .to)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        attachmentUrls = try c.decodeIfPresent([String].self, forKey: .attachmentUrls)
        replyToGuid = try c.decodeIfPresent(String.self, forKey: .replyToGuid)
        effectId = try c.decodeIfPresent(String.self, forKey: .effectId)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        messageGuid = try c.decodeIfPresent(String.self, forKey: .messageGuid)
        reaction = try c.decodeIfPresent(String.self, forKey: .reaction)
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .remove) {
            remove = flag
        } else {
            removeHandles = try c.decodeIfPresent([String].self, forKey: .remove)
        }
        partIndex = try c.decodeIfPresent(Int.self, forKey: .partIndex)
        typing = try c.decodeIfPresent(Bool.self, forKey: .typing)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        add = try c.decodeIfPresent([String].self, forKey: .add)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        handles = try c.decodeIfPresent([String].self, forKey: .handles)
        audioOnly = try c.decodeIfPresent(Bool.self, forKey: .audioOnly)
        callId = try c.decodeIfPresent(String.self, forKey: .callId)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        offset = try c.decodeIfPresent(Int.self, forKey: .offset)
    }
}

public enum Event: Encodable, Sendable {
    case messageNew(Message)
    case messageUpdated(Message)
    case chatTyping(chatGuid: String, handle: String, typing: Bool)
    case agentHealth(privateApi: Bool, messagesRunning: Bool, facetimeRunning: Bool)

    enum Keys: String, CodingKey { case kind, message, chatGuid, handle, typing, privateApi, messagesRunning, facetimeRunning }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .messageNew(let m):
            try c.encode("message.new", forKey: .kind)
            try c.encode(m, forKey: .message)
        case .messageUpdated(let m):
            try c.encode("message.updated", forKey: .kind)
            try c.encode(m, forKey: .message)
        case .chatTyping(let chatGuid, let handle, let typing):
            try c.encode("chat.typing", forKey: .kind)
            try c.encode(chatGuid, forKey: .chatGuid)
            try c.encode(handle, forKey: .handle)
            try c.encode(typing, forKey: .typing)
        case .agentHealth(let privateApi, let messagesRunning, let facetimeRunning):
            try c.encode("agent.health", forKey: .kind)
            try c.encode(privateApi, forKey: .privateApi)
            try c.encode(messagesRunning, forKey: .messagesRunning)
            try c.encode(facetimeRunning, forKey: .facetimeRunning)
        }
    }
}

/// Arbitrary JSON, used for command results.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Converts any Encodable into a JSONValue.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

public struct CommandError: Error, Sendable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

// ---- Frames ----

struct HelloFrame: Encodable {
    let type = "hello"
    let `protocol` = protocolVersion
    var agentVersion: String
    var macOS: String
    var capabilities: [String]
    var accounts: [Account]
}

struct EventFrame: Encodable {
    let type = "event"
    var seq: Int
    var event: Event
}

struct ResultFrame: Encodable {
    let type = "result"
    var id: String
    var ok: Bool
    var data: JSONValue?
    var error: ErrorBody?

    struct ErrorBody: Encodable {
        var code: String
        var message: String
    }
}

struct PingFrame: Codable {
    var type: String
    var t: Double
}

/// Frames the server sends. Decoded loosely: unknown types are ignored for forward compatibility.
struct ServerFrame: Decodable {
    var type: String
    var resumeAfterRowId: Int64?
    var id: String?
    var command: Command?
    var seq: Int?
    var t: Double?
}
