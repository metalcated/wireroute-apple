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

    let routeModeLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }()

    let routeModeImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = WireRouteAppearance.signalBlue
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        return imageView
    }()

    let routeGlyphView = WireRouteGlyphView()

    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = WireRouteAppearance.card
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = WireRouteAppearance.border.withAlphaComponent(0.72).cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.3
        view.layer.shadowRadius = 13
        view.layer.shadowOffset = CGSize(width: 0, height: 8)
        return view
    }()

    private let stateRail: UIView = {
        let view = UIView()
        view.backgroundColor = WireRouteAppearance.signalBlue
        view.layer.cornerRadius = 2
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let routeModeContainer: UIView = {
        let view = UIView()
        view.backgroundColor = WireRouteAppearance.inset
        view.layer.cornerRadius = 11
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = WireRouteAppearance.border.withAlphaComponent(0.52).cgColor
        return view
    }()

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
        button.layer.cornerRadius = 26
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
    private var cardBorderColor = WireRouteAppearance.border.withAlphaComponent(0.72)

    private var nameObservationToken: NSKeyValueObservation?
    private var statusObservationToken: NSKeyValueObservation?
    private var isOnDemandEnabledObservationToken: NSKeyValueObservation?
    private var hasOnDemandRulesObservationToken: NSKeyValueObservation?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .none
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        layer.masksToBounds = false
        contentView.layer.masksToBounds = false

        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        for subview in [stateRail, routeGlyphView, statusButton, busyIndicator, statusLabel, nameLabel, routeModeContainer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview(subview)
        }

        let routeModeStack = UIStackView(arrangedSubviews: [routeModeImageView, routeModeLabel])
        routeModeStack.axis = .horizontal
        routeModeStack.alignment = .center
        routeModeStack.spacing = 5
        routeModeStack.translatesAutoresizingMaskIntoConstraints = false
        routeModeContainer.addSubview(routeModeStack)

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),

            stateRail.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            stateRail.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 20),
            stateRail.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),
            stateRail.widthAnchor.constraint(equalToConstant: 4),

            routeGlyphView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            routeGlyphView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            routeGlyphView.widthAnchor.constraint(equalToConstant: 48),
            routeGlyphView.heightAnchor.constraint(equalTo: routeGlyphView.widthAnchor),

            statusButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            statusButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            statusButton.widthAnchor.constraint(equalToConstant: 52),
            statusButton.heightAnchor.constraint(equalTo: statusButton.widthAnchor),

            nameLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 17),
            nameLabel.leadingAnchor.constraint(equalTo: routeGlyphView.trailingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusButton.leadingAnchor, constant: -14),

            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: busyIndicator.leadingAnchor, constant: -8),

            routeModeContainer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 9),
            routeModeContainer.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            routeModeContainer.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -17),
            routeModeContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            routeModeContainer.trailingAnchor.constraint(lessThanOrEqualTo: statusButton.leadingAnchor, constant: -14),

            routeModeStack.leadingAnchor.constraint(equalTo: routeModeContainer.leadingAnchor, constant: 9),
            routeModeStack.trailingAnchor.constraint(equalTo: routeModeContainer.trailingAnchor, constant: -9),
            routeModeStack.topAnchor.constraint(equalTo: routeModeContainer.topAnchor, constant: 4),
            routeModeStack.bottomAnchor.constraint(equalTo: routeModeContainer.bottomAnchor, constant: -4),
            routeModeImageView.widthAnchor.constraint(equalToConstant: 12),
            routeModeImageView.heightAnchor.constraint(equalToConstant: 12),

            busyIndicator.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
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

    override func layoutSubviews() {
        super.layoutSubviews()
        cardView.layer.shadowPath = UIBezierPath(roundedRect: cardView.bounds, cornerRadius: 20).cgPath
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updateCardInteractionAppearance(animated: animated)
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        updateCardInteractionAppearance(animated: animated)
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
        let stateColor = profileStateColor(status: status, isOnDemandEngaged: isOnDemandEngaged)
        statusLabel.textColor = stateColor
        stateRail.backgroundColor = stateColor
        cardBorderColor = status == .active
            ? WireRouteAppearance.liveTeal.withAlphaComponent(0.42)
            : WireRouteAppearance.border.withAlphaComponent(0.72)
        updateRouteMode(tunnel.routingMode)
        updateCardInteractionAppearance(animated: animated)
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
        statusLabel.textColor = .secondaryLabel
        stateRail.backgroundColor = WireRouteAppearance.signalBlue
        routeModeLabel.text = nil
        routeModeImageView.image = nil
        cardBorderColor = WireRouteAppearance.border.withAlphaComponent(0.72)
        updateCardInteractionAppearance(animated: animated)
        routeGlyphView.update(status: .inactive, routingMode: .split, animated: animated)
    }

    private func updateRouteMode(_ routingMode: TunnelRouteMode) {
        let isFullTunnel = routingMode == .full
        routeModeLabel.text = isFullTunnel
            ? tr("iosProfilesRoutingFull")
            : tr("iosProfilesRoutingSplit")
        routeModeImageView.image = UIImage(systemName: isFullTunnel ? "globe" : "arrow.triangle.branch")
    }

    private func profileStateColor(status: TunnelStatus, isOnDemandEngaged: Bool) -> UIColor {
        switch status {
        case .active:
            return WireRouteAppearance.liveTeal
        case .activating, .deactivating, .reasserting, .restarting, .waiting:
            return WireRouteAppearance.warningAmber
        case .inactive:
            return isOnDemandEngaged ? WireRouteAppearance.warningAmber : .secondaryLabel
        }
    }

    private func updateCardInteractionAppearance(animated: Bool) {
        let isPressed = isHighlighted
        let isChosen = isSelected
        let changes = {
            self.cardView.transform = isPressed ? CGAffineTransform(scaleX: 0.988, y: 0.988) : .identity
            self.cardView.layer.borderColor = isChosen
                ? WireRouteAppearance.signalBlue.cgColor
                : self.cardBorderColor.cgColor
            self.cardView.layer.shadowOpacity = isPressed ? 0.16 : 0.3
            self.cardView.backgroundColor = isChosen
                ? WireRouteAppearance.signalBlue.withAlphaComponent(0.13)
                : WireRouteAppearance.card
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: changes
            )
        } else {
            changes()
        }
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
