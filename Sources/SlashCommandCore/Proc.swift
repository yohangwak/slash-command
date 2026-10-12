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
        let queue = DispatchQueue(label: "slashcommand.proc", attributes: .concurrent)

        // 끝난 것은 `terminationHandler` 로 안다. `waitUntilExit()` 는 그 스레드의 런루프를 돌며 기다리는데, 오래 떠 있는 앱의
        // 작업 스레드에서는 자식이 끝난 뒤에도 깨어나지 않을 때가 있다(2026-10-12 집 맥 2: `wezterm cli` 가 일을 마쳤는데
        // 5초 제한까지 기다리다 «읽지 못했다» 로 끝났고, 표본을 뜨니 자식 없이 `waitUntilExit` 에 멈춘 스레드가 남아 있었다).
        // 런루프를 돌지 않으므로 호출 하나도 약 65ms 에서 자식이 실제로 쓴 시간으로 줄어든다.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

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
        if !waitForExit(process, done, seconds: timeout) {
            timedOut = true
            process.terminate()
            // SIGTERM 을 무시하면 강제로 끝낸다 — 파이프가 닫혀야 아래의 읽기가 끝난다.
            if !waitForExit(process, done, seconds: 2) {
                kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(process, done, seconds: 1)
            }
        }
        group.wait()

        // 아직 살아 있는 프로세스의 `terminationStatus` 를 읽으면 예외가 난다.
        return ProcResult(status: process.isRunning ? -1 : process.terminationStatus,
                          out: String(decoding: outData, as: UTF8.self),
                          err: String(decoding: errData, as: UTF8.self),
                          timedOut: timedOut)
    }

    /// 끝났다는 신호를 `seconds` 까지 기다린다. 신호를 놓쳐도 멈추지 않게 짧게 끊어 `isRunning` 도 같이 본다.
    private static func waitForExit(_ process: Process, _ done: DispatchSemaphore, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let slice = min(0.05, max(0, deadline.timeIntervalSinceNow))
            if done.wait(timeout: .now() + slice) == .success { return true }
            if !process.isRunning { return true }
            if Date() >= deadline { return false }
        }
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
