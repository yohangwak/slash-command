#if os(macOS)
import CoreGraphics

/// Whether someone can be looking at the screen: the main display is awake and the session is not locked.
public enum ScreenState {
    public static func awake() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        return CGDisplayIsAsleep(CGMainDisplayID()) == 0 && !locked
    }
}
#endif
