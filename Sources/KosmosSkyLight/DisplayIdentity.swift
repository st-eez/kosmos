import CKosmos
import CoreGraphics
import Foundation
import IOKit

/// What tells connected displays apart: the EDID serial that monitor matchers use, and the
/// UUIDs that SketchyBar numbers displays by. `kosmos-probe displays` prints all of it.
public enum DisplayIdentity {
    /// The active displays, main display first (CGGetActiveDisplayList).
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

    /// Display UUIDs in the order SketchyBar numbers them (SLSCopyManagedDisplays).
    public static func managed() -> [String] {
        SLSCopyManagedDisplays(SkyLight.connection)?.takeRetainedValue() as? [String] ?? []
    }

    /// The EDID alphanumeric serial number, such as `T9LMTF156633`, or nil when the display's
    /// EDID has none, as built-in displays do.
    ///
    /// The display controller publishes the serial on the framebuffer that drives the display,
    /// and CoreDisplay names that framebuffer by its registry path, such as
    /// `IOService:/AppleARMPE/arm-io@10F00000/AppleH15IO/disp0@7C000000/IOMobileFramebufferShim`.
    /// Each display has its own framebuffer, so two identical monitors should read the serials
    /// of their own panels. Matching by EDID fields cannot tell them apart: Steve's twin
    /// VG279QE5A panels share one EDID UUID, and CGDisplaySerialNumber, the EDID's numeric
    /// serial, is zero on both. Verified so far on the built-in display only, whose framebuffer
    /// has no serial; the twins wait on a run of `kosmos-probe displays` at Steve's desk
    /// (DESIGN.md, section 5.8). When CoreDisplay stops naming the framebuffer, this returns
    /// nil and serial matchers match nothing.
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
