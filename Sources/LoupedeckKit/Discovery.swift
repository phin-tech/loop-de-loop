import Foundation
import IOKit
import IOKit.serial

/// A serial device that looks like a Loupedeck.
public struct DiscoveredDevice: Hashable, Sendable {
    public let path: String
    public let vendorID: Int
    public let productID: Int
    public let serialNumber: String?
    public var model: LoupedeckModel? { LoupedeckModel.forUSB(vendorID: vendorID, productID: productID) }
}

public enum Discovery {
    static let vendorIDs: Set<Int> = [0x2ec2 /* Loupedeck */, 0x1532 /* Razer */]

    /// Find connected Loupedeck serial devices by walking the IORegistry.
    public static func devices() -> [DiscoveredDevice] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var results: [DiscoveredDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey) as? String,
                  let vid = searchParents(service, "idVendor") as? Int,
                  let pid = searchParents(service, "idProduct") as? Int,
                  vendorIDs.contains(vid)
            else { continue }
            let serial = searchParents(service, "USB Serial Number") as? String
            results.append(DiscoveredDevice(path: path, vendorID: vid, productID: pid, serialNumber: serial))
        }
        return results
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func searchParents(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }
}
