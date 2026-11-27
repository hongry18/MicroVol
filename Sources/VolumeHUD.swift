import Cocoa

enum VolumeSymbol {
    static func name(volume: Int?, muted: Bool) -> String {
        guard let volume = volume else {
            return "speaker.slash.fill"
        }
        let clamped = max(0, min(100, volume))
        if muted || clamped == 0 {
            return "speaker.slash.fill"
        } else if clamped < 34 {
            return "speaker.wave.1.fill"
        } else if clamped < 67 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

final class VolumeHUD {
    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let iconView: NSImageView
    private let barFill: NSView
    private let barTrack: NSView
    private var barFillWidthConstraint: NSLayoutConstraint!
    private var hideTimer: Timer?
    private var showGeneration: UInt64 = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 84),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let visualEffect = NSVisualEffectView(frame: panel.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true
        panel.contentView = visualEffect

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .labelColor

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel = NSTextField(labelWithString: "0")
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right

        barTrack = NSView()
        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 3

        barFill = NSView()
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barTrack.addSubview(barFill)

        visualEffect.addSubview(iconView)
        visualEffect.addSubview(titleLabel)
        visualEffect.addSubview(valueLabel)
        visualEffect.addSubview(barTrack)

        barFillWidthConstraint = barFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 18),
            iconView.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),

            valueLabel.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -18),
            valueLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            barTrack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 18),
            barTrack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -18),
            barTrack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -18),
            barTrack.heightAnchor.constraint(equalToConstant: 6),

            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
            barFillWidthConstraint
        ])

        updateBarColors()
    }

    func show(deviceName: String, volume: Int, muted: Bool) {
        let clamped = max(0, min(100, volume))
        titleLabel.stringValue = deviceName
        valueLabel.stringValue = muted ? "0" : "\(clamped)"

        let symbolName = VolumeSymbol.name(volume: clamped, muted: muted)
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        updateBarColors()

        panel.contentView?.layoutSubtreeIfNeeded()
        let trackWidth = barTrack.bounds.width > 0 ? barTrack.bounds.width : (panel.frame.width - 36)
        barFillWidthConstraint.constant = muted ? 0 : trackWidth * CGFloat(clamped) / 100.0

        positionOnActiveScreen()

        showGeneration &+= 1
        let currentGeneration = showGeneration

        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1.0
        }
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            guard let self = self, self.showGeneration == currentGeneration else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0.0
            }, completionHandler: {
                if self.showGeneration == currentGeneration {
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    private func updateBarColors() {
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            barTrack.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
            barFill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.9).cgColor
        }
    }

    private func positionOnActiveScreen() {
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - panel.frame.width / 2.0
        let y = visible.minY + 96.0
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
