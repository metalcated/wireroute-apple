// SPDX-License-Identifier: MIT

import Cocoa
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

@MainActor
enum ConfigurationQRCodePresenter {
    static func present(_ configuration: TunnelConfiguration, from sourceViewController: NSViewController) {
        guard let window = sourceViewController.view.window else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(configuration.asWgQuickConfig().utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("macRouterOSQRCodeFailed")
            alert.addButton(withTitle: tr("macRouterOSDone"))
            alert.beginSheetModal(for: window) { _ in }
            return
        }
        let scaledImage = outputImage.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        )
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = configuration.name ?? tr("macRouterOSExistingPeerDefaultName")
        alert.informativeText = tr("macRouterOSQRCodeMessage")
        alert.accessoryView = imageView
        alert.addButton(withTitle: tr("macRouterOSDone"))
        alert.beginSheetModal(for: window) { _ in }
    }
}

@MainActor
enum SensitiveKeyClipboardPresenter {
    static func confirmAndCopy(_ privateKey: String, from sourceViewController: NSViewController) {
        guard let window = sourceViewController.view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("macRouterOSCopyPrivateKeyTitle")
        alert.informativeText = tr("macRouterOSCopyPrivateKeyMessage")
        alert.addButton(withTitle: tr("macRouterOSCopyPrivateKeyConfirm"))
        alert.addButton(withTitle: tr("macRouterOSCancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            copy(privateKey)
        }
    }

    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            let currentPasteboard = NSPasteboard.general
            guard currentPasteboard.string(forType: .string) == value else { return }
            currentPasteboard.clearContents()
        }
    }
}

@MainActor
private final class RouterOSDiscoveryTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let targetRow = row(at: location)
        guard targetRow >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        return contextMenuProvider?(targetRow)
    }
}

@MainActor
private final class RouterOSDiscoveryRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard WireRouteTheme.isBlueNordic else {
            super.drawBackground(in: dirtyRect)
            return
        }
        let rowIndex = (superview as? NSTableView)?.row(for: self) ?? 0
        let surface: WireRouteTheme.Surface = rowIndex.isMultiple(of: 2) ? .inset : .surface
        WireRouteTheme.color(for: surface).setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class RouterOSDiscoveryHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard WireRouteTheme.isBlueNordic else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }

        WireRouteTheme.color(for: .surface).setFill()
        cellFrame.fill()
        WireRouteTheme.borderColor.withAlphaComponent(0.75).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 1).fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let titleSize = title.size()
        let titleRect = NSRect(
            x: cellFrame.minX + 10,
            y: cellFrame.midY - titleSize.height / 2,
            width: max(0, cellFrame.width - 20),
            height: titleSize.height
        )
        title.draw(in: titleRect)
    }
}

@MainActor
private final class RouterOSRemovePeerOptionsView: NSStackView {
    let removeLocalProfile = NSButton(
        checkboxWithTitle: tr("macRouterOSRemoveLocalProfile"),
        target: nil,
        action: nil
    )
    let exportLocalProfile = NSButton(
        checkboxWithTitle: tr("macRouterOSExportBeforeRemoval"),
        target: nil,
        action: nil
    )

    init(hasLocalProfile: Bool) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        addArrangedSubview(removeLocalProfile)
        addArrangedSubview(exportLocalProfile)

        removeLocalProfile.isEnabled = hasLocalProfile
        removeLocalProfile.target = self
        removeLocalProfile.action = #selector(removeLocalProfileChanged)
        exportLocalProfile.state = .on
        exportLocalProfile.isEnabled = false
        frame = NSRect(x: 0, y: 0, width: 430, height: 52)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func removeLocalProfileChanged() {
        exportLocalProfile.isEnabled = removeLocalProfile.state == .on
    }
}

@MainActor
final class RouterOSManagerViewController: NSViewController {
    private struct ConnectedContext: Sendable {
        let connectionID: UUID
        let baseURL: URL
        let credentials: RouterOSCredentials
        let trustedCertificate: RouterOSServerCertificate?
    }

    private enum DiscoveryRow {
        case peer(RouterOSWireGuardPeer)

        var name: String {
            switch self {
            case .peer(let peer):
                return peer.name ?? peer.comment ?? tr("macRouterOSUnnamedPeer")
            }
        }

        var detail: String {
            switch self {
            case .peer(let peer):
                return peer.interfaceName
            }
        }

        var status: String {
            switch self {
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

    private let tunnelsManager: TunnelsManager
    private let connectionPopUp = WireRoutePopUpButton()
    private let connectButton = NSButton(title: tr("macRouterOSConnect"), target: nil, action: nil)
    private let manageConnectionsButton = NSButton(
        title: tr("macRouterOSManageConnections"),
        target: nil,
        action: nil
    )
    private let addPeerButton = NSButton(title: tr("macRouterOSSetUpPeer"), target: nil, action: nil)
    private let importPeerButton = NSButton(title: tr("macRouterOSImportExistingPeer"), target: nil, action: nil)
    private let showAllPeersButton = NSButton(
        checkboxWithTitle: tr("macRouterOSShowAllPeers"),
        target: nil,
        action: nil
    )
    private let progressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSReadOnlyMessage"))
    private let summaryLabel = NSTextField(labelWithString: tr("macRouterOSNotConnected"))
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSEmptyDiscovery"))
    private let tableView = RouterOSDiscoveryTableView()
    private var rows = [DiscoveryRow]()
    private var interfaces = [RouterOSWireGuardInterface]()
    private var peers = [RouterOSWireGuardPeer]()
    private var publicEndpointSuggestion: RouterOSPublicEndpointSuggestion?
    private var connectedContext: ConnectedContext?
    private var connectionTask: Task<Void, Never>?
    private var isBusy = false
    private var contextPeer: RouterOSWireGuardPeer?
    private var savedConnections = [RouterOSStoredConnection]()
    var onOpenSettings: (() -> Void)?

    private static let selectedConnectionKey = "WireRoute.RouterOSSelectedConnection"

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = NSView()

        let titleLabel = NSTextField(labelWithString: tr("macRouterOSTitle"))
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSSubtitle"))
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 14)

        let readOnlyBadgeLabel = NSTextField(labelWithString: tr("macRouterOSReadOnlyBadge"))
        readOnlyBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        readOnlyBadgeLabel.textColor = WireRouteTheme.accentColor
        readOnlyBadgeLabel.alignment = .center

        let readOnlyBadge = AppearanceAwareLayerView()
        readOnlyBadge.wantsLayer = true
        readOnlyBadge.adaptiveBackgroundColor = WireRouteTheme.accentColor
        readOnlyBadge.adaptiveBackgroundAlpha = 0.12
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

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [titleLabel, readOnlyBadge, headerSpacer])
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
        importPeerButton.target = self
        importPeerButton.action = #selector(importExistingPeerClicked)
        importPeerButton.bezelStyle = .rounded
        importPeerButton.controlSize = .large
        importPeerButton.isEnabled = false
        importPeerButton.toolTip = tr("macRouterOSImportExistingPeerHelp")
        importPeerButton.setContentHuggingPriority(.required, for: .horizontal)
        showAllPeersButton.target = self
        showAllPeersButton.action = #selector(showAllPeersChanged)
        showAllPeersButton.state = .off
        showAllPeersButton.isEnabled = false
        showAllPeersButton.toolTip = tr("macRouterOSShowAllPeersHelp")
        showAllPeersButton.setContentHuggingPriority(.required, for: .horizontal)
        let summarySpacer = NSView()
        summarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let summaryRow = NSStackView(
            views: [summaryLabel, summarySpacer, showAllPeersButton, importPeerButton, addPeerButton]
        )
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = 12

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        configureTableView()
        scrollView.documentView = tableView

