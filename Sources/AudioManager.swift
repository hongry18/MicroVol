import Foundation
import CoreAudio
import AudioToolbox

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let supportsSoftwareVolume: Bool
    let transportType: UInt32

    var isLikelyDisplayAudio: Bool {
        switch transportType {
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeUnknown:
            return true
        default:
            return false
        }
    }
}

final class AudioManager {
    var onDefaultOutputChanged: (() -> Void)?
    var onVolumeOrMuteChanged: (() -> Void)?

    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var observedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        installDefaultOutputListener()
    }

    deinit {
        removeDevicePropertyListeners()
        removeDefaultOutputListener()
    }

    func defaultOutputDevice() -> AudioDeviceInfo? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        let name = deviceName(for: deviceID) ?? "Unknown Output"
        let hasVol = supportsVolume(deviceID: deviceID)
        let transport = transportType(for: deviceID)
        return AudioDeviceInfo(
            id: deviceID,
            name: name,
            supportsSoftwareVolume: hasVol,
            transportType: transport
        )
    }

    func observeVolumeChanges(for deviceID: AudioDeviceID?) {
        let targetID = deviceID ?? kAudioObjectUnknown
        if observedDeviceID == targetID {
            return
        }
        removeDevicePropertyListeners()
        guard targetID != kAudioObjectUnknown else { return }

        observedDeviceID = targetID

        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(targetID, &volAddress) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onVolumeOrMuteChanged?()
            }
            volumeListenerBlock = block
            AudioObjectAddPropertyListenerBlock(targetID, &volAddress, DispatchQueue.main, block)
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(targetID, &muteAddress) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onVolumeOrMuteChanged?()
            }
            muteListenerBlock = block
            AudioObjectAddPropertyListenerBlock(targetID, &muteAddress, DispatchQueue.main, block)
        }
    }

    func getSoftwareVolume(deviceID: AudioDeviceID) -> Int? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return max(0, min(100, Int(round(volume * 100.0))))
    }

    func setSoftwareVolume(deviceID: AudioDeviceID, percent: Int) {
        let clamped = max(0, min(100, percent))
        var volume = Float32(clamped) / 100.0
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        if clamped > 0 {
            setSoftwareMute(deviceID: deviceID, muted: false)
        }
    }

    func isSoftwareMuted(deviceID: AudioDeviceID) -> Bool {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    func setSoftwareMute(deviceID: AudioDeviceID, muted: Bool) {
        var val = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &val)
    }

    private func supportsVolume(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var transport = UInt32(kAudioDeviceTransportTypeUnknown)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : kAudioDeviceTransportTypeUnknown
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
        guard status == noErr, let cfName = nameRef?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    private func installDefaultOutputListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultOutputChanged?()
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultOutputListenerBlock = nil
    }

    private func removeDevicePropertyListeners() {
        guard observedDeviceID != kAudioObjectUnknown else { return }

        if let block = volumeListenerBlock {
            var volAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(observedDeviceID, &volAddress, DispatchQueue.main, block)
            volumeListenerBlock = nil
        }

        if let block = muteListenerBlock {
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(observedDeviceID, &muteAddress, DispatchQueue.main, block)
            muteListenerBlock = nil
        }

        observedDeviceID = kAudioObjectUnknown
    }
}
