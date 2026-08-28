// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

private final class SplitRouteEntryViewController: UIViewController, UITextViewDelegate {
    var onSave: ((String, @escaping @MainActor @Sendable (WireGuardAppError?) -> Void) -> Void)?

    private let routeGlyphView: WireRouteGlyphView = {
        let view = WireRouteGlyphView()
        view.update(status: .inactive, routingMode: .split, animated: false)
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.text = tr("splitRouteEntryMessage")
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private let routesTextView: UITextView = {
        let textView = UITextView()
        textView.backgroundColor = WireRouteAppearance.card
        textView.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .numbersAndPunctuation
        textView.layer.cornerRadius = 14
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        return textView
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = tr("splitRouteEntryPlaceholder")
        label.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        label.textColor = .placeholderText
        label.numberOfLines = 0
        return label
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.text = tr("splitRouteEntryHint")
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private lazy var saveButton = UIBarButtonItem(
        barButtonSystemItem: .save,
        target: self,
        action: #selector(saveTapped)
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        title = tr("splitRouteEntryTitle")
        view.backgroundColor = WireRouteAppearance.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = saveButton
        saveButton.isEnabled = false

        routesTextView.delegate = self
        routesTextView.addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: routesTextView.leadingAnchor, constant: 17),
            placeholderLabel.trailingAnchor.constraint(equalTo: routesTextView.trailingAnchor, constant: -17),
            placeholderLabel.topAnchor.constraint(equalTo: routesTextView.topAnchor, constant: 14)
        ])

        let glyphContainer = UIView()
        glyphContainer.addSubview(routeGlyphView)
        routeGlyphView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            routeGlyphView.centerXAnchor.constraint(equalTo: glyphContainer.centerXAnchor),
            routeGlyphView.centerYAnchor.constraint(equalTo: glyphContainer.centerYAnchor),
            routeGlyphView.widthAnchor.constraint(equalToConstant: 56),
            routeGlyphView.heightAnchor.constraint(equalTo: routeGlyphView.widthAnchor),
            glyphContainer.heightAnchor.constraint(equalToConstant: 56)
        ])

        let stack = UIStackView(arrangedSubviews: [glyphContainer, messageLabel, routesTextView, hintLabel, errorLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(20, after: messageLabel)
        stack.setCustomSpacing(8, after: routesTextView)

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            routesTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        stack.setCustomSpacing(16, after: glyphContainer)
    }

    func textViewDidChange(_ textView: UITextView) {
        let containsText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholderLabel.isHidden = containsText
        saveButton.isEnabled = containsText
        errorLabel.isHidden = true
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        guard let onSave else { return }
        setSaving(true)
        onSave(routesTextView.text) { [weak self] error in
            guard let self else { return }
            self.setSaving(false)
            if let error {
                self.errorLabel.text = error.alertText.message
                self.errorLabel.isHidden = false
                return
            }
            self.dismiss(animated: true)
        }
    }

    private func setSaving(_ isSaving: Bool) {
        routesTextView.isEditable = !isSaving
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        saveButton.isEnabled = !isSaving
    }
}

class TunnelDetailTableViewController: UITableViewController {

    private enum Section {
        case status
        case routing
        case interface
        case peer(index: Int, peer: TunnelViewModel.PeerData)
        case onDemand
        case delete
    }

    static let interfaceFields: [TunnelViewModel.InterfaceField] = [
        .name, .publicKey, .addresses,
        .listenPort, .mtu, .dns
    ]

