// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa

@MainActor
protocol TunnelEditViewControllerDelegate: AnyObject {
    func tunnelSaved(tunnel: TunnelContainer)
    func tunnelEditingCancelled()
}

@MainActor
class TunnelEditViewController: NSViewController {

    let nameRow: EditableKeyValueRow = {
        let nameRow = EditableKeyValueRow()
        nameRow.key = tr(format: "macFieldKey (%@)", TunnelViewModel.InterfaceField.name.localizedUIString)
        return nameRow
    }()

    let publicKeyRow: KeyValueRow = {
        let publicKeyRow = KeyValueRow()
        publicKeyRow.key = tr(format: "macFieldKey (%@)", TunnelViewModel.InterfaceField.publicKey.localizedUIString)
        return publicKeyRow
    }()

    let textView: ConfTextView = {
        let textView = ConfTextView()
        let minWidth: CGFloat = 120
        let minHeight: CGFloat = 0
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width] // Width should be based on superview width
        textView.isHorizontallyResizable = false // Width shouldn't be based on content
        textView.isVerticallyResizable = true // Height should be based on content
        if let textContainer = textView.textContainer {
            textContainer.size = NSSize(width: minWidth, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
        }
        textView.textContainerInset = NSSize(width: 12, height: 12)
        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
        ])
        return textView
    }()

    let onDemandControlsRow = OnDemandControlsRow()

    let scrollView: WireRouteTextEditorScrollView = {
        let scrollView = WireRouteTextEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }()

    let excludePrivateIPsCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = tr("tunnelPeerExcludePrivateIPs")
        checkbox.setButtonType(.switch)
        checkbox.state = .off
        return checkbox
    }()

    let discardButton: NSButton = {
        let button = WireRouteButton()
        button.title = tr("macEditDiscard")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        return button
    }()

    let saveButton: NSButton = {
        let button = WireRouteButton()
        button.title = tr("macEditSave")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = [.command]
        return button
    }()

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer?
    var onDemandViewModel: ActivateOnDemandViewModel

    weak var delegate: TunnelEditViewControllerDelegate?

    var privateKeyObservationToken: AnyObject?
    var hasErrorObservationToken: AnyObject?
    var singlePeerAllowedIPsObservationToken: AnyObject?

    var dnsServersAddedToAllowedIPs: String?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer?) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.onDemandViewModel = tunnel != nil ? ActivateOnDemandViewModel(tunnel: tunnel!) : ActivateOnDemandViewModel()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func populateFields() {
        if let tunnel = tunnel {
            // Editing an existing tunnel
            let tunnelConfiguration = tunnel.tunnelConfiguration!
            nameRow.value = tunnel.name
            textView.string = tunnelConfiguration.asWgQuickConfig()
            publicKeyRow.value = tunnelConfiguration.interface.privateKey.publicKey.base64Key
            textView.privateKeyString = tunnelConfiguration.interface.privateKey.base64Key
            let singlePeer = tunnelConfiguration.peers.count == 1 ? tunnelConfiguration.peers.first : nil
            updateExcludePrivateIPsVisibility(singlePeerAllowedIPs: singlePeer?.allowedIPs.map { $0.stringRepresentation })
            dnsServersAddedToAllowedIPs = excludePrivateIPsCheckbox.state == .on ? tunnelConfiguration.interface.dns.map { $0.stringRepresentation }.joined(separator: ", ") : nil
        } else {
            // Creating a new tunnel
            let privateKey = PrivateKey()
            let bootstrappingText = "[Interface]\nPrivateKey = \(privateKey.base64Key)\n"
            publicKeyRow.value = privateKey.publicKey.base64Key
            textView.string = bootstrappingText
            updateExcludePrivateIPsVisibility(singlePeerAllowedIPs: nil)
            dnsServersAddedToAllowedIPs = nil
        }
        privateKeyObservationToken = textView.observe(\.privateKeyString) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let privateKeyString = self.textView.privateKeyString,
                   let privateKey = PrivateKey(base64Key: privateKeyString) {
                    self.publicKeyRow.value = privateKey.publicKey.base64Key
                } else {
                    self.publicKeyRow.value = ""
                }
            }
        }
        hasErrorObservationToken = textView.observe(\.hasError) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.saveButton.isEnabled = !self.textView.hasError
            }
        }
        singlePeerAllowedIPsObservationToken = textView.observe(\.singlePeerAllowedIPs) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateExcludePrivateIPsVisibility(
                    singlePeerAllowedIPs: self.textView.singlePeerAllowedIPs
                )
            }
        }
    }

    override func loadView() {
        populateFields()

        scrollView.documentView = textView
        scrollView.updateWireRouteTheme()

        saveButton.target = self
        saveButton.action = #selector(handleSaveAction)

        discardButton.target = self
        discardButton.action = #selector(handleDiscardAction)

        excludePrivateIPsCheckbox.target = self
        excludePrivateIPsCheckbox.action = #selector(excludePrivateIPsCheckboxToggled(sender:))

        onDemandControlsRow.onDemandViewModel = onDemandViewModel

        nameRow.keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameRow.keyLabel.textColor = .secondaryLabelColor
        nameRow.valueLabel.font = .systemFont(ofSize: 13, weight: .regular)
        publicKeyRow.keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        publicKeyRow.keyLabel.textColor = .secondaryLabelColor
        publicKeyRow.valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        publicKeyRow.valueLabel.textColor = .secondaryLabelColor
        onDemandControlsRow.keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        onDemandControlsRow.keyLabel.textColor = .secondaryLabelColor

        saveButton.bezelColor = WireRouteTheme.accentColor

        let margin: CGFloat = 24
        let internalSpacing: CGFloat = 12

        let headerIcon = NSImageView()
        headerIcon.image = NSImage(
            systemSymbolName: tunnel == nil ? "plus.square.on.square" : "slider.horizontal.3",
            accessibilityDescription: tr(tunnel == nil ? "newTunnelViewTitle" : "editTunnelViewTitle")
        )
        headerIcon.contentTintColor = WireRouteTheme.accentColor
        headerIcon.imageScaling = .scaleProportionallyUpOrDown

        let iconSurface = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .raised
        )
        iconSurface.adaptiveBorderColor = .separatorColor
        iconSurface.adaptiveBorderAlpha = 0.45
        iconSurface.layer?.borderWidth = 1
        iconSurface.layer?.cornerRadius = 8
        iconSurface.layer?.cornerCurve = .continuous
        iconSurface.addSubview(headerIcon)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconSurface.widthAnchor.constraint(equalToConstant: 38),
            iconSurface.heightAnchor.constraint(equalToConstant: 38),
            headerIcon.centerXAnchor.constraint(equalTo: iconSurface.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: iconSurface.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 18),
            headerIcon.heightAnchor.constraint(equalTo: headerIcon.widthAnchor)
        ])

        let titleLabel = NSTextField(
            labelWithString: tr(tunnel == nil ? "newTunnelViewTitle" : "editTunnelViewTitle")
        )
        titleLabel.font = .systemFont(ofSize: 22, weight: .medium)
        titleLabel.textColor = .labelColor

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [iconSurface, titleLabel, headerSpacer])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let profileStackView = NSStackView(views: [nameRow, publicKeyRow, onDemandControlsRow])
        profileStackView.orientation = .vertical
        profileStackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        profileStackView.spacing = internalSpacing

        let profileCard = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .surface
        )
        profileCard.adaptiveBorderColor = .separatorColor
        profileCard.adaptiveBorderAlpha = 0.55
        profileCard.layer?.borderWidth = 1
        profileCard.layer?.cornerRadius = 12
        profileCard.layer?.cornerCurve = .continuous
        profileCard.addSubview(profileStackView)
        profileStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            profileStackView.leadingAnchor.constraint(equalTo: profileCard.leadingAnchor, constant: 18),
            profileStackView.trailingAnchor.constraint(equalTo: profileCard.trailingAnchor, constant: -18),
            profileStackView.topAnchor.constraint(equalTo: profileCard.topAnchor, constant: 16),
            profileStackView.bottomAnchor.constraint(equalTo: profileCard.bottomAnchor, constant: -16)
        ])

        let configurationTitle = NSTextField(labelWithString: tr("macTunnelTechnicalDetails"))
        configurationTitle.font = .systemFont(ofSize: 13, weight: .medium)
        configurationTitle.textColor = .secondaryLabelColor
        let configurationHeaderSpacer = NSView()
        configurationHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let configurationHeader = NSStackView(views: [configurationTitle, configurationHeaderSpacer])
        configurationHeader.orientation = .horizontal
        configurationHeader.alignment = .centerY

        let configurationStackView = NSStackView(views: [configurationHeader, scrollView])
        configurationStackView.orientation = .vertical
        configurationStackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        configurationStackView.setHuggingPriority(.defaultLow, for: .vertical)
        configurationStackView.spacing = 10

        let configurationCard = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .surface
        )
        configurationCard.adaptiveBorderColor = .separatorColor
        configurationCard.adaptiveBorderAlpha = 0.55
        configurationCard.layer?.borderWidth = 1
        configurationCard.layer?.cornerRadius = 12
        configurationCard.layer?.cornerCurve = .continuous
        configurationCard.addSubview(configurationStackView)
        configurationStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            configurationStackView.leadingAnchor.constraint(equalTo: configurationCard.leadingAnchor, constant: 14),
            configurationStackView.trailingAnchor.constraint(equalTo: configurationCard.trailingAnchor, constant: -14),
            configurationStackView.topAnchor.constraint(equalTo: configurationCard.topAnchor, constant: 12),
            configurationStackView.bottomAnchor.constraint(equalTo: configurationCard.bottomAnchor, constant: -14),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])

        let buttonRowStackView = NSStackView()
        buttonRowStackView.setViews([discardButton, saveButton], in: .trailing)
        buttonRowStackView.addView(excludePrivateIPsCheckbox, in: .leading)
        buttonRowStackView.orientation = .horizontal
        buttonRowStackView.spacing = internalSpacing

        let contentStackView = NSStackView(views: [headerRow, profileCard, configurationCard, buttonRowStackView])
        contentStackView.orientation = .vertical
        contentStackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        contentStackView.spacing = 16
        contentStackView.setCustomSpacing(18, after: headerRow)
        contentStackView.setCustomSpacing(14, after: profileCard)

        let containerView = AppearanceAwareMaterialView(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            nordicSurface: .canvas
        )
        containerView.addSubview(contentStackView)
        contentStackView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: margin),
            contentStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -margin),
            contentStackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: margin),
            contentStackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -margin),
            headerRow.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            profileCard.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            configurationCard.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            buttonRowStackView.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        containerView.frame = NSRect(x: 0, y: 0, width: 680, height: 590)

        self.view = containerView
    }

    func setUserInteractionEnabled(_ enabled: Bool) {
        view.window?.ignoresMouseEvents = !enabled
        nameRow.valueLabel.isEditable = enabled
        textView.isEditable = enabled
        onDemandControlsRow.onDemandSSIDsField.isEnabled = enabled
    }

    @objc func handleSaveAction() {
        let name = nameRow.value
        guard !name.isEmpty else {
            ErrorPresenter.showErrorAlert(title: tr("macAlertNameIsEmpty"), message: "", from: self)
            return
        }

        onDemandControlsRow.saveToViewModel()
        let onDemandOption = onDemandViewModel.toOnDemandOption()

        let isTunnelModifiedWithoutChangingName = (tunnel != nil && tunnel!.name == name)
        guard isTunnelModifiedWithoutChangingName || tunnelsManager.tunnel(named: name) == nil else {
            ErrorPresenter.showErrorAlert(title: tr(format: "macAlertDuplicateName (%@)", name), message: "", from: self)
            return
        }

        var tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: textView.string, called: nameRow.value)
        } catch let error as WireGuardAppError {
            ErrorPresenter.showErrorAlert(error: error, from: self)
            return
        } catch {
            fatalError()
        }

        if excludePrivateIPsCheckbox.state == .on, tunnelConfiguration.peers.count == 1, let dnsServersAddedToAllowedIPs = dnsServersAddedToAllowedIPs {
            // Update the DNS servers in the AllowedIPs
            let tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnelConfiguration)
            let originalAllowedIPs = tunnelViewModel.peersData[0][.allowedIPs].splitToArray(trimmingCharacters: .whitespacesAndNewlines)
            let dnsServersInAllowedIPs =  TunnelViewModel.PeerData.normalizedIPAddressRangeStrings(dnsServersAddedToAllowedIPs.splitToArray(trimmingCharacters: .whitespacesAndNewlines))
            let dnsServersCurrent =  TunnelViewModel.PeerData.normalizedIPAddressRangeStrings(tunnelViewModel.interfaceData[.dns].splitToArray(trimmingCharacters: .whitespacesAndNewlines))
            let modifiedAllowedIPs = originalAllowedIPs.filter { !dnsServersInAllowedIPs.contains($0) } + dnsServersCurrent
            tunnelViewModel.peersData[0][.allowedIPs] = modifiedAllowedIPs.joined(separator: ", ")
            let saveResult = tunnelViewModel.save()
            if case .saved(let modifiedTunnelConfiguration) = saveResult {
                tunnelConfiguration = modifiedTunnelConfiguration
            }
        }

        setUserInteractionEnabled(false)

        if let tunnel = tunnel {
            // We're modifying an existing tunnel
            tunnelsManager.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] error in
                guard let self = self else { return }
                self.setUserInteractionEnabled(true)
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.delegate?.tunnelSaved(tunnel: tunnel)
                self.presentingViewController?.dismiss(self)
            }
        } else {
            // We're creating a new tunnel
            self.tunnelsManager.add(tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] result in
                guard let self = self else { return }
                self.setUserInteractionEnabled(true)
                switch result {
                case .failure(let error):
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                case .success(let tunnel):
                    self.delegate?.tunnelSaved(tunnel: tunnel)
                    self.presentingViewController?.dismiss(self)
                }
            }
        }
    }

    @objc func handleDiscardAction() {
        delegate?.tunnelEditingCancelled()
        presentingViewController?.dismiss(self)
    }

    func updateExcludePrivateIPsVisibility(singlePeerAllowedIPs: [String]?) {
        let shouldAllowExcludePrivateIPsControl: Bool
        let excludePrivateIPsValue: Bool
        if let singlePeerAllowedIPs = singlePeerAllowedIPs {
            (shouldAllowExcludePrivateIPsControl, excludePrivateIPsValue) = TunnelViewModel.PeerData.excludePrivateIPsFieldStates(isSinglePeer: true, allowedIPs: Set<String>(singlePeerAllowedIPs))
        } else {
            (shouldAllowExcludePrivateIPsControl, excludePrivateIPsValue) = TunnelViewModel.PeerData.excludePrivateIPsFieldStates(isSinglePeer: false, allowedIPs: Set<String>())
        }
        excludePrivateIPsCheckbox.isHidden = !shouldAllowExcludePrivateIPsControl
        excludePrivateIPsCheckbox.state = excludePrivateIPsValue ? .on : .off
    }

    @objc func excludePrivateIPsCheckboxToggled(sender: AnyObject?) {
        guard let excludePrivateIPsCheckbox = sender as? NSButton else { return }
        guard let tunnelConfiguration = try? TunnelConfiguration(fromWgQuickConfig: textView.string, called: nameRow.value) else { return }
        let isOn = excludePrivateIPsCheckbox.state == .on
        let tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnelConfiguration)
        tunnelViewModel.peersData.first?.excludePrivateIPsValueChanged(isOn: isOn, dnsServers: tunnelViewModel.interfaceData[.dns], oldDNSServers: dnsServersAddedToAllowedIPs)
        if let modifiedConfig = tunnelViewModel.asWgQuickConfig() {
            textView.setConfText(modifiedConfig)
            dnsServersAddedToAllowedIPs = isOn ? tunnelViewModel.interfaceData[.dns] : nil
        }
    }
}

extension TunnelEditViewController {
    override func cancelOperation(_ sender: Any?) {
        handleDiscardAction()
    }
}
