#if os(Windows)
import Foundation
import WinSDK

extension OrcaRuntime {
    /// Diagnostic of the actual last call, never the descriptor's advertised transports.
    private static let transportLock = NSLock()
    private static var lastTransport = "unavailable"
    public static func windowsTransportStatus() -> String {
        transportLock.lock()
        defer { transportLock.unlock() }
        return lastTransport
    }

    static func windowsCall(_ method: String, _ params: [String: Any], timeout: TimeInterval) -> Result<[String: Any], Failure> {
        transportLock.lock()
        lastTransport = "unavailable"
        transportLock.unlock()
        let localAppData: String
        do {
            _ = try WindowsPaths.requiredEnvironment("APPDATA")
            localAppData = try WindowsPaths.requiredEnvironment("LOCALAPPDATA")
        } catch { return .failure(.failed(loc("Could not read Orca's runtime information"))) }
        guard let data = try? Data(contentsOf: metadataURL), let meta = pipeMetadata(from: data) else {
            return .failure(.unavailable(loc("Could not read Orca's runtime information")))
        }
        guard timeout.isFinite, timeout > 0 else { return .failure(.unavailable(loc("Could not connect to the Orca app"))) }
        let deadline = Date().addingTimeInterval(min(timeout, 60))
        let pipe = meta.endpoint.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OVERLAPPED) | 0x00110000 /* SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: no impersonation */, nil)
        }
        guard pipe != INVALID_HANDLE_VALUE, let pipe else { return .failure(.unavailable(loc("Could not connect to the Orca app"))) }
        defer { CloseHandle(pipe) }
        var pid: ULONG = 0
        let serverPID: UInt32? = GetNamedPipeServerProcessId(pipe, &pid) ? pid : nil
        var bound = false
        guard withVerifiedPipeServer(descriptorPID: meta.pid, serverPID: serverPID,
                                     image: serverPID.map { ProcessTable.executablePath(of: Int32(bitPattern: $0)) } ?? "",
                                     localAppData: localAppData, write: { bound = true }), bound else {
            // A rejected binding must not be bypassed through the CLI fallback.
            return .failure(.failed(loc("Could not connect to the Orca app")))
        }
        // Nothing carrying the credential is even constructed until the server binding has passed.
        let id = UUID().uuidString.lowercased()
        let request: [String: Any] = ["id": id, credentialField: meta.credential, "method": method, "params": params]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return .failure(.unavailable(loc("Could not build the request"))) }
        payload.append(0x0A)
        var sent = 0
        while sent < payload.count {
            let count: Int? = payload.withUnsafeMutableBytes { bytes in
                pipeIO(pipe, buffer: bytes.baseAddress! + sent, count: bytes.count - sent, writing: true, deadline: deadline)
            }
            // An overlapped write may have delivered bytes even when its completion times out.
            guard let count, count > 0 else { return .failure(.failed(loc("The connection dropped while writing the request to the Orca app"))) }
            sent += count
        }
        var pending = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let count = chunk.withUnsafeMutableBytes { pipeIO(pipe, buffer: $0.baseAddress!, count: $0.count, writing: false, deadline: deadline) }
            guard let count, count > 0 else { return .failure(.failed(loc("The Orca app did not respond"))) }
            pending.append(contentsOf: chunk.prefix(count))
            guard pending.count <= 16 * 1024 * 1024 else { return .failure(.failed(loc("Could not parse the Orca app's response"))) }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                switch frame(line, expectingID: id, runtimeID: meta.runtimeID) {
                case .skip: continue
                case .done(let result):
                    if case .success = result {
                        transportLock.lock(); lastTransport = "named-pipe"; transportLock.unlock()
                    }
                    return result
                }
            }
        }
        return .failure(.failed(loc("The Orca app did not respond")))
    }

    /// One overlapped operation. Cancel and drain before its buffer/event leave scope.
    private static func pipeIO(_ pipe: HANDLE, buffer: UnsafeMutableRawPointer, count: Int, writing: Bool, deadline: Date) -> Int? {
        guard Date() < deadline, let event = CreateEventW(nil, true, false, nil) else { return nil }
        defer { CloseHandle(event) }
        var operation = OVERLAPPED()
        operation.hEvent = event
        var transferred: DWORD = 0
        let started = writing ? WriteFile(pipe, buffer, DWORD(count), nil, &operation) : ReadFile(pipe, buffer, DWORD(count), nil, &operation)
        if !started {
            guard GetLastError() == ERROR_IO_PENDING else { return nil }
            let milliseconds = DWORD(max(1, min(60000, deadline.timeIntervalSinceNow * 1000)))
            if WaitForSingleObject(event, milliseconds) != WAIT_OBJECT_0 {
                CancelIoEx(pipe, &operation)
                // Cancellation completion owns the stack buffer until the OS releases it.
                _ = GetOverlappedResult(pipe, &operation, &transferred, true)
                return nil
            }
        }
        guard GetOverlappedResult(pipe, &operation, &transferred, false) else { return nil }
        return Int(transferred)
    }
}
#endif
