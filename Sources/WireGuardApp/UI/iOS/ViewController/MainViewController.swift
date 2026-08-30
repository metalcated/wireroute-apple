// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

private enum WireRouteMainTab: Int {
    case home
    case profiles
    case activity
    case settings
}

private final class WireRouteProfilesSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    let tunnelsListViewController: TunnelsListTableViewController

    init(tunnelsListViewController: TunnelsListTableViewController) {
        self.tunnelsListViewController = tunnelsListViewController

        let listNavigationController = UINavigationController(rootViewController: tunnelsListViewController)
        let emptyDetailViewController = UIViewController()
        emptyDetailViewController.view.backgroundColor = WireRouteAppearance.background
        let detailNavigationController = UINavigationController(rootViewController: emptyDetailViewController)

        super.init(nibName: nil, bundle: nil)

        viewControllers = [listNavigationController, detailNavigationController]
        preferredDisplayMode = .oneBesideSecondary
        delegate = self
        restorationIdentifier = "ProfilesSplitVC"
        listNavigationController.restorationIdentifier = "MasterNC"
        detailNavigationController.restorationIdentifier = "DetailNC"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        collapseSecondary secondaryViewController: UIViewController,
        onto primaryViewController: UIViewController
    ) -> Bool {
        let detailViewController = (secondaryViewController as? UINavigationController)?.viewControllers.first
        return detailViewController.map { type(of: $0) == UIViewController.self } ?? true
    }
}

private final class WireRoutePathNodeView: UIView {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()

    init(symbolName: String, title: String) {
        super.init(frame: .zero)

        imageView.image = UIImage(systemName: symbolName)
        imageView.tintColor = WireRouteAppearance.signalBlue
        imageView.contentMode = .scaleAspectFit

        titleLabel.text = title
        titleLabel.font = WireRouteAppearance.roundedFont(size: 12, weight: .semibold, textStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.textColor = .secondaryLabel

        let iconBackground = UIView()
        iconBackground.backgroundColor = WireRouteAppearance.raised
        iconBackground.layer.cornerRadius = 22
        iconBackground.layer.cornerCurve = .continuous
        iconBackground.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconBackground, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconBackground.widthAnchor.constraint(equalToConstant: 44),
            iconBackground.heightAnchor.constraint(equalToConstant: 44),
            imageView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ isActive: Bool) {
        imageView.tintColor = isActive ? WireRouteAppearance.liveTeal : WireRouteAppearance.signalBlue
    }
}

private final class WireRoutePathView: UIView {
    private let deviceNode = WireRoutePathNodeView(symbolName: "iphone", title: tr("iosHomePathDevice"))
    private let vpnNode = WireRoutePathNodeView(symbolName: "shield.lefthalf.filled", title: tr("iosHomePathVPN"))
    private let endpointNode = WireRoutePathNodeView(symbolName: "network", title: tr("iosHomePathEndpoint"))
    private let firstLine = UIView()
    private let secondLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        [firstLine, secondLine].forEach {
            $0.backgroundColor = WireRouteAppearance.border
            $0.heightAnchor.constraint(equalToConstant: 2).isActive = true
        }

        let stack = UIStackView(arrangedSubviews: [deviceNode, firstLine, vpnNode, secondLine, endpointNode])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = 10
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            firstLine.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            secondLine.widthAnchor.constraint(equalTo: firstLine.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setConnected(_ isConnected: Bool) {
        let color = isConnected ? WireRouteAppearance.liveTeal : WireRouteAppearance.border
        firstLine.backgroundColor = color
        secondLine.backgroundColor = color
        deviceNode.setActive(isConnected)
        vpnNode.setActive(isConnected)
        endpointNode.setActive(isConnected)
    }
}

private final class WireRouteDepthCardView: UIView {
    enum Elevation {
        case standard
        case hero

        var shadowOpacity: Float {
            switch self {
            case .standard: return 0.34
            case .hero: return 0.46
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .standard: return 14
            case .hero: return 22
            }
        }

        var shadowOffset: CGSize {
            switch self {
            case .standard: return CGSize(width: 0, height: 8)
            case .hero: return CGSize(width: 0, height: 14)
            }
        }

