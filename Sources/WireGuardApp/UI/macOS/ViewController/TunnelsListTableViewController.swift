// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa
import UniformTypeIdentifiers

private final class ProfileTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 3, dy: 2)
        let selectionPath = NSBezierPath(roundedRect: selectionRect, xRadius: 11, yRadius: 11)
        let accentColor = NSColor.controlAccentColor
        let fillColor = isEmphasized
            ? accentColor.withAlphaComponent(0.18)
            : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.42)
        fillColor.setFill()
        selectionPath.fill()

        accentColor.withAlphaComponent(isEmphasized ? 0.42 : 0.20).setStroke()
        selectionPath.lineWidth = 1
        selectionPath.stroke()
    }
}

@MainActor
protocol TunnelsListTableViewControllerDelegate: AnyObject {
    func tunnelsSelected(tunnelIndices: [Int])
    func tunnelsListEmpty()
}

class TunnelsListTableViewController: NSViewController {

    let tunnelsManager: TunnelsManager
    weak var delegate: TunnelsListTableViewControllerDelegate?
    var isRemovingTunnelsFromWithinTheApp = false

    let tableView: NSTableView = {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TunnelsList")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 5)
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

        let button = NSPopUpButton(frame: NSRect.zero, pullsDown: true)
        button.menu = menu
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.imagePosition = .imageLeading
        button.toolTip = tr("macTunnelAddProfile")
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        return button
    }()

    let routerOSButton: NSButton = {
        let button = NSButton(title: tr("macButtonRouterOSPeers"), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: tr("macButtonRouterOSPeers"))
        button.imagePosition = .imageLeading
        button.contentTintColor = .systemBlue
        button.toolTip = tr("macMenuRouterOSManager")
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

        let button = NSPopUpButton(frame: NSRect.zero, pullsDown: true)
        button.menu = menu
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.imagePosition = .imageLeading
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
        routerOSButton.target = self
        routerOSButton.action = #selector(handleRouterOSManagerAction)

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
        clipView.documentView = tableView
        scrollView.contentView = clipView

        let titleLabel = NSTextField(labelWithString: tr("macTunnelProfilesTitle"))
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macTunnelProfilesSubtitle"))
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        let sidebarHeader = NSStackView(views: [titleLabel, subtitleLabel, routerOSButton])
        sidebarHeader.orientation = .vertical
        sidebarHeader.alignment = .leading
        sidebarHeader.spacing = 4
        sidebarHeader.setCustomSpacing(13, after: subtitleLabel)

        let buttonBar = NSStackView(views: [addButton, actionButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.distribution = .fillEqually

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        containerView.layer?.cornerRadius = 16
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        containerView.layer?.borderWidth = 1
        containerView.addSubview(sidebarHeader)
        containerView.addSubview(scrollView)
        containerView.addSubview(buttonBar)
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sidebarHeader.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            sidebarHeader.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            sidebarHeader.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            routerOSButton.widthAnchor.constraint(equalTo: sidebarHeader.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),
            buttonBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            buttonBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            containerView.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: 12)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 264),
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

    @objc func handleAddEmptyTunnelAction() {
        let tunnelEditVC = TunnelEditViewController(tunnelsManager: tunnelsManager, tunnel: nil)
        tunnelEditVC.delegate = self
        presentAsSheet(tunnelEditVC)
    }

    @objc func handleImportTunnelAction() {
        ImportPanelPresenter.presentImportPanel(tunnelsManager: tunnelsManager, sourceVC: self)
    }

    @objc func handleRouterOSManagerAction() {
        (NSApp.delegate as? AppDelegate)?.showRouterOSManager()
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

    @objc func handleViewLogAction() {
        let logVC = LogViewController()
        self.presentAsSheet(logVC)
    }

    @objc func handleExportTunnelsAction() {
        PrivateDataConfirmation.confirmAccess(to: tr("macExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let window = self.view.window else { return }
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.zip]
            savePanel.prompt = tr("macSheetButtonExportZip")
            savePanel.nameFieldLabel = tr("macNameFieldExportZip")
            savePanel.nameFieldStringValue = "wireguard-export.zip"
            let tunnelsManager = self.tunnelsManager
            savePanel.beginSheetModal(for: window) { [weak tunnelsManager] response in
                guard let tunnelsManager = tunnelsManager else { return }
                guard response == .OK else { return }
                guard let destinationURL = savePanel.url else { return }
                let count = tunnelsManager.numberOfTunnels()
                let tunnelConfigurations = (0 ..< count).compactMap { tunnelsManager.tunnel(at: $0).tunnelConfiguration }
                ZipExporter.exportConfigFiles(tunnelConfigurations: tunnelConfigurations, to: destinationURL) { [weak self] error in
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                        return
                    }
                }
            }
        }
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
            delegate?.tunnelsListEmpty()
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
            delegate?.tunnelsSelected(tunnelIndices: tableView.selectedRowIndexes.sorted())
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
