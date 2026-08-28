// SPDX-License-Identifier: MIT

import Cocoa
import UniformTypeIdentifiers

@MainActor
final class RouterOSManagerViewController: NSViewController {
    private struct ConnectedContext: Sendable {
        let baseURL: URL
        let credentials: RouterOSCredentials
        let trustedCertificate: RouterOSServerCertificate?
    }

    private enum DiscoveryRow {
        case interface(RouterOSWireGuardInterface)
        case peer(RouterOSWireGuardPeer)

        var type: String {
            switch self {
            case .interface:
                return tr("macRouterOSInterfaceType")
            case .peer:
                return tr("macRouterOSPeerType")
            }
        }

        var name: String {
            switch self {
            case .interface(let interface):
                return interface.name
            case .peer(let peer):
                return peer.name ?? peer.comment ?? tr("macRouterOSUnnamedPeer")
            }
        }

        var detail: String {
            switch self {
            case .interface(let interface):
                if let port = interface.listenPort {
                    return tr(format: "macRouterOSListenPort (%d)", port)
                }
                return "—"
            case .peer(let peer):
                return peer.interfaceName
            }
        }

        var status: String {
            switch self {
            case .interface(let interface):
                if interface.isDisabled {
                    return tr("macRouterOSDisabled")
                }
                return interface.isRunning ? tr("macRouterOSRunning") : tr("macRouterOSStopped")
            case .peer(let peer):
                if peer.isDisabled {
                    return tr("macRouterOSDisabled")
                }
                if let lastHandshake = peer.lastHandshake, !lastHandshake.isEmpty {
                    return tr(format: "macRouterOSLastHandshake (%@)", lastHandshake)
                }
                return tr("macRouterOSNeverConnected")
            }
        }
    }

