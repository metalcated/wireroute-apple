// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

final class WireRouteGlyphView: UIView {
    private let routeLayer = CAShapeLayer()
    private let nodeLayer = CAShapeLayer()
    private var status: TunnelStatus = .inactive
    private var routingMode: TunnelRouteMode = .split

    override init(frame: CGRect) {
        super.init(frame: frame)

        isAccessibilityElement = false
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        routeLayer.fillColor = UIColor.clear.cgColor
        routeLayer.lineCap = .round
        routeLayer.lineJoin = .round
        routeLayer.lineWidth = 2.5
        layer.addSublayer(routeLayer)

        nodeLayer.fillColor = UIColor.clear.cgColor
        nodeLayer.lineWidth = 2.5
        layer.addSublayer(nodeLayer)

        update(status: .inactive, routingMode: .split, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePaths()
    }

    func update(status: TunnelStatus, routingMode: TunnelRouteMode, animated: Bool) {
        self.status = status
        self.routingMode = routingMode

        let routeColor: UIColor
        switch status {
        case .active:
            routeColor = WireRouteAppearance.liveTeal
        case .activating, .deactivating, .reasserting, .restarting, .waiting:
            routeColor = WireRouteAppearance.warningAmber
        case .inactive:
            routeColor = WireRouteAppearance.signalBlue
        }

        backgroundColor = routeColor.withAlphaComponent(0.14)
        routeLayer.strokeColor = routeColor.cgColor
        nodeLayer.strokeColor = routeColor.cgColor
        routeLayer.lineDashPattern = status == .inactive ? [3, 3] : nil

        if animated && !UIAccessibility.isReduceMotionEnabled {
            let transition = CATransition()
            transition.duration = 0.2
            transition.type = .fade
            routeLayer.add(transition, forKey: "route-state")
            nodeLayer.add(transition, forKey: "node-state")
        }

        updatePaths()
    }

    private func updatePaths() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let middleY = bounds.midY
        let start = CGPoint(x: 9, y: middleY)
        let junction = CGPoint(x: bounds.midX, y: middleY)
        let endX = bounds.maxX - 9

        let routePath = UIBezierPath()
        routePath.move(to: start)
        routePath.addLine(to: junction)

        let destinations: [CGPoint]
        if routingMode == .split {
            destinations = [CGPoint(x: endX, y: 11), CGPoint(x: endX, y: bounds.maxY - 11)]
            for destination in destinations {
                routePath.move(to: junction)
                routePath.addLine(to: destination)
            }
        } else {
            destinations = [CGPoint(x: endX, y: middleY)]
            routePath.addLine(to: destinations[0])
        }
        routeLayer.path = routePath.cgPath

        let nodePath = UIBezierPath(ovalIn: CGRect(x: start.x - 2, y: start.y - 2, width: 4, height: 4))
        for destination in destinations {
            nodePath.append(UIBezierPath(ovalIn: CGRect(x: destination.x - 2, y: destination.y - 2, width: 4, height: 4)))
        }
        nodeLayer.path = nodePath.cgPath
    }
}

