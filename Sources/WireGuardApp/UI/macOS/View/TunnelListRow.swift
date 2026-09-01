// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        guard rect.height > textSize.height else {
            return super.drawingRect(forBounds: rect)
        }

        let verticalInset = floor((rect.height - textSize.height) / 2)
        let centeredRect = NSRect(
            x: rect.minX,
            y: rect.minY + verticalInset,
            width: rect.width,
            height: textSize.height
        )
        return super.drawingRect(forBounds: centeredRect)
    }
}

@MainActor
class TunnelListRow: NSView {
    var tunnel: TunnelContainer? {
        didSet(value) {
            updateContent()
            nameObservationToken = tunnel?.observe(\TunnelContainer.name) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateContent()
                }
            }
            statusObservationToken = tunnel?.observe(\TunnelContainer.status) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateContent()
                }
            }
            isOnDemandEnabledObservationToken = tunnel?.observe(\TunnelContainer.isActivateOnDemandEnabled) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateContent()
                }
            }
        }
    }

    let nameLabel: NSTextField = {
        let nameLabel = NSTextField()
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBordered = false
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        return nameLabel
    }()

    let detailLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }()

    let routingModeLabel: NSTextField = {
        let label = NSTextField()
        label.cell = VerticallyCenteredTextFieldCell(textCell: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = WireRouteTheme.accentColor
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.cornerCurve = .continuous
        return label
    }()

    let statusImageView = NSImageView()

    private var statusObservationToken: AnyObject?
    private var nameObservationToken: AnyObject?
    private var isOnDemandEnabledObservationToken: AnyObject?

    init() {
        super.init(frame: CGRect.zero)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )

        let textStack = NSStackView(views: [nameLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        addSubview(statusImageView)
        addSubview(textStack)
        addSubview(routingModeLabel)
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        routingModeLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.backgroundColor = .clear
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        routingModeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            statusImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusImageView.widthAnchor.constraint(equalToConstant: 12),
            statusImageView.heightAnchor.constraint(equalTo: statusImageView.widthAnchor),
            statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 9),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: routingModeLabel.leadingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            routingModeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            routingModeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            routingModeLabel.widthAnchor.constraint(equalToConstant: 48),
            routingModeLabel.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRoutingModeAppearance()
    }

    @objc private func themeDidChange() {
        updateRoutingModeAppearance()
    }

    static func image(for tunnel: TunnelContainer?) -> NSImage? {
        guard let tunnel = tunnel else { return nil }
        switch tunnel.status {
        case .active, .restarting, .reasserting:
            return NSImage(named: NSImage.statusAvailableName)
        case .activating, .waiting, .deactivating:
            return NSImage(named: NSImage.statusPartiallyAvailableName)
        case .inactive:
            if tunnel.isActivateOnDemandEnabled {
                return NSImage(named: NSImage.Name.statusOnDemandEnabled)
            } else {
                return NSImage(named: NSImage.statusNoneName)
            }
        }
    }

    private func updateContent() {
        guard let tunnel else {
            nameLabel.stringValue = ""
            detailLabel.stringValue = ""
            routingModeLabel.stringValue = ""
            statusImageView.image = nil
            return
        }
        nameLabel.stringValue = tunnel.name
        detailLabel.stringValue = Self.statusText(for: tunnel)
        routingModeLabel.stringValue = tunnel.routingMode == .full
            ? tr("macTunnelRoutingFull")
            : tr("macTunnelRoutingSplit")
        statusImageView.image = Self.image(for: tunnel)
        updateRoutingModeAppearance()
    }

    private func updateRoutingModeAppearance() {
        routingModeLabel.textColor = WireRouteTheme.accentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            routingModeLabel.layer?.backgroundColor = WireRouteTheme.accentColor.withAlphaComponent(0.10).cgColor
        }
    }

    private static func statusText(for tunnel: TunnelContainer) -> String {
        switch tunnel.status {
        case .inactive: return tr("tunnelStatusInactive")
        case .activating: return tr("tunnelStatusActivating")
        case .active: return tr("tunnelStatusActive")
        case .deactivating: return tr("tunnelStatusDeactivating")
        case .reasserting: return tr("tunnelStatusReasserting")
        case .restarting: return tr("tunnelStatusRestarting")
        case .waiting: return tr("tunnelStatusWaiting")
        }
    }

    override func prepareForReuse() {
        nameLabel.stringValue = ""
        detailLabel.stringValue = ""
        routingModeLabel.stringValue = ""
        statusImageView.image = nil
    }
}

extension NSImage.Name {
    static let statusOnDemandEnabled = NSImage.Name("StatusCircleYellow")
}
