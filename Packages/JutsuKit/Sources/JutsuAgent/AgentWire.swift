import Darwin
import Foundation

/// Newline-delimited JSON: compact JSON never contains a raw newline, so a line is always one whole message.
public enum AgentWire {
    public static func line(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(message) + Data([newline])
    }

    /// Reads what `line` wrote.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The request on `line`, or the error to answer it with, and the request's `id` whenever it could be read.
    public static func request(from line: Data) -> (id: String?, request: Result<AgentRequest, AgentError>) {
        struct Envelope: Decodable {
            var version: Int?
            var id: String?
        }
        let decoder = Self.decoder
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            return (nil, .failure(.badRequest("not a JSON object with a string id")))
        }
        let id = envelope.id
        // Checked before the command, so a newer client gets the version error rather than an unknown command.
        guard let version = envelope.version else { return (id, .failure(.badRequest("no version"))) }
        guard version == AgentProtocol.version else { return (id, .failure(.unsupportedVersion(version))) }
        do {
            return (id, .success(try decoder.decode(AgentRequest.self, from: line)))
        } catch let error as AgentError {
            return (id, .failure(error))
        } catch DecodingError.keyNotFound(let key, _) {
            return (id, .failure(.badRequest("no \(key.stringValue)")))
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
            DecodingError.dataCorrupted(let context)
        {
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return (id, .failure(.badRequest(field.isEmpty ? "the fields don't match the command" : "bad \(field)")))
        } catch {
            return (id, .failure(.badRequest("the fields don't match the command")))
        }
    }

    static let newline = UInt8(ascii: "\n")
}

/// Splits a byte stream into lines as it arrives, and hands out the raw bytes of an upload that follow its line.
public struct AgentLineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func push(_ data: Data) {
        pending.append(data)
    }

    /// The next complete line without its newline; nil until one has arrived.
    public mutating func nextLine() -> Data? {
        guard let end = pending.firstIndex(of: AgentWire.newline) else { return nil }
        let line = Data(pending[pending.startIndex..<end])
        // A fresh copy, so indices start at zero again.
        pending = Data(pending[(end + 1)...])
        return line
    }

    /// Up to `count` of the bytes after the last line taken: an upload's payload.
    public mutating func take(upTo count: Int) -> Data {
        let taken = Data(pending.prefix(count))
        pending = Data(pending.dropFirst(taken.count))
        return taken
    }

    /// With no line left to take, whether the one arriving is already too long to be a request.
    public var isOverlong: Bool { pending.count > AgentProtocol.maxLineLength }
}

/// Where the app listens.
public enum AgentSocket {
    public static let fileName = "agent.sock"
    /// The Info.plist key with the app group (`<TEAM_ID>.com.jutsustudio.jutsustudio`, set in project.yml) whose
    /// container holds the socket: both the sandboxed app and an unsandboxed process can open it.
    public static let appGroupKey = "JutsuAppGroup"
    /// Another socket for the helper (and a Debug build of the app) to use, for development.
    public static let variable = "JUTSU_AGENT_SOCKET"

    /// Whether `group` can have a container: outside the App Store, macOS creates one only for a group that starts
    /// with the team ID the app is signed with, and an ad-hoc build has no team, so its group starts with a dot.
    public static func hasTeam(_ group: String) -> Bool {
        !group.isEmpty && !group.hasPrefix(".") && !group.hasPrefix("$")
    }

    /// `~/Library/Group Containers/<group>/agent.sock`, the path the app's container manager gives it. Spelled out
    /// for the helper, which doesn't share the group: it opens only this one known path.
    public static func groupSocket(_ group: String, home: URL) -> URL {
        home.appending(path: "Library/Group Containers/\(group)/\(fileName)")
    }

    /// The longest socket path, in bytes. A `sockaddr_un` has room for 103 and a NUL, which the group container's
    /// socket outgrows once the home folder's path passes about 30 bytes. Darwin takes a longer address when its
    /// `sun_len` says so, up to 255 bytes in all (`SOCK_MAXADDRLEN`), so both ends size the address to the path: 252
    /// bytes after the length and family bytes, then the NUL. No chdir and no relative path, which would change the
    /// whole process's working directory while other threads read files.
    public static let maxPathLength = 252

    public static func fits(_ path: URL) -> Bool { path.path(percentEncoded: false).utf8.count <= maxPathLength }

    /// Calls `body` with the address of `path` for `bind` or `connect`; nil, without calling it, when the path is
    /// longer than `maxPathLength`.
    public static func withAddress<T>(_ path: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        guard fits(path) else { return nil }
        let bytes = Array(path.path(percentEncoded: false).utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        // Never shorter than a plain sockaddr_un, so a short path goes exactly as it always did.
        let length = max(MemoryLayout<sockaddr_un>.size, offset + bytes.count + 1)
        let address = UnsafeMutableRawPointer.allocate(
            byteCount: length, alignment: MemoryLayout<sockaddr_un>.alignment)
        defer { address.deallocate() }
        address.initializeMemory(as: UInt8.self, repeating: 0, count: length)
        address.storeBytes(of: UInt8(length), as: UInt8.self)
        address.storeBytes(of: UInt8(AF_UNIX), toByteOffset: 1, as: UInt8.self)
        (address + offset).copyMemory(from: bytes, byteCount: bytes.count)
        return body(address.assumingMemoryBound(to: sockaddr.self), socklen_t(length))
    }
}
