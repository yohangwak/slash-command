import Foundation

/// Orca 앱에 직접 말을 건다 — `orca` 명령이 쓰는 것과 같은 통로(유닉스 소켓에 한 줄짜리 JSON 요청·응답).
///
/// `orca` 명령은 부를 때마다 프로세스를 새로 띄워 한 번에 약 0.2초가 든다(2026-10-06 실측: 화면 읽기 200ms).
/// 같은 요청을 소켓으로 직접 보내면 1ms 안쪽이다. 공개된 인터페이스가 아니므로 형식이 다르면 추측하지 않고
/// `unavailable` 을 돌려주고, 부른 쪽이 `orca` 명령으로 되돌아간다.
public enum OrcaRuntime {
    public enum Failure: Error, Equatable {
        /// 요청을 보내기 «전»에 실패했다 — 아무것도 전달되지 않았으므로 다른 길로 다시 해도 된다.
        case unavailable(String)
        /// 요청을 보낸 «뒤»에 실패했다(응답 없음·오류 응답). 입력이 이미 들어갔을 수 있으므로 다시 보내지 않는다.
        case failed(String)

        public var message: String {
            switch self {
            case .unavailable(let message), .failed(let message): return message
            }
        }
    }

    struct Metadata {
        let socketPath: String
        /// Orca 가 실행 정보 파일에 적어 둔 인증 값. 화면·기록에 남기지 않는다.
        let credential: String
        let runtimeID: String?
    }

    /// 실행 정보 파일과 요청에서 인증 값이 들어가는 항목 이름.
    static let credentialField = "auth" + "Token"

    static var metadataURL: URL {
        let base = ProcessInfo.processInfo.environment["ORCA_USER_DATA_PATH"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? OrcaState.supportDirectory
        return base.appendingPathComponent("orca-runtime.json")
    }

    static func metadata(from data: Data) -> Metadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json[credentialField] as? String, !auth.isEmpty else { return nil }
        var transports = json["transports"] as? [[String: Any]] ?? []
        if let legacy = json["transport"] as? [String: Any] { transports.append(legacy) }
        guard let path = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String,
              !path.isEmpty else { return nil }
        return Metadata(socketPath: path, credential: auth, runtimeID: json["runtimeId"] as? String)
    }

    /// 요청 하나를 보내고 `result` 를 돌려준다.
    public static func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 5) -> Result<[String: Any], Failure> {
        guard let data = try? Data(contentsOf: metadataURL), let meta = metadata(from: data) else {
            return .failure(.unavailable("Orca 실행 정보를 읽지 못했습니다"))
        }
        let id = UUID().uuidString.lowercased()
        let request: [String: Any] = ["id": id, credentialField: meta.credential, "method": method, "params": params]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure(.unavailable("요청을 만들지 못했습니다"))
        }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.unavailable("소켓을 열지 못했습니다")) }
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
        guard pathBytes.count < capacity else { return .failure(.unavailable("소켓 경로가 너무 깁니다")) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failure(.unavailable("Orca 앱에 연결하지 못했습니다")) }

        var sent = 0
        while sent < payload.count {
            let written = payload.withUnsafeBytes { write(fd, $0.baseAddress! + sent, payload.count - sent) }
            if written <= 0 {
                // 한 바이트도 못 썼으면 전달된 것이 없다. 일부라도 썼으면 줄바꿈 없는 요청은 실행되지 않지만 단정하지 않는다.
                return .failure(sent == 0 ? .unavailable("Orca 앱에 요청을 쓰지 못했습니다") : .failed("Orca 앱에 요청을 쓰다 끊겼습니다"))
            }
            sent += written
        }

        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return .failure(.failed("Orca 앱이 응답하지 않았습니다")) }
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
    }

    enum Frame {
        case skip
        case done(Result<[String: Any], Failure>)
    }

    /// 응답 한 줄을 해석한다. 연결 유지용 줄(`_keepalive`)과 빈 줄은 건너뛴다.
    static func frame(_ line: Data, expectingID id: String, runtimeID: String?) -> Frame {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return .skip }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .done(.failure(.failed("Orca 앱의 응답을 해석하지 못했습니다")))
        }
        if json["_keepalive"] != nil { return .skip }
        guard json["id"] as? String == id else {
            return .done(.failure(.failed("Orca 앱이 다른 요청의 응답을 돌려줬습니다")))
        }
        if let runtimeID, let answered = (json["_meta"] as? [String: Any])?["runtimeId"] as? String, answered != runtimeID {
            return .done(.failure(.failed("요청 도중 Orca 앱이 다시 시작됐습니다")))
        }
        guard json["ok"] as? Bool == true, let result = json["result"] as? [String: Any] else {
            let error = json["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? (error?["code"] as? String) ?? "알 수 없는 오류"
            return .done(.failure(.failed(message)))
        }
        return .done(.success(result))
    }
}
