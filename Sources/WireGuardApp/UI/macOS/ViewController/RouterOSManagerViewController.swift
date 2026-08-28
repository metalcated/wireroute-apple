// SPDX-License-Identifier: MIT

import Cocoa

@MainActor
final class RouterOSManagerViewController: NSViewController {
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
    private let progressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSReadOnlyMessage"))
    private let summaryLabel = NSTextField(labelWithString: tr("macRouterOSNotConnected"))
    private let tableView = NSTableView()
    private var rows = [DiscoveryRow]()
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

        let readOnlyBadge = NSTextField(labelWithString: tr("macRouterOSReadOnlyBadge"))
        readOnlyBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        readOnlyBadge.textColor = .systemBlue
        readOnlyBadge.alignment = .center
        readOnlyBadge.wantsLayer = true
        readOnlyBadge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        readOnlyBadge.layer?.cornerRadius = 7
        readOnlyBadge.layer?.cornerCurve = .continuous

        let headerRow = NSStackView(views: [titleLabel, readOnlyBadge])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        readOnlyBadge.setContentHuggingPriority(.required, for: .horizontal)

        let connectionCard = makeConnectionCard()

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)

        summaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        configureTableView()
        scrollView.documentView = tableView

        let contentStack = NSStackView(views: [headerRow, subtitleLabel, connectionCard, messageLabel, summaryLabel, scrollView])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.setCustomSpacing(4, after: headerRow)
        contentStack.setCustomSpacing(20, after: subtitleLabel)
        contentStack.setCustomSpacing(8, after: connectionCard)

        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            readOnlyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            readOnlyBadge.heightAnchor.constraint(equalToConstant: 24),
            connectionCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210)
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
        tableView.usesAlternatingRowBackgroundColors = true
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
        let credentials = RouterOSCredentials(
            username: storedConnection.username,
            password: storedConnection.password
        )

        setConnecting(true)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try RouterOSClient<URLSessionRouterOSHTTPTransport>(
                    baseURL: url,
                    credentials: credentials
                )
                async let interfacesRequest = client.wireGuardInterfaces()
                async let peersRequest = client.wireGuardPeers()
                let (interfaces, peers) = try await (interfacesRequest, peersRequest)
                guard !Task.isCancelled else { return }

                rows = interfaces.map(DiscoveryRow.interface) + peers.map(DiscoveryRow.peer)
                tableView.reloadData()
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
            } catch {
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
