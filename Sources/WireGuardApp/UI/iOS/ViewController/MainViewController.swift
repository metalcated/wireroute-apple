// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import MapKit
import Network

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
private final class WireRouteLegacyHomeViewController: UIViewController {
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

private struct WireRouteEndpointLocation: Sendable {
    let latitude: Double
    let longitude: Double
    let city: String?
    let region: String?
    let country: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        let components = [city, region, country].compactMap { $0 }
        var uniqueComponents = [String]()
        for component in components where !component.isEmpty {
            if !uniqueComponents.contains(component) {
                uniqueComponents.append(component)
            }
        }
        return uniqueComponents.joined(separator: ", ")
    }
}

private enum WireRouteEndpointLocationService {
    private struct Response: Decodable, Sendable {
        let success: Bool?
        let city: String?
        let region: String?
        let country: String?
        let latitude: Double?
        let longitude: Double?
    }

    enum LookupError: LocalizedError, Sendable {
        case unavailable
        case privateAddress
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable: return tr("iosHomeLocationRequiresAddress")
            case .privateAddress: return tr("iosHomeLocationPrivateAddress")
            case .invalidResponse: return tr("iosHomeLocationLookupFailed")
            }
        }
    }

    static func locate(_ endpoint: Endpoint) async throws -> WireRouteEndpointLocation {
        let resolvedEndpoint: Endpoint
        do {
            resolvedEndpoint = try await Task.detached(priority: .userInitiated) {
                try endpoint.resolvedForEndpointLocation()
            }.value
        } catch {
            throw LookupError.unavailable
        }
        guard let address = publicAddress(from: resolvedEndpoint) else {
            throw LookupError.privateAddress
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "ipwho.is"
        components.path = "/\(address)"
        guard let url = components.url else {
            throw LookupError.unavailable
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw LookupError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.success == true,
              let latitude = decoded.latitude,
              let longitude = decoded.longitude,
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude) else {
            throw LookupError.invalidResponse
        }

        return WireRouteEndpointLocation(
            latitude: latitude,
            longitude: longitude,
            city: decoded.city,
            region: decoded.region,
            country: decoded.country
        )
    }

    private static func publicAddress(from endpoint: Endpoint) -> String? {
        switch endpoint.host {
        case .name:
            return nil
        case .ipv4(let address):
            return isPublicIPv4(address) ? "\(address)" : nil
        case .ipv6(let address):
            return isPublicIPv6(address) ? "\(address)" : nil
        @unknown default:
            return nil
        }
    }

    private static func isPublicIPv4(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }

        if bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 { return false }
        if bytes[0] == 100, (64 ... 127).contains(bytes[1]) { return false }
        if bytes[0] == 169, bytes[1] == 254 { return false }
        if bytes[0] == 172, (16 ... 31).contains(bytes[1]) { return false }
        if bytes[0] == 192, bytes[1] == 168 { return false }
        if bytes[0] == 192, bytes[1] == 0, bytes[2] == 2 { return false }
        if bytes[0] == 198, (18 ... 19).contains(bytes[1]) { return false }
        if bytes[0] == 198, bytes[1] == 51, bytes[2] == 100 { return false }
        if bytes[0] == 203, bytes[1] == 0, bytes[2] == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ address: IPv6Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 16 else { return false }

        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff,
           let mappedAddress = IPv4Address(Data(bytes.suffix(4))) {
            return isPublicIPv4(mappedAddress)
        }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return false }
        return true
    }
}

private final class WireRouteEndpointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(location: WireRouteEndpointLocation) {
        coordinate = location.coordinate
        title = location.displayName
        subtitle = tr("iosHomeLocationApproximate")
    }
}

@MainActor
private final class WireRouteHomeViewController: UIViewController, MKMapViewDelegate {
    var onShowProfiles: (() -> Void)?
    var onAddProfile: (() -> Void)?
    var onShowProfileDetail: ((TunnelContainer) -> Void)?
    var onShowActivity: ((TunnelContainer) -> Void)?

    private var tunnelsManager: TunnelsManager?
    private var selectedTunnel: TunnelContainer?
    private var statusObservation: NSKeyValueObservation?
    private var currentEndpoint: Endpoint?
    private var currentEndpointKey: String?
    private var locatedEndpointKey: String?
    private var locationLookupTask: Task<Void, Never>?
    private var approvedLocationLookup = false