    private let urlField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let connectButton = NSButton(title: tr("macRouterOSConnect"), target: nil, action: nil)
    private let addPeerButton = NSButton(title: tr("macRouterOSSetUpPeer"), target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSReadOnlyMessage"))
    private let summaryLabel = NSTextField(labelWithString: tr("macRouterOSNotConnected"))
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSEmptyDiscovery"))
    private let tableView = NSTableView()
    private var rows = [DiscoveryRow]()
    private var interfaces = [RouterOSWireGuardInterface]()
    private var peers = [RouterOSWireGuardPeer]()
    private var connectedContext: ConnectedContext?
    private var connectionTask: Task<Void, Never>?

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: tr("macRouterOSTitle"))
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSSubtitle"))
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 14)

        let readOnlyBadgeLabel = NSTextField(labelWithString: tr("macRouterOSReadOnlyBadge"))
        readOnlyBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        readOnlyBadgeLabel.textColor = .systemBlue
        readOnlyBadgeLabel.alignment = .center

        let readOnlyBadge = NSView()
        readOnlyBadge.wantsLayer = true
        readOnlyBadge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        readOnlyBadge.layer?.cornerRadius = 7
        readOnlyBadge.layer?.cornerCurve = .continuous
        readOnlyBadge.addSubview(readOnlyBadgeLabel)
        readOnlyBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            readOnlyBadgeLabel.centerXAnchor.constraint(equalTo: readOnlyBadge.centerXAnchor),
            readOnlyBadgeLabel.centerYAnchor.constraint(equalTo: readOnlyBadge.centerYAnchor),
            readOnlyBadge.widthAnchor.constraint(equalTo: readOnlyBadgeLabel.widthAnchor, constant: 28),
            readOnlyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            readOnlyBadge.heightAnchor.constraint(equalToConstant: 24)
        ])

        let headerRow = NSStackView(views: [titleLabel, readOnlyBadge])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        readOnlyBadge.setContentHuggingPriority(.required, for: .horizontal)
        readOnlyBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let connectionCard = makeConnectionCard()

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)

        summaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addPeerButton.target = self
        addPeerButton.action = #selector(addPeerClicked)
        addPeerButton.bezelStyle = .rounded
        addPeerButton.controlSize = .large
        addPeerButton.isEnabled = false
        addPeerButton.setContentHuggingPriority(.required, for: .horizontal)
        let summaryRow = NSStackView(views: [summaryLabel, addPeerButton])
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = 12

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        configureTableView()
        scrollView.documentView = tableView

        let tableContainer = NSView()
        tableContainer.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 13)
        tableContainer.addSubview(emptyStateLabel)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor, constant: 12),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableContainer.leadingAnchor, constant: 40),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableContainer.trailingAnchor, constant: -40)
        ])

        let contentStack = NSStackView(views: [headerRow, subtitleLabel, connectionCard, messageLabel, summaryRow, tableContainer])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.setCustomSpacing(4, after: headerRow)
        contentStack.setCustomSpacing(20, after: subtitleLabel)
        contentStack.setCustomSpacing(8, after: connectionCard)

        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            connectionCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            summaryRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tableContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])

        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadStoredConnection()
    }

    private func makeConnectionCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1

        urlField.placeholderString = "https://router.example"
        usernameField.placeholderString = tr("macRouterOSUsernamePlaceholder")
        passwordField.placeholderString = tr("macRouterOSPasswordPlaceholder")
        for field in [urlField, usernameField, passwordField] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 14)
            field.delegate = self
        }

        connectButton.target = self
        connectButton.action = #selector(connectClicked)
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.keyEquivalent = "\r"

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let connectRow = NSStackView(views: [connectButton, progressIndicator])
        connectRow.orientation = .horizontal
        connectRow.alignment = .centerY
        connectRow.spacing = 10

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("macRouterOSAddress")), urlField],
            [NSTextField(labelWithString: tr("macRouterOSUsername")), usernameField],
            [NSTextField(labelWithString: tr("macRouterOSPassword")), passwordField],
            [NSView(), connectRow]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        card.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return card
    }

    private func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 8, height: 2)

        let columns: [(String, String, CGFloat)] = [
            ("type", tr("macRouterOSColumnType"), 100),
            ("name", tr("macRouterOSColumnName"), 190),
            ("detail", tr("macRouterOSColumnInterface"), 180),
            ("status", tr("macRouterOSColumnStatus"), 220)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 90
            tableView.addTableColumn(column)
        }
    }

    private func loadStoredConnection() {
        do {
            guard let storedConnection = try RouterOSCredentialStore.load() else { return }
            urlField.stringValue = storedConnection.url
            usernameField.stringValue = storedConnection.username
            passwordField.stringValue = storedConnection.password
        } catch {
            messageLabel.stringValue = error.localizedDescription
            messageLabel.textColor = .systemRed
        }
    }

    @objc private func connectClicked() {
        connectionTask?.cancel()
        invalidateDiscovery()
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = tr("macRouterOSConnecting")

        guard let url = URL(string: urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showError(RouterOSClientError.invalidBaseURL.localizedDescription)
            return
        }

        let storedConnection = RouterOSStoredConnection(
            url: url.absoluteString,
            username: usernameField.stringValue,
            password: passwordField.stringValue
        )
        connect(to: url, storedConnection: storedConnection)
    }

    private func connect(to url: URL, storedConnection: RouterOSStoredConnection) {
        let credentials = RouterOSCredentials(
            username: storedConnection.username,
            password: storedConnection.password
        )

        setConnecting(true)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trustedCertificate = try RouterOSCertificateStore.load(for: url)
                let client = try RouterOSClient<URLSessionRouterOSHTTPTransport>(
                    baseURL: url,
                    credentials: credentials,
                    trustedCertificate: trustedCertificate
                )
                async let interfacesRequest = client.wireGuardInterfaces()
                async let peersRequest = client.wireGuardPeers()
                let (interfaces, peers) = try await (interfacesRequest, peersRequest)
                guard !Task.isCancelled else { return }

                self.interfaces = interfaces
                self.peers = peers
                connectedContext = ConnectedContext(
                    baseURL: url,
                    credentials: credentials,
                    trustedCertificate: trustedCertificate
                )
                rows = interfaces.map(DiscoveryRow.interface) + peers.map(DiscoveryRow.peer)
                reloadDiscoveryTable()
                addPeerButton.isEnabled = !interfaces.isEmpty
                summaryLabel.stringValue = tr(
                    format: "macRouterOSDiscoverySummary (%d,%d)",
                    interfaces.count,
                    peers.count
                )
                messageLabel.stringValue = tr("macRouterOSConnectedReadOnly")
                messageLabel.textColor = .systemGreen

                do {
                    try RouterOSCredentialStore.save(storedConnection)
                } catch {
                    messageLabel.stringValue = tr("macRouterOSConnectedCredentialWarning")
                    messageLabel.textColor = .systemOrange
                }
            } catch is CancellationError {
                return
            } catch let certificateError as RouterOSTLSCertificateError {
                connectedContext = nil
                setConnecting(false)
                presentCertificateReview(
                    certificateError,
                    routerURL: url,
                    storedConnection: storedConnection
                )
                return
            } catch {
                connectedContext = nil
                showError(error.localizedDescription)
            }
            setConnecting(false)
        }
    }

    private func setConnecting(_ isConnecting: Bool) {
        connectButton.isEnabled = !isConnecting
        urlField.isEnabled = !isConnecting
        usernameField.isEnabled = !isConnecting
        passwordField.isEnabled = !isConnecting
        addPeerButton.isEnabled = !isConnecting && connectedContext != nil && !interfaces.isEmpty
        if isConnecting {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func showError(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.textColor = .systemRed
        setConnecting(false)
    }

    private func presentCertificateReview(
        _ error: RouterOSTLSCertificateError,
        routerURL: URL,
        storedConnection: RouterOSStoredConnection
    ) {
        guard let window = view.window else {
            showError(error.localizedDescription)
            return
        }

        let certificate: RouterOSServerCertificate
        let expectedFingerprint: String?
        let isReplacement: Bool
        let alert = NSAlert()
        switch error {
        case .untrusted(let received):
            certificate = received
            expectedFingerprint = nil
            isReplacement = false
            alert.alertStyle = .warning
            alert.messageText = tr("macRouterOSCertificateUntrustedTitle")
            alert.informativeText = tr("macRouterOSCertificateUntrustedMessage")
        case .changed(let expected, let received):
            certificate = received
            expectedFingerprint = expected
            isReplacement = true
            alert.alertStyle = .critical
            alert.messageText = tr("macRouterOSCertificateChangedTitle")
            alert.informativeText = tr("macRouterOSCertificateChangedMessage")
        }

        messageLabel.stringValue = error.localizedDescription
        messageLabel.textColor = .systemOrange
        alert.accessoryView = certificateDetailsView(
            certificate,
            expectedFingerprint: expectedFingerprint
        )

        let trustButton = alert.addButton(
            withTitle: tr(
                isReplacement
                    ? "macRouterOSReplaceCertificateAndConnect"
                    : "macRouterOSTrustCertificateAndConnect"
            )
        )
        trustButton.hasDestructiveAction = isReplacement
        alert.addButton(withTitle: tr("macRouterOSCancel"))

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                messageLabel.stringValue = tr("macRouterOSCertificateNotTrusted")
                messageLabel.textColor = .secondaryLabelColor
                return
            }
            do {
                try RouterOSCertificateStore.save(certificate, for: routerURL)
                messageLabel.stringValue = tr("macRouterOSCertificateTrustedConnecting")
                messageLabel.textColor = .secondaryLabelColor
                connect(to: routerURL, storedConnection: storedConnection)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func certificateDetailsView(
        _ certificate: RouterOSServerCertificate,
        expectedFingerprint: String?
    ) -> NSView {
        var rows = [[NSView]]()
        rows.append([
            certificateDetailLabel(tr("macRouterOSCertificateRouter")),
            certificateDetailValue("\(certificate.host):\(certificate.port)")
        ])
        rows.append([
            certificateDetailLabel(tr("macRouterOSCertificateName")),
            certificateDetailValue(
                certificate.subjectSummary ?? tr("macRouterOSCertificateUnnamed")
            )
        ])
        if let expectedFingerprint {
            rows.append([
                certificateDetailLabel(tr("macRouterOSCertificatePreviouslyTrusted")),
                certificateDetailValue(expectedFingerprint, isFingerprint: true)
            ])
        }
        rows.append([
            certificateDetailLabel(tr("macRouterOSCertificatePresented")),
            certificateDetailValue(certificate.fingerprintSHA256, isFingerprint: true)
        ])

        let containerHeight: CGFloat = expectedFingerprint == nil ? 104 : 146
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: containerHeight))
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 120
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 360
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return container
    }

    private func certificateDetailLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func certificateDetailValue(
        _ value: String,
        isFingerprint: Bool = false
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = isFingerprint
            ? .monospacedSystemFont(ofSize: 11, weight: .medium)
            : .systemFont(ofSize: 12)
        label.lineBreakMode = isFingerprint ? .byCharWrapping : .byTruncatingTail
        label.maximumNumberOfLines = isFingerprint ? 0 : 1
        label.isSelectable = isFingerprint
        return label
    }

    private func invalidateDiscovery() {
        connectedContext = nil
        interfaces = []
        peers = []
        rows = []
        reloadDiscoveryTable()
        summaryLabel.stringValue = tr("macRouterOSNotConnected")
        addPeerButton.isEnabled = false
    }

    @objc private func addPeerClicked() {
        guard connectedContext != nil, !interfaces.isEmpty else { return }
        let setupViewController = RouterOSPeerSetupViewController(
            interfaces: interfaces,
            existingPeers: peers
        )
        setupViewController.onCancel = { [weak self, weak setupViewController] in
            guard let self, let setupViewController else { return }
            dismiss(setupViewController)
        }
        setupViewController.onCreate = { [weak self, weak setupViewController] proposal in
            guard let self, let setupViewController else { return }
            dismiss(setupViewController)
            createPeer(proposal)
        }
        presentAsSheet(setupViewController)
    }

    private func createPeer(_ proposal: RouterOSPeerSetupViewController.Proposal) {
        guard let connectedContext else { return }
        connectionTask?.cancel()
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = tr("macRouterOSAddingPeer")
        setConnecting(true)

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try RouterOSClient<URLSessionRouterOSHTTPTransport>(
                    baseURL: connectedContext.baseURL,
                    credentials: connectedContext.credentials,
                    trustedCertificate: connectedContext.trustedCertificate
                )
                let createdPeer = try await client.createWireGuardPeer(proposal.peerCreation)
                guard !Task.isCancelled else { return }

                peers.append(createdPeer)
                rows = interfaces.map(DiscoveryRow.interface) + peers.map(DiscoveryRow.peer)
                reloadDiscoveryTable()
                summaryLabel.stringValue = tr(
                    format: "macRouterOSDiscoverySummary (%d,%d)",
                    interfaces.count,
                    peers.count
                )
                messageLabel.stringValue = tr("macRouterOSPeerAdded")
                messageLabel.textColor = .systemGreen
                setConnecting(false)
                showConfigurationHandoff(proposal.clientConfiguration)
            } catch is CancellationError {
                return
            } catch {
                if error as? RouterOSClientError == .writeOutcomeUncertain {
                    invalidateDiscovery()
                    showError(error.localizedDescription)
                    showConfigurationHandoff(
                        proposal.clientConfiguration,
                        title: tr("macRouterOSWriteUncertainTitle"),
                        message: tr("macRouterOSWriteUncertainMessage")
                    )
                } else {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    private func showConfigurationHandoff(
        _ configuration: WireGuardClientConfiguration,
        title: String = tr("macRouterOSPeerAddedTitle"),
        message: String = tr("macRouterOSPeerAddedMessage")
    ) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: tr("macRouterOSSaveConfiguration"))
        alert.addButton(withTitle: tr("macRouterOSCopyConfiguration"))
        alert.addButton(withTitle: tr("macRouterOSDone"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveConfiguration(configuration)
            case .alertSecondButtonReturn:
                Self.copyConfiguration(configuration)
            default:
                break
            }
        }
    }

    private func saveConfiguration(_ configuration: WireGuardClientConfiguration) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.prompt = tr("macRouterOSSave")
        panel.nameFieldStringValue = "\(Self.safeFilename(configuration.name)).conf"
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(configuration.wgQuickConfiguration.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            } catch {
                self?.showConfigurationRecoveryError(error, configuration: configuration)
            }
        }
    }

    private func showConfigurationRecoveryError(
        _ error: Error,
        configuration: WireGuardClientConfiguration
    ) {
        guard let window = view.window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = tr("macRouterOSSaveFailedTitle")
        alert.informativeText = tr("macRouterOSSaveFailedMessage")
        alert.addButton(withTitle: tr("macRouterOSCopyConfiguration"))
        alert.addButton(withTitle: tr("macRouterOSDone"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                Self.copyConfiguration(configuration)
            }
        }
    }

    private static func copyConfiguration(_ configuration: WireGuardClientConfiguration) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.wgQuickConfiguration, forType: .string)
    }

    private static func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\0")
        let sanitized = value.components(separatedBy: forbidden).joined(separator: "-")
        return sanitized.isEmpty ? "WireRoute-Peer" : sanitized
    }

    private func reloadDiscoveryTable() {
        tableView.usesAlternatingRowBackgroundColors = !rows.isEmpty
        emptyStateLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
    }
}

extension RouterOSManagerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier: identifier)
        let discoveryRow = rows[row]
        switch identifier.rawValue {
        case "type":
            cell.textField?.stringValue = discoveryRow.type
        case "name":
            cell.textField?.stringValue = discoveryRow.name
        case "detail":
            cell.textField?.stringValue = discoveryRow.detail
        case "status":
            cell.textField?.stringValue = discoveryRow.status
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

extension RouterOSManagerViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard connectedContext != nil else { return }
        invalidateDiscovery()
        messageLabel.stringValue = tr("macRouterOSReconnectRequired")
        messageLabel.textColor = .secondaryLabelColor
    }
}
