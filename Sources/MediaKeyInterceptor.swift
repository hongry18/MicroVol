import Cocoa

enum MediaKeyAction {
    case volumeUp
    case volumeDown
    case mute
}

final class MediaKeyInterceptor {
    var shouldIntercept: (() -> Bool)?
    var onMediaKey: ((MediaKeyAction) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        eventTap != nil
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        let mask = CGEventMask(1 << 14)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(cgEvent)
                }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = interceptor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(cgEvent)
                }

                if interceptor.handle(cgEvent: cgEvent) {
                    return nil
                }
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func handle(cgEvent: CGEvent) -> Bool {
        let relevantModifiers: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        if !cgEvent.flags.intersection(relevantModifiers).isEmpty {
            return false
        }

        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return false
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = (keyState == 0x0A)
        let isRepeat = (keyFlags & 0x0001) != 0

        let action: MediaKeyAction
        switch keyCode {
        case 0:
            action = .volumeUp
        case 1:
            action = .volumeDown
        case 7:
            action = .mute
        default:
            return false
        }

        if let shouldIntercept = shouldIntercept, !shouldIntercept() {
            return false
        }

        if isKeyDown {
            if action == .mute && isRepeat {
                return true
            }
            DispatchQueue.main.async { [weak self] in
                self?.onMediaKey?(action)
            }
        }
        return true
    }
}