    private let mapView = MKMapView()
    private let mapLocationLabel = UILabel()
    private let locationButton = UIButton(type: .system)
    private let profileButton = UIButton(type: .system)
    private let profileDetailsButton = UIButton(type: .system)
    private let statusImageView = UIImageView()
    private let statusLabel = UILabel()
    private let endpointValueLabel = UILabel()
    private let routingValueLabel = UILabel()
    private let dnsValueLabel = UILabel()
    private let connectionButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private let emptyStateStack = UIStackView()

    override func loadView() {
        view = UIView()
        view.backgroundColor = WireRouteAppearance.background

        let brandLabel = UILabel()
        brandLabel.text = tr("iosHomeTitle")
        brandLabel.font = WireRouteAppearance.roundedFont(size: 30, weight: .semibold, textStyle: .largeTitle)
        brandLabel.adjustsFontForContentSizeCategory = true

        statusImageView.image = UIImage(systemName: "lock.open")
        statusImageView.contentMode = .scaleAspectFit
        statusImageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        statusImageView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        statusLabel.font = WireRouteAppearance.roundedFont(size: 14, weight: .medium, textStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        let statusStack = UIStackView(arrangedSubviews: [statusImageView, statusLabel])
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 7
        let statusPill = UIView()
        statusPill.backgroundColor = WireRouteAppearance.card
        statusPill.layer.cornerRadius = 18
        statusPill.layer.cornerCurve = .continuous
        statusPill.layer.borderWidth = 1
        statusPill.layer.borderColor = WireRouteAppearance.border.withAlphaComponent(0.7).cgColor
        statusPill.addSubview(statusStack)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 12),
            statusStack.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -12),
            statusStack.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 8),
            statusStack.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -8)
        ])

        let header = UIStackView(arrangedSubviews: [brandLabel, UIView(), statusPill])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12

        configureMap()
        let mapContainer = UIView()
        mapContainer.backgroundColor = WireRouteAppearance.card
        mapContainer.layer.cornerRadius = 28
        mapContainer.layer.cornerCurve = .continuous
        mapContainer.layer.masksToBounds = true
        mapContainer.layer.borderWidth = 1
        mapContainer.layer.borderColor = WireRouteAppearance.border.withAlphaComponent(0.65).cgColor
        mapContainer.addSubview(mapView)
        mapView.translatesAutoresizingMaskIntoConstraints = false

        mapLocationLabel.text = tr("iosHomeMapWaiting")
        mapLocationLabel.font = WireRouteAppearance.roundedFont(size: 14, weight: .medium, textStyle: .subheadline)
        mapLocationLabel.adjustsFontForContentSizeCategory = true
        mapLocationLabel.textColor = .white
        mapLocationLabel.numberOfLines = 2
        mapLocationLabel.textAlignment = .center

        var locationConfiguration = UIButton.Configuration.tinted()
        locationConfiguration.title = tr("iosHomeLocateEndpoint")
        locationConfiguration.image = UIImage(systemName: "location.magnifyingglass")
        locationConfiguration.imagePadding = 7
        locationConfiguration.baseForegroundColor = .white
        locationConfiguration.baseBackgroundColor = WireRouteAppearance.signalBlue.withAlphaComponent(0.78)
        locationConfiguration.cornerStyle = .capsule
        locationConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
        locationButton.configuration = locationConfiguration
        locationButton.addTarget(self, action: #selector(locationButtonTapped), for: .touchUpInside)

        mapContainer.addSubview(mapLocationLabel)
        mapContainer.addSubview(locationButton)
        mapLocationLabel.translatesAutoresizingMaskIntoConstraints = false
        locationButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: mapContainer.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: mapContainer.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor),
            mapContainer.heightAnchor.constraint(equalToConstant: 365),
            mapLocationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: mapContainer.leadingAnchor, constant: 18),
            mapLocationLabel.trailingAnchor.constraint(lessThanOrEqualTo: mapContainer.trailingAnchor, constant: -18),
            mapLocationLabel.centerXAnchor.constraint(equalTo: mapContainer.centerXAnchor),
            mapLocationLabel.topAnchor.constraint(equalTo: mapContainer.topAnchor, constant: 16),
            mapLocationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            mapLocationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            locationButton.centerXAnchor.constraint(equalTo: mapContainer.centerXAnchor),
            locationButton.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor, constant: -16)
        ])

        var profileConfiguration = UIButton.Configuration.plain()
        profileConfiguration.image = UIImage(systemName: "chevron.down")
        profileConfiguration.imagePlacement = .trailing
        profileConfiguration.imagePadding = 8
        profileConfiguration.baseForegroundColor = .label
        profileConfiguration.contentInsets = .zero
        profileButton.configuration = profileConfiguration
        profileButton.contentHorizontalAlignment = .leading

        var detailsConfiguration = UIButton.Configuration.tinted()
        detailsConfiguration.image = UIImage(systemName: "slider.horizontal.3")
        detailsConfiguration.baseForegroundColor = WireRouteAppearance.signalBlue
        detailsConfiguration.baseBackgroundColor = WireRouteAppearance.signalBlue.withAlphaComponent(0.13)
        detailsConfiguration.cornerStyle = .capsule
        profileDetailsButton.configuration = detailsConfiguration
        profileDetailsButton.accessibilityLabel = tr("iosHomeProfileDetails")
        profileDetailsButton.addTarget(self, action: #selector(profileDetailsTapped), for: .touchUpInside)

        let profileRow = UIStackView(arrangedSubviews: [profileButton, UIView(), profileDetailsButton])
        profileRow.axis = .horizontal
        profileRow.alignment = .center
        profileRow.spacing = 12

        endpointValueLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        endpointValueLabel.adjustsFontForContentSizeCategory = true
        endpointValueLabel.textColor = .secondaryLabel
        endpointValueLabel.numberOfLines = 2

        let endpointTitle = makeLabel(tr("iosHomeEndpoint"), style: .caption1, color: .secondaryLabel)
        let endpointStack = UIStackView(arrangedSubviews: [endpointTitle, endpointValueLabel])
        endpointStack.axis = .vertical
        endpointStack.spacing = 4

        let summaryRow = UIStackView(arrangedSubviews: [
            makeSummary(title: tr("iosHomeRouting"), valueLabel: routingValueLabel),
            makeSummary(title: tr("dnsProtectionTitle"), valueLabel: dnsValueLabel)
        ])
        summaryRow.axis = .horizontal
        summaryRow.alignment = .top
        summaryRow.distribution = .fillEqually
        summaryRow.spacing = 18

        configureConnectionButton()
        let connectionContent = UIStackView(arrangedSubviews: [profileRow, endpointStack, summaryRow, connectionButton])
        connectionContent.axis = .vertical
        connectionContent.spacing = 18
        let connectionCard = makeDepthCard(containing: connectionContent)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.addArrangedSubview(mapContainer)
        contentStack.addArrangedSubview(connectionCard)

        let emptyIcon = UIImageView(image: UIImage(systemName: "point.3.connected.trianglepath.dotted"))
        emptyIcon.tintColor = WireRouteAppearance.signalBlue
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let emptyTitle = makeLabel(tr("iosHomeNoProfiles"), style: .title2, color: .label)
        emptyTitle.textAlignment = .center
        let emptyDescription = makeLabel(tr("iosHomeNoProfilesDescription"), style: .body, color: .secondaryLabel)
        emptyDescription.numberOfLines = 0
        emptyDescription.textAlignment = .center
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
        emptyStateStack.axis = .vertical
        emptyStateStack.alignment = .center
        emptyStateStack.spacing = 14
        emptyStateStack.addArrangedSubview(emptyIcon)
        emptyStateStack.addArrangedSubview(emptyTitle)
        emptyStateStack.addArrangedSubview(emptyDescription)
        emptyStateStack.addArrangedSubview(addButton)
        emptyStateStack.setCustomSpacing(22, after: emptyDescription)

        let rootStack = UIStackView(arrangedSubviews: [header, contentStack, emptyStateStack])
        rootStack.axis = .vertical
        rootStack.spacing = 18

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
            rootStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -30),
            rootStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        resolveSelection(preferredTunnel: selectedTunnel)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        locationLookupTask?.cancel()
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

    private func configureMap() {
        mapView.delegate = self
        mapView.overrideUserInterfaceStyle = .dark
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration
        showWorld(animated: false)
    }

    private func showWorld(animated: Bool) {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 18, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 125, longitudeDelta: 330)
        )
        mapView.setRegion(region, animated: animated)
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
        updateProfileMenu(tunnels)
        render()
    }

    private func observeSelectedTunnel() {
        statusObservation = selectedTunnel?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.render()
            }
        }
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

    private func render() {
        guard let tunnel = selectedTunnel else {
            contentStack.isHidden = true
            emptyStateStack.isHidden = false
            statusLabel.text = tr("iosHomeNoProfiles")
            statusImageView.image = UIImage(systemName: "lock.open")
            statusImageView.tintColor = .secondaryLabel
            mapLocationLabel.text = tr("iosHomeMapWaiting")
            resetLocatedEndpoint()
            return
        }

        contentStack.isHidden = false
        emptyStateStack.isHidden = true
        profileButton.configuration?.title = tunnel.name
        statusLabel.text = statusText(for: tunnel.status)
        statusImageView.image = UIImage(systemName: tunnel.status == .active ? "lock.fill" : "lock.open")
        statusImageView.tintColor = statusColor(for: tunnel.status)
        refreshEndpointMarker(for: tunnel.status)

        connectionButton.configuration?.title = connectionButtonTitle(for: tunnel.status)
        connectionButton.configuration?.image = UIImage(systemName: "power")
        connectionButton.configuration?.baseBackgroundColor = tunnel.status == .active
            ? WireRouteAppearance.raised
            : WireRouteAppearance.signalBlue
        connectionButton.configuration?.baseForegroundColor = tunnel.status == .active
            ? WireRouteAppearance.liveTeal
            : .white
        connectionButton.isEnabled = tunnel.status == .inactive || tunnel.status == .active

        routingValueLabel.text = tunnel.routingMode == .full
            ? tr("tunnelRoutingFullTunnel")
            : tr("iosHomeSplitTunnel")

        let configuration = tunnel.tunnelConfiguration
        let policy = tunnel.dnsProtectionPolicy
        if policy.mode == .profile {
            let servers = configuration?.interface.dns.map(\.stringRepresentation) ?? []
            dnsValueLabel.text = servers.isEmpty ? tr("iosHomeNotConfigured") : policy.localizedTitle
        } else {
            dnsValueLabel.text = policy.localizedTitle
        }

        let endpoint = configuration?.peers.compactMap(\.endpoint).first
        let endpointKey = endpoint?.stringRepresentation
        currentEndpoint = endpoint
        endpointValueLabel.text = endpointKey ?? tr("iosHomeNotConfigured")
        locationButton.isEnabled = endpoint != nil

        if endpointKey != currentEndpointKey {
            currentEndpointKey = endpointKey
            resetLocatedEndpoint()
        }
    }

    private func resetLocatedEndpoint() {
        locationLookupTask?.cancel()
        locationLookupTask = nil
        locatedEndpointKey = nil
        mapView.removeAnnotations(mapView.annotations)
        mapLocationLabel.text = currentEndpoint == nil ? tr("iosHomeMapWaiting") : tr("iosHomeMapReady")
        locationButton.configuration?.title = tr("iosHomeLocateEndpoint")
        locationButton.configuration?.image = UIImage(systemName: "location.magnifyingglass")
        locationButton.isEnabled = currentEndpoint != nil
        showWorld(animated: false)
    }

    private func beginLocationLookup() {
        guard let endpoint = currentEndpoint, let endpointKey = currentEndpointKey else { return }
        if locatedEndpointKey == endpointKey, let annotation = mapView.annotations.first {
            mapView.setRegion(region(around: annotation.coordinate), animated: true)
            return
        }

        locationLookupTask?.cancel()
        mapLocationLabel.text = tr("iosHomeLocationLoading")
        locationButton.configuration?.title = tr("iosHomeLocationLoadingShort")
        locationButton.configuration?.image = UIImage(systemName: "hourglass")
        locationButton.isEnabled = false

        locationLookupTask = Task { [weak self] in
            do {
                let location = try await WireRouteEndpointLocationService.locate(endpoint)
                guard !Task.isCancelled, let self, self.currentEndpointKey == endpointKey else { return }
                self.apply(location, endpointKey: endpointKey)
            } catch {
                guard !Task.isCancelled, let self, self.currentEndpointKey == endpointKey else { return }
                self.mapLocationLabel.text = (error as? LocalizedError)?.errorDescription
                    ?? tr("iosHomeLocationLookupFailed")
                self.locationButton.configuration?.title = tr("iosHomeTryLocationAgain")
                self.locationButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
                self.locationButton.isEnabled = true
            }
        }
    }

    private func apply(_ location: WireRouteEndpointLocation, endpointKey: String) {
        let annotation = WireRouteEndpointAnnotation(location: location)
        mapView.removeAnnotations(mapView.annotations)
        mapView.addAnnotation(annotation)
        mapView.setRegion(region(around: location.coordinate), animated: true)
        locatedEndpointKey = endpointKey
        let displayName = location.displayName.isEmpty ? tr("iosHomeEndpoint") : location.displayName
        mapLocationLabel.text = "\(displayName)\n\(tr("iosHomeLocationApproximate"))"
        locationButton.configuration?.title = tr("iosHomeRecenterEndpoint")
        locationButton.configuration?.image = UIImage(systemName: "scope")
        locationButton.isEnabled = true
    }

    private func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 7.5, longitudeDelta: 7.5)
        )
    }

    private func configureConnectionButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "power")
        configuration.imagePadding = 9
        configuration.baseBackgroundColor = WireRouteAppearance.signalBlue
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 24, bottom: 15, trailing: 24)
        connectionButton.configuration = configuration
        connectionButton.addTarget(self, action: #selector(connectionButtonTapped), for: .touchUpInside)
    }

    private func makeSummary(title: String, valueLabel: UILabel) -> UIView {
        let titleLabel = makeLabel(title, style: .caption1, color: .secondaryLabel)
        valueLabel.font = WireRouteAppearance.roundedFont(size: 15, weight: .regular, textStyle: .subheadline)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 5
        return stack
    }

    private func makeDepthCard(containing content: UIView) -> UIView {
        let card = WireRouteDepthCardView(elevation: .hero)
        card.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20)
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

    @objc private func locationButtonTapped() {
        guard currentEndpoint != nil else { return }
        if approvedLocationLookup {
            beginLocationLookup()
            return
        }

        let alert = UIAlertController(
            title: tr("iosHomeLocationConsentTitle"),
            message: tr("iosHomeLocationConsentMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: tr("iosHomeLocationNotNow"), style: .cancel))
        alert.addAction(UIAlertAction(title: tr("iosHomeLocationContinue"), style: .default) { [weak self] _ in
            self?.approvedLocationLookup = true
            self?.beginLocationLookup()
        })
        present(alert, animated: true)
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

    @objc private func profileDetailsTapped() {
        guard let selectedTunnel else { return }
        onShowProfileDetail?(selectedTunnel)
    }

    @objc private func addProfileTapped() {
        onAddProfile?()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        let identifier = "WireRouteEndpoint"
        let marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        marker.annotation = annotation
        configureEndpointMarker(marker, for: selectedTunnel?.status)
        marker.animatesWhenAdded = true
        marker.canShowCallout = true
        return marker
    }

    private func refreshEndpointMarker(for status: TunnelStatus) {
        for annotation in mapView.annotations {
            guard let marker = mapView.view(for: annotation) as? MKMarkerAnnotationView else { continue }
            configureEndpointMarker(marker, for: status)
        }
    }

    private func configureEndpointMarker(_ marker: MKMarkerAnnotationView, for status: TunnelStatus?) {
        marker.glyphTintColor = .white
        switch status {
        case .some(.active):
            marker.markerTintColor = WireRouteAppearance.liveTeal
            marker.glyphImage = UIImage(systemName: "lock.fill")
        case .some(.activating), .some(.deactivating), .some(.reasserting), .some(.restarting), .some(.waiting):
            marker.markerTintColor = WireRouteAppearance.warningAmber
            marker.glyphImage = UIImage(systemName: "arrow.triangle.2.circlepath")
        case .some(.inactive), .none:
            marker.markerTintColor = WireRouteAppearance.signalBlue
            marker.glyphImage = UIImage(systemName: "shield.fill")
        }
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
            selectedImage: UIImage(systemName: "house")
        )
        profilesViewController.tabBarItem = UITabBarItem(
            title: tr("iosTabProfiles"),
            image: UIImage(systemName: "rectangle.stack"),
            selectedImage: UIImage(systemName: "rectangle.stack")
        )
        activityNavigationController.tabBarItem = UITabBarItem(
            title: tr("iosTabActivity"),
            image: UIImage(systemName: "chart.xyaxis.line"),
            selectedImage: UIImage(systemName: "chart.xyaxis.line")
        )
        settingsNavigationController.tabBarItem = UITabBarItem(
            title: tr("iosTabSettings"),
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape")
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
