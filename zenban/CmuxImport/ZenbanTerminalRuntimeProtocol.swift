import Foundation

enum ZenbanTerminalRuntimeAction: String, Codable {
    case createOrAttach
    case detach
    case write
    case resize
    case kill
    case snapshot
    case shutdown
}

enum ZenbanTerminalRuntimeSessionKind: String, Codable {
    case shell
    case agent
}

struct ZenbanTerminalRuntimeRequest: Codable {
    let requestID: String
    let action: ZenbanTerminalRuntimeAction
    let sessionID: String?
    let cwd: String?
    let cols: UInt16?
    let rows: UInt16?
    let env: [String: String]?
    let shell: String?
    let sessionKind: ZenbanTerminalRuntimeSessionKind?
    let launchCommand: String?
    let attach: Bool?
    let data: Data?
    let killSessions: Bool?

    init(
        requestID: String = UUID().uuidString,
        action: ZenbanTerminalRuntimeAction,
        sessionID: String? = nil,
        cwd: String? = nil,
        cols: UInt16? = nil,
        rows: UInt16? = nil,
        env: [String: String]? = nil,
        shell: String? = nil,
        sessionKind: ZenbanTerminalRuntimeSessionKind? = nil,
        launchCommand: String? = nil,
        attach: Bool? = nil,
        data: Data? = nil,
        killSessions: Bool? = nil
    ) {
        self.requestID = requestID
        self.action = action
        self.sessionID = sessionID
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.env = env
        self.shell = shell
        self.sessionKind = sessionKind
        self.launchCommand = launchCommand
        self.attach = attach
        self.data = data
        self.killSessions = killSessions
    }
}

struct ZenbanTerminalRuntimeResponse: Codable {
    let requestID: String
    let success: Bool
    let error: String?
    let snapshot: Data?
    let isNewSession: Bool?
    let pid: Int32?
}

enum ZenbanTerminalRuntimeEventKind: String, Codable {
    case data
    case exit
    case error
}

struct ZenbanTerminalRuntimeEvent: Codable {
    let event: ZenbanTerminalRuntimeEventKind
    let sessionID: String
    let data: Data?
    let exitCode: Int32?
    let error: String?
}

enum ZenbanTerminalRuntimeMessage: Codable {
    case response(ZenbanTerminalRuntimeResponse)
    case event(ZenbanTerminalRuntimeEvent)

    private enum CodingKeys: String, CodingKey {
        case type
        case response
        case event
    }

    private enum MessageType: String, Codable {
        case response
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .response:
            self = .response(try container.decode(ZenbanTerminalRuntimeResponse.self, forKey: .response))
        case .event:
            self = .event(try container.decode(ZenbanTerminalRuntimeEvent.self, forKey: .event))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .response(let response):
            try container.encode(MessageType.response, forKey: .type)
            try container.encode(response, forKey: .response)
        case .event(let event):
            try container.encode(MessageType.event, forKey: .type)
            try container.encode(event, forKey: .event)
        }
    }
}

enum ZenbanTerminalRuntimeProtocol {
    static let lineSeparator = Data([0x0A])

    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(value)
        data.append(lineSeparator)
        return data
    }

    static func decodeRequest(from line: Data) throws -> ZenbanTerminalRuntimeRequest {
        try JSONDecoder().decode(ZenbanTerminalRuntimeRequest.self, from: line)
    }

    static func decodeMessage(from line: Data) throws -> ZenbanTerminalRuntimeMessage {
        try JSONDecoder().decode(ZenbanTerminalRuntimeMessage.self, from: line)
    }
}

enum ZenbanTerminalRuntimeShell {
    static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
