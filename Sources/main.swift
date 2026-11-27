import Cocoa
import ApplicationServices

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard !flags.contains(.beginConfigurationFlag),
          let userInfo = userInfo else {
        return
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.scheduleDisplayReconfigurationRefresh()
    }
}

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
    private var currentVolume: Int?
    private var isMuted: Bool = false
    private var volumeBeforeMute: Int = 30
    private var stepSize: Int = 1
    private var stateGeneration: UInt64 = 0

    private var permissionPollTimer: Timer?
    private var displayRefreshWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var displayCallbackRegistered: Bool = false

    private let stepDefaultsKey = "MicroVol.stepSize"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedStep = UserDefaults.standard.integer(forKey: stepDefaultsKey)
        if [1, 2, 5].contains(savedStep) {
            stepSize = savedStep
        }

        setupStatusBar()
        setupCallbacks()
        registerSystemObservers()
        refreshAudioAndDisplayState(readHardwareVolume: true, forceDisplayRefresh: true)
        ensureAccessibilityAndStartTap(prompt: true, showAlertIfDenied: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        displayRefreshWorkItem?.cancel()
        displayRefreshWorkItem = nil
        mediaKeyInterceptor.stop()

        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        if displayCallbackRegistered {
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, userInfo)
            displayCallbackRegistered = false
        }
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
        volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
        volumeSlider.frame = NSRect(x: 16, y: 6, width: 188, height: 20)
        volumeSlider.isContinuous = true
        volumeSlider.isEnabled = false
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
            self?.refreshAudioAndDisplayState(readHardwareVolume: true, forceDisplayRefresh: false)
        }

        audioManager.onVolumeOrMuteChanged = { [weak self] in
            self?.syncSoftwareAudioState()
        }

        mediaKeyInterceptor.shouldIntercept = { [weak self] in
            guard let self = self, let audio = self.activeAudioDevice else {
                return false
            }
            if audio.supportsSoftwareVolume {
                return true
            }
            return self.activeDDCDisplay != nil
        }

        mediaKeyInterceptor.onMediaKey = { [weak self] action in
            self?.handleMediaKey(action)
        }
    }

    private func registerSystemObservers() {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, userInfo) == .success {
            displayCallbackRegistered = true
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDisplayReconfigurationRefresh()
        }
    }

    func scheduleDisplayReconfigurationRefresh() {
        displayRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.ddcController.invalidateCache()
            self.refreshAudioAndDisplayState(readHardwareVolume: true, forceDisplayRefresh: true)
        }
        displayRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func ensureAccessibilityAndStartTap(prompt: Bool, showAlertIfDenied: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted && mediaKeyInterceptor.start() {
            permissionMenuItem.isHidden = true
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            return
        }

        permissionMenuItem.isHidden = false
        startPermissionWatcher()

        if showAlertIfDenied {
            presentAccessibilityAlert(wasTrustedButTapFailed: trusted)
        }
    }

    private func presentAccessibilityAlert(wasTrustedButTapFailed: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility Permission Required"
        if wasTrustedButTapFailed {
            alert.informativeText = "MicroVol could not start listening for volume keys. If you recently updated or rebuilt MicroVol, remove it from System Settings > Privacy & Security > Accessibility and add it again."
        } else {
            alert.informativeText = "MicroVol needs Accessibility permission to intercept keyboard volume keys. Enable MicroVol in System Settings > Privacy & Security > Accessibility."
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPermissionWatcher() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() && self.mediaKeyInterceptor.start() {
                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = nil
                self.permissionMenuItem.isHidden = true
            }
        }
    }

    private func syncSoftwareAudioState() {
        guard let audio = activeAudioDevice, audio.supportsSoftwareVolume else { return }
        if let vol = audioManager.getSoftwareVolume(deviceID: audio.id) {
            currentVolume = vol
            if vol > 0 {
                volumeBeforeMute = vol
            }
        }
        isMuted = audioManager.isSoftwareMuted(deviceID: audio.id)
        volumeSlider?.isEnabled = (currentVolume != nil)
        if let vol = currentVolume {
            volumeSlider?.doubleValue = Double(isMuted ? 0 : vol)
        }
        updateStatusBarTitle()
    }

    private func refreshAudioAndDisplayState(readHardwareVolume: Bool, forceDisplayRefresh: Bool) {
        stateGeneration &+= 1
        let generation = stateGeneration

        let audio = audioManager.defaultOutputDevice()
        activeAudioDevice = audio

        guard let audio = audio else {
            audioManager.observeVolumeChanges(for: nil)
            activeDDCDisplay = nil
            currentVolume = nil
            isMuted = false
            deviceMenuItem.title = "Output: None"
            volumeSlider?.isEnabled = false
            updateStatusBarTitle()
            return
        }

        if audio.supportsSoftwareVolume {
            activeDDCDisplay = nil
            audioManager.observeVolumeChanges(for: audio.id)
            deviceMenuItem.title = "Output: \(audio.name)"
            let vol = audioManager.getSoftwareVolume(deviceID: audio.id)
            currentVolume = vol
            if let vol = vol, vol > 0 {
                volumeBeforeMute = vol
            }
            isMuted = audioManager.isSoftwareMuted(deviceID: audio.id)
            volumeSlider?.isEnabled = (vol != nil)
            if let vol = vol {
                volumeSlider?.doubleValue = Double(isMuted ? 0 : vol)
            }
            updateStatusBarTitle()
        } else {
            audioManager.observeVolumeChanges(for: nil)
            activeDDCDisplay = nil
            currentVolume = nil
            isMuted = false
            deviceMenuItem.title = "Output: \(audio.name) Checking DDC..."
            volumeSlider?.isEnabled = false
            updateStatusBarTitle()

            ddcController.resolveDisplayAndVolume(
                audioDeviceName: audio.name,
                allowFallback: audio.isLikelyDisplayAudio,
                forceRefresh: forceDisplayRefresh,
                readHardwareVolume: readHardwareVolume
            ) { [weak self] display, vol in
                guard let self = self, self.stateGeneration == generation else { return }
                self.activeDDCDisplay = display
                if let display = display {
                    let label = display.productName.isEmpty ? audio.name : display.productName
                    self.deviceMenuItem.title = "Output: \(label) DDC"
                    if let vol = vol {
                        self.currentVolume = vol
                        self.isMuted = (vol == 0)
                        if vol > 0 {
                            self.volumeBeforeMute = vol
                        }
                        self.volumeSlider?.doubleValue = Double(vol)
                    }
                    self.volumeSlider?.isEnabled = true
                } else {
                    self.deviceMenuItem.title = "Output: \(audio.name) No DDC"
                    self.volumeSlider?.isEnabled = false
                }
                self.updateStatusBarTitle()
            }
        }
    }

    private func handleMediaKey(_ action: MediaKeyAction) {
        guard let audio = activeAudioDevice else { return }

        if audio.supportsSoftwareVolume {
            stateGeneration &+= 1
            if let liveVol = audioManager.getSoftwareVolume(deviceID: audio.id) {
                currentVolume = liveVol
            }
            var volume = currentVolume ?? 0
            isMuted = audioManager.isSoftwareMuted(deviceID: audio.id)

            switch action {
            case .volumeUp:
                isMuted = false
                volume = min(100, volume + stepSize)
                audioManager.setSoftwareVolume(deviceID: audio.id, percent: volume)
            case .volumeDown:
                isMuted = false
                volume = max(0, volume - stepSize)
                audioManager.setSoftwareVolume(deviceID: audio.id, percent: volume)
                if volume == 0 {
                    audioManager.setSoftwareMute(deviceID: audio.id, muted: true)
                    isMuted = true
                }
            case .mute:
                isMuted.toggle()
                audioManager.setSoftwareMute(deviceID: audio.id, muted: isMuted)
            }

            currentVolume = volume
            if volume > 0 {
                volumeBeforeMute = volume
            }
            updateStatusBarTitle()
            volumeSlider?.isEnabled = true
            volumeSlider?.doubleValue = Double(isMuted ? 0 : volume)
            hud.show(deviceName: audio.name, volume: volume, muted: isMuted)
        } else {
            guard let display = activeDDCDisplay else { return }

            guard var volume = currentVolume else {
                let generation = stateGeneration
                ddcController.readVolume(display: display) { [weak self] reading in
                    guard let self = self, self.stateGeneration == generation, let reading = reading else { return }
                    self.currentVolume = reading.percent
                    self.isMuted = (reading.percent == 0)
                    if reading.percent > 0 {
                        self.volumeBeforeMute = reading.percent
                    }
                    self.volumeSlider?.doubleValue = Double(reading.percent)
                    self.updateStatusBarTitle()
                }
                return
            }

            stateGeneration &+= 1

            switch action {
            case .volumeUp:
                if isMuted {
                    isMuted = false
                    volume = min(100, max(volumeBeforeMute, volume) + stepSize)
                } else {
                    volume = min(100, volume + stepSize)
                }
                if volume > 0 {
                    volumeBeforeMute = volume
                }
                ddcController.writeVolumeCoalesced(display: display, percent: volume)
            case .volumeDown:
                if isMuted {
                    isMuted = false
                    volume = max(0, volumeBeforeMute - stepSize)
                } else {
                    volume = max(0, volume - stepSize)
                }
                if volume > 0 {
                    volumeBeforeMute = volume
                } else {
                    isMuted = true
                }
                ddcController.writeVolumeCoalesced(display: display, percent: volume)
            case .mute:
                if isMuted || volume == 0 {
                    isMuted = false
                    volume = max(1, volumeBeforeMute)
                    ddcController.writeVolumeCoalesced(display: display, percent: volume)
                } else {
                    volumeBeforeMute = volume
                    isMuted = true
                    volume = 0
                    ddcController.writeVolumeCoalesced(display: display, percent: 0)
                }
            }

            currentVolume = volume
            let displayName = display.productName.isEmpty ? audio.name : display.productName
            updateStatusBarTitle()
            volumeSlider?.isEnabled = true
            volumeSlider?.doubleValue = Double(volume)
            hud.show(deviceName: displayName, volume: volume, muted: isMuted)
        }
    }

    private func updateStatusBarTitle() {
        guard let button = statusItem.button else { return }
        let symbolName = VolumeSymbol.name(volume: currentVolume, muted: isMuted)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Volume")
        button.imagePosition = .imageLeading
        if let volume = currentVolume {
            button.title = " \(isMuted ? 0 : volume)"
        } else {
            button.title = " --"
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let newVol = max(0, min(100, Int(round(sender.doubleValue))))
        stateGeneration &+= 1
        currentVolume = newVol
        isMuted = (newVol == 0)
        if newVol > 0 {
            volumeBeforeMute = newVol
        }

        if let audio = activeAudioDevice {
            if audio.supportsSoftwareVolume {
                audioManager.setSoftwareVolume(deviceID: audio.id, percent: newVol)
                audioManager.setSoftwareMute(deviceID: audio.id, muted: newVol == 0)
            } else if let display = activeDDCDisplay {
                ddcController.writeVolumeCoalesced(display: display, percent: newVol)
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
        ddcController.invalidateCache()
        refreshAudioAndDisplayState(readHardwareVolume: true, forceDisplayRefresh: true)
    }

    @objc private func requestAccessibilityPermission() {
        ensureAccessibilityAndStartTap(prompt: true, showAlertIfDenied: true)
    }

    @objc private func quitApp() {
        mediaKeyInterceptor.stop()
        NSApp.terminate(nil)
    }
}

if let bundleID = Bundle.main.bundleIdentifier {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if running.count > 1 {
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
