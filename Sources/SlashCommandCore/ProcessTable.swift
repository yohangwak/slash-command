import Darwin
import Foundation

/// 실행 중인 프로세스의 명령줄과 환경변수를 프로세스 안에서 읽는다(`ps -axEww` 와 같은 정보).
///
/// `ps` 를 띄우면 약 0.2초가 든다(2026-10-06 실측). 터미널에 붙은 프로세스만 직접 읽으면 수 ms 다.
/// 환경변수에는 비밀이 섞여 있을 수 있으므로 여기서 읽은 것은 어디에도 남기지 않는다.
enum ProcessTable {
    struct Entry {
        let pid: Int32
        let parent: Int32
        let hasTerminal: Bool
        let arguments: [String]
        let environment: [String]
        /// 실제로 실행 중인 파일의 경로(링크를 푼 것). 명령줄의 첫 낱말은 `claude` 처럼 이름만일 수 있다.
        let executable: String
    }

    /// 터미널에 붙어 있고 읽을 수 있는 프로세스들과, 모든 프로세스의 부모 관계.
    static func snapshot() -> (entries: [Entry], parents: [Int32: Int32]) {
        var entries: [Entry] = []
        var parents: [Int32: Int32] = [:]
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parents[pid] = Int32(info.pbi_ppid)
            // e_tdev 가 NODEV(-1) 면 터미널 없는 프로세스다 — 에이전트 세션이 아니므로 명령줄을 읽지 않는다.
            guard info.e_tdev != UInt32.max, let (arguments, environment) = commandLine(of: pid) else { continue }
            entries.append(Entry(pid: pid, parent: Int32(info.pbi_ppid), hasTerminal: true,
                                 arguments: arguments, environment: environment,
                                 executable: executablePath(of: pid)))
        }
        return (entries, parents)
    }

    static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    static func allPIDs() -> [Int32] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    static func commandLine(of pid: Int32) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parse(procargs: Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` 의 배치: 인자 개수(Int32) · 실행 파일 경로 · 0 채움 · 인자들 · 환경변수들(각각 0 으로 끝남).
    static func parse(procargs buffer: [UInt8]) -> (arguments: [String], environment: [String])? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var index = header
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // 실행 파일 경로
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // 채움
        var strings: [String] = []
        while index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            if end == index, strings.count >= Int(argc) { break }       // 환경변수 뒤의 빈 문자열 = 끝
            strings.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        guard strings.count >= Int(argc) else { return nil }
        return (Array(strings.prefix(Int(argc))), Array(strings.dropFirst(Int(argc))))
    }
}
