// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa

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
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .systemBlue
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        label.layer?.cornerRadius = 6
        label.layer?.cornerCurve = .continuous
        return label
    }()

    let statusImageView = NSImageView()

    private var statusObservationToken: AnyObject?
    private var nameObservationToken: AnyObject?
    private var isOnDemandEnabledObservationToken: AnyObject?

    init() {
        super.init(frame: CGRect.zero)

        addSubview(statusImageView)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(routingModeLabel)
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        routingModeLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.backgroundColor = .clear
        NSLayoutConstraint.activate([
            statusImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalTo: statusImageView.widthAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 9),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: routingModeLabel.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: routingModeLabel.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
            routingModeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            routingModeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            routingModeLabel.widthAnchor.constraint(equalToConstant: 42),
            routingModeLabel.heightAnchor.constraint(equalToConstant: 20),
            statusImageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
