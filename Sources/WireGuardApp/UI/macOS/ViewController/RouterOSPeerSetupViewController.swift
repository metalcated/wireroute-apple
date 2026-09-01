// SPDX-License-Identifier: MIT

import Cocoa

@MainActor
final class RouterOSPeerSetupViewController: NSViewController {
    private enum Mode {
        case create
        case recover(RouterOSWireGuardPeer)
    }

    private enum SetupValidationError: LocalizedError {
        case duplicateTunnelName(String)

        var errorDescription: String? {
            switch self {
            case .duplicateTunnelName(let name):
                return tr(format: "macRouterOSDuplicateTunnelName (%@)", name)
            }
        }
    }

    struct Proposal: Sendable {
        let peerCreation: RouterOSPeerCreation
        let clientConfiguration: WireGuardClientConfiguration
    }

    struct RecoveryProposal: Sendable {
        let peer: RouterOSWireGuardPeer
        let clientConfiguration: WireGuardClientConfiguration
    }

    var onCancel: (() -> Void)?
    var onCreate: ((Proposal) -> Void)?
    var onRecover: ((RecoveryProposal) -> Void)?

    private let mode: Mode
    private let interfaces: [RouterOSWireGuardInterface]
    private let existingPeers: [RouterOSWireGuardPeer]
    private let existingTunnelNames: Set<String>
    private let publicEndpointSuggestion: RouterOSPublicEndpointSuggestion?
    private let peerDefaults: RouterOSPeerDefaults
    private let preferredInterfaceName: String?
    private let clientPrivateKey: String
    private let clientPublicKey: String

    private let interfacePopup = WireRoutePopUpButton()
    private let nameField = WireRouteTextField()
    private let clientAddressField = WireRouteTextField()
    private let clientAddressHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let endpointField = WireRouteTextField()
    private let endpointPortField = WireRouteTextField()
    private let endpointHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let dnsField = WireRouteTextField()
    private let routeModeControl = WireRouteSegmentedControl(
        labels: [tr("macRouterOSRouteModeSplit"), tr("macRouterOSRouteModeFull")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let routesTextView = NSTextView()
    private let routeGuidanceView = NSView()
    private let keepaliveField = WireRouteTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let reviewButton = WireRouteButton(title: tr("macRouterOSReviewPeer"), target: nil, action: nil)
    private var lastSuggestedClientAddress: String?

    init(
        interfaces: [RouterOSWireGuardInterface],
        existingPeers: [RouterOSWireGuardPeer],
        existingTunnelNames: Set<String>,
        publicEndpointSuggestion: RouterOSPublicEndpointSuggestion?,
        peerDefaults: RouterOSPeerDefaults,
        preferredInterfaceName: String?
    ) {
        self.mode = .create
        self.interfaces = interfaces
        self.existingPeers = existingPeers
        self.existingTunnelNames = existingTunnelNames
        self.publicEndpointSuggestion = publicEndpointSuggestion
        self.peerDefaults = peerDefaults
        self.preferredInterfaceName = preferredInterfaceName
        let privateKey = PrivateKey()
        clientPrivateKey = privateKey.base64Key
        clientPublicKey = privateKey.publicKey.base64Key
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 700, height: 790)
    }

    init(
        recovering peer: RouterOSWireGuardPeer,
        interfaces: [RouterOSWireGuardInterface],
        existingTunnelNames: Set<String>,
        publicEndpointSuggestion: RouterOSPublicEndpointSuggestion?,
        peerDefaults: RouterOSPeerDefaults
    ) {
        self.mode = .recover(peer)
        self.interfaces = interfaces
        existingPeers = []
        self.existingTunnelNames = existingTunnelNames
        self.publicEndpointSuggestion = publicEndpointSuggestion
        self.peerDefaults = peerDefaults
        preferredInterfaceName = peer.interfaceName
        let privateKey = PrivateKey()
        clientPrivateKey = privateKey.base64Key
        clientPublicKey = privateKey.publicKey.base64Key
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 700, height: 790)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = AppearanceAwareMaterialView(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            nordicSurface: .canvas
        )

        let titleLabel = NSTextField(labelWithString: tr(setupTitleLocalizationKey))
        titleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr(setupSubtitleLocalizationKey))
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        configureFields()
        let form = makeForm()

