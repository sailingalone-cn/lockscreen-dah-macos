import Foundation
import IOKit

/// Seconds since the last keyboard/mouse event, straight from the HID system.
///
/// This is the same signal the system's own idle timer uses, and it is the
/// cheapest proof of presence available: if someone touched the keyboard a
/// second ago, they are at the machine whether or not the camera can see them.
/// Kept tiny and dependency-free so the gate that consumes it stays testable.
enum InputIdle {
    static func seconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as NSDictionary?,
            let idle = dictionary["HIDIdleTime"] as? NSNumber
        else { return 0 }

        return idle.doubleValue / 1_000_000_000
    }
}
