// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa

enum StatusItemIconStyle: String, CaseIterable {
    case adaptive
    case color
    case clear
    case dark
    case light
    case legacy

    var localizedTitle: String {
        switch self {
        case .adaptive:
            return tr("macStatusIconDefault")
        case .color:
            return tr("macStatusIconColor")
        case .clear:
            return tr("macStatusIconClear")
        case .dark:
            return tr("macStatusIconDark")
        case .light:
            return tr("macStatusIconLight")
        case .legacy:
            return tr("macStatusIconLegacy")
        }
    }
}

enum StatusItemIconPreference {
    private static let key = "WireRoute.StatusItemIconStyle"

    static func load(from defaults: UserDefaults = .standard) -> StatusItemIconStyle {
        guard let rawValue = defaults.string(forKey: key),
              let style = StatusItemIconStyle(rawValue: rawValue) else {
            return .adaptive
        }
        return style
    }

    static func save(_ style: StatusItemIconStyle, to defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: key)
    }
}

@MainActor
class StatusItemController {
    private enum VisualState {
        case inactive
        case active
        case transition(phase: Int)
    }

    var currentTunnel: TunnelContainer? {
        didSet {
            updateStatusItemImage()
        }
    }

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var iconStyle = StatusItemIconPreference.load()
    private var animationImageIndex: Int = 0
    private var animationTimer: Timer?

    init() {
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = "WireRoute"
        updateStatusItemImage()
    }

    func setIconStyle(_ style: StatusItemIconStyle) {
        guard iconStyle != style else { return }
        iconStyle = style
        StatusItemIconPreference.save(style)
        updateStatusItemImage()
    }

    static func previewImage(for style: StatusItemIconStyle) -> NSImage {
        return image(for: style, state: .active)
    }

    func updateStatusItemImage() {
        guard let currentTunnel = currentTunnel else {
            stopActivatingAnimation()
            statusItem.button?.image = Self.image(for: iconStyle, state: .inactive)
            return
        }
        switch currentTunnel.status {
        case .inactive:
            stopActivatingAnimation()
            statusItem.button?.image = Self.image(for: iconStyle, state: .inactive)
        case .active:
            stopActivatingAnimation()
            statusItem.button?.image = Self.image(for: iconStyle, state: .active)
        case .activating, .waiting, .reasserting, .restarting, .deactivating:
            startActivatingAnimation()
        }
    }

    func startActivatingAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusItem.button?.image = Self.image(
                    for: self.iconStyle,
                    state: .transition(phase: self.animationImageIndex)
                )
                self.animationImageIndex = (self.animationImageIndex + 1) % 3
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopActivatingAnimation() {
        guard let timer = self.animationTimer else { return }
        timer.invalidate()
        animationTimer = nil
        animationImageIndex = 0
    }

    private static func image(for style: StatusItemIconStyle, state: VisualState) -> NSImage {
        if style == .legacy {
            switch state {
            case .inactive:
                return NSImage(named: "StatusBarIconDimmed")!
            case .active:
                return NSImage(named: "StatusBarIcon")!
            case .transition(let phase):
                return NSImage(named: "StatusBarIconDot\(phase + 1)")!
            }
        }

        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            drawWireRouteGlyph(in: rect, style: style, state: state)
            return true
        }
        image.isTemplate = style == .adaptive || style == .clear
        return image
    }

    private static func drawWireRouteGlyph(
        in rect: NSRect,
        style: StatusItemIconStyle,
        state: VisualState
    ) {
        let colors: (primary: NSColor, accent: NSColor)
        switch style {
        case .color:
            colors = (.systemBlue, .systemCyan)
        case .dark:
            colors = (.black, .black)
        case .light:
            colors = (.white, .white)
        case .adaptive, .clear, .legacy:
            colors = (.labelColor, .labelColor)
        }

        let stateAlpha: CGFloat
        switch state {
        case .inactive:
            stateAlpha = 0.46
        case .active, .transition:
            stateAlpha = 1
        }

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        let primary = colors.primary.withAlphaComponent(stateAlpha)
        let accent = colors.accent.withAlphaComponent(stateAlpha)
        let route = NSBezierPath()
        route.move(to: NSPoint(x: rect.minX + 4.2, y: rect.maxY - 4.2))
        route.line(to: NSPoint(x: rect.midX, y: rect.minY + 3.6))
        route.line(to: NSPoint(x: rect.maxX - 4.2, y: rect.maxY - 4.2))
        route.lineWidth = 2.05
        route.lineCapStyle = .round
        route.lineJoinStyle = .round
        primary.setStroke()
        route.stroke()

        let nodeCenters = [
            NSPoint(x: rect.minX + 4.2, y: rect.maxY - 4.2),
            NSPoint(x: rect.midX, y: rect.minY + 3.6),
            NSPoint(x: rect.maxX - 4.2, y: rect.maxY - 4.2)
        ]
        for center in nodeCenters {
            let nodeRect = NSRect(x: center.x - 1.75, y: center.y - 1.75, width: 3.5, height: 3.5)
            let node = NSBezierPath(ovalIn: nodeRect)
            node.lineWidth = 1.45
            primary.setStroke()
            node.stroke()
        }

        let halo = NSBezierPath(ovalIn: NSRect(
            x: rect.minX + 4.2,
            y: rect.minY + 7.2,
            width: rect.width - 8.4,
            height: 5.1
        ))
        halo.lineWidth = 1.45
        accent.setStroke()
        halo.stroke()

        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: rect.midX, y: rect.minY + 7.2))
        shield.line(to: NSPoint(x: rect.midX + 2.15, y: rect.minY + 6.35))
        shield.curve(
            to: NSPoint(x: rect.midX, y: rect.minY + 2.7),
            controlPoint1: NSPoint(x: rect.midX + 2.15, y: rect.minY + 4.65),
            controlPoint2: NSPoint(x: rect.midX + 1.15, y: rect.minY + 3.35)
        )
        shield.curve(
            to: NSPoint(x: rect.midX - 2.15, y: rect.minY + 6.35),
            controlPoint1: NSPoint(x: rect.midX - 1.15, y: rect.minY + 3.35),
            controlPoint2: NSPoint(x: rect.midX - 2.15, y: rect.minY + 4.65)
        )
        shield.close()
        shield.lineWidth = 1.15
        primary.setStroke()
        shield.stroke()
        if style != .clear {
            primary.withAlphaComponent(stateAlpha * 0.82).setFill()
            shield.fill()
        }

        if case .transition(let phase) = state {
            let pulseRadius = CGFloat(phase + 1) * 0.72 + 1.8
            let pulse = NSBezierPath(ovalIn: NSRect(
                x: rect.midX - pulseRadius,
                y: rect.minY + 3.6 - pulseRadius,
                width: pulseRadius * 2,
                height: pulseRadius * 2
            ))
            pulse.lineWidth = 1
            accent.withAlphaComponent(CGFloat(3 - phase) / 4).setStroke()
            pulse.stroke()
        }
    }
}