        var surfaceColor: UIColor {
            switch self {
            case .standard: return WireRouteAppearance.card
            case .hero: return WireRouteAppearance.raised
            }
        }
    }

    private let surfaceLayer = CALayer()
    private let rimLayer = CAShapeLayer()
    private let topEdgeLayer = CAShapeLayer()
    private let bottomEdgeLayer = CAShapeLayer()
    private let elevation: Elevation

    init(elevation: Elevation) {
        self.elevation = elevation
        super.init(frame: .zero)

        backgroundColor = .clear
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = elevation.shadowOpacity
        layer.shadowRadius = elevation.shadowRadius
        layer.shadowOffset = elevation.shadowOffset

        surfaceLayer.backgroundColor = elevation.surfaceColor.cgColor
        surfaceLayer.cornerRadius = 20
        surfaceLayer.cornerCurve = .continuous

        rimLayer.fillColor = UIColor.clear.cgColor
        rimLayer.strokeColor = WireRouteAppearance.border.withAlphaComponent(0.78).cgColor
        rimLayer.lineWidth = 1

        topEdgeLayer.fillColor = UIColor.clear.cgColor
        topEdgeLayer.strokeColor = UIColor.white.withAlphaComponent(elevation == .hero ? 0.18 : 0.12).cgColor
        topEdgeLayer.lineWidth = 1
        topEdgeLayer.lineCap = .round

        bottomEdgeLayer.fillColor = UIColor.clear.cgColor
        bottomEdgeLayer.strokeColor = UIColor.black.withAlphaComponent(elevation == .hero ? 0.34 : 0.24).cgColor
        bottomEdgeLayer.lineWidth = 1
        bottomEdgeLayer.lineCap = .round

        layer.insertSublayer(surfaceLayer, at: 0)
        layer.insertSublayer(rimLayer, above: surfaceLayer)
        layer.insertSublayer(topEdgeLayer, above: rimLayer)
        layer.insertSublayer(bottomEdgeLayer, above: topEdgeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        surfaceLayer.frame = bounds
        rimLayer.frame = bounds
        topEdgeLayer.frame = bounds
        bottomEdgeLayer.frame = bounds
        let rimRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        rimLayer.path = UIBezierPath(roundedRect: rimRect, cornerRadius: 19.5).cgPath

        let topEdgePath = UIBezierPath()
        topEdgePath.move(to: CGPoint(x: 20, y: 1))
        topEdgePath.addLine(to: CGPoint(x: max(20, bounds.width - 20), y: 1))
        topEdgeLayer.path = topEdgePath.cgPath

        let bottomEdgePath = UIBezierPath()
        bottomEdgePath.move(to: CGPoint(x: 20, y: max(1, bounds.height - 1)))
        bottomEdgePath.addLine(to: CGPoint(x: max(20, bounds.width - 20), y: max(1, bounds.height - 1)))
        bottomEdgeLayer.path = bottomEdgePath.cgPath
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 20).cgPath
    }
}

@MainActor
private final class WireRouteHomeViewController: UIViewController {
    var onShowProfiles: (() -> Void)?
    var onAddProfile: (() -> Void)?
    var onShowProfileDetail: ((TunnelContainer) -> Void)?
    var onShowActivity: ((TunnelContainer) -> Void)?

    private var tunnelsManager: TunnelsManager?
    private var selectedTunnel: TunnelContainer?
    private var statusObservation: NSKeyValueObservation?
    private var refreshTimer: Timer?

