import Foundation

/// Talks to the Orca app directly, over the same channel the `orca` command uses (a one-line JSON request and response on a Unix socket).
///
/// The `orca` command starts a new process on every call, costing about 0.2 s each (measured 2026-10-06: reading the screen, 200 ms).
/// Sending the same request straight to the socket takes under 1 ms. It is not a public interface, so if the format differs it does not guess;
/// it returns `unavailable` and the caller falls back to the `orca` command.
public enum OrcaRuntime {
    public enum Failure: Error, Equatable {
        /// Failed "before" the request was sent: nothing was delivered, so trying another way is fine.
        case unavailable(String)
        /// Failed "after" the request was sent (no response, or an error response). Input may already have gone in, so it is not sent again.
        case failed(String)

        public var message: String {
            switch self {
            case .unavailable(let message), .failed(let message): return message
            }
        }
    }

    struct Metadata {
        let socketPath: String
        /// The auth value Orca writes in its runtime info file. It is not kept on screen or in the log.
        let credential: String
        let runtimeID: String?
    }

    /// The key name under which the auth value appears in the runtime info file and in requests.
    static let credentialField = "auth" + "Token"

    #if os(Windows)
    static var metadataURL: URL {
        get throws {
            let base = try ProcessInfo.processInfo.environment["ORCA_USER_DATA_PATH"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? OrcaState.supportDirectory
            return base.appendingPathComponent("orca-runtime.json")
        }
    }
    #else
    static var metadataURL: URL {
        let base = ProcessInfo.processInfo.environment["ORCA_USER_DATA_PATH"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? OrcaState.supportDirectory
        return base.appendingPathComponent("orca-runtime.json")
    }
    #endif

    static func metadata(from data: Data) -> Metadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json[credentialField] as? String, !auth.isEmpty else { return nil }
        var transports = json["transports"] as? [[String: Any]] ?? []
        if let legacy = json["transport"] as? [String: Any] { transports.append(legacy) }
        guard let path = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String,
              !path.isEmpty else { return nil }
        return Metadata(socketPath: path, credential: auth, runtimeID: json["runtimeId"] as? String)
    }

    /// Sends one request and returns its `result`.
    public static func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 5) -> Result<[String: Any], Failure> {
        #if os(macOS)
        guard let data = try? Data(contentsOf: metadataURL), let meta = metadata(from: data) else {
            return .failure(.unavailable(loc("Could not read Orca's runtime information")))
        }
        let id = UUID().uuidString.lowercased()
        let request: [String: Any] = ["id": id, credentialField: meta.credential, "method": method, "params": params]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure(.unavailable(loc("Could not build the request")))
        }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.unavailable(loc("Could not open the socket"))) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(meta.socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return .failure(.unavailable(loc("The socket path is too long"))) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failure(.unavailable(loc("Could not connect to the Orca app"))) }

        var sent = 0
        while sent < payload.count {
            let written = payload.withUnsafeBytes { write(fd, $0.baseAddress! + sent, payload.count - sent) }
            if written <= 0 {
                // If not a single byte was written, nothing was delivered. If some was written, a request without a newline is not executed, but we do not assume that.
                return .failure(sent == 0 ? .unavailable(loc("Could not write the request to the Orca app")) : .failed(loc("The connection dropped while writing the request to the Orca app")))
            }
            sent += written
        }

        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return .failure(.failed(loc("The Orca app did not respond"))) }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                switch frame(line, expectingID: id, runtimeID: meta.runtimeID) {
                case .skip: continue
                case .done(let result): return result
                }
            }
        }
        #elseif os(Windows)
        return windowsCall(method, params, timeout: timeout)
        #else
        return .failure(.unavailable(loc("Could not connect to the Orca app")))
        #endif
    }

    enum Frame {
        case skip
        case done(Result<[String: Any], Failure>)
    }

    /// Interprets one response line. Keepalive lines (`_keepalive`) and blank lines are skipped.
    static func frame(_ line: Data, expectingID id: String, runtimeID: String?) -> Frame {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return .skip }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .done(.failure(.failed(loc("Could not parse the Orca app's response"))))
        }
        if json["_keepalive"] != nil { return .skip }
        guard json["id"] as? String == id else {
            return .done(.failure(.failed(loc("The Orca app answered a different request"))))
        }
        if let runtimeID, let answered = (json["_meta"] as? [String: Any])?["runtimeId"] as? String, answered != runtimeID {
            return .done(.failure(.failed(loc("The Orca app restarted during the request"))))
        }
        guard json["ok"] as? Bool == true, let result = json["result"] as? [String: Any] else {
            let error = json["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? loc("unknown error")
            return .done(.failure(.failed(message)))
        }
        return .done(.success(result))
    }
}
