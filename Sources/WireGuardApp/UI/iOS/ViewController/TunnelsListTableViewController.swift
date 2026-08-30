// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import UniformTypeIdentifiers
import UserNotifications

class TunnelsListTableViewController: UIViewController {

    var tunnelsManager: TunnelsManager?
    var onTunnelSelected: ((TunnelContainer) -> Void)?
    var onTunnelListChanged: (() -> Void)?

    enum TableState: Equatable {
        case normal
        case rowSwiped
        case multiSelect(selectionCount: Int)
    }

    let tableView: UITableView = {
        let tableView = UITableView(frame: CGRect.zero, style: .insetGrouped)
        tableView.backgroundColor = WireRouteAppearance.background
        tableView.estimatedRowHeight = 76
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 16)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.register(TunnelListCell.self)
        return tableView
    }()

    let centeredAddButton: BorderedTextButton = {
        let button = BorderedTextButton()
        button.title = tr("tunnelsListCenteredAddTunnelButtonTitle")
        return button
    }()

    let emptyStateView: UIView = {
        let view = UIView()
        view.isHidden = true
        return view
    }()

    let emptyStateGlyph: WireRouteGlyphView = {
        let glyph = WireRouteGlyphView()
        glyph.update(status: .inactive, routingMode: .split, animated: false)
        return glyph
    }()

    let emptyStateTitleLabel: UILabel = {
        let label = UILabel()
        label.text = tr("tunnelsListTitle")
        label.font = WireRouteAppearance.roundedFont(size: 28, weight: .bold, textStyle: .title1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        return label
    }()

    let emptyStateMessageLabel: UILabel = {
        let label = UILabel()
        label.text = tr("addTunnelMenuHeader")
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    let busyIndicator: UIActivityIndicatorView = {
        let busyIndicator: UIActivityIndicatorView
        busyIndicator = UIActivityIndicatorView(style: .medium)
        busyIndicator.hidesWhenStopped = true
        busyIndicator.color = WireRouteAppearance.signalBlue
        return busyIndicator
    }()

    var detailDisplayedTunnel: TunnelContainer?
    var tableState: TableState = .normal {
        didSet {
            handleTableStateChange()
        }
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = WireRouteAppearance.background

        tableView.dataSource = self
        tableView.delegate = self

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        view.addSubview(busyIndicator)
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            busyIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            busyIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        let emptyStateStack = UIStackView(arrangedSubviews: [emptyStateGlyph, emptyStateTitleLabel, emptyStateMessageLabel, centeredAddButton])
        emptyStateStack.axis = .vertical
        emptyStateStack.alignment = .center
        emptyStateStack.spacing = 12
        emptyStateStack.setCustomSpacing(20, after: emptyStateMessageLabel)

        emptyStateView.addSubview(emptyStateStack)
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateView)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyStateView.leadingAnchor, constant: 32),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: emptyStateView.trailingAnchor, constant: -32),
            emptyStateStack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -24),

            emptyStateGlyph.widthAnchor.constraint(equalToConstant: 72),
            emptyStateGlyph.heightAnchor.constraint(equalTo: emptyStateGlyph.widthAnchor),
            emptyStateMessageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])

        centeredAddButton.onTapped = { [weak self] in
            guard let self = self else { return }
            self.addButtonTapped(sender: self.centeredAddButton)
        }

        if tunnelsManager == nil {
            busyIndicator.startAnimating()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableState = .normal
        restorationIdentifier = "TunnelsListVC"

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = WireRouteAppearance.background
        navigationAppearance.shadowColor = .clear
        navigationAppearance.titleTextAttributes = [
            .font: WireRouteAppearance.roundedFont(size: 17, weight: .semibold, textStyle: .headline),
            .foregroundColor: UIColor.label
        ]
        navigationAppearance.largeTitleTextAttributes = [
            .font: WireRouteAppearance.roundedFont(size: 34, weight: .bold, textStyle: .largeTitle),
            .foregroundColor: UIColor.label
        ]
        navigationController?.navigationBar.standardAppearance = navigationAppearance
        navigationController?.navigationBar.scrollEdgeAppearance = navigationAppearance
        navigationController?.navigationBar.compactAppearance = navigationAppearance
    }

    func handleTableStateChange() {
        switch tableState {
        case .normal:
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addButtonTapped(sender:)))
            let settingsButton = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settingsButtonTapped(sender:)))
            settingsButton.accessibilityLabel = tr("tunnelsListSettingsButtonTitle")
            navigationItem.leftBarButtonItem = settingsButton
        case .rowSwiped:
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneButtonTapped))
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListSelectButtonTitle"), style: .plain, target: self, action: #selector(selectButtonTapped))
        case .multiSelect(let selectionCount):
            if selectionCount > 0 {
                navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListDeleteButtonTitle"), style: .plain, target: self, action: #selector(deleteButtonTapped(sender:)))
            } else {
                navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListSelectAllButtonTitle"), style: .plain, target: self, action: #selector(selectAllButtonTapped))
            }
        }
        if case .multiSelect(let selectionCount) = tableState, selectionCount > 0 {
            navigationItem.title = tr(format: "tunnelsListSelectedTitle (%d)", selectionCount)
        } else {
            navigationItem.title = tr("tunnelsListTitle")
        }
        if case .multiSelect = tableState {
            tableView.allowsMultipleSelectionDuringEditing = true
            navigationItem.largeTitleDisplayMode = .never
        } else {
            tableView.allowsMultipleSelectionDuringEditing = false
            navigationItem.largeTitleDisplayMode = .always
        }
    }

    func setTunnelsManager(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        tunnelsManager.tunnelsListDelegate = self

        busyIndicator.stopAnimating()
        tableView.reloadData()
        updateEmptyState(animated: false)
        onTunnelListChanged?()
    }

    func updateEmptyState(animated: Bool) {
        let shouldShowEmptyState = (tunnelsManager?.numberOfTunnels() ?? 0) == 0
        guard emptyStateView.isHidden == shouldShowEmptyState || tableView.isHidden != shouldShowEmptyState else { return }

        let changes = {
            self.emptyStateView.alpha = shouldShowEmptyState ? 1 : 0
            self.tableView.alpha = shouldShowEmptyState ? 0 : 1
        }

        if shouldShowEmptyState {
            emptyStateView.alpha = 0
            emptyStateView.isHidden = false
        } else {
            tableView.alpha = 0
            tableView.isHidden = false
        }

        let completion: (Bool) -> Void = { _ in
            self.emptyStateView.isHidden = !shouldShowEmptyState
            self.tableView.isHidden = shouldShowEmptyState
        }

        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    override func viewWillAppear(_: Bool) {
        if let selectedRowIndexPath = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selectedRowIndexPath, animated: false)
        }
    }

    @objc func addButtonTapped(sender: AnyObject) {
        guard tunnelsManager != nil else { return }

        let alert = UIAlertController(title: "", message: tr("addTunnelMenuHeader"), preferredStyle: .actionSheet)
        let importFileAction = UIAlertAction(title: tr("addTunnelMenuImportFile"), style: .default) { [weak self] _ in
            self?.presentViewControllerForFileImport()
        }
        alert.addAction(importFileAction)

        let scanQRCodeAction = UIAlertAction(title: tr("addTunnelMenuQRCode"), style: .default) { [weak self] _ in
            self?.presentViewControllerForScanningQRCode()
        }
        alert.addAction(scanQRCodeAction)

        let createFromScratchAction = UIAlertAction(title: tr("addTunnelMenuFromScratch"), style: .default) { [weak self] _ in
            if let self = self, let tunnelsManager = self.tunnelsManager {
                self.presentViewControllerForTunnelCreation(tunnelsManager: tunnelsManager)
            }
        }
        alert.addAction(createFromScratchAction)

        let cancelAction = UIAlertAction(title: tr("actionCancel"), style: .cancel)
        alert.addAction(cancelAction)

        if let sender = sender as? UIBarButtonItem {
            alert.popoverPresentationController?.barButtonItem = sender
        } else if let sender = sender as? UIView {
            alert.popoverPresentationController?.sourceView = sender
            alert.popoverPresentationController?.sourceRect = sender.bounds
        }
        present(alert, animated: true, completion: nil)
    }

    @objc func settingsButtonTapped(sender: UIBarButtonItem) {
        let settingsVC = SettingsTableViewController(tunnelsManager: tunnelsManager)
        let settingsNC = UINavigationController(rootViewController: settingsVC)
        settingsNC.modalPresentationStyle = .formSheet
        present(settingsNC, animated: true)
    }

    func presentViewControllerForTunnelCreation(tunnelsManager: TunnelsManager) {
        let editVC = TunnelEditTableViewController(tunnelsManager: tunnelsManager)
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .fullScreen
        present(editNC, animated: true)
    }

    func presentViewControllerForFileImport() {
        let wireGuardConfigurationType = UTType(importedAs: "com.wireguard.config.quick")
        let filePicker = UIDocumentPickerViewController(
            forOpeningContentTypes: [wireGuardConfigurationType, .plainText, .zip],
            asCopy: true
        )
        filePicker.delegate = self
        present(filePicker, animated: true)
    }

    func presentViewControllerForScanningQRCode() {
        let scanQRCodeVC = QRScanViewController()
        scanQRCodeVC.delegate = self
        let scanQRCodeNC = UINavigationController(rootViewController: scanQRCodeVC)
        scanQRCodeNC.modalPresentationStyle = .fullScreen
        present(scanQRCodeNC, animated: true)
    }

    @objc func selectButtonTapped() {
        let shouldCancelSwipe = tableState == .rowSwiped
        tableState = .multiSelect(selectionCount: 0)
        if shouldCancelSwipe {
            tableView.setEditing(false, animated: false)
        }
        tableView.setEditing(true, animated: true)
    }

    @objc func doneButtonTapped() {
        tableState = .normal
        tableView.setEditing(false, animated: true)
    }

    @objc func selectAllButtonTapped() {
        guard tableView.isEditing else { return }
        guard let tunnelsManager = tunnelsManager else { return }
        for index in 0 ..< tunnelsManager.numberOfTunnels() {
            tableView.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
        }
        tableState = .multiSelect(selectionCount: tableView.indexPathsForSelectedRows?.count ?? 0)
    }

    @objc func cancelButtonTapped() {
        tableState = .normal
        tableView.setEditing(false, animated: true)
    }

    @objc func deleteButtonTapped(sender: AnyObject?) {
        guard let sender = sender as? UIBarButtonItem else { return }
        guard let tunnelsManager = tunnelsManager else { return }

        let selectedTunnelIndices = tableView.indexPathsForSelectedRows?.map { $0.row } ?? []
        let selectedTunnels = selectedTunnelIndices.compactMap { tunnelIndex in
            tunnelIndex >= 0 && tunnelIndex < tunnelsManager.numberOfTunnels() ? tunnelsManager.tunnel(at: tunnelIndex) : nil
        }
        guard !selectedTunnels.isEmpty else { return }
        let message = selectedTunnels.count == 1 ?
            tr(format: "deleteTunnelConfirmationAlertButtonMessage (%d)", selectedTunnels.count) :
            tr(format: "deleteTunnelsConfirmationAlertButtonMessage (%d)", selectedTunnels.count)
        let title = tr("deleteTunnelsConfirmationAlertButtonTitle")
        ConfirmationAlertPresenter.showConfirmationAlert(message: message, buttonTitle: title,
                                                         from: sender, presentingVC: self) { [weak self] in
            self?.tunnelsManager?.removeMultiple(tunnels: selectedTunnels) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.tableState = .normal
                self.tableView.setEditing(false, animated: true)
            }
        }
    }

    func showTunnelDetail(for tunnel: TunnelContainer, animated: Bool) {
        guard let tunnelsManager = tunnelsManager else { return }
        guard let splitViewController = splitViewController else { return }
        guard let navController = navigationController else { return }

        onTunnelSelected?(tunnel)
        let tunnelDetailVC = TunnelDetailTableViewController(tunnelsManager: tunnelsManager,
                                                             tunnel: tunnel)
        let tunnelDetailNC = UINavigationController(rootViewController: tunnelDetailVC)
        tunnelDetailNC.restorationIdentifier = "DetailNC"
        if splitViewController.isCollapsed && navController.viewControllers.count > 1 {
            navController.setViewControllers([self, tunnelDetailNC], animated: animated)
        } else {
            splitViewController.showDetailViewController(tunnelDetailNC, sender: self, animated: animated)
        }
        detailDisplayedTunnel = tunnel
        self.presentedViewController?.dismiss(animated: false, completion: nil)
    }
}

