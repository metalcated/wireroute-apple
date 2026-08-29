// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa

@MainActor
private final class MacSplitRouteEntryViewController: NSViewController {
    var onSave: ((String, @escaping @MainActor @Sendable (WireGuardAppError?) -> Void) -> Void)?

    private let routesTextView: NSTextView = {
        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        return textView
    }()
    private let errorLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .systemRed
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.isHidden = true
        return label
    }()
    private let cancelButton = NSButton(title: tr("macRouterOSCancel"), target: nil, action: nil)
    private let saveButton = NSButton(title: tr("macEditSave"), target: nil, action: nil)

    override func loadView() {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: tr("splitRouteEntryTitle"))
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        let messageLabel = NSTextField(wrappingLabelWithString: tr("splitRouteEntryMessage"))
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        let hintLabel = NSTextField(wrappingLabelWithString: tr("splitRouteEntryHint"))
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let scrollView = AppearanceAwareLayerScrollView()
        scrollView.documentView = routesTextView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 12
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.borderWidth = 1
        scrollView.adaptiveBorderColor = .separatorColor

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let spacer = NSView()
        let footer = NSStackView(views: [errorLabel, spacer, buttonRow])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, messageLabel, scrollView, hintLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(18, after: messageLabel)
        stack.setCustomSpacing(8, after: scrollView)
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        container.frame = NSRect(x: 0, y: 0, width: 560, height: 390)
        view = container
    }

    @objc private func cancelClicked() {
        presentingViewController?.dismiss(self)
    }

    @objc private func saveClicked() {
        guard let onSave else { return }
        let routes = routesTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = false
        routesTextView.isEditable = false
        errorLabel.isHidden = true
        onSave(routes) { [weak self] error in
            guard let self else { return }
            self.saveButton.isEnabled = true
            self.routesTextView.isEditable = true
            if let error {
                self.errorLabel.stringValue = error.alertText.message
                self.errorLabel.isHidden = false
            } else {
                self.presentingViewController?.dismiss(self)
            }
        }
    }
}

@MainActor
private final class MacDNSProtectionViewController: NSViewController, NSTextFieldDelegate {
    var onSave: ((DNSProtectionPolicy, @escaping @MainActor @Sendable (WireGuardAppError?) -> Void) -> Void)?

