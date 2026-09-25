import CKosmos
import CoreGraphics
import Foundation
import IOKit

/// `kosmos-probe displays` prints what these read for each display.
public enum DisplayIdentity {
    /// Main display first.
    public static func active() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Display UUIDs in the order SketchyBar numbers them.
    public static func managed() -> [String] {
        SLSCopyManagedDisplays(SkyLight.connection)?.takeRetainedValue() as? [String] ?? []
    }

    /// The EDID alphanumeric serial, from the framebuffer CoreDisplay names for the display, so
    /// twin monitors read their own (docs/config.md). Nil when the EDID has none.
    public static func serial(of display: CGDirectDisplayID) -> String? {
        let info = CoreDisplay_DisplayCreateInfoDictionary(display)?.takeRetainedValue() as? [String: Any]
        guard let path = info?["IODisplayLocation"] as? String else { return nil }
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        let product = attributes?["ProductAttributes"] as? [String: Any]
        // The EDID pads a serial shorter than 13 characters with a newline and spaces.
        let serial = (product?["AlphanumericSerialNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return serial?.isEmpty == false ? serial : nil
    }
}