        let cancelButton = WireRouteButton(title: tr("macRouterOSCancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .regularSquare
        cancelButton.controlSize = .regular
        reviewButton.target = self
        reviewButton.action = #selector(reviewClicked)
        reviewButton.title = tr(reviewButtonLocalizationKey)
        reviewButton.bezelStyle = .regularSquare
        reviewButton.controlSize = .regular
        reviewButton.keyEquivalent = "\r"

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true

        let spacer = NSView()
        let buttonRow = NSStackView(views: [spacer, cancelButton, reviewButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        reviewButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, subtitleLabel, form, errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(20, after: subtitleLabel)
        stack.setCustomSpacing(18, after: form)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        self.view = view
    }

    private var setupTitleLocalizationKey: String {
        switch mode {
        case .create:
            return "macRouterOSSetupTitle"
        case .recover:
            return "macRouterOSRecoverProfileSetupTitle"
        }
    }

    private var setupSubtitleLocalizationKey: String {
        switch mode {
        case .create:
            return "macRouterOSSetupSubtitle"
        case .recover:
            return "macRouterOSRecoverProfileSetupSubtitle"
        }
    }

    private var reviewButtonLocalizationKey: String {
        switch mode {
        case .create:
            return "macRouterOSReviewPeer"
        case .recover:
            return "macRouterOSReviewRecovery"
        }
    }

    private func configureFields() {
        for interface in interfaces {
            interfacePopup.addItem(withTitle: interface.name)
        }
        if let preferredInterfaceName,
           let preferredIndex = interfaces.firstIndex(where: { $0.name == preferredInterfaceName }) {
            interfacePopup.selectItem(at: preferredIndex)
        } else if let preferredIndex = interfaces.firstIndex(where: { $0.isRunning && !$0.isDisabled }) {
            interfacePopup.selectItem(at: preferredIndex)
        }
        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged)
        if case .recover = mode {
            interfacePopup.isEnabled = false
        }

        nameField.placeholderString = tr("macRouterOSPeerNamePlaceholder")
        if case .recover(let peer) = mode {
            nameField.stringValue = Self.displayName(for: peer)
        }
        clientAddressField.placeholderString = tr("macRouterOSClientAddressPlaceholder")
        clientAddressField.delegate = self
        clientAddressHelpLabel.font = .systemFont(ofSize: 11)
        clientAddressHelpLabel.textColor = .secondaryLabelColor
        clientAddressHelpLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        endpointField.placeholderString = tr("macRouterOSEndpointPlaceholder")
        endpointHelpLabel.font = .systemFont(ofSize: 11)
        endpointHelpLabel.textColor = .secondaryLabelColor
        endpointHelpLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        if let endpointAddress = peerDefaults.endpointAddress {
            endpointField.stringValue = endpointAddress
            endpointHelpLabel.stringValue = tr("macRouterOSEndpointSaved")
        } else if let publicEndpointSuggestion {
            endpointField.stringValue = publicEndpointSuggestion.address
            endpointHelpLabel.stringValue = tr("macRouterOSEndpointDiscovered")
        } else {
            endpointHelpLabel.stringValue = tr("macRouterOSEndpointUnavailable")
        }
        dnsField.placeholderString = tr("macRouterOSDNSPlaceholder")
        dnsField.stringValue = peerDefaults.dnsServers.joined(separator: ", ")
        keepaliveField.integerValue = Int(peerDefaults.persistentKeepalive)
        routeModeControl.selectedSegment = peerDefaults.splitRoutes.isEmpty && isRecovering ? 1 : 0
        routeModeControl.target = self
        routeModeControl.action = #selector(routeModeChanged)

        for field in [nameField, clientAddressField, endpointField, endpointPortField, dnsField, keepaliveField] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 14)
        }
        endpointPortField.alignment = .right
        keepaliveField.alignment = .right

        routesTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        routesTextView.isRichText = false
        routesTextView.isAutomaticQuoteSubstitutionEnabled = false
        routesTextView.isAutomaticDashSubstitutionEnabled = false
        routesTextView.textContainerInset = NSSize(width: 8, height: 7)
        routesTextView.string = peerDefaults.splitRoutes.map(\.notation).joined(separator: ", ")
        updateEndpointPort()
        updateClientAddress()
        updateRouteMode()
    }

    private var isRecovering: Bool {
        if case .recover = mode {
            return true
        }
        return false
    }