    private let profileButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let statusDot = UIView()
    private let routePathView = WireRoutePathView()
    private let connectionButton = UIButton(type: .system)
    private let routingValueLabel = UILabel()
    private let dnsValueLabel = UILabel()
    private let endpointValueLabel = UILabel()
    private let transferValueLabel = UILabel()
    private let profileActionButton = UIButton(type: .system)
    private let activityActionButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private let emptyStateStack = UIStackView()
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    override func loadView() {
        view = UIView()
        view.backgroundColor = WireRouteAppearance.background

        let titleLabel = UILabel()
        titleLabel.text = tr("iosHomeTitle")
        titleLabel.font = WireRouteAppearance.roundedFont(size: 38, weight: .bold, textStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true

        let subtitleLabel = UILabel()
        subtitleLabel.text = tr("iosHomeSubtitle")
        subtitleLabel.font = UIFont.preferredFont(forTextStyle: .body)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        var profileConfiguration = UIButton.Configuration.plain()
        profileConfiguration.image = UIImage(systemName: "chevron.down")
        profileConfiguration.imagePlacement = .trailing
        profileConfiguration.imagePadding = 8
        profileConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        profileConfiguration.baseForegroundColor = .label
        profileButton.configuration = profileConfiguration
        profileButton.contentHorizontalAlignment = .leading

        statusDot.backgroundColor = .secondaryLabel
        statusDot.layer.cornerRadius = 5
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel.font = WireRouteAppearance.roundedFont(size: 14, weight: .semibold, textStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        let statusStack = UIStackView(arrangedSubviews: [statusDot, statusLabel, UIView()])
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 8

        let connectionHeader = UIStackView(arrangedSubviews: [profileButton, statusStack])
        connectionHeader.axis = .vertical
        connectionHeader.spacing = 8

        configureConnectionButton()

        let connectionContent = UIStackView(arrangedSubviews: [connectionHeader, routePathView, connectionButton])
        connectionContent.axis = .vertical
        connectionContent.spacing = 22
        let connectionCard = makeCard(containing: connectionContent, inset: 20, elevation: .hero)

        let routingCard = makeSummaryCard(
            title: tr("iosHomeRouting"),
            symbolName: "arrow.triangle.branch",
            valueLabel: routingValueLabel
        )
        let dnsCard = makeSummaryCard(
            title: tr("dnsProtectionTitle"),
            symbolName: "lock.shield",
            valueLabel: dnsValueLabel
        )
        let summaryRow = UIStackView(arrangedSubviews: [routingCard, dnsCard])
        summaryRow.axis = .horizontal
        summaryRow.distribution = .fillEqually
        summaryRow.alignment = .fill
        summaryRow.spacing = 12

        let endpointCard = makeDetailCard(
            title: tr("iosHomeEndpoint"),
            symbolName: "network",
            valueLabel: endpointValueLabel
        )
        let transferCard = makeDetailCard(
            title: tr("iosHomeTransfer"),
            symbolName: "arrow.down.arrow.up",
            valueLabel: transferValueLabel
        )

        configureQuickAction(profileActionButton, title: tr("iosHomeProfileDetails"), symbolName: "slider.horizontal.3")
        configureQuickAction(activityActionButton, title: tr("iosHomeViewActivity"), symbolName: "chart.xyaxis.line")
        profileActionButton.addTarget(self, action: #selector(profileActionTapped), for: .touchUpInside)
        activityActionButton.addTarget(self, action: #selector(activityActionTapped), for: .touchUpInside)
        let actionRow = UIStackView(arrangedSubviews: [profileActionButton, activityActionButton])
        actionRow.axis = .horizontal
        actionRow.distribution = .fillEqually
        actionRow.spacing = 12

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.addArrangedSubview(connectionCard)
        contentStack.addArrangedSubview(summaryRow)
        contentStack.addArrangedSubview(endpointCard)
        contentStack.addArrangedSubview(transferCard)
        contentStack.addArrangedSubview(actionRow)

        let emptyTitle = UILabel()
        emptyTitle.text = tr("iosHomeNoProfiles")
        emptyTitle.font = WireRouteAppearance.roundedFont(size: 24, weight: .bold, textStyle: .title2)
        emptyTitle.adjustsFontForContentSizeCategory = true
        emptyTitle.textAlignment = .center
        let emptyDescription = UILabel()
        emptyDescription.text = tr("iosHomeNoProfilesDescription")
        emptyDescription.font = UIFont.preferredFont(forTextStyle: .body)
        emptyDescription.adjustsFontForContentSizeCategory = true
        emptyDescription.textColor = .secondaryLabel
        emptyDescription.textAlignment = .center
        emptyDescription.numberOfLines = 0
        let addButton = UIButton(type: .system)
        var addConfiguration = UIButton.Configuration.filled()
        addConfiguration.title = tr("iosHomeAddProfile")
        addConfiguration.image = UIImage(systemName: "plus")
        addConfiguration.imagePadding = 8
        addConfiguration.baseBackgroundColor = WireRouteAppearance.signalBlue
        addConfiguration.baseForegroundColor = .white
        addConfiguration.cornerStyle = .large
        addConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        addButton.configuration = addConfiguration
        addButton.addTarget(self, action: #selector(addProfileTapped), for: .touchUpInside)
        let emptyIcon = UIImageView(image: UIImage(systemName: "point.3.connected.trianglepath.dotted"))
        emptyIcon.tintColor = WireRouteAppearance.signalBlue
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.heightAnchor.constraint(equalToConstant: 60).isActive = true
        emptyStateStack.axis = .vertical
        emptyStateStack.alignment = .center
        emptyStateStack.spacing = 14
        emptyStateStack.addArrangedSubview(emptyIcon)
        emptyStateStack.addArrangedSubview(emptyTitle)
        emptyStateStack.addArrangedSubview(emptyDescription)
        emptyStateStack.addArrangedSubview(addButton)
        emptyStateStack.setCustomSpacing(22, after: emptyDescription)

        let rootStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, contentStack, emptyStateStack])
        rootStack.axis = .vertical
        rootStack.spacing = 10
        rootStack.setCustomSpacing(24, after: subtitleLabel)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(rootStack)
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -30),
            rootStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        resolveSelection(preferredTunnel: selectedTunnel)
        startRefreshing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func setTunnelsManager(_ tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        resolveSelection(preferredTunnel: selectedTunnel)
    }

    func selectTunnel(_ tunnel: TunnelContainer?) {
        resolveSelection(preferredTunnel: tunnel)
    }

    func reloadTunnels() {
        resolveSelection(preferredTunnel: selectedTunnel)
    }

    private func allTunnels() -> [TunnelContainer] {
        guard let tunnelsManager else { return [] }
        return (0 ..< tunnelsManager.numberOfTunnels()).map { tunnelsManager.tunnel(at: $0) }
    }

    private func resolveSelection(preferredTunnel: TunnelContainer?) {
        let tunnels = allTunnels()
        let savedName = UserDefaults.standard.string(forKey: "WireRoute.iOS.selectedProfile")
        let resolvedTunnel: TunnelContainer?
        if let preferredTunnel, tunnels.contains(where: { $0 === preferredTunnel }) {
            resolvedTunnel = preferredTunnel
        } else if let activeTunnel = tunnels.first(where: { $0.status != .inactive }) {
            resolvedTunnel = activeTunnel
        } else if let savedName, let savedTunnel = tunnels.first(where: { $0.name == savedName }) {
            resolvedTunnel = savedTunnel
        } else {
            resolvedTunnel = tunnels.first
        }

        if selectedTunnel !== resolvedTunnel {
            selectedTunnel = resolvedTunnel
            observeSelectedTunnel()
        }
        if let resolvedTunnel {
            UserDefaults.standard.set(resolvedTunnel.name, forKey: "WireRoute.iOS.selectedProfile")
        }
        updateProfileMenu(tunnels: tunnels)
        render()
    }

    private func observeSelectedTunnel() {
        statusObservation = selectedTunnel?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.render()
            }
        }
    }

    private func updateProfileMenu(tunnels: [TunnelContainer]) {
        let actions = tunnels.map { tunnel in
            UIAction(title: tunnel.name, state: tunnel === selectedTunnel ? .on : .off) { [weak self] _ in
                self?.selectTunnel(tunnel)
            }
        }
        profileButton.menu = UIMenu(title: tr("iosHomeChooseProfile"), children: actions)
        profileButton.showsMenuAsPrimaryAction = true
    }

    private func startRefreshing() {
        render()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLiveTransfer() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func render() {
        guard let tunnel = selectedTunnel else {
            contentStack.isHidden = true
            emptyStateStack.isHidden = false
            return
        }

        contentStack.isHidden = false
        emptyStateStack.isHidden = true
        profileButton.configuration?.title = tunnel.name
        statusLabel.text = statusText(for: tunnel.status)
        statusDot.backgroundColor = statusColor(for: tunnel.status)
        routePathView.setConnected(tunnel.status == .active)

        connectionButton.configuration?.title = connectionButtonTitle(for: tunnel.status)
        connectionButton.configuration?.baseBackgroundColor = tunnel.status == .active
            ? WireRouteAppearance.raised
            : WireRouteAppearance.signalBlue
        connectionButton.isEnabled = tunnel.status == .inactive || tunnel.status == .active

        routingValueLabel.text = tunnel.routingMode == .full
            ? tr("tunnelRoutingFullTunnel")
            : tr("iosHomeSplitTunnel")

        let configuration = tunnel.tunnelConfiguration
        let policy = tunnel.dnsProtectionPolicy
        let dnsDetails: String
        if policy.mode == .profile {
            let servers = configuration?.interface.dns.map(\.stringRepresentation) ?? []
            dnsDetails = servers.isEmpty ? tr("iosHomeNotConfigured") : servers.joined(separator: ", ")
        } else {
            dnsDetails = policy.serverURL?.host ?? policy.localizedTitle
        }
        dnsValueLabel.text = "\(policy.localizedTitle)\n\(dnsDetails)"

        endpointValueLabel.text = configuration?.peers.compactMap { $0.endpoint?.stringRepresentation }.first
            ?? tr("iosHomeNotConfigured")
        transferValueLabel.text = tr("iosHomeNoLiveTransfer")
        refreshLiveTransfer()
    }

    private func refreshLiveTransfer() {
        guard let tunnel = selectedTunnel, tunnel.status == .active else { return }
        tunnel.getRuntimeTunnelConfiguration { [weak self] configuration in
            guard let self, let configuration else { return }
            let received = configuration.peers.reduce(UInt64(0)) { partial, peer in
                let (sum, overflow) = partial.addingReportingOverflow(peer.rxBytes ?? 0)
                return overflow ? .max : sum
            }
            let sent = configuration.peers.reduce(UInt64(0)) { partial, peer in
                let (sum, overflow) = partial.addingReportingOverflow(peer.txBytes ?? 0)
                return overflow ? .max : sum
            }
            self.transferValueLabel.text = "↓ \(self.formatBytes(received))   ↑ \(self.formatBytes(sent))"
        }
    }

    private func configureConnectionButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = WireRouteAppearance.signalBlue
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        connectionButton.configuration = configuration
        connectionButton.addTarget(self, action: #selector(connectionButtonTapped), for: .touchUpInside)
    }

    private func configureQuickAction(_ button: UIButton, title: String, symbolName: String) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbolName)
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = WireRouteAppearance.raised
        configuration.baseForegroundColor = WireRouteAppearance.signalBlue
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 10, bottom: 13, trailing: 10)
        button.configuration = configuration
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.24
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 5)
    }

