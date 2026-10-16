import Foundation

/// The quoted key/value form of Apple's .strings format used by our UTF-8 translation files.
/// Kept available on macOS for comparison tests; production macOS still uses NSDictionary.
enum StringsTable {
    static func parse(_ text: String) -> [String: String]? {
        var parser = Parser(input: Array(text.utf16))
        return parser.table()
    }

    private struct Parser {
        let input: [UInt16]
        var index = 0

        mutating func take(_ value: UInt16) -> Bool {
            guard index < input.count, input[index] == value else { return false }
            index += 1
            return true
        }

        mutating func skip() -> Bool {
            while index < input.count {
                if [9, 10, 13, 32, 0xFEFF].contains(input[index]) { index += 1; continue }
                guard index + 1 < input.count, input[index] == 47 else { break }
                if input[index + 1] == 47 {
                    index += 2
                    while index < input.count, input[index] != 10 { index += 1 }
                } else if input[index + 1] == 42 {
                    index += 2
                    while index + 1 < input.count, !(input[index] == 42 && input[index + 1] == 47) { index += 1 }
                    guard index + 1 < input.count else { return false }
                    index += 2
                } else { break }
            }
            return true
        }

        mutating func quoted() -> String? {
            guard take(34) else { return nil }
            var units: [UInt16] = []
            while index < input.count {
                let unit = input[index]
                index += 1
                if unit == 34 { return String(decoding: units, as: UTF16.self) }
                if unit != 92 { units.append(unit); continue }
                guard index < input.count else { return nil }
                let escaped = input[index]
                index += 1
                switch escaped {
                case 34, 92: units.append(escaped)
                case 110: units.append(10)
                case 114: units.append(13)
                case 116: units.append(9)
                case 98: units.append(8)
                case 102: units.append(12)
                case 85, 117:
                    guard index + 4 <= input.count,
                          let value = UInt16(String(decoding: input[index..<index + 4], as: UTF16.self), radix: 16) else { return nil }
                    units.append(value)
                    index += 4
                default: return nil
                }
            }
            return nil
        }

        mutating func table() -> [String: String]? {
            var result: [String: String] = [:]
            guard skip() else { return nil }
            while index < input.count {
                guard let key = quoted(), skip(), take(61), skip(),
                      let value = quoted(), skip(), take(59), skip() else { return nil }
                result[key] = value
            }
            return result
        }
    }
}
