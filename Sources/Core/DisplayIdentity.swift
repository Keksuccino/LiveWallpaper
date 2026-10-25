import CoreGraphics
import ColorSync

/// Names a display by its UUID, which stays the same across restarts and reconnecting (its CGDirectDisplayID may
/// not). Everything per display is keyed by it: the settings in state.json, the service's windows and stills.
public enum DisplayIdentity {
    public static func uuid(of display: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String?
        else { return String(display) }
        return string
    }

    /// The UUIDs of the displays in use.
    public static func active() -> [String] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(uuid(of:))
    }
}