    private func makeSummaryCard(title: String, symbolName: String, valueLabel: UILabel) -> UIView {
        let symbol = UIImageView(image: UIImage(systemName: symbolName))
        symbol.tintColor = WireRouteAppearance.signalBlue
        symbol.contentMode = .scaleAspectFit
        symbol.widthAnchor.constraint(equalToConstant: 22).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let titleLabel = makeLabel(title, style: .caption1, color: .secondaryLabel)
        let heading = UIStackView(arrangedSubviews: [symbol, titleLabel, UIView()])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 8
        valueLabel.font = WireRouteAppearance.roundedFont(size: 16, weight: .regular, textStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.numberOfLines = 3
        valueLabel.lineBreakMode = .byTruncatingTail
        let content = UIStackView(arrangedSubviews: [heading, valueLabel])
        content.axis = .vertical
        content.spacing = 12
        return makeCard(containing: content, inset: 16, elevation: .standard)
    }

    private func makeDetailCard(title: String, symbolName: String, valueLabel: UILabel) -> UIView {
        let symbol = UIImageView(image: UIImage(systemName: symbolName))
        symbol.tintColor = WireRouteAppearance.signalBlue
        symbol.contentMode = .scaleAspectFit
        symbol.widthAnchor.constraint(equalToConstant: 24).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let titleLabel = makeLabel(title, style: .caption1, color: .secondaryLabel)
        valueLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.numberOfLines = 2
        valueLabel.textAlignment = .right
        let labels = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        labels.axis = .vertical
        labels.spacing = 4
        labels.alignment = .trailing
        let row = UIStackView(arrangedSubviews: [symbol, labels])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        return makeCard(containing: row, inset: 16, elevation: .standard)
    }

    private func makeCard(
        containing content: UIView,
        inset: CGFloat,
        elevation: WireRouteDepthCardView.Elevation
    ) -> UIView {
        let card = WireRouteDepthCardView(elevation: elevation)
        card.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset)
        ])
        return card
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        return label
    }

    private func statusText(for status: TunnelStatus) -> String {
        switch status {
        case .inactive: return tr("tunnelStatusInactive")
        case .activating: return tr("tunnelStatusActivating")
        case .active: return tr("tunnelStatusActive")
        case .deactivating: return tr("tunnelStatusDeactivating")
        case .reasserting: return tr("tunnelStatusReasserting")
        case .restarting: return tr("tunnelStatusRestarting")
        case .waiting: return tr("tunnelStatusWaiting")
        }
    }

    private func statusColor(for status: TunnelStatus) -> UIColor {
        switch status {
        case .active: return WireRouteAppearance.liveTeal
        case .activating, .deactivating, .reasserting, .restarting, .waiting: return WireRouteAppearance.warningAmber
        case .inactive: return .secondaryLabel
        }
    }

    private func connectionButtonTitle(for status: TunnelStatus) -> String {
        switch status {
        case .active: return tr("iosHomeDisconnect")
        case .inactive: return tr("iosHomeConnect")
        default: return statusText(for: status)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    @objc private func connectionButtonTapped() {
        guard let tunnelsManager, let tunnel = selectedTunnel else { return }
        switch tunnel.status {
        case .inactive:
            tunnelsManager.startActivation(of: tunnel)
        case .active:
            if tunnel.isActivateOnDemandEnabled {
                tunnelsManager.setOnDemandEnabled(false, on: tunnel) { [weak self] error in
                    if error == nil {
                        self?.tunnelsManager?.startDeactivation(of: tunnel)
                    }
                }
            } else {
                tunnelsManager.startDeactivation(of: tunnel)
            }
        default:
            break
        }
    }

    @objc private func profileActionTapped() {
        guard let selectedTunnel else { return }
        onShowProfileDetail?(selectedTunnel)
    }

    @objc private func activityActionTapped() {
        guard let selectedTunnel else { return }
        onShowActivity?(selectedTunnel)
    }

    @objc private func addProfileTapped() {
        onAddProfile?()
    }
}

@MainActor
private final class WireRouteActivityDashboardViewController: UIViewController {
    private var tunnelsManager: TunnelsManager?
    private var selectedTunnel: TunnelContainer?
    private var monitorViewController: ActivityMonitorViewController?
    private let profileButton = UIButton(type: .system)
    private let monitorContainer = UIView()
    private let emptyLabel = UILabel()

    override func loadView() {
        view = UIView()
        view.backgroundColor = WireRouteAppearance.background

        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = WireRouteAppearance.raised
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        profileButton.configuration = configuration
        profileButton.contentHorizontalAlignment = .leading

        emptyLabel.text = tr("iosActivityNoProfiles")
        emptyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center

        view.addSubview(profileButton)
        view.addSubview(monitorContainer)
        view.addSubview(emptyLabel)
        profileButton.translatesAutoresizingMaskIntoConstraints = false
        monitorContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            profileButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            profileButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            profileButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            monitorContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            monitorContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            monitorContainer.topAnchor.constraint(equalTo: profileButton.bottomAnchor, constant: 4),
            monitorContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("activityTitle")
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
    }

    func setTunnelsManager(_ tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        reloadTunnels()
    }

    func selectTunnel(_ tunnel: TunnelContainer?) {
        rebuildMonitor(for: tunnel)
    }

    func reloadTunnels() {
        let tunnels = allTunnels()
        let selected = selectedTunnel.flatMap { current in
            tunnels.first(where: { $0 === current })
        } ?? tunnels.first(where: { $0.status != .inactive }) ?? tunnels.first
        updateProfileMenu(tunnels)
        rebuildMonitor(for: selected)
    }

    private func allTunnels() -> [TunnelContainer] {
        guard let tunnelsManager else { return [] }
        return (0 ..< tunnelsManager.numberOfTunnels()).map { tunnelsManager.tunnel(at: $0) }
    }

    private func updateProfileMenu(_ tunnels: [TunnelContainer]) {
        let actions = tunnels.map { tunnel in
            UIAction(title: tunnel.name, state: tunnel === selectedTunnel ? .on : .off) { [weak self] _ in
                self?.selectTunnel(tunnel)
            }
        }
        profileButton.menu = UIMenu(title: tr("iosHomeChooseProfile"), children: actions)
        profileButton.showsMenuAsPrimaryAction = true
    }

    private func rebuildMonitor(for tunnel: TunnelContainer?) {
        if selectedTunnel === tunnel, monitorViewController != nil {
            updateProfileMenu(allTunnels())
            return
        }

        if let monitorViewController {
            monitorViewController.willMove(toParent: nil)
            monitorViewController.view.removeFromSuperview()
            monitorViewController.removeFromParent()
        }
        monitorViewController = nil
        selectedTunnel = tunnel

        guard let tunnel else {
            profileButton.configuration?.title = tr("iosHomeNoProfiles")
            profileButton.isHidden = true
            monitorContainer.isHidden = true
            emptyLabel.isHidden = false
            navigationItem.rightBarButtonItem = nil
            updateProfileMenu([])
            return
        }

        profileButton.configuration?.title = tunnel.name
        profileButton.isHidden = false
        monitorContainer.isHidden = false
        emptyLabel.isHidden = true

        let monitor = ActivityMonitorViewController(tunnel: tunnel)
        addChild(monitor)
        monitor.loadViewIfNeeded()
        monitorContainer.addSubview(monitor.view)
        monitor.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            monitor.view.leadingAnchor.constraint(equalTo: monitorContainer.leadingAnchor),
            monitor.view.trailingAnchor.constraint(equalTo: monitorContainer.trailingAnchor),
            monitor.view.topAnchor.constraint(equalTo: monitorContainer.topAnchor),
            monitor.view.bottomAnchor.constraint(equalTo: monitorContainer.bottomAnchor)
        ])
        monitor.didMove(toParent: self)
        monitorViewController = monitor
        navigationItem.rightBarButtonItem = monitor.navigationItem.rightBarButtonItem
        updateProfileMenu(allTunnels())
    }
}

