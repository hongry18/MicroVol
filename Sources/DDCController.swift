import Foundation
import IOKit

private typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
private typealias IOAVServiceReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias IOAVServiceWriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

private enum IOAVBridge {
    static let createWithService: IOAVServiceCreateWithServiceFn? = load("IOAVServiceCreateWithService")
    static let readI2C: IOAVServiceReadI2CFn? = load("IOAVServiceReadI2C")
    static let writeI2C: IOAVServiceWriteI2CFn? = load("IOAVServiceWriteI2C")

    private static func load<T>(_ symbol: String) -> T? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sym = dlsym(handle, symbol) else {
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }
}

struct DDCDisplay {
    let service: AnyObject
    let productName: String
    let isExternal: Bool
}

final class DDCController {
    static let vcpAudioVolume: UInt8 = 0x62

    private var cachedDisplays: [DDCDisplay] = []
    private let ddcQueue = DispatchQueue(label: "com.microvol.app.ddc", qos: .userInteractive)
    private var pendingWriteWorkItem: DispatchWorkItem?

    func refreshDisplays() -> [DDCDisplay] {
        var result: [DDCDisplay] = []
        guard let createFn = IOAVBridge.createWithService else {
            return result
        }

        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else {
            return result
        }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            let info = inspectEntryAndAncestors(entry)
            guard info.isExternal else { continue }

            if let unmanaged = createFn(kCFAllocatorDefault, entry) {
                let avService = unmanaged.takeRetainedValue()
                result.append(DDCDisplay(
                    service: avService,
                    productName: info.productName,
                    isExternal: info.isExternal
                ))
            }
        }

        cachedDisplays = result
        return result
    }

    func findDisplay(matchingAudioDeviceName audioName: String) -> DDCDisplay? {
        if cachedDisplays.isEmpty {
            _ = refreshDisplays()
        }
        if cachedDisplays.isEmpty {
            return nil
        }

        let needle = audioName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            if let exact = cachedDisplays.first(where: { $0.productName.lowercased() == needle }) {
                return exact
            }
            if let partial = cachedDisplays.first(where: {
                let p = $0.productName.lowercased()
                return !p.isEmpty && (p.contains(needle) || needle.contains(p))
            }) {
                return partial
            }
        }

        for disp in cachedDisplays {
            if readVolumeSync(display: disp) != nil {
                return disp
            }
        }
        return cachedDisplays.first
    }

    func readVolume(display: DDCDisplay, completion: @escaping (Int?) -> Void) {
        ddcQueue.async { [weak self] in
            let vol = self?.readVolumeSync(display: display)
            DispatchQueue.main.async {
                completion(vol)
            }
        }
    }

    func readVolumeSync(display: DDCDisplay) -> Int? {
        guard let writeFn = IOAVBridge.writeI2C,
              let readFn = IOAVBridge.readI2C else {
            return nil
        }

        var request: [UInt8] = [0x82, 0x01, Self.vcpAudioVolume, 0x00]
        request[3] = checksum(chipWriteAddr: 0x6E, dataAddr: 0x51, payload: Array(request[0..<3]))

        for _ in 0..<2 {
            let wkr = request.withUnsafeBytes { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnError }
                return writeFn(display.service, 0x37, 0x51, base, UInt32(buf.count))
            }
            guard wkr == KERN_SUCCESS else {
                usleep(20_000)
                continue
            }

            usleep(40_000)

            var reply = [UInt8](repeating: 0, count: 12)
            let rkr = reply.withUnsafeMutableBytes { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnError }
                return readFn(display.service, 0x37, 0x51, base, UInt32(buf.count))
            }

            if rkr == KERN_SUCCESS && reply[2] == 0x02 && reply[4] == Self.vcpAudioVolume {
                let maxVal = (Int(reply[6]) << 8) | Int(reply[7])
                let curVal = (Int(reply[8]) << 8) | Int(reply[9])
                if maxVal > 0 && maxVal != 100 {
                    return Int(round(Double(curVal) * 100.0 / Double(maxVal)))
                }
                return max(0, min(100, curVal))
            }
            usleep(20_000)
        }
        return nil
    }

    func writeVolumeCoalesced(display: DDCDisplay, volume: Int) {
        let clamped = max(0, min(100, volume))
        pendingWriteWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.writeVolumeSync(display: display, volume: clamped)
        }
        pendingWriteWorkItem = workItem
        ddcQueue.async(execute: workItem)
    }

    private func writeVolumeSync(display: DDCDisplay, volume: Int) {
        guard let writeFn = IOAVBridge.writeI2C else { return }

        let hi = UInt8((volume >> 8) & 0xFF)
        let lo = UInt8(volume & 0xFF)
        var packet: [UInt8] = [0x84, 0x03, Self.vcpAudioVolume, hi, lo, 0x00]
        packet[5] = checksum(chipWriteAddr: 0x6E, dataAddr: 0x51, payload: Array(packet[0..<5]))

        for attempt in 0..<2 {
            _ = packet.withUnsafeBytes { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnError }
                return writeFn(display.service, 0x37, 0x51, base, UInt32(buf.count))
            }
            if attempt == 0 {
                usleep(12_000)
            }
        }
    }

    private func checksum(chipWriteAddr: UInt8, dataAddr: UInt8, payload: [UInt8]) -> UInt8 {
        var chk = chipWriteAddr ^ dataAddr
        for b in payload {
            chk ^= b
        }
        return chk
    }

    private func inspectEntryAndAncestors(_ startEntry: io_service_t) -> (productName: String, isExternal: Bool) {
        var productName = ""
        var isExternal = false
        var current: io_registry_entry_t = startEntry
        IOObjectRetain(current)

        for _ in 0..<8 {
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(current, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = propsRef?.takeRetainedValue() as? [String: Any] {
                if let loc = dict["Location"] as? String {
                    if loc.caseInsensitiveCompare("External") == .orderedSame {
                        isExternal = true
                    } else if loc.caseInsensitiveCompare("Embedded") == .orderedSame {
                        isExternal = false
                    }
                }
                if productName.isEmpty,
                   let dispAttrs = dict["DisplayAttributes"] as? [String: Any],
                   let prodAttrs = dispAttrs["ProductAttributes"] as? [String: Any],
                   let name = prodAttrs["ProductName"] as? String, !name.isEmpty {
                    productName = name
                }
            }

            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            if kr != KERN_SUCCESS || parent == 0 {
                break
            }
            current = parent
        }

        return (productName, isExternal)
    }
}
