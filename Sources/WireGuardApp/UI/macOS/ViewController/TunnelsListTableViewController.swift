// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa
import UniformTypeIdentifiers

private final class ProfileTableRowView: NSTableRowView {
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false {
        didSet { needsDisplay = true }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isPointerInside, !isSelected else { return }

        let hoverRect = bounds.insetBy(dx: 3, dy: 2)
        let hoverPath = NSBezierPath(roundedRect: hoverRect, xRadius: 7, yRadius: 7)
        let hoverColor = WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .raised).withAlphaComponent(0.72)
            : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.08)
        hoverColor.setFill()
        hoverPath.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 3, dy: 2)
        let selectionPath = NSBezierPath(roundedRect: selectionRect, xRadius: 7, yRadius: 7)
        let accentColor = WireRouteTheme.accentColor
        let fillColor = isEmphasized
            ? accentColor.withAlphaComponent(0.16)
            : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.30)
        fillColor.setFill()
        selectionPath.fill()

        let railRect = NSRect(
            x: selectionRect.minX,
            y: selectionRect.midY - 11,
            width: 3,
            height: 22
        )
        let railPath = NSBezierPath(roundedRect: railRect, xRadius: 1.5, yRadius: 1.5)
        accentColor.setFill()
        railPath.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }
}

final class ProfileTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let targetRow = row(at: location)
        guard targetRow >= 0 else { return nil }

        if !selectedRowIndexes.contains(targetRow) {
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        }
        return contextMenuProvider?(targetRow)
    }
}

private final class SidebarActionButton: NSButton {
    private let leadingImageView = NSImageView()
    private let buttonTitleLabel = NSTextField(labelWithString: "")
    private let trailingImageView = NSImageView()
    private let selectionRail = NSView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false {
        didSet {
            updateSymbolColors()
            needsDisplay = true
        }
    }
    var isDestinationSelected = false {
        didSet {
            updateSymbolColors()
            needsDisplay = true
        }
    }

    init(title: String, leadingSymbolName: String) {
        super.init(frame: .zero)

        self.title = ""
        isBordered = false
        wantsLayer = true
        focusRingType = .exterior
        setAccessibilityLabel(title)

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        leadingImageView.image = NSImage(systemSymbolName: leadingSymbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(symbolConfiguration)
        leadingImageView.contentTintColor = .secondaryLabelColor
        leadingImageView.imageScaling = .scaleProportionallyDown

        buttonTitleLabel.stringValue = title
        buttonTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        buttonTitleLabel.textColor = .labelColor
        buttonTitleLabel.alignment = .left
        buttonTitleLabel.lineBreakMode = .byTruncatingTail

        trailingImageView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        trailingImageView.contentTintColor = .tertiaryLabelColor
        trailingImageView.imageScaling = .scaleProportionallyDown

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )

        selectionRail.wantsLayer = true
        selectionRail.layer?.cornerRadius = 1.5
        selectionRail.isHidden = true

        addSubview(selectionRail)
        addSubview(leadingImageView)
        addSubview(buttonTitleLabel)
        addSubview(trailingImageView)
        selectionRail.translatesAutoresizingMaskIntoConstraints = false
        leadingImageView.translatesAutoresizingMaskIntoConstraints = false
        buttonTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingImageView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            selectionRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionRail.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionRail.widthAnchor.constraint(equalToConstant: 3),
            selectionRail.heightAnchor.constraint(equalToConstant: 18),
            leadingImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leadingImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingImageView.widthAnchor.constraint(equalToConstant: 18),
            leadingImageView.heightAnchor.constraint(equalToConstant: 18),
            trailingImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailingImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingImageView.widthAnchor.constraint(equalTo: leadingImageView.widthAnchor),
            trailingImageView.heightAnchor.constraint(equalTo: leadingImageView.heightAnchor),
            buttonTitleLabel.leadingAnchor.constraint(equalTo: leadingImageView.trailingAnchor, constant: 10),
            buttonTitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingImageView.leadingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let backgroundColor: NSColor
            if isDestinationSelected {
                backgroundColor = WireRouteTheme.accentColor.withAlphaComponent(0.16)
            } else if isPointerInside {
                backgroundColor = WireRouteTheme.isBlueNordic
                    ? WireRouteTheme.color(for: .raised).withAlphaComponent(0.72)
                    : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.08)
            } else {
                backgroundColor = .clear
            }
            layer?.backgroundColor = backgroundColor.cgColor
            selectionRail.layer?.backgroundColor = WireRouteTheme.accentColor.cgColor
        }
        layer?.borderWidth = 0
        selectionRail.isHidden = !isDestinationSelected
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSymbolColors()
        needsDisplay = true
    }

    @objc private func themeDidChange() {
        updateSymbolColors()
        needsDisplay = true
    }

    private func updateSymbolColors() {
        let isHighlighted = isDestinationSelected || isPointerInside
        leadingImageView.contentTintColor = isHighlighted ? WireRouteTheme.accentColor : .secondaryLabelColor
        trailingImageView.contentTintColor = isHighlighted ? WireRouteTheme.accentColor : .tertiaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }
}