    static let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .persistentKeepAlive,
        .rxBytes, .txBytes, .lastHandshakeTime
    ]

    static let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .onDemand, .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer
    var tunnelViewModel: TunnelViewModel
    var onDemandViewModel: ActivateOnDemandViewModel

    private var sections = [Section]()
    private var interfaceFieldIsVisible = [Bool]()
    private var peerFieldIsVisible = [[Bool]]()

    private var statusObservationToken: AnyObject?
    private var onDemandObservationToken: AnyObject?
    private var reloadRuntimeConfigurationTimer: Timer?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(style: .grouped)
        loadSections()
        loadVisibleFields()
        statusObservationToken = tunnel.observe(\.status) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.tunnel.status == .active {
                    self.startUpdatingRuntimeConfiguration()
                } else if self.tunnel.status == .inactive {
                    self.reloadRuntimeConfiguration()
                    self.stopUpdatingRuntimeConfiguration()
                }
            }
        }
        onDemandObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Handle On-Demand getting turned on/off outside of the app.
                self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: self.tunnel)
                self.updateActivateOnDemandFields()
            }
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tunnelViewModel.interfaceData[.name]
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(ChevronCell.self)

        restorationIdentifier = "TunnelDetailVC:\(tunnel.name)"
    }

    private func loadSections() {
        sections.removeAll()
        sections.append(.status)
        sections.append(.routing)
        sections.append(.interface)
        for (index, peer) in tunnelViewModel.peersData.enumerated() {
            sections.append(.peer(index: index, peer: peer))
        }
        sections.append(.onDemand)
        sections.append(.delete)
    }

    private func loadVisibleFields() {
        let visibleInterfaceFields = tunnelViewModel.interfaceData.filterFieldsWithValueOrControl(interfaceFields: TunnelDetailTableViewController.interfaceFields)
        interfaceFieldIsVisible = TunnelDetailTableViewController.interfaceFields.map { visibleInterfaceFields.contains($0) }
        peerFieldIsVisible = tunnelViewModel.peersData.map { peer in
            let visiblePeerFields = peer.filterFieldsWithValueOrControl(peerFields: TunnelDetailTableViewController.peerFields)
            return TunnelDetailTableViewController.peerFields.map { visiblePeerFields.contains($0) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        if tunnel.status == .active {
            self.startUpdatingRuntimeConfiguration()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        stopUpdatingRuntimeConfiguration()
    }

    @objc func editTapped() {
        PrivateDataConfirmation.confirmAccess(to: tr("iosViewPrivateData")) { [weak self] in
            guard let self = self else { return }
            let editVC = TunnelEditTableViewController(tunnelsManager: self.tunnelsManager, tunnel: self.tunnel)
            editVC.delegate = self
            let editNC = UINavigationController(rootViewController: editVC)
            editNC.modalPresentationStyle = .fullScreen
            self.present(editNC, animated: true)
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
        reloadRuntimeConfigurationTimer?.invalidate()
        reloadRuntimeConfigurationTimer = nil
    }

    func applyTunnelConfiguration(tunnelConfiguration: TunnelConfiguration) {
        // Incorporates changes from tunnelConfiguation. Ignores any changes in peer ordering.
        guard let tableView = self.tableView else { return }
        let sections = self.sections
        let interfaceSectionIndex = sections.firstIndex {
            if case .interface = $0 {
                return true
            } else {
                return false
            }
        }!
        let firstPeerSectionIndex = interfaceSectionIndex + 1
        let interfaceFieldIsVisible = self.interfaceFieldIsVisible
        let peerFieldIsVisible = self.peerFieldIsVisible

        func handleSectionFieldsModified<T>(fields: [T], fieldIsVisible: [Bool], section: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            for (index, field) in fields.enumerated() {
                guard let change = changes[field] else { continue }
                if case .modified(let newValue) = change {
                    let row = fieldIsVisible[0 ..< index].filter { $0 }.count
                    let indexPath = IndexPath(row: row, section: section)
                    if let cell = tableView.cellForRow(at: indexPath) as? KeyValueCell {
                        cell.value = newValue
                    }
                }
            }
        }

        func handleSectionRowsInsertedOrRemoved<T>(fields: [T], fieldIsVisible fieldIsVisibleInput: [Bool], section: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            var fieldIsVisible = fieldIsVisibleInput

            var removedIndexPaths = [IndexPath]()
            for (index, field) in fields.enumerated().reversed() where changes[field] == .removed {
                let row = fieldIsVisible[0 ..< index].filter { $0 }.count
                removedIndexPaths.append(IndexPath(row: row, section: section))
                fieldIsVisible[index] = false
            }
            if !removedIndexPaths.isEmpty {
                tableView.deleteRows(at: removedIndexPaths, with: .automatic)
            }

            var addedIndexPaths = [IndexPath]()
            for (index, field) in fields.enumerated() where changes[field] == .added {
                let row = fieldIsVisible[0 ..< index].filter { $0 }.count
                addedIndexPaths.append(IndexPath(row: row, section: section))
                fieldIsVisible[index] = true
            }
            if !addedIndexPaths.isEmpty {
                tableView.insertRows(at: addedIndexPaths, with: .automatic)
            }
        }

        let changes = self.tunnelViewModel.applyConfiguration(other: tunnelConfiguration)

        if !changes.interfaceChanges.isEmpty {
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.interfaceFields, fieldIsVisible: interfaceFieldIsVisible,
                                        section: interfaceSectionIndex, changes: changes.interfaceChanges)
        }
        for (peerIndex, peerChanges) in changes.peerChanges {
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.peerFields, fieldIsVisible: peerFieldIsVisible[peerIndex], section: firstPeerSectionIndex + peerIndex, changes: peerChanges)
        }

        let isAnyInterfaceFieldAddedOrRemoved = changes.interfaceChanges.contains { $0.value == .added || $0.value == .removed }
        let isAnyPeerFieldAddedOrRemoved = changes.peerChanges.contains { $0.changes.contains { $0.value == .added || $0.value == .removed } }
        let peersRemovedSectionIndices = changes.peersRemovedIndices.map { firstPeerSectionIndex + $0 }
        let peersInsertedSectionIndices = changes.peersInsertedIndices.map { firstPeerSectionIndex + $0 }

        if isAnyInterfaceFieldAddedOrRemoved || isAnyPeerFieldAddedOrRemoved || !peersRemovedSectionIndices.isEmpty || !peersInsertedSectionIndices.isEmpty {
            tableView.beginUpdates()
            if isAnyInterfaceFieldAddedOrRemoved {
                handleSectionRowsInsertedOrRemoved(fields: TunnelDetailTableViewController.interfaceFields, fieldIsVisible: interfaceFieldIsVisible, section: interfaceSectionIndex, changes: changes.interfaceChanges)
            }
            if isAnyPeerFieldAddedOrRemoved {
                for (peerIndex, peerChanges) in changes.peerChanges {
                    handleSectionRowsInsertedOrRemoved(fields: TunnelDetailTableViewController.peerFields, fieldIsVisible: peerFieldIsVisible[peerIndex], section: firstPeerSectionIndex + peerIndex, changes: peerChanges)
                }
            }
            if !peersRemovedSectionIndices.isEmpty {
                tableView.deleteSections(IndexSet(peersRemovedSectionIndices), with: .automatic)
            }
            if !peersInsertedSectionIndices.isEmpty {
                tableView.insertSections(IndexSet(peersInsertedSectionIndices), with: .automatic)
            }
            self.loadSections()
            self.loadVisibleFields()
            tableView.endUpdates()
        } else {
            self.loadSections()
            self.loadVisibleFields()
        }
    }

    private func reloadRuntimeConfiguration() {
        tunnel.getRuntimeTunnelConfiguration { [weak self] tunnelConfiguration in
            guard let tunnelConfiguration = tunnelConfiguration else { return }
            guard let self = self else { return }
            self.applyTunnelConfiguration(tunnelConfiguration: tunnelConfiguration)
        }
    }

    private func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(where: { if case .onDemand = $0 { return true } else { return false } }) else { return }
        let numberOfTableViewOnDemandRows = tableView.numberOfRows(inSection: onDemandSection)
        let ssidRowIndexPath = IndexPath(row: 1, section: onDemandSection)
        switch (numberOfTableViewOnDemandRows, onDemandViewModel.isWiFiInterfaceEnabled) {
        case (1, true):
            tableView.insertRows(at: [ssidRowIndexPath], with: .automatic)
        case (2, false):
            tableView.deleteRows(at: [ssidRowIndexPath], with: .automatic)
        default:
            break
        }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
    }
}

