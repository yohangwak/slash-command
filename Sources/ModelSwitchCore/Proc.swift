import Foundation

public struct ProcResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
}

public enum Proc {
    /// 자식 프로세스를 실행하고 끝날 때까지 기다린다. 시간 초과면 종료시키고 `timedOut` 을 세운다.
    public static func run(_ exe: String,
                           _ args: [String],
                           env: [String: String]? = nil,
                           cwd: String? = nil,
                           timeout: TimeInterval = 10) -> ProcResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let env { process.environment = env }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "modelswitch.proc", attributes: .concurrent)

        do {
            try process.run()
        } catch {
            return ProcResult(status: -1, out: "", err: "\(exe): \(error.localizedDescription)", timedOut: false)
        }

        // 파이프 버퍼가 차서 자식이 멈추지 않도록 두 스트림을 동시에 비운다.
        group.enter()
        queue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        let done = DispatchSemaphore(value: 0)
        queue.async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        group.wait()

        return ProcResult(status: process.terminationStatus,
                          out: String(decoding: outData, as: UTF8.self),
                          err: String(decoding: errData, as: UTF8.self),
                          timedOut: timedOut)
    }

    /// GUI 앱은 로그인 셸의 PATH 를 물려받지 않으므로 흔한 설치 위치를 직접 찾는다.
    public static func locate(_ name: String, extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin", "/usr/bin", "/bin"] + extra
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