        let tableContainer = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .inset
        )
        tableContainer.adaptiveBorderColor = .separatorColor
        tableContainer.adaptiveBorderAlpha = 0.45
        tableContainer.layer?.cornerRadius = 12
        tableContainer.layer?.cornerCurve = .continuous
        tableContainer.layer?.borderWidth = 1
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
            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            summaryRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tableContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])

        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savedConnectionsDidChange),
            name: RouterOSCredentialStore.connectionsDidChange,
            object: nil
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--app-store-screenshots") {
            savedConnections = [RouterOSStoredConnection(
                id: UUID(),
                name: "Office Router",
                url: "https://router.example",
                username: "reviewer",
                password: ""
            )]
            populateConnectionPopUp(preferredID: savedConnections[0].id)
            return
        }
        #endif
        reloadSavedConnections()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        #if DEBUG
        guard !ProcessInfo.processInfo.arguments.contains("--app-store-screenshots") else { return }
        #endif
        reloadSavedConnections()
    }

    private func makeConnectionCard() -> NSView {
        let card = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .surface
        )
        card.adaptiveBorderColor = .separatorColor
        card.adaptiveBorderAlpha = 0.65
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1

        let titleLabel = NSTextField(labelWithString: tr("macRouterOSConnectionTitle"))
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let helpLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSConnectionHelp"))
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor

        connectionPopUp.controlSize = .large
        connectionPopUp.font = .systemFont(ofSize: 14)
        connectionPopUp.target = self
        connectionPopUp.action = #selector(connectionSelectionChanged)

        connectButton.target = self
        connectButton.action = #selector(connectClicked)
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.keyEquivalent = "\r"

        manageConnectionsButton.target = self
        manageConnectionsButton.action = #selector(manageConnectionsClicked)
        manageConnectionsButton.bezelStyle = .rounded
        manageConnectionsButton.controlSize = .large

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let connectRow = NSStackView(views: [connectionPopUp, connectButton, progressIndicator, rowSpacer, manageConnectionsButton])
        connectRow.orientation = .horizontal
        connectRow.alignment = .centerY
        connectRow.spacing = 10

        let stack = NSStackView(views: [titleLabel, connectRow, helpLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        connectRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        helpLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            connectionPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
        return card
    }

    private func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.contextMenuProvider = { [weak self] row in
            self?.peerContextMenu(for: row)
        }

        let columns: [(String, String, CGFloat)] = [
            ("name", tr("macRouterOSColumnName"), 240),
            ("detail", tr("macRouterOSColumnInterface"), 200),
            ("status", tr("macRouterOSColumnStatus"), 220)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.headerCell = RouterOSDiscoveryHeaderCell(textCell: title)
            column.width = width
            column.minWidth = 90
            tableView.addTableColumn(column)
        }
    }

    private var selectedConnection: RouterOSStoredConnection? {
        guard let identifier = connectionPopUp.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: identifier) else {
            return nil
        }
        return savedConnections.first { $0.id == id }
    }

    @objc private func savedConnectionsDidChange() {
        reloadSavedConnections()
    }

    private func reloadSavedConnections() {
        let preferredID = selectedConnection?.id
            ?? UserDefaults.standard.string(forKey: Self.selectedConnectionKey).flatMap(UUID.init(uuidString:))
        do {
            savedConnections = try RouterOSCredentialStore.loadAll().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            populateConnectionPopUp(preferredID: preferredID)

            if let context = connectedContext {
                let matchingConnection = savedConnections.first { $0.id == context.connectionID }
                let stillMatches = matchingConnection.map {
                    URL(string: $0.url) == context.baseURL
                        && $0.username == context.credentials.username
                        && $0.password == context.credentials.password
                } ?? false
                if !stillMatches {
                    invalidateDiscovery()
                    messageLabel.stringValue = tr("macRouterOSReconnectRequired")
                    messageLabel.textColor = .secondaryLabelColor
                }
            }
        } catch {
            savedConnections = []
            populateConnectionPopUp(preferredID: nil)
            messageLabel.stringValue = error.localizedDescription
            messageLabel.textColor = .systemRed
        }
    }

    private func populateConnectionPopUp(preferredID: UUID?) {
        connectionPopUp.removeAllItems()
        if savedConnections.isEmpty {
            connectionPopUp.addItem(withTitle: tr("macRouterOSNoConnections"))
        }
        for connection in savedConnections {
            let host = URL(string: connection.url)?.host ?? connection.url
            let title = connection.name.compare(
                host,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame ? connection.name : "\(connection.name) — \(host)"
            connectionPopUp.addItem(withTitle: title)
            connectionPopUp.lastItem?.representedObject = connection.id.uuidString
        }

        let selectedIndex = preferredID.flatMap { id in
            savedConnections.firstIndex { $0.id == id }
        } ?? (savedConnections.isEmpty ? nil : 0)
        if let selectedIndex {
            connectionPopUp.selectItem(at: selectedIndex)
            UserDefaults.standard.set(savedConnections[selectedIndex].id.uuidString, forKey: Self.selectedConnectionKey)
        }

        let hasConnections = !savedConnections.isEmpty
        connectionPopUp.isEnabled = hasConnections && !isBusy
        connectButton.isEnabled = hasConnections && !isBusy
        updateConnectButtonPresentation()
        connectionPopUp.toolTip = hasConnections
            ? tr("macRouterOSConnectionSelectorHelp")
            : tr("macRouterOSNoConnectionsHelp")
        reloadDiscoveryTable()
    }

    @objc private func connectionSelectionChanged() {
        guard let selectedConnection else { return }
        UserDefaults.standard.set(selectedConnection.id.uuidString, forKey: Self.selectedConnectionKey)
        if let context = connectedContext, context.connectionID != selectedConnection.id {
            invalidateDiscovery()
            messageLabel.stringValue = tr("macRouterOSReconnectRequired")
            messageLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func manageConnectionsClicked() {
        onOpenSettings?()
    }

    @objc private func connectClicked() {
        connectionTask?.cancel()
        invalidateDiscovery()
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = tr("macRouterOSConnecting")

        guard let storedConnection = selectedConnection else {
            showError(tr("macRouterOSNoConnectionsHelp"))
            return
        }
        guard let url = URL(string: storedConnection.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showError(RouterOSClientError.invalidBaseURL.localizedDescription)
            return
        }
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
                async let addressesRequest = try? client.ipAddresses()
                let (interfaces, peers, addresses) = try await (
                    interfacesRequest,
                    peersRequest,
                    addressesRequest
                )
                guard !Task.isCancelled else { return }

                self.interfaces = interfaces
                self.peers = peers
                publicEndpointSuggestion = RouterOSPublicEndpointSuggestion.discover(
                    from: addresses ?? []
                )
                connectedContext = ConnectedContext(
                    connectionID: storedConnection.id,
                    baseURL: url,
                    credentials: credentials,
                    trustedCertificate: trustedCertificate
                )
                rebuildDiscoveryRows()
                addPeerButton.isEnabled = !interfaces.isEmpty
                messageLabel.stringValue = tr("macRouterOSConnectedReadOnly")
                messageLabel.textColor = .systemGreen
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
        isBusy = isConnecting
        connectButton.isEnabled = !isConnecting && selectedConnection != nil
        updateConnectButtonPresentation()
        connectionPopUp.isEnabled = !isConnecting && !savedConnections.isEmpty
        manageConnectionsButton.isEnabled = !isConnecting
        addPeerButton.isEnabled = !isConnecting && connectedContext != nil && !interfaces.isEmpty
        showAllPeersButton.isEnabled = !isConnecting && connectedContext != nil && !peers.isEmpty
        updateImportPeerButtonState()
        if isConnecting {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func updateConnectButtonPresentation() {
        let isConnectedToSelection = connectedContext?.connectionID == selectedConnection?.id
        connectButton.title = tr(isConnectedToSelection ? "macRouterOSConnected" : "macRouterOSConnect")
        connectButton.toolTip = isConnectedToSelection
            ? tr("macRouterOSConnectedRefreshHelp")
            : tr("macRouterOSConnect")
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
        updateConnectButtonPresentation()
        interfaces = []
        peers = []
        publicEndpointSuggestion = nil
        rows = []
        reloadDiscoveryTable()
        summaryLabel.stringValue = tr("macRouterOSNotConnected")
        addPeerButton.isEnabled = false
        importPeerButton.isEnabled = false
        showAllPeersButton.isEnabled = false
    }

    @objc private func showAllPeersChanged() {
        rebuildDiscoveryRows()
    }

    private var selectedPeer: RouterOSWireGuardPeer? {
        let selectedRow = tableView.selectedRow
        guard rows.indices.contains(selectedRow), case .peer(let peer) = rows[selectedRow] else {
            return nil
        }
        return peer
    }

    private func updateImportPeerButtonState() {
        importPeerButton.isEnabled = !isBusy && connectedContext != nil && selectedPeer != nil
    }

    private func peerContextMenu(for row: Int) -> NSMenu? {
        guard !isBusy, connectedContext != nil, rows.indices.contains(row),
              case .peer(let peer) = rows[row] else {
            return nil
        }
        contextPeer = peer
        let tunnel = existingTunnel(matching: peer)
        let hasLocalConfiguration = tunnel?.tunnelConfiguration != nil
        let hasRecovery = Keychain.recoveryConfiguration(for: peer.id) != nil

        let menu = NSMenu()
        let openItem = menuItem(
            title: tr("macRouterOSContextOpenInWireRoute"),
            action: #selector(openContextPeerInWireRoute)
        )
        openItem.isEnabled = tunnel != nil
        menu.addItem(openItem)
        menu.addItem(
            menuItem(
                title: tr("macRouterOSContextImportConfiguration"),
                action: #selector(importContextPeerConfiguration)
            )
        )

        let exportItem = menuItem(
            title: tr("macRouterOSContextExportConfiguration"),
            action: #selector(exportContextPeerConfiguration)
        )
        exportItem.isEnabled = hasLocalConfiguration
        menu.addItem(exportItem)
        let qrItem = menuItem(
            title: tr("macRouterOSContextShowQRCode"),
            action: #selector(showContextPeerQRCode)
        )
        qrItem.isEnabled = hasLocalConfiguration
        menu.addItem(qrItem)
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: tr("macRouterOSContextCopyPublicKey"),
                action: #selector(copyContextPeerPublicKey)
            )
        )
        let privateKeyItem = menuItem(
            title: tr("macRouterOSContextCopyPrivateKey"),
            action: #selector(copyContextPeerPrivateKey)
        )
        privateKeyItem.isEnabled = hasLocalConfiguration
        menu.addItem(privateKeyItem)
        menu.addItem(.separator())

        let replaceItem = menuItem(
            title: tr(
                hasRecovery
                    ? "macRouterOSContextResumeCredentialReplacement"
                    : "macRouterOSContextReplaceCredentials"
            ),
            action: #selector(replaceContextPeerCredentials)
        )
        replaceItem.isEnabled = tunnel != nil || hasRecovery
        menu.addItem(replaceItem)
        let removeItem = menuItem(
            title: tr("macRouterOSContextRemovePeer"),
            action: #selector(removeContextPeer)
        )
        removeItem.isEnabled = true
        menu.addItem(removeItem)
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openContextPeerInWireRoute() {
        guard let peer = contextPeer, let tunnel = existingTunnel(matching: peer) else { return }
        (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: tunnel)
    }

    @objc private func importContextPeerConfiguration() {
        guard let peer = contextPeer else { return }
        beginImportExistingPeer(peer)
    }

    @objc private func exportContextPeerConfiguration() {
        guard let peer = contextPeer,
              let configuration = existingTunnel(matching: peer)?.tunnelConfiguration else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("macRouterOSExportPrivateData")) { [weak self] in
            self?.saveTunnelConfiguration(configuration)
        }
    }

    @objc private func showContextPeerQRCode() {
        guard let peer = contextPeer,
              let configuration = existingTunnel(matching: peer)?.tunnelConfiguration else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("macRouterOSShowQRCodePrivateData")) { [weak self] in
            self?.showConfigurationQRCode(configuration)
        }
    }

    @objc private func copyContextPeerPublicKey() {
        guard let peer = contextPeer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(peer.publicKey, forType: .string)
    }

    @objc private func copyContextPeerPrivateKey() {
        guard let peer = contextPeer,
              let privateKey = existingTunnel(matching: peer)?
                .tunnelConfiguration?.interface.privateKey.base64Key else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("macRouterOSCopyPrivateKeyAuthentication")) { [weak self] in
            self?.confirmCopyPrivateKey(privateKey)
        }
    }

    @objc private func replaceContextPeerCredentials() {
        guard let peer = contextPeer else { return }
        PrivateDataConfirmation.confirmAccess(
            to: tr("macRouterOSReplaceCredentialsAuthentication")
        ) { [weak self] in
            self?.beginCredentialReplacement(for: peer)
        }
    }

    @objc private func removeContextPeer() {
        guard let peer = contextPeer, let window = view.window else { return }
        let tunnel = existingTunnel(matching: peer)
        let options = RouterOSRemovePeerOptionsView(hasLocalProfile: tunnel != nil)
        let allowedAddresses = peer.allowedAddresses.isEmpty
            ? tr("macRouterOSNone")
            : peer.allowedAddresses.joined(separator: ", ")

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = tr("macRouterOSRemovePeerTitle")
        alert.informativeText = tr(
            format: "macRouterOSRemovePeerMessage (%@,%@,%@)",
            displayName(for: peer),
            peer.interfaceName,
            allowedAddresses
        )
        alert.accessoryView = options
        let removeButton = alert.addButton(withTitle: tr("macRouterOSRemovePeerConfirm"))
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: tr("macRouterOSCancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let shouldRemoveLocalProfile = options.removeLocalProfile.state == .on
            let shouldExport = shouldRemoveLocalProfile && options.exportLocalProfile.state == .on
            self?.preparePeerRemoval(
                peer,
                localTunnel: shouldRemoveLocalProfile ? tunnel : nil,
                shouldExportLocalProfile: shouldExport
            )
        }
    }

    private func beginCredentialReplacement(for peer: RouterOSWireGuardPeer) {
        if let recovery = Keychain.recoveryConfiguration(for: peer.id) {
            resumeCredentialReplacement(for: peer, recovery: recovery)
            return
        }
        guard let tunnel = existingTunnel(matching: peer),
              let currentConfiguration = tunnel.tunnelConfiguration else {
            showError(tr("macRouterOSReplaceCredentialsRequiresProfile"))
            return
        }

        var replacementInterface = currentConfiguration.interface
        replacementInterface.privateKey = PrivateKey()
        let replacementConfiguration = TunnelConfiguration(
            name: currentConfiguration.name,
            interface: replacementInterface,
            peers: currentConfiguration.peers
        )
        guard let recoveryReference = Keychain.makeRecoveryReference(
            containing: replacementConfiguration.asWgQuickConfig(),
            called: tunnel.name,
            peerID: peer.id
        ) else {
            showError(tr("macRouterOSCredentialRecoveryStoreFailed"))
            return
        }
        presentCredentialReplacementReview(
            peer: peer,
            tunnel: tunnel,
            replacementConfiguration: replacementConfiguration,
            recoveryReference: recoveryReference
        )
    }

    private func presentCredentialReplacementReview(
        peer: RouterOSWireGuardPeer,
        tunnel: TunnelContainer,
        replacementConfiguration: TunnelConfiguration,
        recoveryReference: Data
    ) {
        guard let window = view.window else {
            Keychain.deleteReference(called: recoveryReference)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = tr("macRouterOSReplaceCredentialsTitle")
        alert.informativeText = tr(
            format: "macRouterOSReplaceCredentialsMessage (%@,%@,%@,%@)",
            displayName(for: peer),
            peer.interfaceName,
            peer.publicKey,
            replacementConfiguration.interface.privateKey.publicKey.base64Key
        )
        let replaceButton = alert.addButton(withTitle: tr("macRouterOSReplaceCredentialsConfirm"))
        replaceButton.hasDestructiveAction = true
        alert.addButton(withTitle: tr("macRouterOSCancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                Keychain.deleteReference(called: recoveryReference)
                return
            }
            self?.performCredentialReplacement(
                peer: peer,
                tunnel: tunnel,
                replacementConfiguration: replacementConfiguration,
                recoveryReference: recoveryReference,
                updateRouter: true
            )
        }
    }

    private func resumeCredentialReplacement(
        for peer: RouterOSWireGuardPeer,
        recovery: KeychainRecoveryConfiguration
    ) {
        guard let replacementConfiguration = try? TunnelConfiguration(
            fromWgQuickConfig: recovery.configuration,
            called: recovery.name
        ) else {
            showError(tr("macRouterOSCredentialRecoveryInvalid"))
            return
        }
        let replacementPublicKey = replacementConfiguration.interface.privateKey.publicKey.base64Key
        let localTunnel = tunnelsManager.tunnel(named: recovery.name)
        let localPublicKey = localTunnel?.tunnelConfiguration?
            .interface.privateKey.publicKey.base64Key

        if localPublicKey == replacementPublicKey {
            Keychain.deleteReference(called: recovery.reference)
            messageLabel.stringValue = tr("macRouterOSCredentialReplacementComplete")
            messageLabel.textColor = .systemGreen
            if let localTunnel {
                (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: localTunnel)
            }
            return
        }

        guard let localTunnel else {
            showCredentialRecoveryOptions(
                replacementConfiguration,
                recoveryReference: recovery.reference,
                message: tr("macRouterOSCredentialRecoveryProfileMissing")
            )
            return
        }

        if peer.publicKey == replacementPublicKey {
            performCredentialReplacement(
                peer: peer,
                tunnel: localTunnel,
                replacementConfiguration: replacementConfiguration,
                recoveryReference: recovery.reference,
                updateRouter: false
            )
            return
        }

        guard localPublicKey == peer.publicKey else {
            showCredentialRecoveryOptions(
                replacementConfiguration,
                recoveryReference: recovery.reference,
                message: tr("macRouterOSCredentialRecoveryConflict")
            )
            return
        }

        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("macRouterOSResumeCredentialReplacementTitle")
        alert.informativeText = tr("macRouterOSResumeCredentialReplacementMessage")
        alert.addButton(withTitle: tr("macRouterOSResumeCredentialReplacement"))
        alert.addButton(withTitle: tr("macRouterOSCancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performCredentialReplacement(
                peer: peer,
                tunnel: localTunnel,
                replacementConfiguration: replacementConfiguration,
                recoveryReference: recovery.reference,
                updateRouter: true
            )
        }
    }

    private func performCredentialReplacement(
        peer: RouterOSWireGuardPeer,
        tunnel: TunnelContainer,
        replacementConfiguration: TunnelConfiguration,
        recoveryReference: Data,
        updateRouter: Bool
    ) {
        guard let connectedContext else { return }
        let replacementPublicKey = replacementConfiguration.interface.privateKey.publicKey.base64Key
        connectionTask?.cancel()
        messageLabel.stringValue = updateRouter
            ? tr("macRouterOSReplacingCredentials")
            : tr("macRouterOSFinishingCredentialReplacement")
        messageLabel.textColor = .secondaryLabelColor
        setConnecting(true)

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                var updatedPeer = peer
                if updateRouter {
                    let client = try RouterOSClient<URLSessionRouterOSHTTPTransport>(
                        baseURL: connectedContext.baseURL,
                        credentials: connectedContext.credentials,
                        trustedCertificate: connectedContext.trustedCertificate
                    )
                    updatedPeer = try await client.replaceWireGuardPeerPublicKey(
                        peer,
                        with: replacementPublicKey
                    )
                    guard updatedPeer.id == peer.id,
                          updatedPeer.publicKey == replacementPublicKey else {
                        throw RouterOSClientError.writeOutcomeUncertain
                    }
                    replacePeerInDiscovery(updatedPeer)
                }
                guard !Task.isCancelled else { return }
                finishLocalCredentialReplacement(
                    peer: updatedPeer,
                    tunnel: tunnel,
                    replacementConfiguration: replacementConfiguration,
                    recoveryReference: recoveryReference
                )
            } catch is CancellationError {
                return
            } catch {
                if error as? RouterOSClientError == .writeOutcomeUncertain {
                    invalidateDiscovery()
                }
                setConnecting(false)
                showCredentialRecoveryOptions(
                    replacementConfiguration,
                    recoveryReference: recoveryReference,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func finishLocalCredentialReplacement(
        peer: RouterOSWireGuardPeer,
        tunnel: TunnelContainer,
        replacementConfiguration: TunnelConfiguration,
        recoveryReference: Data
    ) {
        if tunnel.tunnelConfiguration?.interface.privateKey.publicKey.base64Key
            == replacementConfiguration.interface.privateKey.publicKey.base64Key {
            Keychain.deleteReference(called: recoveryReference)
            setConnecting(false)
            credentialReplacementSucceeded(peer: peer, tunnel: tunnel)
            return
        }
        tunnelsManager.modify(
            tunnel: tunnel,
            tunnelConfiguration: replacementConfiguration,
            onDemandOption: tunnel.onDemandOption
        ) { [weak self] error in
            guard let self else { return }
            setConnecting(false)
            if let error {
                showCredentialRecoveryOptions(
                    replacementConfiguration,
                    recoveryReference: recoveryReference,
                    message: [
                        tr("macRouterOSCredentialReplacementLocalSaveFailed"),
                        error.alertText.message
                    ].filter { !$0.isEmpty }.joined(separator: "\n\n")
                )
                return
            }
            Keychain.deleteReference(called: recoveryReference)
            credentialReplacementSucceeded(peer: peer, tunnel: tunnel)
        }
    }

    private func credentialReplacementSucceeded(
        peer: RouterOSWireGuardPeer,
        tunnel: TunnelContainer
    ) {
        messageLabel.stringValue = tr(
            format: "macRouterOSCredentialReplacementSucceeded (%@)",
            displayName(for: peer)
        )
        messageLabel.textColor = .systemGreen
        (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: tunnel)
    }

    private func showCredentialRecoveryOptions(
        _ configuration: TunnelConfiguration,
        recoveryReference: Data,
        message: String
    ) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = tr("macRouterOSCredentialRecoveryTitle")
        alert.informativeText = message + "\n\n" + tr("macRouterOSCredentialRecoveryRetained")
        alert.addButton(withTitle: tr("macRouterOSSaveConfiguration"))
        alert.addButton(withTitle: tr("macRouterOSCopyConfiguration"))
        alert.addButton(withTitle: tr("macRouterOSDone"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveTunnelConfiguration(configuration)
            case .alertSecondButtonReturn:
                self?.copySensitiveConfiguration(configuration.asWgQuickConfig())
            default:
                _ = recoveryReference
            }
        }
    }

    private func preparePeerRemoval(
        _ peer: RouterOSWireGuardPeer,
        localTunnel: TunnelContainer?,
        shouldExportLocalProfile: Bool
    ) {
        guard shouldExportLocalProfile,
              let configuration = localTunnel?.tunnelConfiguration else {
            performPeerRemoval(peer, localTunnel: localTunnel)
            return
        }
        PrivateDataConfirmation.confirmAccess(to: tr("macRouterOSExportPrivateData")) { [weak self] in
            self?.saveTunnelConfiguration(configuration) { saved in
                guard saved else { return }
                self?.performPeerRemoval(peer, localTunnel: localTunnel)
            }
        }
    }

    private func performPeerRemoval(
        _ peer: RouterOSWireGuardPeer,
        localTunnel: TunnelContainer?
    ) {
        guard let connectedContext else { return }
        connectionTask?.cancel()
        messageLabel.stringValue = tr("macRouterOSRemovingPeer")
        messageLabel.textColor = .secondaryLabelColor
        setConnecting(true)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try RouterOSClient<URLSessionRouterOSHTTPTransport>(
                    baseURL: connectedContext.baseURL,
                    credentials: connectedContext.credentials,
                    trustedCertificate: connectedContext.trustedCertificate
                )
                try await client.removeWireGuardPeer(peer)
                guard !Task.isCancelled else { return }
                removePeerFromDiscovery(peer)
                guard let localTunnel else {
                    setConnecting(false)
                    messageLabel.stringValue = tr("macRouterOSPeerRemoved")
                    messageLabel.textColor = .systemGreen
                    return
                }
                tunnelsManager.remove(tunnel: localTunnel) { [weak self] error in
                    guard let self else { return }
                    setConnecting(false)
                    if let error {
                        showExistingPeerImportError(
                            title: tr("macRouterOSPeerRemovedLocalFailedTitle"),
                            message: tr("macRouterOSPeerRemovedLocalFailedMessage")
                                + "\n\n" + error.alertText.message
                        )
                    } else {
                        messageLabel.stringValue = tr("macRouterOSPeerAndProfileRemoved")
                        messageLabel.textColor = .systemGreen
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if error as? RouterOSClientError == .writeOutcomeUncertain {
                    invalidateDiscovery()
                }
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func addPeerClicked() {
        guard let connectedContext, !interfaces.isEmpty else { return }
        let defaultInterface = savedConnections.first {
            $0.id == connectedContext.connectionID
        }?.defaultInterface
        let setupViewController = RouterOSPeerSetupViewController(
            interfaces: interfaces,
            existingPeers: peers,
            existingTunnelNames: Set(tunnelsManager.mapTunnels { $0.name }),
            publicEndpointSuggestion: publicEndpointSuggestion,
            peerDefaults: RouterOSPeerDefaultsStore.load(),
            preferredInterfaceName: defaultInterface
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

    @objc private func importExistingPeerClicked() {
        guard let peer = selectedPeer else { return }
        beginImportExistingPeer(peer)
    }

    private func beginImportExistingPeer(_ peer: RouterOSWireGuardPeer) {
        if let tunnel = existingTunnel(matching: peer) {
            messageLabel.stringValue = tr(
                format: "macRouterOSExistingPeerAlreadyImported (%@)",
                tunnel.name
            )
            messageLabel.textColor = .systemGreen
            (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: tunnel)
            return
        }
        guard let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.prompt = tr("macRouterOSChooseConfiguration")
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importExistingPeer(peer, from: url)
        }
    }

    private func createPeer(_ proposal: RouterOSPeerSetupViewController.Proposal) {
        guard let connectedContext else { return }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(
                fromWgQuickConfig: proposal.clientConfiguration.wgQuickConfiguration,
                called: proposal.clientConfiguration.name
            )
        } catch {
            showError(tr("macRouterOSGeneratedConfigurationInvalid"))
            return
        }
        guard tunnelsManager.tunnel(named: proposal.clientConfiguration.name) == nil else {
            showError(
                tr(
                    format: "macRouterOSDuplicateTunnelName (%@)",
                    proposal.clientConfiguration.name
                )
            )
            return
        }

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
                rebuildDiscoveryRows()
                messageLabel.stringValue = tr("macRouterOSPeerImporting")
                messageLabel.textColor = .secondaryLabelColor
                importClientConfiguration(
                    tunnelConfiguration,
                    recoveryConfiguration: proposal.clientConfiguration
                )
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
        title: String,
        message: String
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

    private func importClientConfiguration(
        _ tunnelConfiguration: TunnelConfiguration,
        recoveryConfiguration: WireGuardClientConfiguration
    ) {
        tunnelsManager.add(tunnelConfiguration: tunnelConfiguration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tunnel):
                messageLabel.stringValue = tr("macRouterOSPeerImported")
                messageLabel.textColor = .systemGreen
                setConnecting(false)
                (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: tunnel)
            case .failure(let error):
                setConnecting(false)
                let recoveryMessage = [
                    tr("macRouterOSImportFailedMessage"),
                    error.alertText.message
                ].filter { !$0.isEmpty }.joined(separator: "\n\n")
                showConfigurationHandoff(
                    recoveryConfiguration,
                    title: tr("macRouterOSImportFailedTitle"),
                    message: recoveryMessage
                )
            }
        }
    }

    private func importExistingPeer(_ peer: RouterOSWireGuardPeer, from url: URL) {
        let fileName = url.lastPathComponent
        let fileBaseName = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let peerName = peer.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = peerName.flatMap { $0.isEmpty ? nil : $0 }
            ?? tr("macRouterOSExistingPeerDefaultName")
        let configurationName = fileBaseName.isEmpty
            ? fallbackName
            : fileBaseName

        let fileContents: String
        do {
            fileContents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            showExistingPeerImportError(
                title: tr("alertCantOpenInputConfFileTitle"),
                message: error.localizedDescription
            )
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(
                fromWgQuickConfig: fileContents,
                called: configurationName
            )
        } catch let error as WireGuardAppError {
            showExistingPeerImportError(
                title: error.alertText.title,
                message: error.alertText.message
            )
            return
        } catch {
            showExistingPeerImportError(
                title: tr("alertBadConfigImportTitle"),
                message: tr(format: "alertBadConfigImportMessage (%@)", fileName)
            )
            return
        }

        do {
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: interfaces,
                clientPublicKey: tunnelConfiguration.interface.privateKey.publicKey.base64Key,
                clientAddresses: tunnelConfiguration.interface.addresses.map(\.stringRepresentation),
                serverPublicKeys: tunnelConfiguration.peers.map { $0.publicKey.base64Key }
            )
        } catch {
            showExistingPeerImportError(
                title: tr("macRouterOSExistingPeerMismatchTitle"),
                message: error.localizedDescription
            )
            return
        }

        if let tunnel = existingTunnel(matching: peer) {
            messageLabel.stringValue = tr(
                format: "macRouterOSExistingPeerAlreadyImported (%@)",
                tunnel.name
            )
            messageLabel.textColor = .systemGreen
            (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: tunnel)
            return
        }
        guard tunnelsManager.tunnel(named: configurationName) == nil else {
            showExistingPeerImportError(
                title: tr("alertTunnelAlreadyExistsWithThatNameTitle"),
                message: tr(
                    format: "macRouterOSExistingPeerDuplicateName (%@)",
                    configurationName
                )
            )
            return
        }

        messageLabel.stringValue = tr("macRouterOSImportingExistingPeer")
        messageLabel.textColor = .secondaryLabelColor
        setConnecting(true)
        tunnelsManager.add(tunnelConfiguration: tunnelConfiguration) { [weak self] result in
            guard let self else { return }
            setConnecting(false)
            switch result {
            case .success(let tunnel):
                messageLabel.stringValue = tr(
                    format: "macRouterOSExistingPeerImported (%@)",
                    tunnel.name
                )
                messageLabel.textColor = .systemGreen
                (NSApp.delegate as? AppDelegate)?.showManageTunnelsWindow(selecting: tunnel)
            case .failure(let error):
                showExistingPeerImportError(
                    title: error.alertText.title,
                    message: error.alertText.message
                )
            }
        }
    }

    private func existingTunnel(matching peer: RouterOSWireGuardPeer) -> TunnelContainer? {
        tunnelsManager.mapTunnels { $0 }.first { tunnel in
            tunnel.tunnelConfiguration?.interface.privateKey.publicKey.base64Key == peer.publicKey
        }
    }

    private func displayName(for peer: RouterOSWireGuardPeer) -> String {
        let name = peer.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = peer.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
            ?? comment.flatMap { $0.isEmpty ? nil : $0 }
            ?? tr("macRouterOSUnnamedPeer")
    }

    private func replacePeerInDiscovery(_ peer: RouterOSWireGuardPeer) {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        rebuildDiscoveryRows()
    }

    private func removePeerFromDiscovery(_ peer: RouterOSWireGuardPeer) {
        peers.removeAll { $0.id == peer.id }
        rebuildDiscoveryRows()
    }

    private func rebuildDiscoveryRows() {
        let displayedPeers = showAllPeersButton.state == .on
            ? peers
            : peers.filter(Self.isWireRouteManagedPeer)
        rows = displayedPeers.map(DiscoveryRow.peer)
        contextPeer = nil
        tableView.deselectAll(nil)
        reloadDiscoveryTable()
        showAllPeersButton.isEnabled = !isBusy && connectedContext != nil && !peers.isEmpty
        summaryLabel.stringValue = showAllPeersButton.state == .on
            ? tr(format: "macRouterOSAllPeersSummary (%d)", peers.count)
            : tr(format: "macRouterOSManagedPeersSummary (%d,%d)", displayedPeers.count, peers.count)
    }

    private static func isWireRouteManagedPeer(_ peer: RouterOSWireGuardPeer) -> Bool {
        RouterOSPeerCreation.isWireRouteManagedComment(peer.comment)
    }

    private func showExistingPeerImportError(title: String, message: String) {
        messageLabel.stringValue = message
        messageLabel.textColor = .systemRed
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: tr("macRouterOSDone"))
        alert.beginSheetModal(for: window) { _ in }
    }

    private func saveTunnelConfiguration(
        _ configuration: TunnelConfiguration,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let window = view.window else {
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.prompt = tr("macRouterOSSave")
        panel.nameFieldStringValue = "\(Self.safeFilename(configuration.name ?? "WireRoute-Peer")).conf"
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            do {
                try Data(configuration.asWgQuickConfig().utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                completion?(true)
            } catch {
                self?.showExistingPeerImportError(
                    title: tr("macRouterOSExportFailedTitle"),
                    message: error.localizedDescription
                )
                completion?(false)
            }
        }
    }

    private func showConfigurationQRCode(_ configuration: TunnelConfiguration) {
        ConfigurationQRCodePresenter.present(configuration, from: self)
    }

    private func confirmCopyPrivateKey(_ privateKey: String) {
        SensitiveKeyClipboardPresenter.confirmAndCopy(privateKey, from: self)
    }

    private func copySensitiveConfiguration(_ value: String) {
        SensitiveKeyClipboardPresenter.copy(value)
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
        if connectedContext == nil {
            emptyStateLabel.stringValue = savedConnections.isEmpty
                ? tr("macRouterOSNoConnectionsHelp")
                : tr("macRouterOSEmptyDiscovery")
        } else if peers.isEmpty {
            emptyStateLabel.stringValue = tr("macRouterOSNoPeers")
        } else {
            emptyStateLabel.stringValue = tr("macRouterOSNoManagedPeers")
        }
        tableView.reloadData()
        updateImportPeerButtonState()
    }
}

extension RouterOSManagerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return RouterOSDiscoveryRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier: identifier)
        let discoveryRow = rows[row]
        switch identifier.rawValue {
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateImportPeerButtonState()
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

@MainActor
enum RouterOSPeerDefaultsStore {
    private enum Key {
        static let endpointAddress = "WireRoute.RouterOSPeerDefaults.endpointAddress"
        static let dnsServers = "WireRoute.RouterOSPeerDefaults.dnsServers"
        static let splitRoutes = "WireRoute.RouterOSPeerDefaults.splitRoutes"
        static let persistentKeepalive = "WireRoute.RouterOSPeerDefaults.persistentKeepalive"
    }

    static func load(from defaults: UserDefaults = .standard) -> RouterOSPeerDefaults {
        let keepalive = defaults.object(forKey: Key.persistentKeepalive) == nil
            ? 25
            : defaults.integer(forKey: Key.persistentKeepalive)
        return (try? RouterOSPeerDefaults(
            endpointAddress: defaults.string(forKey: Key.endpointAddress),
            dnsServers: defaults.stringArray(forKey: Key.dnsServers) ?? [],
            splitRoutes: defaults.stringArray(forKey: Key.splitRoutes) ?? [],
            persistentKeepalive: keepalive
        )) ?? .standard
    }

    static func save(_ peerDefaults: RouterOSPeerDefaults, to defaults: UserDefaults = .standard) {
        if let endpointAddress = peerDefaults.endpointAddress {
            defaults.set(endpointAddress, forKey: Key.endpointAddress)
        } else {
            defaults.removeObject(forKey: Key.endpointAddress)
        }
        defaults.set(peerDefaults.dnsServers, forKey: Key.dnsServers)
        defaults.set(peerDefaults.splitRoutes.map(\.notation), forKey: Key.splitRoutes)
        defaults.set(Int(peerDefaults.persistentKeepalive), forKey: Key.persistentKeepalive)
    }
}

@MainActor
private final class RouterOSConnectionEditorViewController: NSViewController {
    private let existingConnection: RouterOSStoredConnection?
    private let existingConnections: [RouterOSStoredConnection]
    private let nameField = WireRouteTextField()
    private let addressField = WireRouteTextField()
    private let usernameField = WireRouteTextField()
    private let passwordField = WireRouteSecureTextField()
    private let defaultInterfacePopUp = WireRoutePopUpButton()
    private let loadInterfacesButton = NSButton(
        title: tr("macRouterOSLoadInterfaces"),
        target: nil,
        action: nil
    )
    private let interfaceProgressIndicator = NSProgressIndicator()
    private let defaultInterfaceHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: tr("macRouterOSSaveConnection"), target: nil, action: nil)
    private let onSave: (RouterOSStoredConnection) throws -> Void
    private var interfaceTask: Task<Void, Never>?

    init(
        connection: RouterOSStoredConnection?,
        existingConnections: [RouterOSStoredConnection],
        onSave: @escaping (RouterOSStoredConnection) throws -> Void
    ) {
        existingConnection = connection
        self.existingConnections = existingConnections
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 700, height: 490)
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
        let titleLabel = NSTextField(labelWithString: tr(
            existingConnection == nil
                ? "macRouterOSAddConnectionTitle"
                : "macRouterOSEditConnectionTitle"
        ))
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSConnectionEditorHelp"))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        nameField.placeholderString = tr("macRouterOSConnectionNamePlaceholder")
        addressField.placeholderString = "https://router.example"
        usernameField.placeholderString = tr("macRouterOSUsernamePlaceholder")
        passwordField.placeholderString = existingConnection == nil
            ? tr("macRouterOSPasswordRequiredPlaceholder")
            : tr("macRouterOSPasswordKeepPlaceholder")
        for field in [nameField, addressField, usernameField, passwordField] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 14)
        }

        if let existingConnection {
            nameField.stringValue = existingConnection.name
            addressField.stringValue = existingConnection.url
            usernameField.stringValue = existingConnection.username
        }

        configureDefaultInterfacePopUp(preferredInterface: existingConnection?.defaultInterface)
        defaultInterfacePopUp.controlSize = .large
        defaultInterfacePopUp.font = .systemFont(ofSize: 14)
        loadInterfacesButton.target = self
        loadInterfacesButton.action = #selector(loadInterfacesClicked)
        loadInterfacesButton.bezelStyle = .rounded
        loadInterfacesButton.controlSize = .large
        interfaceProgressIndicator.style = .spinning
        interfaceProgressIndicator.controlSize = .small
        interfaceProgressIndicator.isDisplayedWhenStopped = false
        defaultInterfaceHelpLabel.stringValue = tr("macRouterOSDefaultInterfaceConnectHelp")
        defaultInterfaceHelpLabel.font = .systemFont(ofSize: 11)
        defaultInterfaceHelpLabel.textColor = .secondaryLabelColor
        let interfaceRow = NSStackView(
            views: [defaultInterfacePopUp, loadInterfacesButton, interfaceProgressIndicator]
        )
        interfaceRow.orientation = .horizontal
        interfaceRow.alignment = .centerY
        interfaceRow.spacing = 8
        let defaultInterfaceStack = NSStackView(views: [interfaceRow, defaultInterfaceHelpLabel])
        defaultInterfaceStack.orientation = .vertical
        defaultInterfaceStack.alignment = .leading
        defaultInterfaceStack.spacing = 4
        interfaceRow.widthAnchor.constraint(equalTo: defaultInterfaceStack.widthAnchor).isActive = true
        defaultInterfaceHelpLabel.widthAnchor.constraint(equalTo: defaultInterfaceStack.widthAnchor).isActive = true
        defaultInterfacePopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        defaultInterfacePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel(tr("macRouterOSConnectionName")), nameField],
            [fieldLabel(tr("macRouterOSAddress")), addressField],
            [fieldLabel(tr("macRouterOSUsername")), usernameField],
            [fieldLabel(tr("macRouterOSPassword")), passwordField],
            [fieldLabel(tr("macRouterOSDefaultInterface")), defaultInterfaceStack]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let card = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .surface
        )
        card.adaptiveBorderColor = .separatorColor
        card.adaptiveBorderAlpha = 0.65
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: tr("macRouterOSCancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [buttonSpacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let stack = NSStackView(views: [titleLabel, subtitleLabel, card, errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(18, after: subtitleLabel)
        stack.setCustomSpacing(8, after: card)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -22),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        self.view = view
    }

    private func fieldLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    @objc private func cancelClicked() {
        interfaceTask?.cancel()
        dismiss(self)
    }

    @objc private func saveClicked() {
        guard let connection = validatedConnection() else { return }
        do {
            try onSave(connection)
            dismiss(self)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func loadInterfacesClicked() {
        guard let connection = validatedConnection(),
              let url = URL(string: connection.url) else {
            return
        }
        interfaceTask?.cancel()
        errorLabel.isHidden = true
        defaultInterfaceHelpLabel.stringValue = tr("macRouterOSLoadingInterfaces")
        defaultInterfaceHelpLabel.textColor = .secondaryLabelColor
        loadInterfaces(from: url, connection: connection)
    }

    private func validatedConnection() -> RouterOSStoredConnection? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPassword = passwordField.stringValue

        guard !name.isEmpty else {
            showError(tr("macRouterOSConnectionNameRequired"))
            return nil
        }
        let duplicateName = existingConnections.contains {
            $0.id != existingConnection?.id
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !duplicateName else {
            showError(tr("macRouterOSConnectionNameDuplicate"))
            return nil
        }
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            showError(tr("macRouterOSConnectionAddressInvalid"))
            return nil
        }
        guard !username.isEmpty else {
            showError(tr("macRouterOSConnectionUsernameRequired"))
            return nil
        }
        let password = newPassword.isEmpty ? existingConnection?.password ?? "" : newPassword
        guard !password.isEmpty else {
            showError(tr("macRouterOSConnectionPasswordRequired"))
            return nil
        }

        return RouterOSStoredConnection(
            id: existingConnection?.id ?? UUID(),
            name: name,
            url: url.absoluteString,
            username: username,
            password: password,
            defaultInterface: selectedDefaultInterface
        )
    }

    private var selectedDefaultInterface: String? {
        guard defaultInterfacePopUp.indexOfSelectedItem > 0 else { return nil }
        return defaultInterfacePopUp.selectedItem?.representedObject as? String
    }

    private func configureDefaultInterfacePopUp(preferredInterface: String?) {
        defaultInterfacePopUp.removeAllItems()
        defaultInterfacePopUp.addItem(withTitle: tr("macRouterOSAutomatic"))
        if let preferredInterface, !preferredInterface.isEmpty {
            defaultInterfacePopUp.addItem(withTitle: preferredInterface)
            defaultInterfacePopUp.lastItem?.representedObject = preferredInterface
            defaultInterfacePopUp.selectItem(at: 1)
        } else {
            defaultInterfacePopUp.selectItem(at: 0)
        }
    }

    private func populateDefaultInterfacePopUp(
        interfaces: [RouterOSWireGuardInterface],
        preferredInterface: String?
    ) {
        defaultInterfacePopUp.removeAllItems()
        defaultInterfacePopUp.addItem(withTitle: tr("macRouterOSAutomatic"))
        for interface in interfaces {
            let suffix = interface.isDisabled ? " — \(tr("macRouterOSDisabled"))" : ""
            defaultInterfacePopUp.addItem(withTitle: interface.name + suffix)
            defaultInterfacePopUp.lastItem?.representedObject = interface.name
        }

        if let preferredInterface,
           let preferredIndex = interfaces.firstIndex(where: { $0.name == preferredInterface }) {
            defaultInterfacePopUp.selectItem(at: preferredIndex + 1)
        } else if let activeIndex = interfaces.firstIndex(where: { $0.isRunning && !$0.isDisabled }) {
            defaultInterfacePopUp.selectItem(at: activeIndex + 1)
        } else if let enabledIndex = interfaces.firstIndex(where: { !$0.isDisabled }) {
            defaultInterfacePopUp.selectItem(at: enabledIndex + 1)
        } else if !interfaces.isEmpty {
            defaultInterfacePopUp.selectItem(at: 1)
        } else {
            defaultInterfacePopUp.selectItem(at: 0)
        }
    }

    private func loadInterfaces(from url: URL, connection: RouterOSStoredConnection) {
        setLoadingInterfaces(true)
        interfaceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trustedCertificate = try RouterOSCertificateStore.load(for: url)
                let client = try RouterOSClient<URLSessionRouterOSHTTPTransport>(
                    baseURL: url,
                    credentials: RouterOSCredentials(
                        username: connection.username,
                        password: connection.password
                    ),
                    trustedCertificate: trustedCertificate
                )
                let interfaces = try await client.wireGuardInterfaces()
                guard !Task.isCancelled else { return }

                let previousSelection = selectedDefaultInterface ?? connection.defaultInterface
                populateDefaultInterfacePopUp(
                    interfaces: interfaces,
                    preferredInterface: previousSelection
                )
                if interfaces.isEmpty {
                    showError(tr("macRouterOSNoInterfacesForDefault"))
                    defaultInterfaceHelpLabel.stringValue = tr("macRouterOSNoInterfacesForDefault")
                    defaultInterfaceHelpLabel.textColor = .systemOrange
                } else {
                    defaultInterfaceHelpLabel.stringValue = tr(
                        format: "macRouterOSInterfacesLoaded (%d)",
                        interfaces.count
                    )
                    defaultInterfaceHelpLabel.textColor = .systemGreen
                }
            } catch is CancellationError {
                return
            } catch let certificateError as RouterOSTLSCertificateError {
                setLoadingInterfaces(false)
                presentCertificateReview(
                    certificateError,
                    routerURL: url,
                    connection: connection
                )
                return
            } catch {
                showError(error.localizedDescription)
                defaultInterfaceHelpLabel.stringValue = tr("macRouterOSDefaultInterfaceConnectHelp")
                defaultInterfaceHelpLabel.textColor = .secondaryLabelColor
            }
            setLoadingInterfaces(false)
        }
    }

    private func setLoadingInterfaces(_ isLoading: Bool) {
        for field in [nameField, addressField, usernameField, passwordField] {
            field.isEnabled = !isLoading
        }
        defaultInterfacePopUp.isEnabled = !isLoading
        loadInterfacesButton.isEnabled = !isLoading
        saveButton.isEnabled = !isLoading
        if isLoading {
            interfaceProgressIndicator.startAnimation(nil)
        } else {
            interfaceProgressIndicator.stopAnimation(nil)
        }
    }

    private func presentCertificateReview(
        _ error: RouterOSTLSCertificateError,
        routerURL: URL,
        connection: RouterOSStoredConnection
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

        defaultInterfaceHelpLabel.stringValue = error.localizedDescription
        defaultInterfaceHelpLabel.textColor = .systemOrange
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
                defaultInterfaceHelpLabel.stringValue = tr("macRouterOSCertificateNotTrusted")
                defaultInterfaceHelpLabel.textColor = .secondaryLabelColor
                return
            }
            do {
                try RouterOSCertificateStore.save(certificate, for: routerURL)
                defaultInterfaceHelpLabel.stringValue = tr("macRouterOSCertificateTrustedConnecting")
                defaultInterfaceHelpLabel.textColor = .secondaryLabelColor
                loadInterfaces(from: routerURL, connection: connection)
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

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}

