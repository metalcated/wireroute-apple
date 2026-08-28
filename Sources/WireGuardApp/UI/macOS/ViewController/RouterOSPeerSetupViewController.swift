// SPDX-License-Identifier: MIT

import Cocoa

@MainActor
final class RouterOSPeerSetupViewController: NSViewController {
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

    var onCancel: (() -> Void)?
    var onCreate: ((Proposal) -> Void)?

    private let interfaces: [RouterOSWireGuardInterface]
    private let existingPeers: [RouterOSWireGuardPeer]
    private let existingTunnelNames: Set<String>
    private let publicEndpointSuggestion: RouterOSPublicEndpointSuggestion?
    private let peerDefaults: RouterOSPeerDefaults
    private let clientPrivateKey: String
    private let clientPublicKey: String

    private let interfacePopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let clientAddressField = NSTextField()
    private let clientAddressHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let endpointField = NSTextField()
    private let endpointPortField = NSTextField()
    private let endpointHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let dnsField = NSTextField()
    private let routeModeControl = NSSegmentedControl(
        labels: [tr("macRouterOSRouteModeSplit"), tr("macRouterOSRouteModeFull")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let routesTextView = NSTextView()
    private let keepaliveField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let reviewButton = NSButton(title: tr("macRouterOSReviewPeer"), target: nil, action: nil)
    private var lastSuggestedClientAddress: String?

    init(
        interfaces: [RouterOSWireGuardInterface],
        existingPeers: [RouterOSWireGuardPeer],
        existingTunnelNames: Set<String>,
        publicEndpointSuggestion: RouterOSPublicEndpointSuggestion?,
        peerDefaults: RouterOSPeerDefaults
    ) {
        self.interfaces = interfaces
        self.existingPeers = existingPeers
        self.existingTunnelNames = existingTunnelNames
        self.publicEndpointSuggestion = publicEndpointSuggestion
        self.peerDefaults = peerDefaults
        let privateKey = PrivateKey()
        clientPrivateKey = privateKey.base64Key
        clientPublicKey = privateKey.publicKey.base64Key
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 700, height: 710)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: tr("macRouterOSSetupTitle"))
        titleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSSetupSubtitle"))
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        configureFields()
        let form = makeForm()

        let cancelButton = NSButton(title: tr("macRouterOSCancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        reviewButton.target = self
        reviewButton.action = #selector(reviewClicked)
        reviewButton.bezelStyle = .rounded
        reviewButton.controlSize = .large
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

    private func configureFields() {
        for interface in interfaces {
            interfacePopup.addItem(withTitle: interface.name)
        }
        if let preferredIndex = interfaces.firstIndex(where: { $0.isRunning && !$0.isDisabled }) {
            interfacePopup.selectItem(at: preferredIndex)
        }
        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged)

        nameField.placeholderString = tr("macRouterOSPeerNamePlaceholder")
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
        routeModeControl.selectedSegment = 0
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
        updateClientAddressSuggestion()
        updateRouteMode()
    }

    private func makeForm() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderColor = NSColor.separatorColor.cgColor
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

        let routesScrollView = NSScrollView()
        routesScrollView.borderType = .bezelBorder
        routesScrollView.hasVerticalScroller = true
        routesScrollView.documentView = routesTextView
        routesScrollView.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let routeStack = NSStackView(views: [routeModeControl, routesScrollView])
        routeStack.orientation = .vertical
        routeStack.alignment = .leading
        routeStack.spacing = 8
        routesScrollView.widthAnchor.constraint(equalTo: routeStack.widthAnchor).isActive = true

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

    private func label(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    @objc private func interfaceChanged() {
        updateEndpointPort()
        updateClientAddressSuggestion()
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

    private func updateClientAddressSuggestion() {
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
        clientAddressHelpLabel.stringValue = tr("macRouterOSClientAddressManual")
    }

    private func updateRouteMode() {
        let isSplit = routeModeControl.selectedSegment == 0
        routesTextView.isEditable = isSplit
        routesTextView.textColor = isSplit ? .labelColor : .tertiaryLabelColor
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
            let proposal = try makeProposal()
            showReview(for: proposal)
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
    }

    private func makeProposal() throws -> Proposal {
        guard interfaces.indices.contains(interfacePopup.indexOfSelectedItem) else {
            throw RouterOSProvisioningError.missingInterface
        }
        let interface = interfaces[interfacePopup.indexOfSelectedItem]
        let clientAddress = clientAddressField.stringValue
        guard let persistentKeepalive = Int(
            keepaliveField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RouterOSProvisioningError.invalidPersistentKeepalive
        }
        guard let endpointPort = Int(
            endpointPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw RouterOSProvisioningError.invalidEndpointPort
        }
        let peerCreation = try RouterOSPeerCreation(
            interfaceName: interface.name,
            name: nameField.stringValue,
            comment: tr("macRouterOSManagedPeerComment"),
            publicKey: clientPublicKey,
            clientAddress: clientAddress,
            persistentKeepalive: persistentKeepalive,
            existingPeers: existingPeers
        )
        guard !existingTunnelNames.contains(peerCreation.name) else {
            throw SetupValidationError.duplicateTunnelName(peerCreation.name)
        }

        let allowedIPs: [String]
        if routeModeControl.selectedSegment == 1 {
            allowedIPs = [peerCreation.clientAddress.family == .ipv4 ? "0.0.0.0/0" : "::/0"]
        } else {
            allowedIPs = try RoutePrefix.parseList(routesTextView.string).map(\.notation)
        }
        let clientConfiguration = try WireGuardClientConfiguration(
            name: peerCreation.name,
            privateKey: clientPrivateKey,
            clientAddress: peerCreation.clientAddress.notation,
            dnsServers: Self.splitValues(dnsField.stringValue),
            serverPublicKey: interface.publicKey,
            endpointAddress: endpointField.stringValue,
            endpointPort: endpointPort,
            allowedIPs: allowedIPs,
            persistentKeepalive: persistentKeepalive
        )
        errorLabel.isHidden = true
        return Proposal(peerCreation: peerCreation, clientConfiguration: clientConfiguration)
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