class TunnelListCell: UITableViewCell {
    var tunnel: TunnelContainer? {
        didSet {
            // Bind to the tunnel's name
            nameLabel.text = tunnel?.name ?? ""
            nameObservationToken = tunnel?.observe(\.name) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.nameLabel.text = self?.tunnel?.name
                }
            }
            // Bind to the tunnel's status
            update(from: tunnel, animated: false)
            statusObservationToken = tunnel?.observe(\.status) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.update(from: self?.tunnel, animated: true)
                }
            }
            // Bind to tunnel's on-demand settings
            isOnDemandEnabledObservationToken = tunnel?.observe(\.isActivateOnDemandEnabled) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.update(from: self?.tunnel, animated: true)
                }
            }
            hasOnDemandRulesObservationToken = tunnel?.observe(\.hasOnDemandRules) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.update(from: self?.tunnel, animated: true)
                }
            }
        }
    }
    var onStatusButtonTapped: ((Bool) -> Void)?

    let nameLabel: UILabel = {
        let nameLabel = UILabel()
        nameLabel.font = WireRouteAppearance.roundedFont(size: 17, weight: .semibold, textStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        return nameLabel
    }()

    let statusLabel: UILabel = {
        let label = UILabel()
        label.text = ""
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        return label
    }()

    let routeGlyphView = WireRouteGlyphView()

    let busyIndicator: UIActivityIndicatorView = {
        let busyIndicator: UIActivityIndicatorView
        busyIndicator = UIActivityIndicatorView(style: .medium)
        busyIndicator.hidesWhenStopped = true
        return busyIndicator
    }()

    let statusButton: UIButton = {
        let button = UIButton(type: .system)
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        button.setImage(UIImage(systemName: "power", withConfiguration: symbolConfiguration), for: .normal)
        button.tintColor = .secondaryLabel
        button.backgroundColor = WireRouteAppearance.raised
        button.layer.cornerRadius = 24
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 1
        button.layer.borderColor = WireRouteAppearance.border.cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.24
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 5)
        button.accessibilityTraits = .button
        return button
    }()

    private var isStatusButtonOn = false

    private var nameObservationToken: NSKeyValueObservation?
    private var statusObservationToken: NSKeyValueObservation?
    private var isOnDemandEnabledObservationToken: NSKeyValueObservation?
    private var hasOnDemandRulesObservationToken: NSKeyValueObservation?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .disclosureIndicator
        backgroundColor = WireRouteAppearance.card

        let selectedBackgroundView = UIView()
        selectedBackgroundView.backgroundColor = WireRouteAppearance.signalBlue.withAlphaComponent(0.1)
        self.selectedBackgroundView = selectedBackgroundView

        for subview in [routeGlyphView, statusButton, busyIndicator, statusLabel, nameLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            routeGlyphView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            routeGlyphView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            routeGlyphView.widthAnchor.constraint(equalToConstant: 44),
            routeGlyphView.heightAnchor.constraint(equalTo: routeGlyphView.widthAnchor),

            statusButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusButton.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            statusButton.widthAnchor.constraint(equalToConstant: 48),
            statusButton.heightAnchor.constraint(equalTo: statusButton.widthAnchor),

            nameLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: routeGlyphView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusButton.leadingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: busyIndicator.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -6),

            busyIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            busyIndicator.trailingAnchor.constraint(equalTo: statusButton.leadingAnchor, constant: -8)
        ])

        statusButton.addTarget(self, action: #selector(statusButtonTapped), for: .touchUpInside)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reset(animated: false)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        updateStatusButtonAvailability()
    }

    @objc private func statusButtonTapped() {
        onStatusButtonTapped?(!isStatusButtonOn)
    }

    private func update(from tunnel: TunnelContainer?, animated: Bool) {
        guard let tunnel = tunnel else {
            reset(animated: animated)
            return
        }
        let status = tunnel.status
        let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

        let shouldButtonBeOn = ((status != .deactivating && status != .inactive) || isOnDemandEngaged)
        let statusTint = isOnDemandEngaged && !(status == .activating || status == .active)
            ? WireRouteAppearance.warningAmber
            : WireRouteAppearance.liveTeal
        updateStatusButton(isOn: shouldButtonBeOn, tintColor: statusTint, animated: animated)

        var statusText: String
        switch status {
        case .inactive:
            statusText = tr("tunnelStatusInactive")
        case .activating:
            statusText = tr("tunnelStatusActivating")
        case .active:
            statusText = tr("tunnelStatusActive")
        case .deactivating:
            statusText = tr("tunnelStatusDeactivating")
        case .reasserting:
            statusText = tr("tunnelStatusReasserting")
        case .restarting:
            statusText = tr("tunnelStatusRestarting")
        case .waiting:
            statusText = tr("tunnelStatusWaiting")
        }

        if tunnel.hasOnDemandRules {
            statusText = isOnDemandEngaged
                ? statusText + tr("tunnelStatusAddendumOnDemand")
                : tr("tunnelStatusOnDemandDisabled")
        }
        statusLabel.text = statusText
        routeGlyphView.update(status: status, routingMode: tunnel.routingMode, animated: animated)
        statusButton.accessibilityLabel = tunnel.hasOnDemandRules
            ? tr(
                format: isOnDemandEngaged
                    ? "tunnelPowerButtonDisableOnDemand (%@)"
                    : "tunnelPowerButtonEnableOnDemand (%@)",
                tunnel.name
            )
            : tr(
                format: shouldButtonBeOn
                    ? "tunnelPowerButtonDisconnect (%@)"
                    : "tunnelPowerButtonConnect (%@)",
                tunnel.name
            )
        statusButton.accessibilityValue = statusText

        if tunnel.hasOnDemandRules {
            busyIndicator.stopAnimating()
        } else {
            if status == .inactive || status == .active {
                busyIndicator.stopAnimating()
            } else {
                busyIndicator.startAnimating()
            }
        }
        updateStatusButtonAvailability()
    }

    private func reset(animated: Bool) {
        updateStatusButton(isOn: false, tintColor: WireRouteAppearance.liveTeal, animated: animated)
        statusButton.isEnabled = false
        statusButton.accessibilityLabel = nil
        statusButton.accessibilityValue = nil
        busyIndicator.stopAnimating()
        statusLabel.text = nil
        routeGlyphView.update(status: .inactive, routingMode: .split, animated: animated)
    }

    private func updateStatusButtonAvailability() {
        guard let tunnel else {
            statusButton.isEnabled = false
            return
        }
        let canToggle = tunnel.hasOnDemandRules || tunnel.status == .inactive || tunnel.status == .active
        statusButton.isEnabled = canToggle && !isEditing
    }

    private func updateStatusButton(isOn: Bool, tintColor: UIColor, animated: Bool) {
        isStatusButtonOn = isOn
        if isOn {
            statusButton.accessibilityTraits.insert(.selected)
        } else {
            statusButton.accessibilityTraits.remove(.selected)
        }

        let changes = {
            self.statusButton.tintColor = isOn ? tintColor : UIColor.secondaryLabel
            self.statusButton.backgroundColor = isOn
                ? tintColor.withAlphaComponent(0.17)
                : WireRouteAppearance.raised
            self.statusButton.layer.borderColor = isOn
                ? tintColor.withAlphaComponent(0.62).cgColor
                : WireRouteAppearance.border.cgColor
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: statusButton,
                duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: changes
            )
        } else {
            changes()
        }
    }
}
