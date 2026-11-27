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
    private let writeLock = NSLock()
    private var writeGeneration: UInt64 = 0
    private var pendingWrite: (display: DDCDisplay, percent: Int)?
    private var isWriteLoopRunning: Bool = false

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
        writeLock.lock()
        writeGeneration &+= 1
        pendingWrite = (display, clamped)
        let shouldStartLoop = !isWriteLoopRunning
        if shouldStartLoop {
            isWriteLoopRunning = true
        }
        writeLock.unlock()

        guard shouldStartLoop else { return }

        ddcQueue.async { [weak self] in
            self?.drainPendingWritesOnQueue()
        }
    }

    private func drainPendingWritesOnQueue() {
        while true {
            writeLock.lock()
            guard let next = pendingWrite else {
                isWriteLoopRunning = false
                writeLock.unlock()
                return
            }
            pendingWrite = nil
            let generation = writeGeneration
            writeLock.unlock()

            let maxVol = cachedMaxVolumeOnQueue(for: next.display)
            let rawValue: Int
            if maxVol > 0 && maxVol != 100 {
                rawValue = max(0, min(maxVol, Int(round(Double(next.percent) * Double(maxVol) / 100.0))))
            } else {
                rawValue = next.percent
            }

            writeVolumeOnQueue(display: next.display, rawValue: rawValue) { [weak self] in
                guard let self = self else { return true }
                self.writeLock.lock()
                let superseded = (self.writeGeneration != generation)
                self.writeLock.unlock()
                return superseded
            }
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
        return (cachedDisplays.first, nil)
    }

    private func readVolumeOnQueue(display: DDCDisplay) -> DDCVolumeReading? {
        guard let writeFn = IOAVBridge.writeI2C,
              let readFn = IOAVBridge.readI2C else {
            return nil
        }

        var request: [UInt8] = [0x82, 0x01, Self.vcpAudioVolume, 0x00]
        request[3] = checksum(seed: 0x6E ^ 0x51, payload: request[0..<3])

        for _ in 0..<4 {
            var writeOK = false
            // Apple Silicon IOAVServiceWriteI2C can return KERN_SUCCESS on a wake-up
            // frame that the monitor replies to with a DDC NULL message (6E 80 BE).
            // Sending the request twice with a short gap matches Arm64DDC/MonitorControl.
            for w in 0..<2 {
                let wkr = request.withUnsafeBytes { buf -> IOReturn in
                    guard let base = buf.baseAddress else { return kIOReturnError }
                    return writeFn(display.service, 0x37, 0x51, base, UInt32(buf.count))
                }
                if wkr == KERN_SUCCESS {
                    writeOK = true
                }
                if w == 0 {
                    usleep(10_000)
                }
            }
            guard writeOK else {
                usleep(20_000)
                continue
            }

            usleep(50_000)

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
                usleep(30_000)
                continue
            }

            let expectedChecksum = checksum(seed: 0x50, payload: reply[0..<10])
            guard reply[10] == expectedChecksum else {
                usleep(30_000)
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

        // Apple Silicon IOAVServiceWriteI2C requires sending the packet twice
        // for reliable DDC delivery on many external monitors (e.g. LG).
        for attempt in 0..<2 {
            if isCancelled() { return }
            _ = packet.withUnsafeBytes { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnError }
                return writeFn(display.service, 0x37, 0x51, base, UInt32(buf.count))
            }
            if attempt == 0 {
                usleep(10_000)
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
                   let name = extractProductName(from: dict) {
                    productName = name
                }
            }

            if productName.isEmpty {
                productName = findProductNameInChildren(of: current)
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

    private func extractProductName(from dict: [String: Any]) -> String? {
        if let dispAttrs = dict["DisplayAttributes"] as? [String: Any],
           let prodAttrs = dispAttrs["ProductAttributes"] as? [String: Any],
           let name = prodAttrs["ProductName"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    private func findProductNameInChildren(of entry: io_registry_entry_t) -> String {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return ""
        }
        defer { IOObjectRelease(childIter) }

        while case let child = IOIteratorNext(childIter), child != 0 {
            defer { IOObjectRelease(child) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(child, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = propsRef?.takeRetainedValue() as? [String: Any],
               let name = extractProductName(from: dict) {
                return name
            }
        }
        return ""
    }
}