@MainActor
class MainViewController: UITabBarController {
    var tunnelsManager: TunnelsManager?
    var onTunnelsManagerReady: ((TunnelsManager) -> Void)?
    let tunnelsListVC: TunnelsListTableViewController

    private let homeViewController = WireRouteHomeViewController()
    private let activityViewController = WireRouteActivityDashboardViewController()
    private let settingsViewController = SettingsTableViewController(tunnelsManager: nil, showsDoneButton: false)
    private let profilesViewController: WireRouteProfilesSplitViewController

    init() {
        let tunnelsListViewController = TunnelsListTableViewController()
        tunnelsListVC = tunnelsListViewController
        profilesViewController = WireRouteProfilesSplitViewController(
            tunnelsListViewController: tunnelsListViewController
        )
        super.init(nibName: nil, bundle: nil)

        restorationIdentifier = "MainVC"
        configureTabs()
        configureNavigation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WireRouteAppearance.background

        tunnelsListVC.onTunnelSelected = { [weak self] tunnel in
            self?.homeViewController.selectTunnel(tunnel)
            self?.activityViewController.selectTunnel(tunnel)
        }
        tunnelsListVC.onTunnelListChanged = { [weak self] in
            self?.homeViewController.reloadTunnels()
            self?.activityViewController.reloadTunnels()
        }

        TunnelsManager.create { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                ErrorPresenter.showErrorAlert(error: error, from: self)
            case .success(let tunnelsManager):
                self.tunnelsManager = tunnelsManager
                self.tunnelsListVC.setTunnelsManager(tunnelsManager: tunnelsManager)
                self.homeViewController.setTunnelsManager(tunnelsManager)
                self.activityViewController.setTunnelsManager(tunnelsManager)
                self.settingsViewController.setTunnelsManager(tunnelsManager)
                tunnelsManager.activationDelegate = self
                self.onTunnelsManagerReady?(tunnelsManager)
                self.onTunnelsManagerReady = nil
            }
        }
    }

    private func configureTabs() {
        let homeNavigationController = UINavigationController(rootViewController: homeViewController)
        let activityNavigationController = UINavigationController(rootViewController: activityViewController)
        let settingsNavigationController = UINavigationController(rootViewController: settingsViewController)

        homeNavigationController.tabBarItem = UITabBarItem(
            title: tr("iosTabHome"),
            image: UIImage(systemName: "house"),
            selectedImage: UIImage(systemName: "house.fill")
        )
        profilesViewController.tabBarItem = UITabBarItem(
            title: tr("iosTabProfiles"),
            image: UIImage(systemName: "rectangle.stack"),
            selectedImage: UIImage(systemName: "rectangle.stack.fill")
        )
        activityNavigationController.tabBarItem = UITabBarItem(
            title: tr("iosTabActivity"),
            image: UIImage(systemName: "chart.xyaxis.line"),
            selectedImage: UIImage(systemName: "chart.xyaxis.line")
        )
        settingsNavigationController.tabBarItem = UITabBarItem(
            title: tr("iosTabSettings"),
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )
        viewControllers = [
            homeNavigationController,
            profilesViewController,
            activityNavigationController,
            settingsNavigationController
        ]
        selectedIndex = WireRouteMainTab.home.rawValue
    }

    private func configureNavigation() {
        homeViewController.onShowProfiles = { [weak self] in
            self?.selectedIndex = WireRouteMainTab.profiles.rawValue
        }
        homeViewController.onAddProfile = { [weak self] in
            guard let self else { return }
            self.selectedIndex = WireRouteMainTab.profiles.rawValue
            self.tunnelsListVC.addButtonTapped(sender: self.tunnelsListVC.navigationItem.rightBarButtonItem ?? self.tunnelsListVC.view)
        }
        homeViewController.onShowProfileDetail = { [weak self] tunnel in
            self?.showTunnelDetail(tunnel, animated: true)
        }
        homeViewController.onShowActivity = { [weak self] tunnel in
            self?.activityViewController.selectTunnel(tunnel)
            self?.selectedIndex = WireRouteMainTab.activity.rawValue
        }
    }

    private func showTunnelDetail(_ tunnel: TunnelContainer, animated: Bool) {
        homeViewController.selectTunnel(tunnel)
        activityViewController.selectTunnel(tunnel)
        selectedIndex = WireRouteMainTab.profiles.rawValue
        tunnelsListVC.showTunnelDetail(for: tunnel, animated: animated)
    }

    func allTunnelNames() -> [String]? {
        tunnelsManager?.mapTunnels { $0.name }
    }
}