extension TunnelDetailTableViewController: TunnelEditTableViewControllerDelegate {
    func tunnelSaved(tunnel: TunnelContainer) {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        loadSections()
        loadVisibleFields()
        title = tunnel.name
        restorationIdentifier = "TunnelDetailVC:\(tunnel.name)"
        tableView.reloadData()
    }
    func tunnelEditingCancelled() {
        // Nothing to do
    }
}

extension TunnelDetailTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status:
            return 1
        case .routing:
            return 1
        case .interface:
            return interfaceFieldIsVisible.filter { $0 }.count
        case .peer(let peerIndex, _):
            return peerFieldIsVisible[peerIndex].filter { $0 }.count
        case .onDemand:
            return onDemandViewModel.isWiFiInterfaceEnabled ? 2 : 1
        case .delete:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status:
            return tr("tunnelSectionTitleStatus")
        case .routing:
            return tr("tunnelSectionTitleRouting")
        case .interface:
            return tr("tunnelSectionTitleInterface")
        case .peer:
            return tr("tunnelSectionTitlePeer")
        case .onDemand:
            return tr("tunnelSectionTitleOnDemand")
        case .delete:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .status:
            return statusCell(for: tableView, at: indexPath)
        case .routing:
            return routingCell(for: tableView, at: indexPath)
        case .interface:
            return interfaceCell(for: tableView, at: indexPath)
        case .peer(let index, let peer):
            return peerCell(for: tableView, at: indexPath, with: peer, peerIndex: index)
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        case .delete:
            return deleteConfigurationCell(for: tableView, at: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard case .routing = sections[section] else { return nil }
        return tunnel.routingMode == .full
            ? tr("tunnelRoutingFullDescription")
            : tr("tunnelRoutingSplitDescription")
    }

    private func statusCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)

        let update: @MainActor @Sendable (SwitchCell?, TunnelContainer) -> Void = { cell, tunnel in
            guard let cell = cell else { return }

            let status = tunnel.status
            let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

            let isSwitchOn = (status == .activating || status == .active || isOnDemandEngaged)
            cell.switchView.setOn(isSwitchOn, animated: true)

            if isOnDemandEngaged && !(status == .activating || status == .active) {
                cell.switchView.onTintColor = UIColor.systemYellow
            } else {
                cell.switchView.onTintColor = UIColor.systemGreen
            }

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
                text += isOnDemandEngaged ? tr("tunnelStatusAddendumOnDemand") : ""
                cell.switchView.isUserInteractionEnabled = true
                cell.isEnabled = true
            } else {
                cell.switchView.isUserInteractionEnabled = (status == .inactive || status == .active)
                cell.isEnabled = (status == .inactive || status == .active)
            }

            if tunnel.hasOnDemandRules && !isOnDemandEngaged && status == .inactive {
                text = tr("tunnelStatusOnDemandDisabled")
            }

            cell.textLabel?.text = text
        }

        update(cell, tunnel)
        cell.statusObservationToken = tunnel.observe(\.status) { [weak self, weak cell] _, _ in
            Task { @MainActor in
                guard let self else { return }
                update(cell, self.tunnel)
            }
        }
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self, weak cell] _, _ in
            Task { @MainActor in
                guard let self else { return }
                update(cell, self.tunnel)
            }
        }
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { [weak self, weak cell] _, _ in
            Task { @MainActor in
                guard let self else { return }
                update(cell, self.tunnel)
            }
        }

        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self else { return }

            if self.tunnel.hasOnDemandRules {
                self.tunnelsManager.setOnDemandEnabled(isOn, on: self.tunnel) { error in
                    if error == nil && !isOn {
                        self.tunnelsManager.startDeactivation(of: self.tunnel)
                    }
                }
            } else {
                if isOn {
                    self.tunnelsManager.startActivation(of: self.tunnel)
                } else {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        }
        return cell
    }

    private func routingCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = tr("tunnelRoutingFullTunnel")
        cell.isOn = tunnel.routingMode == .full
        cell.onSwitchToggled = { [weak self, weak cell] isFullTunnel in
            guard let self, let cell else { return }
            cell.isEnabled = false
            let requestedMode: TunnelRouteMode = isFullTunnel ? .full : .split
            self.tunnelsManager.setRoutingMode(requestedMode, on: self.tunnel) { error in
                cell.isEnabled = true
                guard let error else {
                    self.refreshAfterRoutingChange()
                    return
                }
                cell.isOn = self.tunnel.routingMode == .full
                if let routingError = error as? TunnelRoutingError,
                   case .missingSplitRoutes = routingError {
                    self.presentSplitRouteEntry()
                    return
                }
                ErrorPresenter.showErrorAlert(error: error, from: self)
            }
        }
        return cell
    }

    private func presentSplitRouteEntry() {
        let routeEntryViewController = SplitRouteEntryViewController()
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

        let navigationController = UINavigationController(rootViewController: routeEntryViewController)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.preferredContentSize = CGSize(width: 540, height: 520)
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func refreshAfterRoutingChange() {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        loadSections()
        loadVisibleFields()
        tableView.reloadData()
    }

    private func interfaceCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let visibleInterfaceFields = TunnelDetailTableViewController.interfaceFields.enumerated().filter { interfaceFieldIsVisible[$0.offset] }.map { $0.element }
        let field = visibleInterfaceFields[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        cell.value = tunnelViewModel.interfaceData[field]
        return cell
    }

    private func peerCell(for tableView: UITableView, at indexPath: IndexPath, with peerData: TunnelViewModel.PeerData, peerIndex: Int) -> UITableViewCell {
        let visiblePeerFields = TunnelDetailTableViewController.peerFields.enumerated().filter { peerFieldIsVisible[peerIndex][$0.offset] }.map { $0.element }
        let field = visiblePeerFields[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        if field == .persistentKeepAlive {
            cell.value = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", peerData[field])
        } else if field == .preSharedKey {
            cell.value = tr("tunnelPeerPresharedKeyEnabled")
        } else {
            cell.value = peerData[field]
        }
        return cell
    }

    private func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = TunnelDetailTableViewController.onDemandFields[indexPath.row]
        if field == .onDemand {
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.key = field.localizedUIString
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.copyableGesture = false
            return cell
        } else {
            assert(field == .ssid)
            if onDemandViewModel.ssidOption == .anySSID {
                let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
                cell.key = field.localizedUIString
                cell.value = onDemandViewModel.ssidOption.localizedUIString
                cell.copyableGesture = false
                return cell
            } else {
                let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = field.localizedUIString
                cell.detailMessage = onDemandViewModel.localizedSSIDDescription
                return cell
            }
        }
    }

    private func deleteConfigurationCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = tr("deleteTunnelButtonTitle")
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            ConfirmationAlertPresenter.showConfirmationAlert(message: tr("deleteTunnelConfirmationAlertMessage"),
                                       buttonTitle: tr("deleteTunnelConfirmationAlertButtonTitle"),
                                       from: cell, presentingVC: self) { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.remove(tunnel: self.tunnel) { error in
                    if error != nil {
                        print("Error removing tunnel: \(String(describing: error))")
                        return
                    }
                }
            }
        }
        return cell
    }

}

extension TunnelDetailTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .onDemand = sections[indexPath.section],
            case .ssid = TunnelDetailTableViewController.onDemandFields[indexPath.row] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .onDemand = sections[indexPath.section],
            case .ssid = TunnelDetailTableViewController.onDemandFields[indexPath.row] {
            let ssidDetailVC = SSIDOptionDetailTableViewController(title: onDemandViewModel.ssidOption.localizedUIString, ssids: onDemandViewModel.selectedSSIDs)
            navigationController?.pushViewController(ssidDetailVC, animated: true)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
