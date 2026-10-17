#if os(Windows)
import Foundation
import CWindowsConsoleFixture
guard CommandLine.arguments.count == 3, let records = Int32(CommandLine.arguments[2]) else { exit(2) }
exit(CommandLine.arguments[1].withCString(encodedAs: UTF16.self) { sc_test_console_reader($0, records) })
#endif
