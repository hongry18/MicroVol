import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audioManager = AudioManager()
    private let ddcController = DDCController()
    private let mediaKeyInterceptor = MediaKeyInterceptor()
    private let hud = VolumeHUD()

    private var statusItem: NSStatusItem!
    private var deviceMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var volumeSlider: NSSlider!
    private var stepItems: [Int: NSMenuItem] = [:]

    private var activeAudioDevice: AudioDeviceInfo?
    private var activeDDCDisplay: DDCDisplay?
    private var currentVolume: Int = 50
    private var isMuted: Bool = false
    private var volumeBeforeMute: Int = 30
    private var stepSize: Int = 1
    private var permissionPollTimer: Timer?

    private let stepDefaultsKey = "MicroVol.stepSize"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedStep = UserDefaults.standard.integer(forKey: stepDefaultsKey)
        if [1, 2, 5].contains(savedStep) {
            stepSize = savedStep
        }

        setupStatusBar()
        setupCallbacks()
        refreshAudioAndDisplayState(readHardwareVolume: true)
        ensureAccessibilityAndStartTap(prompt: true)
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarTitle()

        let menu = NSMenu()

        deviceMenuItem = NSMenuItem(title: "Output: Checking...", action: nil, keyEquivalent: "")
        deviceMenuItem.isEnabled = false
        menu.addItem(deviceMenuItem)

        permissionMenuItem = NSMenuItem(title: "Grant Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
        permissionMenuItem.target = self
        permissionMenuItem.isHidden = true
        menu.addItem(permissionMenuItem)

        menu.addItem(.separator())

        let sliderItem = NSMenuItem()
        let sliderContainer = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        volumeSlider = NSSlider(value: Double(currentVolume), minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
        volumeSlider.frame = NSRect(x: 16, y: 6, width: 188, height: 20)
        volumeSlider.isContinuous = true
        sliderContainer.addSubview(volumeSlider)
        sliderItem.view = sliderContainer
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let stepSubmenu = NSMenu()
        for step in [1, 2, 5] {
            let item = NSMenuItem(title: "Step \(step)", action: #selector(selectStep(_:)), keyEquivalent: "")
            item.tag = step
            item.target = self
            item.state = (step == stepSize) ? .on : .off
            stepSubmenu.addItem(item)
            stepItems[step] = item
        }
        let stepMenu = NSMenuItem(title: "Volume Step", action: nil, keyEquivalent: "")
        stepMenu.submenu = stepSubmenu
        menu.addItem(stepMenu)

        let refreshItem = NSMenuItem(title: "Reconnect Displays", action: #selector(reloadDisplays), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MicroVol", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupCallbacks() {
        audioManager.onDefaultOutputChanged = { [weak self] in
            self?.refreshAudioAndDisplayState(readHardwareVolume: true)
        }

        mediaKeyInterceptor.onMediaKey = { [weak self] action in
            self?.handleMediaKey(action)
        }
    }

    private func ensureAccessibilityAndStartTap(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            permissionMenuItem.isHidden = true
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            _ = mediaKeyInterceptor.start()
        } else {
            permissionMenuItem.isHidden = false
            startPermissionWatcher()
        }
    }

    private func startPermissionWatcher() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = nil
                self.permissionMenuItem.isHidden = true
                _ = self.mediaKeyInterceptor.start()
            }
        }
    }

    private func refreshAudioAndDisplayState(readHardwareVolume: Bool) {
        let audio = audioManager.defaultOutputDevice()
        activeAudioDevice = audio

        guard let audio = audio else {
            activeDDCDisplay = nil
            deviceMenuItem.title = "Output: None"
            updateStatusBarTitle()
            return
        }

        if audio.supportsSoftwareVolume {
            activeDDCDisplay = nil
            deviceMenuItem.title = "Output: \(audio.name)"
            if let vol = audioManager.getSoftwareVolume(deviceID: audio.id) {
                currentVolume = vol
            }
            isMuted = audioManager.isSoftwareMuted(deviceID: audio.id)
            updateStatusBarTitle()
            volumeSlider?.doubleValue = Double(currentVolume)
        } else {
            let display = ddcController.findDisplay(matchingAudioDeviceName: audio.name)
            activeDDCDisplay = display
            if let display = display {
                let label = display.productName.isEmpty ? audio.name : display.productName
                deviceMenuItem.title = "Output: \(label) DDC"
                if readHardwareVolume {
                    ddcController.readVolume(display: display) { [weak self] vol in
                        guard let self = self else { return }
                        if let vol = vol {
                            self.currentVolume = vol
                            self.isMuted = (vol == 0)
                            if vol > 0 {
                                self.volumeBeforeMute = vol
                            }
                            self.updateStatusBarTitle()
                            self.volumeSlider?.doubleValue = Double(vol)
                        }
                    }
                }
            } else {
                deviceMenuItem.title = "Output: \(audio.name) No DDC"
            }
            updateStatusBarTitle()
        }
    }

    private func handleMediaKey(_ action: MediaKeyAction) {
        if activeAudioDevice == nil {
            refreshAudioAndDisplayState(readHardwareVolume: false)
        }
        guard let audio = activeAudioDevice else { return }

        if audio.supportsSoftwareVolume {
            if let liveVol = audioManager.getSoftwareVolume(deviceID: audio.id) {
                currentVolume = liveVol
            }
            isMuted = audioManager.isSoftwareMuted(deviceID: audio.id)

            switch action {
            case .volumeUp:
                isMuted = false
                currentVolume = min(100, currentVolume + stepSize)
                audioManager.setSoftwareVolume(deviceID: audio.id, percent: currentVolume)
            case .volumeDown:
                isMuted = false
                currentVolume = max(0, currentVolume - stepSize)
                audioManager.setSoftwareVolume(deviceID: audio.id, percent: currentVolume)
            case .mute:
                isMuted.toggle()
                audioManager.setSoftwareMute(deviceID: audio.id, muted: isMuted)
            }

            updateStatusBarTitle()
            volumeSlider?.doubleValue = Double(currentVolume)
            hud.show(deviceName: audio.name, volume: currentVolume, muted: isMuted)
        } else {
            if activeDDCDisplay == nil {
                activeDDCDisplay = ddcController.findDisplay(matchingAudioDeviceName: audio.name)
            }
            guard let display = activeDDCDisplay else { return }

            switch action {
            case .volumeUp:
                if isMuted {
                    isMuted = false
                    currentVolume = min(100, max(volumeBeforeMute, currentVolume) + stepSize)
                } else {
                    currentVolume = min(100, currentVolume + stepSize)
                }
                if currentVolume > 0 {
                    volumeBeforeMute = currentVolume
                }
                ddcController.writeVolumeCoalesced(display: display, volume: currentVolume)
            case .volumeDown:
                isMuted = false
                currentVolume = max(0, currentVolume - stepSize)
                if currentVolume > 0 {
                    volumeBeforeMute = currentVolume
                }
                ddcController.writeVolumeCoalesced(display: display, volume: currentVolume)
            case .mute:
                if isMuted || currentVolume == 0 {
                    isMuted = false
                    currentVolume = max(1, volumeBeforeMute)
                    ddcController.writeVolumeCoalesced(display: display, volume: currentVolume)
                } else {
                    volumeBeforeMute = currentVolume
                    isMuted = true
                    currentVolume = 0
                    ddcController.writeVolumeCoalesced(display: display, volume: 0)
                }
            }

            let displayName = display.productName.isEmpty ? audio.name : display.productName
            updateStatusBarTitle()
            volumeSlider?.doubleValue = Double(currentVolume)
            hud.show(deviceName: displayName, volume: currentVolume, muted: isMuted)
        }
    }

    private func updateStatusBarTitle() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        if isMuted || currentVolume == 0 {
            symbolName = "speaker.slash.fill"
        } else if currentVolume < 34 {
            symbolName = "speaker.wave.1.fill"
        } else if currentVolume < 67 {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.3.fill"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Volume")
        button.imagePosition = .imageLeading
        button.title = " \(isMuted ? 0 : currentVolume)"
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let newVol = max(0, min(100, Int(round(sender.doubleValue))))
        currentVolume = newVol
        isMuted = (newVol == 0)
        if newVol > 0 {
            volumeBeforeMute = newVol
        }

        if let audio = activeAudioDevice {
            if audio.supportsSoftwareVolume {
                audioManager.setSoftwareVolume(deviceID: audio.id, percent: newVol)
            } else if let display = activeDDCDisplay {
                ddcController.writeVolumeCoalesced(display: display, volume: newVol)
            }
        }
        updateStatusBarTitle()
    }

    @objc private func selectStep(_ sender: NSMenuItem) {
        stepSize = sender.tag
        UserDefaults.standard.set(stepSize, forKey: stepDefaultsKey)
        for (step, item) in stepItems {
            item.state = (step == stepSize) ? .on : .off
        }
    }

    @objc private func reloadDisplays() {
        _ = ddcController.refreshDisplays()
        refreshAudioAndDisplayState(readHardwareVolume: true)
    }

    @objc private func requestAccessibilityPermission() {
        ensureAccessibilityAndStartTap(prompt: true)
    }

    @objc private func quitApp() {
        mediaKeyInterceptor.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