    private let currentPolicy: DNSProtectionPolicy
    private let isTunnelActive: Bool
    private let modeControl = NSSegmentedControl(
        labels: [tr("dnsProtectionProfileDNS"), tr("dnsProtectionEncryptedDNS")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let presetPopUp = NSPopUpButton()
    private let presetDescriptionLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()
    private let resolverURLField = WireRouteTextField()
    private let bootstrapServersField = WireRouteTextField()
    private let resolverFieldsStack = NSStackView()
    private let errorLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemRed
        label.isHidden = true
        return label
    }()
    private let cancelButton = NSButton(title: tr("macRouterOSCancel"), target: nil, action: nil)
    private let saveButton = NSButton(title: tr("dnsProtectionSave"), target: nil, action: nil)

    init(policy: DNSProtectionPolicy, isTunnelActive: Bool) {
        currentPolicy = policy
        self.isTunnelActive = isTunnelActive
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: tr("dnsProtectionTitle")
        )
        iconView.contentTintColor = WireRouteTheme.accentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: tr("dnsProtectionTitle"))
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        let introLabel = NSTextField(wrappingLabelWithString: tr("dnsProtectionIntro"))
        introLabel.font = .systemFont(ofSize: 13)
        introLabel.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [titleLabel, introLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let header = NSStackView(views: [iconView, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let modeLabel = makeFieldLabel(tr("dnsProtectionMode"))
        modeControl.segmentStyle = .rounded
        modeControl.selectedSegment = currentPolicy.mode == .encryptedHTTPS ? 1 : 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        configurePresetPopUp()
        resolverURLField.placeholderString = tr("dnsProtectionResolverURLPlaceholder")
        bootstrapServersField.placeholderString = tr("dnsProtectionBootstrapPlaceholder")
        resolverURLField.delegate = self
        bootstrapServersField.delegate = self
        if currentPolicy.mode == .encryptedHTTPS {
            resolverURLField.stringValue = currentPolicy.serverURL?.absoluteString ?? ""
            bootstrapServersField.stringValue = currentPolicy.bootstrapServers.joined(separator: ", ")
        }

        let bootstrapHelp = NSTextField(wrappingLabelWithString: tr("dnsProtectionBootstrapHelp"))
        bootstrapHelp.font = .systemFont(ofSize: 11)
        bootstrapHelp.textColor = .secondaryLabelColor

        resolverFieldsStack.orientation = .vertical
        resolverFieldsStack.alignment = .leading
        resolverFieldsStack.spacing = 8
        resolverFieldsStack.addArrangedSubview(makeFieldLabel(tr("dnsProtectionProvider")))
        resolverFieldsStack.addArrangedSubview(presetPopUp)
        resolverFieldsStack.addArrangedSubview(presetDescriptionLabel)
        resolverFieldsStack.setCustomSpacing(16, after: presetDescriptionLabel)
        resolverFieldsStack.addArrangedSubview(makeFieldLabel(tr("dnsProtectionResolverURL")))
        resolverFieldsStack.addArrangedSubview(resolverURLField)
        resolverFieldsStack.setCustomSpacing(16, after: resolverURLField)
        resolverFieldsStack.addArrangedSubview(makeFieldLabel(tr("dnsProtectionBootstrapServers")))
        resolverFieldsStack.addArrangedSubview(bootstrapServersField)
        resolverFieldsStack.addArrangedSubview(bootstrapHelp)

        let stateLabel = NSTextField(wrappingLabelWithString: tr("dnsProtectionAppliesNextConnection"))
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.isHidden = !isTunnelActive

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [errorLabel, buttonSpacer, buttonRow])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [header, modeLabel, modeControl, resolverFieldsStack, stateLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: header)
        stack.setCustomSpacing(18, after: modeControl)
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            modeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resolverFieldsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            presetPopUp.widthAnchor.constraint(equalTo: resolverFieldsStack.widthAnchor),
            presetDescriptionLabel.widthAnchor.constraint(equalTo: resolverFieldsStack.widthAnchor),
            resolverURLField.widthAnchor.constraint(equalTo: resolverFieldsStack.widthAnchor),
            bootstrapServersField.widthAnchor.constraint(equalTo: resolverFieldsStack.widthAnchor),
            bootstrapHelp.widthAnchor.constraint(equalTo: resolverFieldsStack.widthAnchor),
            stateLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        container.frame = NSRect(x: 0, y: 0, width: 580, height: 530)
        view = container
        updateMode()
    }

    @objc private func modeChanged() {
        errorLabel.isHidden = true
        updateMode()
    }

    private func updateMode() {
        resolverFieldsStack.isHidden = modeControl.selectedSegment != 1
    }

    private func configurePresetPopUp() {
        presetPopUp.removeAllItems()
        presetPopUp.addItems(withTitles: DNSProtectionPreset.allCases.map(\.localizedTitle))
        presetPopUp.addItem(withTitle: tr("dnsPresetCustom"))
        presetPopUp.controlSize = .large
        presetPopUp.font = .systemFont(ofSize: 13)
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged)

        if let preset = DNSProtectionPreset.matching(currentPolicy),
           let index = DNSProtectionPreset.allCases.firstIndex(of: preset) {
            presetPopUp.selectItem(at: index)
        } else {
            presetPopUp.selectItem(at: DNSProtectionPreset.allCases.count)
        }
        updatePresetDescription()
    }

    @objc private func presetChanged() {
        let selectedIndex = presetPopUp.indexOfSelectedItem
        guard DNSProtectionPreset.allCases.indices.contains(selectedIndex) else {
            updatePresetDescription()
            return
        }
        let preset = DNSProtectionPreset.allCases[selectedIndex]
        resolverURLField.stringValue = preset.serverURLString
        bootstrapServersField.stringValue = preset.bootstrapServers.joined(separator: ", ")
        errorLabel.isHidden = true
        updatePresetDescription()
    }

    private func updatePresetDescription() {
        let selectedIndex = presetPopUp.indexOfSelectedItem
        if DNSProtectionPreset.allCases.indices.contains(selectedIndex) {
            presetDescriptionLabel.stringValue = DNSProtectionPreset.allCases[selectedIndex].localizedDescription
        } else {
            presetDescriptionLabel.stringValue = tr("dnsPresetCustomDescription")
        }
    }

    @objc private func cancelClicked() {
        presentingViewController?.dismiss(self)
    }

    @objc private func saveClicked() {
        let policy: DNSProtectionPolicy
        if modeControl.selectedSegment == 0 {
            policy = .profile
        } else {
            do {
                policy = try DNSProtectionPolicy.encryptedHTTPS(
                    serverURLString: resolverURLField.stringValue,
                    bootstrapServerStrings: parsedBootstrapServers()
                )
            } catch DNSProtectionPolicyError.invalidServerURL {
                showError(tr("dnsProtectionInvalidURLMessage"))
                return
            } catch DNSProtectionPolicyError.invalidBootstrapServer(let server) {
                showError(tr(format: "dnsProtectionInvalidBootstrapMessage (%@)", server))
                return
            } catch {
                showError(tr("dnsProtectionInvalidStoredMessage"))
                return
            }
        }

        guard let onSave else { return }
        setSaving(true)
        onSave(policy) { [weak self] error in
            guard let self else { return }
            self.setSaving(false)
            if let error {
                self.showError(error.alertText.message)
            } else {
                self.presentingViewController?.dismiss(self)
            }
        }
    }