@MainActor
final class RouterOSSettingsViewController: NSViewController {
    private let appearancePopUp = WireRoutePopUpButton()
    private let statusIconPopUp = WireRoutePopUpButton()
    private let connectionsTableView = NSTableView()
    private let connectionsEmptyLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSConnectionsEmpty"))
    private let addConnectionButton = NSButton(title: tr("macRouterOSAddConnection"), target: nil, action: nil)
    private let editConnectionButton = NSButton(title: tr("macRouterOSEditConnection"), target: nil, action: nil)
    private let removeConnectionButton = NSButton(title: tr("macRouterOSRemoveConnection"), target: nil, action: nil)
    private let endpointField = WireRouteTextField()
    private let dnsField = WireRouteTextField()
    private let routesField = WireRouteTextField()
    private let keepaliveField = WireRouteTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var connections = [RouterOSStoredConnection]()

    override func viewWillAppear() {
        super.viewWillAppear()
        errorLabel.isHidden = true
        loadStoredDefaults()
        loadConnections()
    }

    override func loadView() {
        let view = AppearanceAwareMaterialView(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            nordicSurface: .canvas
        )

        let titleLabel = NSTextField(labelWithString: tr("macSettingsTitle"))
        titleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: tr("macSettingsSubtitle"))
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        configureFields()
        let appearanceForm = makeAppearanceForm()
        let connectionsForm = makeConnectionsForm()
        let peerDefaultsForm = makePeerDefaultsForm()
        let appearanceTitle = sectionTitle(tr("macSettingsAppearanceTitle"))
        let connectionsTitle = sectionTitle(tr("macRouterOSConnectionsTitle"))
        let peerDefaultsTitle = sectionTitle(tr("macRouterOSSettingsTitle"))