private final class SidebarMenuButton: WireRoutePopUpButton {
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        controlSize = .regular
        font = .systemFont(ofSize: 13, weight: .medium)
        imagePosition = .imageLeading
        updateWireRouteTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
protocol TunnelsListTableViewControllerDelegate: AnyObject {
    func routerOSManagerSelected()
    func settingsSelected()
    func tunnelsSelected(tunnelIndices: [Int])
    func tunnelsListEmpty()
    func editSelectedTunnel()
    func toggleSelectedTunnelStatus()
}

class TunnelsListTableViewController: NSViewController {

    let tunnelsManager: TunnelsManager
    weak var delegate: TunnelsListTableViewControllerDelegate?
    var isRemovingTunnelsFromWithinTheApp = false
    private var isRouterOSManagerSelected = false
    private var isSettingsSelected = false

    let tableView: ProfileTableView = {
        let tableView = ProfileTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TunnelsList")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 54
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        return tableView
    }()

    let addButton: NSPopUpButton = {
        let imageItem = NSMenuItem(title: tr("macTunnelAddProfile"), action: nil, keyEquivalent: "")
        imageItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: tr("macTunnelAddProfile"))

        let menu = NSMenu()
        menu.addItem(imageItem)
        menu.addItem(withTitle: tr("macMenuAddEmptyTunnel"), action: #selector(handleAddEmptyTunnelAction), keyEquivalent: "n")
        menu.addItem(withTitle: tr("macMenuImportTunnels"), action: #selector(handleImportTunnelAction), keyEquivalent: "o")
        menu.autoenablesItems = false

        let button = SidebarMenuButton(frame: NSRect.zero, pullsDown: true)
        button.menu = menu
        button.toolTip = tr("macTunnelAddProfile")
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        return button
    }()

    let routerOSButton: NSButton = {
        let button = SidebarActionButton(title: tr("macButtonRouterOSPeers"), leadingSymbolName: "server.rack")
        button.toolTip = tr("macMenuRouterOSManager")
        return button
    }()

    let settingsButton: NSButton = {
        let button = SidebarActionButton(title: tr("macSettingsSidebar"), leadingSymbolName: "gearshape")
        button.toolTip = tr("macMenuSettings")
        return button
    }()

    let actionButton: NSPopUpButton = {
        let imageItem = NSMenuItem(title: tr("macTunnelMoreActions"), action: nil, keyEquivalent: "")
        imageItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: tr("macTunnelMoreActions"))

        let menu = NSMenu()
        menu.addItem(imageItem)
        menu.addItem(withTitle: tr("macMenuViewLog"), action: #selector(handleViewLogAction), keyEquivalent: "")
        menu.addItem(withTitle: tr("macMenuExportTunnels"), action: #selector(handleExportTunnelsAction), keyEquivalent: "")
        menu.addItem(.separator())
        let deleteItem = menu.addItem(withTitle: tr("macMenuDeleteSelected"), action: #selector(handleRemoveTunnelAction), keyEquivalent: "")
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: tr("macMenuDeleteSelected"))
        menu.autoenablesItems = true

        let button = SidebarMenuButton(frame: NSRect.zero, pullsDown: true)
        button.menu = menu
        button.toolTip = tr("macTunnelMoreActions")
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        return button
    }()

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contextMenuProvider = { [weak self] row in
            self?.profileContextMenu(for: row)
        }
        routerOSButton.target = self
        routerOSButton.action = #selector(handleRouterOSManagerAction)
        settingsButton.target = self
        settingsButton.action = #selector(handleSettingsAction)

        tableView.doubleAction = #selector(listDoubleClicked(sender:))

        let isSelected = selectTunnelInOperation() || selectTunnel(at: 0)
        if !isSelected {
            delegate?.tunnelsListEmpty()
        }
        tableView.allowsEmptySelection = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = tableView
        scrollView.contentView = clipView

        let titleLabel = NSTextField(labelWithString: tr("macTunnelProfilesTitle"))
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macTunnelProfilesSubtitle"))
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        let sidebarHeader = NSStackView(views: [titleLabel, subtitleLabel])
        sidebarHeader.orientation = .vertical
        sidebarHeader.alignment = .leading
        sidebarHeader.spacing = 4

        let buttonBar = NSStackView(views: [addButton, actionButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.distribution = .fillEqually

        let sectionDivider = NSBox()
        sectionDivider.boxType = .separator

        let manageTitleLabel = NSTextField(labelWithString: tr("macSidebarManageTitle").uppercased())
        manageTitleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        manageTitleLabel.textColor = .secondaryLabelColor
        manageTitleLabel.attributedStringValue = NSAttributedString(
            string: manageTitleLabel.stringValue,
            attributes: [
                .font: manageTitleLabel.font as Any,
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.8
            ]
        )

        let containerView = AppearanceAwareMaterialView(
            material: .sidebar,
            blendingMode: .withinWindow,
            nordicSurface: .sidebar
        )
        containerView.adaptiveBorderAlpha = 0
        containerView.layer?.cornerRadius = 9
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.borderWidth = 0
        containerView.addSubview(sidebarHeader)
        containerView.addSubview(scrollView)
        containerView.addSubview(buttonBar)
        containerView.addSubview(sectionDivider)
        containerView.addSubview(manageTitleLabel)
        containerView.addSubview(routerOSButton)
        containerView.addSubview(settingsButton)
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        sectionDivider.translatesAutoresizingMaskIntoConstraints = false
        manageTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        routerOSButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sidebarHeader.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 18),
            sidebarHeader.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 14),
            sidebarHeader.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 7),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -7),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -10),
            buttonBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            buttonBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            buttonBar.heightAnchor.constraint(equalToConstant: 34),
            sectionDivider.topAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: 14),
            sectionDivider.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            sectionDivider.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            manageTitleLabel.topAnchor.constraint(equalTo: sectionDivider.bottomAnchor, constant: 14),
            manageTitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 14),
            manageTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -14),
            routerOSButton.topAnchor.constraint(equalTo: manageTitleLabel.bottomAnchor, constant: 8),
            routerOSButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            routerOSButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            routerOSButton.heightAnchor.constraint(equalToConstant: 36),
            settingsButton.topAnchor.constraint(equalTo: routerOSButton.bottomAnchor, constant: 3),
            settingsButton.leadingAnchor.constraint(equalTo: routerOSButton.leadingAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: routerOSButton.trailingAnchor),
            settingsButton.heightAnchor.constraint(equalToConstant: 36),
            containerView.bottomAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 12)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 276),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        addButton.menu?.items.forEach { $0.target = self }
        actionButton.menu?.items.forEach { $0.target = self }

        view = containerView
    }

    override func viewWillAppear() {
        selectTunnelInOperation()
    }

    @discardableResult
    func selectTunnelInOperation() -> Bool {
        if let currentTunnel = tunnelsManager.tunnelInOperation(), let indexToSelect = tunnelsManager.index(of: currentTunnel) {
            return selectTunnel(at: indexToSelect)
        }
        return false
    }

    func selectTunnel(_ tunnel: TunnelContainer) {
        guard let tunnelIndex = tunnelsManager.index(of: tunnel) else { return }
        selectTunnel(at: tunnelIndex)
    }

    func selectRouterOSManager() {
        loadViewIfNeeded()
        isRouterOSManagerSelected = true
        isSettingsSelected = false
        (routerOSButton as? SidebarActionButton)?.isDestinationSelected = true
        (settingsButton as? SidebarActionButton)?.isDestinationSelected = false
        tableView.allowsEmptySelection = true
        tableView.deselectAll(nil)
        actionButton.isEnabled = false
        delegate?.routerOSManagerSelected()
    }

    func selectSettings() {
        loadViewIfNeeded()
        isRouterOSManagerSelected = false
        isSettingsSelected = true
        (routerOSButton as? SidebarActionButton)?.isDestinationSelected = false
        (settingsButton as? SidebarActionButton)?.isDestinationSelected = true
        tableView.allowsEmptySelection = true
        tableView.deselectAll(nil)
        actionButton.isEnabled = false
        delegate?.settingsSelected()
    }

    @objc func handleAddEmptyTunnelAction() {
        let tunnelEditVC = TunnelEditViewController(tunnelsManager: tunnelsManager, tunnel: nil)
        tunnelEditVC.delegate = self
        presentAsSheet(tunnelEditVC)
    }

    @objc func handleImportTunnelAction() {
        ImportPanelPresenter.presentImportPanel(tunnelsManager: tunnelsManager, sourceVC: self)
    }

    @objc func handleRouterOSManagerAction() {
        selectRouterOSManager()
    }

    @objc func handleSettingsAction() {
        selectSettings()
    }

    @objc func handleRemoveTunnelAction() {
        guard let window = view.window else { return }

        let selectedTunnelIndices = tableView.selectedRowIndexes.sorted().filter { $0 >= 0 && $0 < tunnelsManager.numberOfTunnels() }
        guard !selectedTunnelIndices.isEmpty else { return }
        var nextSelection = selectedTunnelIndices.last! + 1
        if nextSelection >= tunnelsManager.numberOfTunnels() {
            nextSelection = max(selectedTunnelIndices.first! - 1, 0)
        }

        let alert = DeleteTunnelsConfirmationAlert()
        if selectedTunnelIndices.count == 1 {
            let firstSelectedTunnel = tunnelsManager.tunnel(at: selectedTunnelIndices.first!)
            alert.messageText = tr(format: "macDeleteTunnelConfirmationAlertMessage (%@)", firstSelectedTunnel.name)
        } else {
            alert.messageText = tr(format: "macDeleteMultipleTunnelsConfirmationAlertMessage (%d)", selectedTunnelIndices.count)
        }
        alert.informativeText = tr("macDeleteTunnelConfirmationAlertInfo")
        alert.onDeleteClicked = { [weak self] completion in
            guard let self = self else { return }
            self.selectTunnel(at: nextSelection)
            let selectedTunnels = selectedTunnelIndices.map { self.tunnelsManager.tunnel(at: $0) }
            self.isRemovingTunnelsFromWithinTheApp = true
            self.tunnelsManager.removeMultiple(tunnels: selectedTunnels) { [weak self] error in
                guard let self = self else { return }
                self.isRemovingTunnelsFromWithinTheApp = false
                defer { completion() }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
             }
        }
        alert.beginSheetModal(for: window)
    }

    @objc private func handleEditSelectedTunnelAction() {
        delegate?.editSelectedTunnel()
    }

    @objc private func handleToggleSelectedTunnelStatusAction() {
        delegate?.toggleSelectedTunnelStatus()
    }

    @objc private func handleExportSelectedTunnelsAction() {
        let selectedIndices = tableView.selectedRowIndexes.sorted().filter {
            $0 >= 0 && $0 < tunnelsManager.numberOfTunnels()
        }
        guard !selectedIndices.isEmpty else { return }
        exportTunnels(at: selectedIndices)
    }

    @objc private func handleShowSelectedTunnelQRCodeAction() {
        guard let configuration = selectedSingleTunnelConfiguration() else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("macRouterOSShowQRCodePrivateData")) { [weak self] in
            guard let self else { return }
            ConfigurationQRCodePresenter.present(configuration, from: self)
        }
    }

    @objc private func handleCopySelectedTunnelPublicKeyAction() {
        guard let configuration = selectedSingleTunnelConfiguration() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            configuration.interface.privateKey.publicKey.base64Key,
            forType: .string
        )
    }

    @objc private func handleCopySelectedTunnelPrivateKeyAction() {
        guard let configuration = selectedSingleTunnelConfiguration() else { return }
        let privateKey = configuration.interface.privateKey.base64Key
        PrivateDataConfirmation.confirmAccess(to: tr("macRouterOSCopyPrivateKeyAuthentication")) { [weak self] in
            guard let self else { return }
            SensitiveKeyClipboardPresenter.confirmAndCopy(privateKey, from: self)
        }
    }

    private func selectedSingleTunnelConfiguration() -> TunnelConfiguration? {
        let selectedIndices = tableView.selectedRowIndexes.sorted().filter {
            $0 >= 0 && $0 < tunnelsManager.numberOfTunnels()
        }
        guard selectedIndices.count == 1 else { return nil }
        let tunnel = tunnelsManager.tunnel(at: selectedIndices[0])
        guard tunnel.isTunnelAvailableToUser else { return nil }
        return tunnel.tunnelConfiguration
    }

    @objc func handleViewLogAction() {
        let logVC = LogViewController()
        self.presentAsSheet(logVC)
    }

    @objc func handleExportTunnelsAction() {
        exportTunnels(at: Array(0 ..< tunnelsManager.numberOfTunnels()))
    }

    private func exportTunnels(at indices: [Int]) {
        guard !indices.isEmpty else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("macExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let window = self.view.window else { return }
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.zip]
            savePanel.prompt = tr("macSheetButtonExportZip")
            savePanel.nameFieldLabel = tr("macNameFieldExportZip")
            savePanel.nameFieldStringValue = "wireguard-export.zip"
            let tunnelsManager = self.tunnelsManager
            let tunnelIndices = indices
            savePanel.beginSheetModal(for: window) { [weak tunnelsManager] response in
                guard let tunnelsManager = tunnelsManager else { return }
                guard response == .OK else { return }
                guard let destinationURL = savePanel.url else { return }
                let tunnelConfigurations = tunnelIndices.compactMap { tunnelsManager.tunnel(at: $0).tunnelConfiguration }
                ZipExporter.exportConfigFiles(tunnelConfigurations: tunnelConfigurations, to: destinationURL) { [weak self] error in
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                        return
                    }
                }
            }
        }
    }

    private func profileContextMenu(for row: Int) -> NSMenu? {
        guard row >= 0, row < tunnelsManager.numberOfTunnels() else { return nil }

        let selectedIndices = tableView.selectedRowIndexes.sorted().filter {
            $0 >= 0 && $0 < tunnelsManager.numberOfTunnels()
        }
        guard !selectedIndices.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        if selectedIndices.count == 1 {
            let tunnel = tunnelsManager.tunnel(at: selectedIndices[0])
            if tunnel.isTunnelAvailableToUser {
                let toggleItem = menu.addItem(
                    withTitle: TunnelDetailTableViewController.localizedToggleStatusActionText(for: tunnel),
                    action: #selector(handleToggleSelectedTunnelStatusAction),
                    keyEquivalent: ""
                )
                toggleItem.target = self
                toggleItem.isEnabled = tunnel.hasOnDemandRules
                    || tunnel.status == .active
                    || tunnel.status == .inactive
                toggleItem.image = NSImage(
                    systemSymbolName: tunnel.status == .active ? "stop.circle" : "play.circle",
                    accessibilityDescription: toggleItem.title
                )

                let editItem = menu.addItem(
                    withTitle: tr("macMenuEditTunnel"),
                    action: #selector(handleEditSelectedTunnelAction),
                    keyEquivalent: ""
                )
                editItem.target = self
                editItem.image = NSImage(
                    systemSymbolName: "pencil",
                    accessibilityDescription: editItem.title
                )
                menu.addItem(.separator())

                let qrItem = menu.addItem(
                    withTitle: tr("macRouterOSContextShowQRCode"),
                    action: #selector(handleShowSelectedTunnelQRCodeAction),
                    keyEquivalent: ""
                )
                qrItem.target = self
                qrItem.isEnabled = tunnel.tunnelConfiguration != nil
                qrItem.image = NSImage(
                    systemSymbolName: "qrcode",
                    accessibilityDescription: qrItem.title
                )

                let copyPublicKeyItem = menu.addItem(
                    withTitle: tr("macRouterOSContextCopyPublicKey"),
                    action: #selector(handleCopySelectedTunnelPublicKeyAction),
                    keyEquivalent: ""
                )
                copyPublicKeyItem.target = self
                copyPublicKeyItem.isEnabled = tunnel.tunnelConfiguration != nil
                copyPublicKeyItem.image = NSImage(
                    systemSymbolName: "key.horizontal",
                    accessibilityDescription: copyPublicKeyItem.title
                )

                let copyPrivateKeyItem = menu.addItem(
                    withTitle: tr("macRouterOSContextCopyPrivateKey"),
                    action: #selector(handleCopySelectedTunnelPrivateKeyAction),
                    keyEquivalent: ""
                )
                copyPrivateKeyItem.target = self
                copyPrivateKeyItem.isEnabled = tunnel.tunnelConfiguration != nil
                copyPrivateKeyItem.image = NSImage(
                    systemSymbolName: "key.horizontal.fill",
                    accessibilityDescription: copyPrivateKeyItem.title
                )
                menu.addItem(.separator())
            }
        }

        let addItem = menu.addItem(
            withTitle: tr("macMenuAddEmptyTunnel"),
            action: #selector(handleAddEmptyTunnelAction),
            keyEquivalent: ""
        )
        addItem.target = self
        addItem.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: addItem.title
        )

        let importItem = menu.addItem(
            withTitle: tr("macMenuImportTunnels"),
            action: #selector(handleImportTunnelAction),
            keyEquivalent: ""
        )
        importItem.target = self
        importItem.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: importItem.title
        )

        menu.addItem(.separator())

        let exportKey = selectedIndices.count == 1
            ? "macTunnelContextExportProfile"
            : "macTunnelContextExportProfiles"
        let exportItem = menu.addItem(
            withTitle: tr(exportKey),
            action: #selector(handleExportSelectedTunnelsAction),
            keyEquivalent: ""
        )
        exportItem.target = self
        exportItem.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: exportItem.title
        )

        let exportAllItem = menu.addItem(
            withTitle: tr("macMenuExportTunnels"),
            action: #selector(handleExportTunnelsAction),
            keyEquivalent: ""
        )
        exportAllItem.target = self
        exportAllItem.image = NSImage(
            systemSymbolName: "archivebox",
            accessibilityDescription: exportAllItem.title
        )

        menu.addItem(.separator())

        let viewLogItem = menu.addItem(
            withTitle: tr("macMenuViewLog"),
            action: #selector(handleViewLogAction),
            keyEquivalent: ""
        )
        viewLogItem.target = self
        viewLogItem.image = NSImage(
            systemSymbolName: "doc.text.magnifyingglass",
            accessibilityDescription: viewLogItem.title
        )

        let routerOSItem = menu.addItem(
            withTitle: tr("macMenuRouterOSManager"),
            action: #selector(AppDelegate.showRouterOSManager),
            keyEquivalent: ""
        )
        routerOSItem.target = NSApp.delegate
        routerOSItem.image = NSImage(
            systemSymbolName: "server.rack",
            accessibilityDescription: routerOSItem.title
        )

        let settingsItem = menu.addItem(
            withTitle: tr("macMenuSettings"),
            action: #selector(AppDelegate.showRouterOSSettings),
            keyEquivalent: ""
        )
        settingsItem.target = NSApp.delegate
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: settingsItem.title
        )

        menu.addItem(.separator())
        let deleteItem = menu.addItem(
            withTitle: tr("macMenuDeleteSelected"),
            action: #selector(handleRemoveTunnelAction),
            keyEquivalent: ""
        )
        deleteItem.target = self
        deleteItem.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: deleteItem.title
        )

        return menu
    }

    @objc func listDoubleClicked(sender: AnyObject) {
        let tunnelIndex = tableView.clickedRow
        guard tunnelIndex >= 0 && tunnelIndex < tunnelsManager.numberOfTunnels() else { return }
        let tunnel = tunnelsManager.tunnel(at: tunnelIndex)
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            tunnelsManager.setOnDemandEnabled(turnOn, on: tunnel) { error in
                if error == nil && !turnOn {
                    self.tunnelsManager.startDeactivation(of: tunnel)
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

    @discardableResult
    private func selectTunnel(at index: Int) -> Bool {
        if index < tunnelsManager.numberOfTunnels() {
            isRouterOSManagerSelected = false
            isSettingsSelected = false
            (routerOSButton as? SidebarActionButton)?.isDestinationSelected = false
            (settingsButton as? SidebarActionButton)?.isDestinationSelected = false
            tableView.allowsEmptySelection = false
            actionButton.isEnabled = true
            tableView.scrollRowToVisible(index)
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return true
        }
        return false
    }
}

extension TunnelsListTableViewController: TunnelEditViewControllerDelegate {
    func tunnelSaved(tunnel: TunnelContainer) {
        if let tunnelIndex = tunnelsManager.index(of: tunnel), tunnelIndex >= 0 {
            self.selectTunnel(at: tunnelIndex)
        }
    }

    func tunnelEditingCancelled() {
        // Nothing to do
    }
}

extension TunnelsListTableViewController {
    func tunnelAdded(at index: Int) {
        tableView.insertRows(at: IndexSet(integer: index), withAnimation: .slideLeft)
        if tunnelsManager.numberOfTunnels() == 1 {
            selectTunnel(at: 0)
        }
        if !NSApp.isActive {
            // macOS's VPN prompt might have caused us to lose focus
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func tunnelModified(at index: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        tableView.moveRow(at: oldIndex, to: newIndex)
    }

    func tunnelRemoved(at index: Int) {
        let selectedIndices = tableView.selectedRowIndexes
        let isSingleSelectedTunnelBeingRemoved = selectedIndices.contains(index) && selectedIndices.count == 1
        tableView.removeRows(at: IndexSet(integer: index), withAnimation: .slideLeft)
        if tunnelsManager.numberOfTunnels() == 0 {
            if !isRouterOSManagerSelected && !isSettingsSelected {
                delegate?.tunnelsListEmpty()
            }
        } else if !isRemovingTunnelsFromWithinTheApp && isSingleSelectedTunnelBeingRemoved {
            let newSelection = min(index, tunnelsManager.numberOfTunnels() - 1)
            tableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
        }
    }
}

extension TunnelsListTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tunnelsManager.numberOfTunnels()
    }
}

extension TunnelsListTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return ProfileTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: TunnelListRow = tableView.dequeueReusableCell()
        cell.tunnel = tunnelsManager.tunnel(at: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedTunnelIndices = tableView.selectedRowIndexes.sorted()
        if !selectedTunnelIndices.isEmpty {
            isRouterOSManagerSelected = false
            isSettingsSelected = false
            (routerOSButton as? SidebarActionButton)?.isDestinationSelected = false
            (settingsButton as? SidebarActionButton)?.isDestinationSelected = false
            tableView.allowsEmptySelection = false
            actionButton.isEnabled = true
            delegate?.tunnelsSelected(tunnelIndices: selectedTunnelIndices)
        }
    }
}

extension TunnelsListTableViewController {
    override func keyDown(with event: NSEvent) {
        if event.specialKey == .delete {
            handleRemoveTunnelAction()
        }
    }
}

extension TunnelsListTableViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(TunnelsListTableViewController.handleRemoveTunnelAction) {
            return !tableView.selectedRowIndexes.isEmpty
        }
        return true
    }
}

class FillerButton: NSButton {
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    init() {
        super.init(frame: CGRect.zero)
        title = ""
        bezelStyle = .smallSquare
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // Eat mouseDown event, so that the button looks enabled but is unresponsive
    }
}