extension MainViewController: TunnelsManagerActivationDelegate {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {
        ErrorPresenter.showErrorAlert(error: error, from: self)
    }

    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {
        homeViewController.selectTunnel(tunnel)
        activityViewController.selectTunnel(tunnel)
    }

    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        ErrorPresenter.showErrorAlert(error: error, from: self)
    }

    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        homeViewController.selectTunnel(tunnel)
        activityViewController.selectTunnel(tunnel)
    }
}

extension MainViewController {
    func refreshTunnelConnectionStatuses() {
        tunnelsManager?.refreshStatuses()
        homeViewController.reloadTunnels()
        activityViewController.reloadTunnels()
    }

    func showTunnelDetailForTunnel(named tunnelName: String, animated: Bool, shouldToggleStatus: Bool) {
        let showTunnelDetailBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            guard let self, let tunnel = tunnelsManager.tunnel(named: tunnelName) else { return }
            self.showTunnelDetail(tunnel, animated: animated)
            if shouldToggleStatus {
                if tunnel.status == .inactive {
                    tunnelsManager.startActivation(of: tunnel)
                } else if tunnel.status == .active {
                    tunnelsManager.startDeactivation(of: tunnel)
                }
            }
        }
        if let tunnelsManager {
            showTunnelDetailBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = showTunnelDetailBlock
        }
    }

    func importFromDisposableFile(url: URL) {
        let importFromFileBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            TunnelImporter.importFromFile(
                urls: [url],
                into: tunnelsManager,
                sourceVC: self,
                errorPresenterType: ErrorPresenter.self
            ) {
                _ = FileManager.deleteFile(at: url)
            }
        }
        if let tunnelsManager {
            importFromFileBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = importFromFileBlock
        }
    }
}