    private func parsedBootstrapServers() -> [String] {
        let separators = CharacterSet(charactersIn: ",\n \t")
        return bootstrapServersField.stringValue
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func setSaving(_ isSaving: Bool) {
        saveButton.isEnabled = !isSaving
        cancelButton.isEnabled = !isSaving
        modeControl.isEnabled = !isSaving
        presetPopUp.isEnabled = !isSaving
        resolverURLField.isEnabled = !isSaving
        bootstrapServersField.isEnabled = !isSaving
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    func controlTextDidChange(_ notification: Notification) {
        guard presetPopUp.indexOfSelectedItem != DNSProtectionPreset.allCases.count else { return }
        presetPopUp.selectItem(at: DNSProtectionPreset.allCases.count)
        updatePresetDescription()
    }
}

@MainActor
class TunnelDetailTableViewController: NSViewController {

    private enum TableViewModelRow {
        case interfaceFieldRow(TunnelViewModel.InterfaceField)
        case peerFieldRow(peer: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField)
        case onDemandRow
        case onDemandSSIDRow
        case spacerRow

        func localizedSectionKeyString() -> String {
            switch self {
            case .interfaceFieldRow: return tr("tunnelSectionTitleInterface")
            case .peerFieldRow: return tr("tunnelSectionTitlePeer")
            case .onDemandRow: return tr("macFieldOnDemand")
            case .onDemandSSIDRow: return ""
            case .spacerRow: return ""
            }
        }

        func isTitleRow() -> Bool {
            switch self {
            case .interfaceFieldRow(let field): return field == .name
            case .peerFieldRow(_, let field): return field == .publicKey
            case .onDemandRow: return true
            case .onDemandSSIDRow: return false
            case .spacerRow: return false
            }
        }
    }

    static let interfaceFields: [TunnelViewModel.InterfaceField] = [
        .name, .publicKey, .addresses, .listenPort, .mtu, .dns
    ]

    static let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .persistentKeepAlive,
        .rxBytes, .txBytes, .lastHandshakeTime
    ]

    static let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .onDemand, .ssid
    ]

    let tableView: NSTableView = {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TunnelDetail")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        return tableView
    }()

    let editButton: NSButton = {
        let button = NSButton()
        button.title = tr("macButtonEdit")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.toolTip = tr("macToolTipEditTunnel")
        return button
    }()

    let box: AppearanceAwareMaterialView = {
        let box = AppearanceAwareMaterialView(material: .contentBackground, blendingMode: .withinWindow)
        box.adaptiveBorderColor = .separatorColor
        box.adaptiveBorderAlpha = 0.65
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 16
        box.layer?.cornerCurve = .continuous
        return box
    }()