    private func makeForm() -> NSView {
        let card = AppearanceAwareMaterialView(material: .contentBackground, blendingMode: .withinWindow)
        card.adaptiveBorderColor = .separatorColor
        card.adaptiveBorderAlpha = 0.65
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1

        let endpointRow = NSStackView(views: [endpointField, endpointPortField])
        endpointRow.orientation = .horizontal
        endpointRow.spacing = 8
        endpointPortField.widthAnchor.constraint(equalToConstant: 86).isActive = true

        let endpointStack = NSStackView(views: [endpointRow, endpointHelpLabel])
        endpointStack.orientation = .vertical
        endpointStack.alignment = .leading
        endpointStack.spacing = 4
        endpointRow.widthAnchor.constraint(equalTo: endpointStack.widthAnchor).isActive = true
        endpointHelpLabel.widthAnchor.constraint(equalTo: endpointStack.widthAnchor).isActive = true

        let clientAddressStack = NSStackView(views: [clientAddressField, clientAddressHelpLabel])
        clientAddressStack.orientation = .vertical
        clientAddressStack.alignment = .leading
        clientAddressStack.spacing = 4
        clientAddressField.widthAnchor.constraint(equalTo: clientAddressStack.widthAnchor).isActive = true
        clientAddressHelpLabel.widthAnchor.constraint(equalTo: clientAddressStack.widthAnchor).isActive = true

        let routesScrollView = WireRouteTextEditorScrollView()
        routesScrollView.hasVerticalScroller = true
        routesScrollView.documentView = routesTextView
        routesScrollView.updateWireRouteTheme()
        routesScrollView.heightAnchor.constraint(equalToConstant: 76).isActive = true

        configureRouteGuidanceView()
        let routeStack = NSStackView(views: [routeModeControl, routesScrollView, routeGuidanceView])
        routeStack.orientation = .vertical
        routeStack.alignment = .leading
        routeStack.spacing = 8
        routesScrollView.widthAnchor.constraint(equalTo: routeStack.widthAnchor).isActive = true
        routeGuidanceView.widthAnchor.constraint(equalTo: routeStack.widthAnchor).isActive = true

        let keepaliveRow = NSStackView(views: [keepaliveField, NSTextField(labelWithString: tr("macRouterOSSeconds"))])
        keepaliveRow.orientation = .horizontal
        keepaliveRow.alignment = .centerY
        keepaliveRow.spacing = 7
        keepaliveField.widthAnchor.constraint(equalToConstant: 86).isActive = true

        let grid = NSGridView(views: [
            [label(tr("macRouterOSInterface")), interfacePopup],
            [label(tr("macRouterOSPeerName")), nameField],
            [label(tr("macRouterOSClientAddress")), clientAddressStack],
            [label(tr("macRouterOSEndpoint")), endpointStack],
            [label(tr("macRouterOSDNS")), dnsField],
            [label(tr("macRouterOSRoutes")), routeStack],
            [label(tr("macRouterOSKeepalive")), keepaliveRow]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 15
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 5).yPlacement = .top

        card.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 390)
        ])
        return card
    }

    private func configureRouteGuidanceView() {
        guard routeGuidanceView.subviews.isEmpty else { return }
        routeGuidanceView.wantsLayer = true
        routeGuidanceView.layer?.backgroundColor = WireRouteTheme.accentColor.withAlphaComponent(0.08).cgColor
        routeGuidanceView.layer?.borderColor = WireRouteTheme.accentColor.withAlphaComponent(0.32).cgColor
        routeGuidanceView.layer?.borderWidth = 1
        routeGuidanceView.layer?.cornerRadius = 10
        routeGuidanceView.layer?.cornerCurve = .continuous

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "questionmark.circle.fill",
            accessibilityDescription: tr("splitRouteEntryGuidanceTitle")
        )
        iconView.contentTintColor = WireRouteTheme.accentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: tr("splitRouteEntryGuidanceTitle"))
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let messageLabel = NSTextField(
            wrappingLabelWithString: tr("splitRouteEntryGuidanceMessage")
        )
        messageLabel.font = .systemFont(ofSize: 10.5)
        messageLabel.textColor = .secondaryLabelColor
        let exampleLabel = NSTextField(
            wrappingLabelWithString: tr("splitRouteEntryGuidanceExample")
        )
        exampleLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        exampleLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, messageLabel, exampleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        let contentStack = NSStackView(views: [iconView, textStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 9
        routeGuidanceView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: routeGuidanceView.leadingAnchor, constant: 11),
            contentStack.trailingAnchor.constraint(equalTo: routeGuidanceView.trailingAnchor, constant: -11),
            contentStack.topAnchor.constraint(equalTo: routeGuidanceView.topAnchor, constant: 9),
            contentStack.bottomAnchor.constraint(equalTo: routeGuidanceView.bottomAnchor, constant: -9),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            messageLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            exampleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor)
        ])
    }

    private func label(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    @objc private func interfaceChanged() {
        updateEndpointPort()
        updateClientAddress()
    }

    @objc private func routeModeChanged() {
        updateRouteMode()
    }

    private func updateEndpointPort() {
        guard interfaces.indices.contains(interfacePopup.indexOfSelectedItem),
              let port = interfaces[interfacePopup.indexOfSelectedItem].listenPort else {
            endpointPortField.stringValue = ""
            return
        }
        endpointPortField.stringValue = String(port)
    }

    private func updateClientAddress() {
        if case .recover(let peer) = mode {
            if let address = RouterOSMissingProfileRecoveryValidator.suggestedClientAddress(for: peer) {
                clientAddressField.stringValue = address.notation
                lastSuggestedClientAddress = address.notation
                clientAddressHelpLabel.stringValue = tr("macRouterOSRecoverProfileAddressFound")
            } else {
                clientAddressField.stringValue = ""
                lastSuggestedClientAddress = nil
                clientAddressHelpLabel.stringValue = tr("macRouterOSRecoverProfileAddressReview")
            }
            return
        }

        let currentAddress = clientAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentAddress.isEmpty || currentAddress == lastSuggestedClientAddress else {
            showManualClientAddressHelp()
            return
        }
        guard interfaces.indices.contains(interfacePopup.indexOfSelectedItem) else {
            clientAddressField.stringValue = ""
            lastSuggestedClientAddress = nil
            clientAddressHelpLabel.stringValue = ""
            return
        }

        let interfaceName = interfaces[interfacePopup.indexOfSelectedItem].name
        guard let suggestion = RouterOSClientAddressSuggestion.discover(
            for: interfaceName,
            existingPeers: existingPeers
        ) else {
            clientAddressField.stringValue = ""
            lastSuggestedClientAddress = nil
            clientAddressHelpLabel.stringValue = tr(
                format: "macRouterOSClientAddressUnavailable (%@)",
                interfaceName
            )
            return
        }

        clientAddressField.stringValue = suggestion.address.notation
        lastSuggestedClientAddress = suggestion.address.notation
        clientAddressHelpLabel.stringValue = tr(
            format: "macRouterOSClientAddressSuggested (%@)",
            interfaceName
        )
    }

    private func showManualClientAddressHelp() {
        clientAddressHelpLabel.stringValue = tr(
            isRecovering
                ? "macRouterOSRecoverProfileAddressManual"
                : "macRouterOSClientAddressManual"
        )
    }

    private static func displayName(for peer: RouterOSWireGuardPeer) -> String {
        let name = peer.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = peer.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
            ?? comment.flatMap { $0.isEmpty ? nil : $0 }
            ?? tr("macRouterOSExistingPeerDefaultName")
    }

    private func updateRouteMode() {
        let isSplit = routeModeControl.selectedSegment == 0
        routesTextView.isEditable = isSplit
        routesTextView.textColor = isSplit ? .labelColor : .tertiaryLabelColor
        routeGuidanceView.isHidden = !isSplit
        if !isSplit {
            routesTextView.string = tr("macRouterOSFullRouteAutomatic")
        } else if routesTextView.string == tr("macRouterOSFullRouteAutomatic") {
            routesTextView.string = ""
        }
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    @objc private func reviewClicked() {
        do {
            switch mode {
            case .create:
                showReview(for: try makeProposal())
            case .recover(let peer):
                showRecoveryReview(for: try makeRecoveryProposal(peer: peer))
            }
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
    }

    private func makeProposal() throws -> Proposal {
        let interface = try selectedInterface()
        let clientAddress = clientAddressField.stringValue
        let persistentKeepalive = try selectedPersistentKeepalive()
        let peerCreation = try RouterOSPeerCreation(
            interfaceName: interface.name,
            name: nameField.stringValue,
            comment: RouterOSPeerCreation.wireRouteManagedComment,
            publicKey: clientPublicKey,
            clientAddress: clientAddress,
            persistentKeepalive: persistentKeepalive,
            existingPeers: existingPeers
        )
        guard !existingTunnelNames.contains(peerCreation.name) else {
            throw SetupValidationError.duplicateTunnelName(peerCreation.name)
        }

        let clientConfiguration = try makeClientConfiguration(
            name: peerCreation.name,
            clientAddress: peerCreation.clientAddress,
            interface: interface,
            persistentKeepalive: persistentKeepalive
        )
        errorLabel.isHidden = true
        return Proposal(peerCreation: peerCreation, clientConfiguration: clientConfiguration)
    }

    private func makeRecoveryProposal(peer: RouterOSWireGuardPeer) throws -> RecoveryProposal {
        let interface = try selectedInterface()
        let clientAddress = try RouterOSMissingProfileRecoveryValidator.validate(
            peer: peer,
            interface: interface,
            clientAddress: clientAddressField.stringValue
        )
        let profileName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingTunnelNames.contains(profileName) else {
            throw SetupValidationError.duplicateTunnelName(profileName)
        }
        let clientConfiguration = try makeClientConfiguration(
            name: profileName,
            clientAddress: clientAddress,
            interface: interface,
            persistentKeepalive: try selectedPersistentKeepalive()
        )
        errorLabel.isHidden = true
        return RecoveryProposal(peer: peer, clientConfiguration: clientConfiguration)
    }

    private func selectedInterface() throws -> RouterOSWireGuardInterface {
        guard interfaces.indices.contains(interfacePopup.indexOfSelectedItem) else {
            throw RouterOSProvisioningError.missingInterface
        }
        return interfaces[interfacePopup.indexOfSelectedItem]
    }

    private func selectedPersistentKeepalive() throws -> Int {
        guard let persistentKeepalive = Int(
            keepaliveField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RouterOSProvisioningError.invalidPersistentKeepalive
        }
        return persistentKeepalive
    }

    private func makeClientConfiguration(
        name: String,
        clientAddress: RoutePrefix,
        interface: RouterOSWireGuardInterface,
        persistentKeepalive: Int
    ) throws -> WireGuardClientConfiguration {
        let allowedIPs: [String]
        if routeModeControl.selectedSegment == 1 {
            allowedIPs = [clientAddress.family == .ipv4 ? "0.0.0.0/0" : "::/0"]
        } else {
            allowedIPs = try RoutePrefix.parseList(routesTextView.string).map(\.notation)
        }
        guard let endpointPort = Int(
            endpointPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RouterOSProvisioningError.invalidEndpointPort
        }
        return try WireGuardClientConfiguration(
            name: name,
            privateKey: clientPrivateKey,
            clientAddress: clientAddress.notation,
            dnsServers: Self.splitValues(dnsField.stringValue),
            serverPublicKey: interface.publicKey,
            endpointAddress: endpointField.stringValue,
            endpointPort: endpointPort,
            allowedIPs: allowedIPs,
            persistentKeepalive: persistentKeepalive
        )
    }

    private func showReview(for proposal: Proposal) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("macRouterOSReviewTitle")
        alert.informativeText = tr(
            format: "macRouterOSReviewMessage (%@,%@,%@,%@,%@)",
            proposal.peerCreation.name,
            proposal.peerCreation.interfaceName,
            proposal.peerCreation.clientAddress.notation,
            "\(proposal.clientConfiguration.endpointAddress):\(proposal.clientConfiguration.endpointPort)",
            proposal.clientConfiguration.allowedIPs.map(\.notation).joined(separator: ", ")
        )
        alert.addButton(withTitle: tr("macRouterOSAddPeer"))
        alert.addButton(withTitle: tr("macRouterOSBack"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onCreate?(proposal)
        }
    }

    private func showRecoveryReview(for proposal: RecoveryProposal) {
        guard let window = view.window else { return }
        let configuration = proposal.clientConfiguration
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("macRouterOSRecoverProfileReviewTitle")
        alert.informativeText = tr(
            format: "macRouterOSRecoverProfileReviewMessage (%@,%@,%@,%@,%@,%@,%@)",
            configuration.name,
            proposal.peer.interfaceName,
            configuration.clientAddress.notation,
            "\(configuration.endpointAddress):\(configuration.endpointPort)",
            configuration.allowedIPs.map(\.notation).joined(separator: ", "),
            proposal.peer.publicKey,
            clientPublicKey
        )
        alert.addButton(withTitle: tr("macRouterOSRecoverProfileConfirm"))
        alert.addButton(withTitle: tr("macRouterOSBack"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onRecover?(proposal)
        }
    }

    private static func splitValues(_ value: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        return value.components(separatedBy: separators).filter { !$0.isEmpty }
    }
}

extension RouterOSPeerSetupViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === clientAddressField,
              field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != lastSuggestedClientAddress else {
            return
        }
        showManualClientAddressHelp()
    }
}