        let restoreButton = NSButton(
            title: tr("macRouterOSRestoreDefaults"),
            target: self,
            action: #selector(restoreDefaultsClicked)
        )
        restoreButton.bezelStyle = .rounded
        let saveButton = NSButton(
            title: tr("macSettingsSave"),
            target: self,
            action: #selector(saveClicked)
        )
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [restoreButton, spacer, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            appearanceTitle,
            appearanceForm,
            connectionsTitle,
            connectionsForm,
            peerDefaultsTitle,
            peerDefaultsForm,
            errorLabel,
            buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(20, after: subtitleLabel)
        stack.setCustomSpacing(6, after: appearanceTitle)
        stack.setCustomSpacing(18, after: appearanceForm)
        stack.setCustomSpacing(6, after: connectionsTitle)
        stack.setCustomSpacing(18, after: connectionsForm)
        stack.setCustomSpacing(6, after: peerDefaultsTitle)
        stack.setCustomSpacing(16, after: peerDefaultsForm)

        let documentView = NSView()
        documentView.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            documentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            appearanceForm.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectionsForm.widthAnchor.constraint(equalTo: stack.widthAnchor),
            peerDefaultsForm.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        self.view = view
    }

    private func configureFields() {
        appearancePopUp.removeAllItems()
        for appearance in WireRouteAppearance.allCases {
            appearancePopUp.addItem(withTitle: appearance.localizedTitle)
            appearancePopUp.lastItem?.representedObject = appearance.rawValue
        }
        appearancePopUp.controlSize = .large
        appearancePopUp.font = .systemFont(ofSize: 14)

        statusIconPopUp.removeAllItems()
        for style in StatusItemIconStyle.allCases {
            statusIconPopUp.addItem(withTitle: style.localizedTitle)
            guard let item = statusIconPopUp.lastItem else { continue }
            item.representedObject = style.rawValue
            item.image = StatusItemController.previewImage(for: style)
        }
        statusIconPopUp.controlSize = .large
        statusIconPopUp.font = .systemFont(ofSize: 14)

        endpointField.placeholderString = tr("macRouterOSEndpointPlaceholder")
        dnsField.placeholderString = tr("macRouterOSDNSPlaceholder")
        routesField.placeholderString = tr("macRouterOSRoutesPlaceholder")
        keepaliveField.alignment = .right
        for field in [endpointField, dnsField, routesField, keepaliveField] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 14)
        }
        loadStoredDefaults()
    }

    private func loadStoredDefaults() {
        let appearance = WireRouteAppearancePreference.load()
        if let item = appearancePopUp.itemArray.first(where: {
            $0.representedObject as? String == appearance.rawValue
        }) {
            appearancePopUp.select(item)
        }
        let iconStyle = StatusItemIconPreference.load()
        if let styleIndex = StatusItemIconStyle.allCases.firstIndex(of: iconStyle) {
            statusIconPopUp.selectItem(at: styleIndex)
        }
        let peerDefaults = RouterOSPeerDefaultsStore.load()
        endpointField.stringValue = peerDefaults.endpointAddress ?? ""
        dnsField.stringValue = peerDefaults.dnsServers.joined(separator: ", ")
        routesField.stringValue = peerDefaults.splitRoutes.map(\.notation).joined(separator: ", ")
        keepaliveField.integerValue = Int(peerDefaults.persistentKeepalive)
    }

    private func makeAppearanceForm() -> NSView {
        let card = makeCard()
        let themeHelpLabel = NSTextField(wrappingLabelWithString: tr("macSettingsThemeHelp"))
        themeHelpLabel.font = .systemFont(ofSize: 11)
        themeHelpLabel.textColor = .secondaryLabelColor
        let themeStack = NSStackView(views: [appearancePopUp, themeHelpLabel])
        themeStack.orientation = .vertical
        themeStack.alignment = .leading
        themeStack.spacing = 4

        let iconHelpLabel = NSTextField(wrappingLabelWithString: tr("macStatusIconHelp"))
        iconHelpLabel.font = .systemFont(ofSize: 11)
        iconHelpLabel.textColor = .secondaryLabelColor
        let iconStack = NSStackView(views: [statusIconPopUp, iconHelpLabel])
        iconStack.orientation = .vertical
        iconStack.alignment = .leading
        iconStack.spacing = 4

        let grid = NSGridView(views: [
            [fieldLabel(tr("macSettingsThemeLabel")), themeStack],
            [fieldLabel(tr("macSettingsMenuBarIconLabel")), iconStack]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 15
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        for rowIndex in 0 ... 1 {
            grid.row(at: rowIndex).yPlacement = .top
        }

        card.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            appearancePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            statusIconPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            themeHelpLabel.widthAnchor.constraint(equalTo: themeStack.widthAnchor),
            iconHelpLabel.widthAnchor.constraint(equalTo: iconStack.widthAnchor)
        ])
        return card
    }

    private func makeConnectionsForm() -> NSView {
        let card = makeCard()
        let helpLabel = NSTextField(wrappingLabelWithString: tr("macRouterOSConnectionsHelp"))
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor

        connectionsTableView.dataSource = self
        connectionsTableView.delegate = self
        connectionsTableView.backgroundColor = .clear
        connectionsTableView.headerView = NSTableHeaderView()
        connectionsTableView.rowHeight = 30
        connectionsTableView.intercellSpacing = NSSize(width: 8, height: 2)
        connectionsTableView.usesAlternatingRowBackgroundColors = false
        connectionsTableView.target = self
        connectionsTableView.doubleAction = #selector(editConnectionClicked)

        let columns: [(String, String, CGFloat)] = [
            ("connectionName", tr("macRouterOSConnectionName"), 160),
            ("connectionAddress", tr("macRouterOSAddress"), 250),
            ("connectionUsername", tr("macRouterOSUsername"), 130),
            ("connectionInterface", tr("macRouterOSDefaultInterface"), 150)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.headerCell = RouterOSDiscoveryHeaderCell(textCell: title)
            column.width = width
            column.minWidth = 90
            connectionsTableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = connectionsTableView

        let listContainer = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .inset
        )
        listContainer.adaptiveBorderColor = .separatorColor
        listContainer.adaptiveBorderAlpha = 0.45
        listContainer.layer?.cornerRadius = 10
        listContainer.layer?.cornerCurve = .continuous
        listContainer.layer?.borderWidth = 1
        listContainer.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        connectionsEmptyLabel.alignment = .center
        connectionsEmptyLabel.font = .systemFont(ofSize: 12)
        connectionsEmptyLabel.textColor = .tertiaryLabelColor
        listContainer.addSubview(connectionsEmptyLabel)
        connectionsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            connectionsEmptyLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            connectionsEmptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor, constant: 8),
            connectionsEmptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 24),
            connectionsEmptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -24),
            listContainer.heightAnchor.constraint(equalToConstant: 150)
        ])

        addConnectionButton.target = self
        addConnectionButton.action = #selector(addConnectionClicked)
        editConnectionButton.target = self
        editConnectionButton.action = #selector(editConnectionClicked)
        removeConnectionButton.target = self
        removeConnectionButton.action = #selector(removeConnectionClicked)
        for button in [addConnectionButton, editConnectionButton, removeConnectionButton] {
            button.bezelStyle = .rounded
        }
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [addConnectionButton, editConnectionButton, removeConnectionButton, buttonSpacer])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [helpLabel, listContainer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        helpLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        listContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        updateConnectionButtons()
        return card
    }

    private func makePeerDefaultsForm() -> NSView {
        let card = makeCard()

        let endpointStack = valueStack(
            field: endpointField,
            help: tr("macRouterOSSettingsEndpointHelp")
        )
        let dnsStack = valueStack(field: dnsField, help: tr("macRouterOSSettingsDNSHelp"))
        let routesStack = valueStack(field: routesField, help: tr("macRouterOSSettingsRoutesHelp"))
        let keepaliveRow = NSStackView(views: [keepaliveField, NSTextField(labelWithString: tr("macRouterOSSeconds"))])
        keepaliveRow.orientation = .horizontal
        keepaliveRow.alignment = .centerY
        keepaliveRow.spacing = 7
        keepaliveField.widthAnchor.constraint(equalToConstant: 86).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel(tr("macRouterOSPreferredEndpoint")), endpointStack],
            [fieldLabel(tr("macRouterOSDNS")), dnsStack],
            [fieldLabel(tr("macRouterOSDefaultSplitRoutes")), routesStack],
            [fieldLabel(tr("macRouterOSKeepalive")), keepaliveRow]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 15
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        for rowIndex in 0 ... 2 {
            grid.row(at: rowIndex).yPlacement = .top
        }

        card.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            endpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)
        ])
        return card
    }

    private func makeCard() -> AppearanceAwareMaterialView {
        let card = AppearanceAwareMaterialView(material: .contentBackground, blendingMode: .withinWindow)
        card.adaptiveBorderColor = .separatorColor
        card.adaptiveBorderAlpha = 0.65
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        return card
    }

    private func valueStack(field: NSTextField, help: String) -> NSStackView {
        let helpLabel = NSTextField(wrappingLabelWithString: help)
        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, helpLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        helpLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func fieldLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private var selectedStoredConnection: RouterOSStoredConnection? {
        let row = connectionsTableView.selectedRow
        guard connections.indices.contains(row) else { return nil }
        return connections[row]
    }

    private func loadConnections(selecting connectionID: UUID? = nil) {
        let preferredID = connectionID ?? selectedStoredConnection?.id
        do {
            connections = try RouterOSCredentialStore.loadAll().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            connectionsTableView.reloadData()
            if let preferredID, let index = connections.firstIndex(where: { $0.id == preferredID }) {
                connectionsTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                connectionsTableView.scrollRowToVisible(index)
            } else if !connections.isEmpty {
                connectionsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            connectionsEmptyLabel.isHidden = !connections.isEmpty
            updateConnectionButtons()
        } catch {
            connections = []
            connectionsTableView.reloadData()
            connectionsEmptyLabel.isHidden = false
            updateConnectionButtons()
            showSettingsError(error.localizedDescription)
        }
    }

    private func updateConnectionButtons() {
        let hasSelection = selectedStoredConnection != nil
        editConnectionButton.isEnabled = hasSelection
        removeConnectionButton.isEnabled = hasSelection
    }

    @objc private func addConnectionClicked() {
        presentConnectionEditor(connection: nil)
    }

    @objc private func editConnectionClicked() {
        guard let connection = selectedStoredConnection else { return }
        presentConnectionEditor(connection: connection)
    }

    private func presentConnectionEditor(connection: RouterOSStoredConnection?) {
        let editor = RouterOSConnectionEditorViewController(
            connection: connection,
            existingConnections: connections
        ) { [weak self] savedConnection in
            try RouterOSCredentialStore.save(savedConnection)
            self?.loadConnections(selecting: savedConnection.id)
        }
        presentAsSheet(editor)
    }

    @objc private func removeConnectionClicked() {
        guard let connection = selectedStoredConnection, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr(format: "macRouterOSRemoveConnectionTitle (%@)", connection.name)
        alert.informativeText = tr("macRouterOSRemoveConnectionMessage")
        let removeButton = alert.addButton(withTitle: tr("macRouterOSRemoveConnectionConfirm"))
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: tr("macRouterOSCancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try RouterOSCredentialStore.delete(id: connection.id)
                self?.loadConnections()
            } catch {
                self?.showSettingsError(error.localizedDescription)
            }
        }
    }

    private func showSettingsError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = false
    }

    @objc private func restoreDefaultsClicked() {
        endpointField.stringValue = ""
        dnsField.stringValue = ""
        routesField.stringValue = ""
        keepaliveField.integerValue = Int(RouterOSPeerDefaults.standard.persistentKeepalive)
        if let blueNordicItem = appearancePopUp.itemArray.first(where: {
            $0.representedObject as? String == WireRouteAppearance.blueNordic.rawValue
        }) {
            appearancePopUp.select(blueNordicItem)
        }
        statusIconPopUp.selectItem(at: StatusItemIconStyle.allCases.firstIndex(of: .adaptive) ?? 0)
        errorLabel.isHidden = true
    }

    @objc private func saveClicked() {
        do {
            guard let persistentKeepalive = Int(
                keepaliveField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw RouterOSProvisioningError.invalidPersistentKeepalive
            }
            let peerDefaults = try RouterOSPeerDefaults(
                endpointAddress: endpointField.stringValue,
                dnsServers: Self.splitValues(dnsField.stringValue),
                splitRoutes: Self.splitValues(routesField.stringValue),
                persistentKeepalive: persistentKeepalive
            )
            RouterOSPeerDefaultsStore.save(peerDefaults)
            let selectedIndex = statusIconPopUp.indexOfSelectedItem
            guard StatusItemIconStyle.allCases.indices.contains(selectedIndex) else {
                return
            }
            let iconStyle = StatusItemIconStyle.allCases[selectedIndex]
            StatusItemIconPreference.save(iconStyle)
            (NSApp.delegate as? AppDelegate)?.statusItemController?.setIconStyle(iconStyle)
            guard let appearanceRawValue = appearancePopUp.selectedItem?.representedObject as? String,
                  let appearance = WireRouteAppearance(rawValue: appearanceRawValue) else {
                return
            }
            WireRouteTheme.apply(appearance)
            errorLabel.stringValue = tr("macSettingsSaved")
            errorLabel.textColor = .systemGreen
            errorLabel.isHidden = false
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.textColor = .systemRed
            errorLabel.isHidden = false
        }
    }

    private static func splitValues(_ value: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        return value.components(separatedBy: separators).filter { !$0.isEmpty }
    }
}

extension RouterOSSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        connections.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RouterOSDiscoveryRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, connections.indices.contains(row) else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeConnectionCell(identifier: identifier)
        let connection = connections[row]
        switch identifier.rawValue {
        case "connectionName":
            cell.textField?.stringValue = connection.name
        case "connectionAddress":
            cell.textField?.stringValue = connection.url
        case "connectionUsername":
            cell.textField?.stringValue = connection.username
        case "connectionInterface":
            cell.textField?.stringValue = connection.defaultInterface ?? tr("macRouterOSAutomatic")
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateConnectionButtons()
    }

    private func makeConnectionCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
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