    private let heroCard: AppearanceAwareMaterialView = {
        let box = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .raised
        )
        box.adaptiveBorderColor = .separatorColor
        box.adaptiveBorderAlpha = 0.65
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 18
        box.layer?.cornerCurve = .continuous
        return box
    }()
    private let identityImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.contentTintColor = WireRouteTheme.accentColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        return imageView
    }()
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 25, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }()
    private let routeModeControl = NSSegmentedControl(
        labels: [tr("macTunnelRoutingSplit"), tr("macTunnelRoutingFull")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let routeDescriptionLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        return label
    }()
    private let routeProgressIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        return indicator
    }()
    private let dnsProtectionDescriptionLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        return label
    }()
    private let dnsProtectionButton: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.image = NSImage(
            systemSymbolName: "lock.shield",
            accessibilityDescription: tr("dnsProtectionTitle")
        )
        button.imagePosition = .imageLeading
        return button
    }()
    private let connectionButton: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.bezelColor = WireRouteTheme.accentColor
        button.image = NSImage(
            systemSymbolName: "power",
            accessibilityDescription: tr("macToggleStatusButtonActivate")
        )
        button.imagePosition = .imageLeading
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()
    private let technicalDetailsLabel: NSTextField = {
        let label = NSTextField(labelWithString: tr("macTunnelTechnicalDetails"))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }()

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer

    var tunnelViewModel: TunnelViewModel {
        didSet {
            updateTableViewModelRowsBySection()
            updateTableViewModelRows()
        }
    }

    var onDemandViewModel: ActivateOnDemandViewModel

    private var tableViewModelRowsBySection = [[(isVisible: Bool, modelRow: TableViewModelRow)]]()
    private var tableViewModelRows = [TableViewModelRow]()

    private var statusObservationToken: AnyObject?
    private var isOnDemandEnabledObservationToken: AnyObject?
    private var hasOnDemandRulesObservationToken: AnyObject?
    private var tunnelEditVC: TunnelEditViewController?
    private var reloadRuntimeConfigurationTimer: Timer?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateTableViewModelRowsBySection()
        updateTableViewModelRows()
        statusObservationToken = tunnel.observe(\TunnelContainer.status) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateDashboard()
                if self.tunnel.status == .active {
                    self.startUpdatingRuntimeConfiguration()
                } else if self.tunnel.status == .inactive {
                    self.reloadRuntimeConfiguration()
                    self.stopUpdatingRuntimeConfiguration()
                }
            }
        }
        isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateDashboard()
            }
        }
        hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateDashboard()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func themeDidChange() {
        identityImageView.contentTintColor = WireRouteTheme.accentColor
        connectionButton.bezelColor = WireRouteTheme.accentColor
        view.needsDisplay = true
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.gridStyleMask = []

        editButton.target = self
        editButton.action = #selector(handleEditTunnelAction)
        routeModeControl.target = self
        routeModeControl.action = #selector(routingModeChanged)
        routeModeControl.segmentStyle = .rounded
        connectionButton.target = self
        connectionButton.action = #selector(handleToggleActiveStatusAction)
        dnsProtectionButton.target = self
        dnsProtectionButton.action = #selector(dnsProtectionClicked)

        let clipView = NSClipView()
        clipView.documentView = tableView

        let scrollView = NSScrollView()
        scrollView.contentView = clipView // Set contentView before setting drawsBackground
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let identityText = NSStackView(views: [titleLabel, statusLabel])
        identityText.orientation = .vertical
        identityText.alignment = .leading
        identityText.spacing = 3
        let identitySpacer = NSView()
        identitySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [connectionButton, editButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        let identityRow = NSStackView(views: [identityImageView, identityText, identitySpacer, actionRow])
        identityRow.orientation = .horizontal
        identityRow.alignment = .centerY
        identityRow.spacing = 14

        let routingLabel = NSTextField(labelWithString: tr("macTunnelTrafficRouting"))
        routingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let routingSpacer = NSView()
        routingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let routingRow = NSStackView(
            views: [routingLabel, routingSpacer, routeProgressIndicator, routeModeControl]
        )
        routingRow.orientation = .horizontal
        routingRow.alignment = .centerY
        routingRow.spacing = 10

        let descriptionSpacer = NSView()
        descriptionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let descriptionRow = NSStackView(
            views: [routeDescriptionLabel, descriptionSpacer]
        )
        descriptionRow.orientation = .horizontal
        descriptionRow.alignment = .centerY
        descriptionRow.spacing = 16

        let dnsLabel = NSTextField(labelWithString: tr("dnsProtectionTitle"))
        dnsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let dnsTextStack = NSStackView(views: [dnsLabel, dnsProtectionDescriptionLabel])
        dnsTextStack.orientation = .vertical
        dnsTextStack.alignment = .leading
        dnsTextStack.spacing = 2
        let dnsSpacer = NSView()
        dnsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let dnsRow = NSStackView(views: [dnsTextStack, dnsSpacer, dnsProtectionButton])
        dnsRow.orientation = .horizontal
        dnsRow.alignment = .centerY
        dnsRow.spacing = 16

        let heroStack = NSStackView(views: [identityRow, routingRow, descriptionRow, dnsRow])
        heroStack.orientation = .vertical
        heroStack.alignment = .leading
        heroStack.spacing = 15
        heroStack.setCustomSpacing(20, after: identityRow)
        heroCard.addSubview(heroStack)
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.addSubview(heroCard)
        containerView.addSubview(technicalDetailsLabel)
        containerView.addSubview(box)
        containerView.addSubview(scrollView)
        heroCard.translatesAutoresizingMaskIntoConstraints = false
        technicalDetailsLabel.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 20),
            heroStack.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -20),
            heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 18),
            heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -18),
            identityRow.widthAnchor.constraint(equalTo: heroStack.widthAnchor),
            routingRow.widthAnchor.constraint(equalTo: heroStack.widthAnchor),
            descriptionRow.widthAnchor.constraint(equalTo: heroStack.widthAnchor),
            dnsRow.widthAnchor.constraint(equalTo: heroStack.widthAnchor),
            identityImageView.widthAnchor.constraint(equalToConstant: 44),
            identityImageView.heightAnchor.constraint(equalTo: identityImageView.widthAnchor),
            routeModeControl.widthAnchor.constraint(equalToConstant: 220),
            routeDescriptionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            connectionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])

        NSLayoutConstraint.activate([
            heroCard.topAnchor.constraint(equalTo: containerView.topAnchor),
            heroCard.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            heroCard.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            technicalDetailsLabel.topAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: 18),
            technicalDetailsLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 4),
            box.topAnchor.constraint(equalTo: technicalDetailsLabel.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])

        view = containerView
        updateDashboard()
    }

    func updateTableViewModelRowsBySection() {
        var modelRowsBySection = [[(isVisible: Bool, modelRow: TableViewModelRow)]]()

        var interfaceSection = [(isVisible: Bool, modelRow: TableViewModelRow)]()
        for field in TunnelDetailTableViewController.interfaceFields {
            let isEmpty = tunnelViewModel.interfaceData[field].isEmpty
            interfaceSection.append((isVisible: !isEmpty, modelRow: .interfaceFieldRow(field)))
        }
        interfaceSection.append((isVisible: true, modelRow: .spacerRow))
        modelRowsBySection.append(interfaceSection)

        for peerData in tunnelViewModel.peersData {
            var peerSection = [(isVisible: Bool, modelRow: TableViewModelRow)]()
            for field in TunnelDetailTableViewController.peerFields {
                peerSection.append((isVisible: !peerData[field].isEmpty, modelRow: .peerFieldRow(peer: peerData, field: field)))
            }
            peerSection.append((isVisible: true, modelRow: .spacerRow))
            modelRowsBySection.append(peerSection)
        }

        var onDemandSection = [(isVisible: Bool, modelRow: TableViewModelRow)]()
        onDemandSection.append((isVisible: true, modelRow: .onDemandRow))
        if onDemandViewModel.isWiFiInterfaceEnabled {
            onDemandSection.append((isVisible: true, modelRow: .onDemandSSIDRow))
        }
        modelRowsBySection.append(onDemandSection)

        tableViewModelRowsBySection = modelRowsBySection
    }

    func updateTableViewModelRows() {
        tableViewModelRows = tableViewModelRowsBySection.flatMap { $0.filter { $0.isVisible }.map { $0.modelRow } }
    }

    @objc func handleEditTunnelAction() {
        PrivateDataConfirmation.confirmAccess(to: tr("macViewPrivateData")) { [weak self] in
            guard let self = self else { return }
            let tunnelEditVC = TunnelEditViewController(tunnelsManager: self.tunnelsManager, tunnel: self.tunnel)
            tunnelEditVC.delegate = self
            self.presentAsSheet(tunnelEditVC)
            self.tunnelEditVC = tunnelEditVC
        }
    }

    @objc func handleToggleActiveStatusAction() {
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            tunnelsManager.setOnDemandEnabled(turnOn, on: tunnel) { [weak self] error in
                guard let self else { return }
                if let error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                } else if !turnOn {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        } else {
            if tunnel.status == .inactive {
                tunnelsManager.startActivation(of: tunnel)
            } else if tunnel.status == .active {
                tunnelsManager.startDeactivation(of: tunnel)
            }
        }
    }

    @objc private func dnsProtectionClicked() {
        let dnsViewController = MacDNSProtectionViewController(
            policy: tunnel.dnsProtectionPolicy,
            isTunnelActive: tunnel.status != .inactive
        )
        dnsViewController.onSave = { [weak self] policy, completion in
            guard let self else {
                completion(TunnelDNSProtectionError.invalidStoredConfiguration)
                return
            }
            self.tunnelsManager.setDNSProtectionPolicy(policy, on: self.tunnel) { error in
                if error == nil {
                    self.updateDashboard()
                }
                completion(error)
            }
        }
        presentAsSheet(dnsViewController)
    }

    @objc private func routingModeChanged() {
        let requestedMode: TunnelRouteMode = routeModeControl.selectedSegment == 1
            ? .full
            : .split
        guard requestedMode != tunnel.routingMode else { return }
        setRoutingControlBusy(true)
        tunnelsManager.setRoutingMode(requestedMode, on: tunnel) { [weak self] error in
            guard let self else { return }
            self.setRoutingControlBusy(false)
            guard let error else {
                self.refreshAfterRoutingChange()
                return
            }
            self.updateDashboard()
            if let routingError = error as? TunnelRoutingError,
               case .missingSplitRoutes = routingError {
                self.presentSplitRouteEntry()
            } else {
                ErrorPresenter.showErrorAlert(error: error, from: self)
            }
        }
    }

    private func presentSplitRouteEntry() {
        let routeEntryViewController = MacSplitRouteEntryViewController()
        routeEntryViewController.onSave = { [weak self] routes, completion in
            guard let self else {
                completion(TunnelRoutingError.invalidStoredRoutes)
                return
            }
            self.tunnelsManager.setRoutingMode(
                .split,
                enteredSplitRoutes: routes,
                on: self.tunnel
            ) { error in
                if error == nil {
                    self.refreshAfterRoutingChange()
                }
                completion(error)
            }
        }
        presentAsSheet(routeEntryViewController)
    }

    private func refreshAfterRoutingChange() {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        tableView.reloadData()
        updateDashboard()
    }

    private func setRoutingControlBusy(_ isBusy: Bool) {
        routeModeControl.isEnabled = !isBusy
        editButton.isEnabled = !isBusy
        connectionButton.isEnabled = !isBusy
        if isBusy {
            routeProgressIndicator.startAnimation(nil)
        } else {
            routeProgressIndicator.stopAnimation(nil)
        }
    }

    private func updateDashboard() {
        guard isViewLoaded else { return }
        titleLabel.stringValue = tunnel.name
        statusLabel.stringValue = Self.localizedStatusDescription(for: tunnel)
        routeModeControl.selectedSegment = tunnel.routingMode == .full ? 1 : 0
        routeDescriptionLabel.stringValue = tunnel.routingMode == .full
            ? tr("tunnelRoutingFullDescription")
            : tr("tunnelRoutingSplitDescription")
        dnsProtectionButton.title = tunnel.dnsProtectionPolicy.localizedTitle
        dnsProtectionDescriptionLabel.stringValue = tunnel.dnsProtectionPolicy.localizedDescription
        identityImageView.image = NSImage(
            systemSymbolName: tunnel.routingMode == .full
                ? "globe.americas.fill"
                : "arrow.triangle.branch",
            accessibilityDescription: tr("macTunnelTrafficRouting")
        ) ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        connectionButton.title = Self.localizedToggleStatusActionText(for: tunnel)
        connectionButton.toolTip = connectionButton.title
        connectionButton.isEnabled = tunnel.hasOnDemandRules
            || tunnel.status == .active
            || tunnel.status == .inactive
        switch tunnel.status {
        case .active, .restarting, .reasserting:
            statusLabel.textColor = .systemGreen
            connectionButton.image = NSImage(
                systemSymbolName: "stop.fill",
                accessibilityDescription: connectionButton.title
            )
        case .activating, .waiting, .deactivating:
            statusLabel.textColor = .systemOrange
            connectionButton.image = NSImage(
                systemSymbolName: "ellipsis",
                accessibilityDescription: connectionButton.title
            )
        case .inactive:
            statusLabel.textColor = .secondaryLabelColor
            connectionButton.image = NSImage(
                systemSymbolName: "power",
                accessibilityDescription: connectionButton.title
            )
        }
    }

    override func viewWillAppear() {
        if tunnel.status == .active {
            startUpdatingRuntimeConfiguration()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let tunnelEditVC = tunnelEditVC {
            dismiss(tunnelEditVC)
        }
        stopUpdatingRuntimeConfiguration()
    }

    func applyTunnelConfiguration(tunnelConfiguration: TunnelConfiguration) {
        // Incorporates changes from tunnelConfiguation. Ignores any changes in peer ordering.

        let tableView = self.tableView

        func handleSectionFieldsModified<T>(fields: [T], modelRowsInSection: [(isVisible: Bool, modelRow: TableViewModelRow)], rowOffset: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            var modifiedRowIndices = IndexSet()
            for (index, field) in fields.enumerated() {
                guard let change = changes[field] else { continue }
                if case .modified = change {
                    let row = modelRowsInSection[0 ..< index].filter { $0.isVisible }.count
                    modifiedRowIndices.insert(rowOffset + row)
                }
            }
            if !modifiedRowIndices.isEmpty {
                tableView.reloadData(forRowIndexes: modifiedRowIndices, columnIndexes: IndexSet(integer: 0))
            }
        }

        func handleSectionFieldsAddedOrRemoved<T>(fields: [T], modelRowsInSection: inout [(isVisible: Bool, modelRow: TableViewModelRow)], rowOffset: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            for (index, field) in fields.enumerated() {
                guard let change = changes[field] else { continue }
                let row = modelRowsInSection[0 ..< index].filter { $0.isVisible }.count
                switch change {
                case .added:
                    tableView.insertRows(at: IndexSet(integer: rowOffset + row), withAnimation: .effectFade)
                    modelRowsInSection[index].isVisible = true
                case .removed:
                    tableView.removeRows(at: IndexSet(integer: rowOffset + row), withAnimation: .effectFade)
                    modelRowsInSection[index].isVisible = false
                case .modified:
                    break
                }
            }
        }

        let changes = self.tunnelViewModel.applyConfiguration(other: tunnelConfiguration)

        if !changes.interfaceChanges.isEmpty {
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.interfaceFields,
                                        modelRowsInSection: self.tableViewModelRowsBySection[0],
                                        rowOffset: 0, changes: changes.interfaceChanges)
        }
        for (peerIndex, peerChanges) in changes.peerChanges {
            let sectionIndex = 1 + peerIndex
            let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.peerFields,
                                        modelRowsInSection: self.tableViewModelRowsBySection[sectionIndex],
                                        rowOffset: rowOffset, changes: peerChanges)
        }

        let isAnyInterfaceFieldAddedOrRemoved = changes.interfaceChanges.contains { $0.value == .added || $0.value == .removed }
        let isAnyPeerFieldAddedOrRemoved = changes.peerChanges.contains { $0.changes.contains { $0.value == .added || $0.value == .removed } }

        if isAnyInterfaceFieldAddedOrRemoved || isAnyPeerFieldAddedOrRemoved || !changes.peersRemovedIndices.isEmpty || !changes.peersInsertedIndices.isEmpty {
            tableView.beginUpdates()
            if isAnyInterfaceFieldAddedOrRemoved {
                handleSectionFieldsAddedOrRemoved(fields: TunnelDetailTableViewController.interfaceFields,
                                                  modelRowsInSection: &self.tableViewModelRowsBySection[0],
                                                  rowOffset: 0, changes: changes.interfaceChanges)
            }
            if isAnyPeerFieldAddedOrRemoved {
                for (peerIndex, peerChanges) in changes.peerChanges {
                    let sectionIndex = 1 + peerIndex
                    let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
                    handleSectionFieldsAddedOrRemoved(fields: TunnelDetailTableViewController.peerFields, modelRowsInSection: &self.tableViewModelRowsBySection[sectionIndex], rowOffset: rowOffset, changes: peerChanges)
                }
            }
            if !changes.peersRemovedIndices.isEmpty {
                for peerIndex in changes.peersRemovedIndices {
                    let sectionIndex = 1 + peerIndex
                    let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
                    let count = self.tableViewModelRowsBySection[sectionIndex].filter { $0.isVisible }.count
                    self.tableView.removeRows(at: IndexSet(integersIn: rowOffset ..< rowOffset + count), withAnimation: .effectFade)
                    self.tableViewModelRowsBySection.remove(at: sectionIndex)
                }
            }
            if !changes.peersInsertedIndices.isEmpty {
                for peerIndex in changes.peersInsertedIndices {
                    let peerData = self.tunnelViewModel.peersData[peerIndex]
                    let sectionIndex = 1 + peerIndex
                    let rowOffset = self.tableViewModelRowsBySection[0 ..< sectionIndex].flatMap { $0.filter { $0.isVisible } }.count
                    var modelRowsInSection: [(isVisible: Bool, modelRow: TableViewModelRow)] = TunnelDetailTableViewController.peerFields.map {
                        (isVisible: !peerData[$0].isEmpty, modelRow: .peerFieldRow(peer: peerData, field: $0))
                    }
                    modelRowsInSection.append((isVisible: true, modelRow: .spacerRow))
                    let count = modelRowsInSection.filter { $0.isVisible }.count
                    self.tableView.insertRows(at: IndexSet(integersIn: rowOffset ..< rowOffset + count), withAnimation: .effectFade)
                    self.tableViewModelRowsBySection.insert(modelRowsInSection, at: sectionIndex)
                }
            }
            updateTableViewModelRows()
            tableView.endUpdates()
        }
    }

    private func reloadRuntimeConfiguration() {
        tunnel.getRuntimeTunnelConfiguration { [weak self] tunnelConfiguration in
            guard let tunnelConfiguration = tunnelConfiguration else { return }
            self?.applyTunnelConfiguration(tunnelConfiguration: tunnelConfiguration)
        }
    }

    func startUpdatingRuntimeConfiguration() {
        reloadRuntimeConfiguration()
        reloadRuntimeConfigurationTimer?.invalidate()
        let reloadTimer = Timer(timeInterval: 1 /* second */, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadRuntimeConfiguration()
            }
        }
        reloadRuntimeConfigurationTimer = reloadTimer
        RunLoop.main.add(reloadTimer, forMode: .common)
    }

    func stopUpdatingRuntimeConfiguration() {
        reloadRuntimeConfiguration()
        reloadRuntimeConfigurationTimer?.invalidate()
        reloadRuntimeConfigurationTimer = nil
    }

}

