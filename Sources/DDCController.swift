import Foundation
import IOKit

private typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
private typealias IOAVServiceReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias IOAVServiceWriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

private enum IOAVBridge {
    private static let iokitHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    static let createWithService: IOAVServiceCreateWithServiceFn? = load("IOAVServiceCreateWithService")
    static let readI2C: IOAVServiceReadI2CFn? = load("IOAVServiceReadI2C")
    static let writeI2C: IOAVServiceWriteI2CFn? = load("IOAVServiceWriteI2C")

    private static func load<T>(_ symbol: String) -> T? {
        guard let handle = iokitHandle,
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
    var maxVolume: Int = 100
}

struct DDCVolumeReading {
    let percent: Int
    let maxVolume: Int
}

final class DDCController {
    static let vcpAudioVolume: UInt8 = 0x62

    private var cachedDisplays: [DDCDisplay] = []
    private let ddcQueue = DispatchQueue(label: "com.microvol.app.ddc", qos: .userInteractive)
    private var pendingWriteWorkItem: DispatchWorkItem?

    func invalidateCache() {
        ddcQueue.async { [weak self] in
            self?.cachedDisplays = []
        }
    }

    func refreshDisplays(completion: (([DDCDisplay]) -> Void)? = nil) {
        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            let displays = self.refreshDisplaysOnQueue()
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(displays)
                }
            }
        }
    }

    func resolveDisplayAndVolume(
        audioDeviceName: String,
        allowFallback: Bool,
        forceRefresh: Bool,
        readHardwareVolume: Bool,
        completion: @escaping (DDCDisplay?, Int?) -> Void
    ) {
        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            if forceRefresh || self.cachedDisplays.isEmpty {
                _ = self.refreshDisplaysOnQueue()
            }
            guard !self.cachedDisplays.isEmpty else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            let matched = self.matchDisplayOnQueue(audioName: audioDeviceName, allowFallback: allowFallback)
            guard var display = matched.display else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            var reading = matched.reading
            if readHardwareVolume && reading == nil {
                reading = self.readVolumeOnQueue(display: display)
            }
            if let reading = reading {
                display.maxVolume = reading.maxVolume
                self.updateCachedMaxVolumeOnQueue(service: display.service, maxVolume: reading.maxVolume)
            }

            let resolvedDisplay = display
            let resolvedPercent = reading?.percent
            DispatchQueue.main.async {
                completion(resolvedDisplay, resolvedPercent)
            }
        }
    }

    func readVolume(display: DDCDisplay, completion: @escaping (DDCVolumeReading?) -> Void) {
        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            let reading = self.readVolumeOnQueue(display: display)
            if let reading = reading {
                self.updateCachedMaxVolumeOnQueue(service: display.service, maxVolume: reading.maxVolume)
            }
            DispatchQueue.main.async {
                completion(reading)
            }
        }
    }

    func writeVolumeCoalesced(display: DDCDisplay, percent: Int) {
        let clamped = max(0, min(100, percent))
        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingWriteWorkItem?.cancel()

            var workItem: DispatchWorkItem!
            workItem = DispatchWorkItem { [weak self] in
                guard let self = self, !workItem.isCancelled else { return }
                let maxVol = self.cachedMaxVolumeOnQueue(for: display)
                let rawValue: Int
                if maxVol > 0 && maxVol != 100 {
                    rawValue = max(0, min(maxVol, Int(round(Double(clamped) * Double(maxVol) / 100.0))))
                } else {
                    rawValue = clamped
                }
                self.writeVolumeOnQueue(display: display, rawValue: rawValue, isCancelled: { workItem.isCancelled })
                if self.pendingWriteWorkItem === workItem {
                    self.pendingWriteWorkItem = nil
                }
            }
            self.pendingWriteWorkItem = workItem
            self.ddcQueue.async(execute: workItem)
        }
    }

    private func refreshDisplaysOnQueue() -> [DDCDisplay] {
        var result: [DDCDisplay] = []
        guard let createFn = IOAVBridge.createWithService else {
            cachedDisplays = result
            return result
        }

        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else {
            cachedDisplays = result
            return result
        }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            cachedDisplays = result
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

    private func matchDisplayOnQueue(audioName: String, allowFallback: Bool) -> (display: DDCDisplay?, reading: DDCVolumeReading?) {
        let needle = audioName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            if let exact = cachedDisplays.first(where: { $0.productName.lowercased() == needle }) {
                return (exact, nil)
            }
            if let partial = cachedDisplays.first(where: {
                let p = $0.productName.lowercased()
                return !p.isEmpty && (p.contains(needle) || needle.contains(p))
            }) {
                return (partial, nil)
            }
        }

        guard allowFallback else {
            return (nil, nil)
        }

        for disp in cachedDisplays {
            if let reading = readVolumeOnQueue(display: disp) {
                return (disp, reading)
            }
        }
        return (nil, nil)
    }

    private func readVolumeOnQueue(display: DDCDisplay) -> DDCVolumeReading? {
        guard let writeFn = IOAVBridge.writeI2C,
              let readFn = IOAVBridge.readI2C else {
            return nil
        }

        var request: [UInt8] = [0x82, 0x01, Self.vcpAudioVolume, 0x00]
        request[3] = checksum(seed: 0x6E ^ 0x51, payload: request[0..<3])

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

            guard rkr == KERN_SUCCESS,
                  reply[0] == 0x6E,
                  (reply[1] & 0x7F) >= 8,
                  reply[2] == 0x02,
                  reply[3] == 0x00,
                  reply[4] == Self.vcpAudioVolume else {
                usleep(20_000)
                continue
            }

            let expectedChecksum = checksum(seed: 0x50, payload: reply[0..<10])
            guard reply[10] == expectedChecksum else {
                usleep(20_000)
                continue
            }

            let maxVal = (Int(reply[6]) << 8) | Int(reply[7])
            let curVal = (Int(reply[8]) << 8) | Int(reply[9])
            let normalizedMax = maxVal > 0 ? maxVal : 100
            let percent: Int
            if normalizedMax != 100 {
                percent = max(0, min(100, Int(round(Double(curVal) * 100.0 / Double(normalizedMax)))))
            } else {
                percent = max(0, min(100, curVal))
            }
            return DDCVolumeReading(percent: percent, maxVolume: normalizedMax)
        }
        return nil
    }

    private func writeVolumeOnQueue(display: DDCDisplay, rawValue: Int, isCancelled: () -> Bool) {
        guard let writeFn = IOAVBridge.writeI2C else { return }

        let hi = UInt8((rawValue >> 8) & 0xFF)
        let lo = UInt8(rawValue & 0xFF)
        var packet: [UInt8] = [0x84, 0x03, Self.vcpAudioVolume, hi, lo, 0x00]
        packet[5] = checksum(seed: 0x6E ^ 0x51, payload: packet[0..<5])

        for attempt in 0..<2 {
            if isCancelled() { return }
            let kr = packet.withUnsafeBytes { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnError }
                return writeFn(display.service, 0x37, 0x51, base, UInt32(buf.count))
            }
            if kr == KERN_SUCCESS {
                return
            }
            if attempt == 0 {
                usleep(12_000)
            }
        }
    }

    private func updateCachedMaxVolumeOnQueue(service: AnyObject, maxVolume: Int) {
        guard maxVolume > 0 else { return }
        if let idx = cachedDisplays.firstIndex(where: { $0.service === service }) {
            cachedDisplays[idx].maxVolume = maxVolume
        }
    }

    private func cachedMaxVolumeOnQueue(for display: DDCDisplay) -> Int {
        if let existing = cachedDisplays.first(where: { $0.service === display.service }) {
            return existing.maxVolume
        }
        return display.maxVolume
    }

    private func checksum(seed: UInt8, payload: ArraySlice<UInt8>) -> UInt8 {
        var chk = seed
        for b in payload {
            chk ^= b
        }
        return chk
    }

    private func inspectEntryAndAncestors(_ startEntry: io_service_t) -> (productName: String, isExternal: Bool) {
        var productName = ""
        var isExternal: Bool?
        var current: io_registry_entry_t = startEntry
        IOObjectRetain(current)
        defer {
            if current != 0 {
                IOObjectRelease(current)
            }
        }

        for _ in 0..<8 {
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(current, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = propsRef?.takeRetainedValue() as? [String: Any] {
                if isExternal == nil, let loc = dict["Location"] as? String {
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

            if isExternal != nil && !productName.isEmpty {
                break
            }

            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            if kr != KERN_SUCCESS || parent == 0 {
                current = 0
                break
            }
            current = parent
        }

        return (productName, isExternal ?? false)
    }
}