extension TunnelsListTableViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let tunnelsManager = tunnelsManager else { return }
        TunnelImporter.importFromFile(urls: urls, into: tunnelsManager, sourceVC: self, errorPresenterType: ErrorPresenter.self)
    }
}

extension TunnelsListTableViewController: QRScanViewControllerDelegate {
    func addScannedQRCode(tunnelConfiguration: TunnelConfiguration, qrScanViewController: QRScanViewController,
                          completionHandler: (@MainActor @Sendable () -> Void)?) {
        tunnelsManager?.add(tunnelConfiguration: tunnelConfiguration) { result in
            switch result {
            case .failure(let error):
                ErrorPresenter.showErrorAlert(error: error, from: qrScanViewController, onDismissal: completionHandler)
            case .success:
                completionHandler?()
            }
        }
    }
}

extension TunnelsListTableViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return (tunnelsManager?.numberOfTunnels() ?? 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: TunnelListCell = tableView.dequeueReusableCell(for: indexPath)
        if let tunnelsManager = tunnelsManager {
            let tunnel = tunnelsManager.tunnel(at: indexPath.row)
            cell.tunnel = tunnel
            cell.onSwitchToggled = { [weak self] isOn in
                guard let self = self, let tunnelsManager = self.tunnelsManager else { return }
                if tunnel.hasOnDemandRules {
                    tunnelsManager.setOnDemandEnabled(isOn, on: tunnel) { error in
                        if error == nil && !isOn {
                            tunnelsManager.startDeactivation(of: tunnel)
                        }
                    }
                } else {
                    if isOn {
                        tunnelsManager.startActivation(of: tunnel)
                    } else {
                        tunnelsManager.startDeactivation(of: tunnel)
                    }
                }
            }
        }
        return cell
    }
}