extension TunnelDetailTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableViewModelRows.count
    }
}

extension TunnelDetailTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let modelRow = tableViewModelRows[row]
        switch modelRow {
        case .interfaceFieldRow(let field):
            if field == .status {
                return statusCell()
            } else if field == .toggleStatus {
                return toggleStatusCell()
            } else {
                let cell: KeyValueRow = tableView.dequeueReusableCell()
                let localizedKeyString = modelRow.isTitleRow() ? modelRow.localizedSectionKeyString() : field.localizedUIString
                cell.key = tr(format: "macFieldKey (%@)", localizedKeyString)
                cell.value = tunnelViewModel.interfaceData[field]
                cell.isKeyInBold = modelRow.isTitleRow()
                return cell
            }
        case .peerFieldRow(let peerData, let field):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            let localizedKeyString = modelRow.isTitleRow() ? modelRow.localizedSectionKeyString() : field.localizedUIString
            cell.key = tr(format: "macFieldKey (%@)", localizedKeyString)
            if field == .persistentKeepAlive {
                cell.value = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", peerData[field])
            } else if field == .preSharedKey {
                cell.value = tr("tunnelPeerPresharedKeyEnabled")
            } else {
                cell.value = peerData[field]
            }
            cell.isKeyInBold = modelRow.isTitleRow()
            return cell
        case .spacerRow:
            return NSView()
        case .onDemandRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = modelRow.localizedSectionKeyString()
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.isKeyInBold = true
            return cell
        case .onDemandSSIDRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr("macFieldOnDemandSSIDs")
            let value: String
            if onDemandViewModel.ssidOption == .anySSID {
                value = onDemandViewModel.ssidOption.localizedUIString
            } else {
                value = tr(format: "tunnelOnDemandSSIDOptionDescriptionMac (%1$@: %2$@)",
                           onDemandViewModel.ssidOption.localizedUIString,
                           onDemandViewModel.selectedSSIDs.joined(separator: ", "))
            }
            cell.value = value
            cell.isKeyInBold = false
            return cell
        }
    }

    func statusCell() -> NSView {
        let cell: KeyValueImageRow = tableView.dequeueReusableCell()
        cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceStatus"))
        cell.value = TunnelDetailTableViewController.localizedStatusDescription(for: tunnel)
        cell.valueImage = TunnelDetailTableViewController.image(for: tunnel)
        let refreshCell: @MainActor () -> Void = { [weak self, weak cell] in
            guard let self, let cell else { return }
            cell.value = Self.localizedStatusDescription(for: self.tunnel)
            cell.valueImage = Self.image(for: self.tunnel)
        }
        cell.statusObservationToken = tunnel.observe(\.status) { _, _ in
            Task { @MainActor in refreshCell() }
        }
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { _, _ in
            Task { @MainActor in refreshCell() }
        }
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { _, _ in
            Task { @MainActor in refreshCell() }
        }
        return cell
    }

    func toggleStatusCell() -> NSView {
        let cell: ButtonRow = tableView.dequeueReusableCell()
        cell.buttonTitle = TunnelDetailTableViewController.localizedToggleStatusActionText(for: tunnel)
        cell.isButtonEnabled = (tunnel.hasOnDemandRules || tunnel.status == .active || tunnel.status == .inactive)
        cell.buttonToolTip = tr("macToolTipToggleStatus")
        cell.onButtonClicked = { [weak self] in
            self?.handleToggleActiveStatusAction()
        }
        let refreshCell: @MainActor () -> Void = { [weak self, weak cell] in
            guard let self, let cell else { return }
            cell.buttonTitle = Self.localizedToggleStatusActionText(for: self.tunnel)
            cell.isButtonEnabled = self.tunnel.hasOnDemandRules
                || self.tunnel.status == .active
                || self.tunnel.status == .inactive
        }
        cell.statusObservationToken = tunnel.observe(\.status) { _, _ in
            Task { @MainActor in refreshCell() }
        }
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { _, _ in
            Task { @MainActor in refreshCell() }
        }
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { _, _ in
            Task { @MainActor in refreshCell() }
        }
        return cell
    }

    private static func localizedStatusDescription(for tunnel: TunnelContainer) -> String {
        let status = tunnel.status
        let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

        var text: String
        switch status {
        case .inactive:
            text = tr("tunnelStatusInactive")
        case .activating:
            text = tr("tunnelStatusActivating")
        case .active:
            text = tr("tunnelStatusActive")
        case .deactivating:
            text = tr("tunnelStatusDeactivating")
        case .reasserting:
            text = tr("tunnelStatusReasserting")
        case .restarting:
            text = tr("tunnelStatusRestarting")
        case .waiting:
            text = tr("tunnelStatusWaiting")
        }

        if tunnel.hasOnDemandRules {
            text += isOnDemandEngaged ?
                tr("tunnelStatusAddendumOnDemandEnabled") : tr("tunnelStatusAddendumOnDemandDisabled")
        }

        return text
    }

    private static func image(for tunnel: TunnelContainer?) -> NSImage? {
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

    private static func localizedToggleStatusActionText(for tunnel: TunnelContainer) -> String {
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            if turnOn {
                return tr("macToggleStatusButtonEnableOnDemand")
            } else {
                if tunnel.status == .active {
                    return tr("macToggleStatusButtonDisableOnDemandDeactivate")
                } else {
                    return tr("macToggleStatusButtonDisableOnDemand")
                }
            }
        } else {
            switch tunnel.status {
            case .waiting:
                return tr("macToggleStatusButtonWaiting")
            case .inactive:
                return tr("macToggleStatusButtonActivate")
            case .activating:
                return tr("macToggleStatusButtonActivating")
            case .active:
                return tr("macToggleStatusButtonDeactivate")
            case .deactivating:
                return tr("macToggleStatusButtonDeactivating")
            case .reasserting:
                return tr("macToggleStatusButtonReasserting")
            case .restarting:
                return tr("macToggleStatusButtonRestarting")
            }
        }
    }
}

extension TunnelDetailTableViewController: TunnelEditViewControllerDelegate {
    func tunnelSaved(tunnel: TunnelContainer) {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        updateTableViewModelRowsBySection()
        updateTableViewModelRows()
        tableView.reloadData()
        updateDashboard()
        self.tunnelEditVC = nil
    }

    func tunnelEditingCancelled() {
        self.tunnelEditVC = nil
    }
}
