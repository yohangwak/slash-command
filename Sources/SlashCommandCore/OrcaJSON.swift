import Foundation

/// Parses JSON that Orca writes, whether it came from the socket or from the `orca` command.
///
/// Orca cuts each terminal's `preview` to its last 300 UTF-16 code units (`slice(-300)`), so a cut that lands inside an emoji
/// leaves half of a surrogate pair, which Orca's `JSON.stringify` writes as an escape such as `"\udd34"`. Foundation's
/// `JSONSerialization` rejects a lone surrogate, so one idle terminal whose last output ended that way made the whole terminal
/// list unreadable until it printed again (2026-11-24). A lone surrogate escape is replaced with U+FFFD before parsing;
/// everything else is parsed exactly as before.
enum OrcaJSON {
    static func object(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        guard let repaired = replacingLoneSurrogateEscapes(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: repaired) as? [String: Any]
    }

    static func object(_ text: String) -> [String: Any]? {
        object(Data(text.utf8))
    }

    /// The same bytes with each `\uD800`–`\uDFFF` escape that is not part of a high-low pair written as `�`.
    /// nil when there was nothing to replace.
    static func replacingLoneSurrogateEscapes(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                output.append(bytes[index])
                index += 1
                continue
            }
            // A backslash in JSON only appears inside a string, and always starts a two-byte escape or a `\uXXXX`.
            guard bytes[index + 1] == UInt8(ascii: "u"), let unit = codeUnit(bytes, at: index) else {
                output.append(contentsOf: bytes[index...index + 1])
                index += 2
                continue
            }
            if (0xD800...0xDBFF).contains(unit), let low = codeUnit(bytes, at: index + 6), (0xDC00...0xDFFF).contains(low) {
                output.append(contentsOf: bytes[index..<index + 12])
                index += 12
            } else if (0xD800...0xDFFF).contains(unit) {
                output.append(contentsOf: Array("\\ufffd".utf8))
                changed = true
                index += 6
            } else {
                output.append(contentsOf: bytes[index..<index + 6])
                index += 6
            }
        }
        return changed ? Data(output) : nil
    }

    /// The code unit of the `\uXXXX` escape starting at `index`, or nil when there is none there.
    private static func codeUnit(_ bytes: [UInt8], at index: Int) -> UInt16? {
        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
        var value: UInt16 = 0
        for byte in bytes[index + 2..<index + 6] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt16(digit)
        }
        return value
    }
}