extension TunnelsListTableViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !tableView.isEditing else {
            tableState = .multiSelect(selectionCount: tableView.indexPathsForSelectedRows?.count ?? 0)
            return
        }
        guard let tunnelsManager = tunnelsManager else { return }
        let tunnel = tunnelsManager.tunnel(at: indexPath.row)
        showTunnelDetail(for: tunnel, animated: true)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard !tableView.isEditing else {
            tableState = .multiSelect(selectionCount: tableView.indexPathsForSelectedRows?.count ?? 0)
            return
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: tr("tunnelsListSwipeDeleteButtonTitle")) { [weak self] _, _, completionHandler in
            guard let tunnelsManager = self?.tunnelsManager else { return }
            let tunnel = tunnelsManager.tunnel(at: indexPath.row)
            tunnelsManager.remove(tunnel: tunnel) { error in
                if error != nil {
                    ErrorPresenter.showErrorAlert(error: error!, from: self)
                    completionHandler(false)
                } else {
                    completionHandler(true)
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        if tableState == .normal {
            tableState = .rowSwiped
        }
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        if tableState == .rowSwiped {
            tableState = .normal
        }
    }
}

extension TunnelsListTableViewController: TunnelsManagerListDelegate {
    func tunnelAdded(at index: Int) {
        tableView.insertRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
        updateEmptyState(animated: true)
        onTunnelListChanged?()
    }

    func tunnelModified(at index: Int) {
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
        onTunnelListChanged?()
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        tableView.moveRow(at: IndexPath(row: oldIndex, section: 0), to: IndexPath(row: newIndex, section: 0))
        onTunnelListChanged?()
    }

    func tunnelRemoved(at index: Int, tunnel: TunnelContainer) {
        tableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
        updateEmptyState(animated: true)
        onTunnelListChanged?()
        if detailDisplayedTunnel == tunnel, let splitViewController = splitViewController {
            if splitViewController.isCollapsed != false {
                (splitViewController.viewControllers[0] as? UINavigationController)?.popToRootViewController(animated: false)
            } else {
                let detailVC = UIViewController()
                detailVC.view.backgroundColor = WireRouteAppearance.background
                let detailNC = UINavigationController(rootViewController: detailVC)
                splitViewController.showDetailViewController(detailNC, sender: self)
            }
            detailDisplayedTunnel = nil
            if let presentedNavController = self.presentedViewController as? UINavigationController, presentedNavController.viewControllers.first is TunnelEditTableViewController {
                self.presentedViewController?.dismiss(animated: false, completion: nil)
            }
        }
    }
}

extension UISplitViewController {
    func showDetailViewController(_ viewController: UIViewController, sender: Any?, animated: Bool) {
        if animated {
            showDetailViewController(viewController, sender: sender)
        } else {
            UIView.performWithoutAnimation {
                showDetailViewController(viewController, sender: sender)
            }
        }
    }
}
