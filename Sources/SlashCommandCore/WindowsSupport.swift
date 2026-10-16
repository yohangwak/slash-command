import Foundation

/// Pure Windows path and trust decisions also tested on the other platforms.
enum WindowsPaths {
    static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    #if os(Windows)
    static func requiredEnvironment(_ name: String, in values: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard let value = values.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value,
              !value.isEmpty else { throw SlashCommandError(loc("Could not read Orca's runtime information")) }
        return value
    }
    #endif

    static func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

extension OrcaRuntime {
    struct PipeMetadata {
        let endpoint: String
        let credential: String
        let runtimeID: String?
        let pid: UInt32
    }

    static func pipeMetadata(from data: Data) -> PipeMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credential = json[credentialField] as? String, !credential.isEmpty,
              let number = json["pid"] as? NSNumber, String(cString: number.objCType) != String(cString: NSNumber(value: true).objCType),
              number.doubleValue > 0, number.doubleValue <= Double(UInt32.max),
              number.doubleValue.rounded() == number.doubleValue,
              let transports = json["transports"] as? [[String: Any]],
              let endpoint = transports.first(where: { $0["kind"] as? String == "named-pipe" })?["endpoint"] as? String,
              WindowsPaths.normalized(endpoint).hasPrefix("//./pipe/"), endpoint.count > 9 else { return nil }
        return PipeMetadata(endpoint: endpoint, credential: credential, runtimeID: json["runtimeId"] as? String, pid: number.uint32Value)
    }

    /// The closure is never entered on an unbound pipe, including when the server PID cannot be read.
    static func withVerifiedPipeServer(descriptorPID: UInt32, serverPID: UInt32?, image: String,
                                       localAppData: String, write: () -> Void) -> Bool {
        guard descriptorPID > 0, serverPID == descriptorPID, !localAppData.isEmpty,
              WindowsPaths.normalized(image) == WindowsPaths.normalized(localAppData + "/Programs/orca/Orca.exe") else { return false }
        write()
        return true
    }
}
