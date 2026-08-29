// SPDX-License-Identifier: MIT

import AppKit

@MainActor
private final class WireRouteActivityChartView: NSView {
    var points = [WireRouteActivityPoint]() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plotRect = bounds.insetBy(dx: 8, dy: 10)
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        for step in 0 ... 3 {
            let y = plotRect.minY + plotRect.height * CGFloat(step) / 3
            let gridLine = NSBezierPath()
            gridLine.move(to: NSPoint(x: plotRect.minX, y: y))
            gridLine.line(to: NSPoint(x: plotRect.maxX, y: y))
            gridLine.lineWidth = 0.5
            gridLine.stroke()
        }

        guard !points.isEmpty else {
            drawEmptyState(in: plotRect)
            return
        }
        let maximumRate = max(
            points.map(\.receivedBytesPerSecond).max() ?? 0,
            points.map(\.sentBytesPerSecond).max() ?? 0,
            1
        )
        drawSeries(
            points.map(\.receivedBytesPerSecond),
            color: WireRouteTheme.accentColor,
            maximumRate: maximumRate,
            in: plotRect
        )
        drawSeries(
            points.map(\.sentBytesPerSecond),
            color: .systemTeal,
            maximumRate: maximumRate,
            in: plotRect
        )
    }

    private func drawSeries(
        _ values: [Double],
        color: NSColor,
        maximumRate: Double,
        in rect: NSRect
    ) {
        let path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let progress = values.count > 1 ? CGFloat(index) / CGFloat(values.count - 1) : 1
            let normalized = CGFloat(max(0, value) / maximumRate)
            let point = NSPoint(
                x: rect.minX + rect.width * progress,
                y: rect.maxY - rect.height * normalized
            )
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        color.setStroke()
        path.lineWidth = 2.25
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawEmptyState(in rect: NSRect) {
        let message = NSAttributedString(
            string: tr("activityWaitingForTraffic"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let size = message.size()
        message.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

@MainActor
final class WireRouteActivityDashboardView: NSView {
    var onOpenHistory: (() -> Void)?

    private let tunnel: TunnelContainer
    private let store: WireRouteActivityStore?
    private var accumulator = WireRouteActivityAccumulator()
    private var livePoints = [WireRouteActivityPoint]()
    private let chart = WireRouteActivityChartView()
    private let downloadValue = NSTextField(labelWithString: "—")
    private let uploadValue = NSTextField(labelWithString: "—")
    private let totalValue = NSTextField(labelWithString: "—")
    private let handshakeValue = NSTextField(labelWithString: "—")
    private let stateLabel = NSTextField(labelWithString: "")
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()
    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(tunnel: TunnelContainer, showsHistoryButton: Bool = true) {
        self.tunnel = tunnel
        store = try? WireRouteActivityStore()
        super.init(frame: .zero)
        configureView(showsHistoryButton: showsHistoryButton)
        refreshStoredHistory()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: TunnelConfiguration?, isActive: Bool) {
        refreshStoredHistory()
        guard isActive, let configuration else {
            downloadValue.stringValue = formatRate(0)
            uploadValue.stringValue = formatRate(0)
            stateLabel.stringValue = tr("activityInactiveShort")
            return
        }
        let peers = configuration.peers.map {
            WireRouteActivityPeerCounters(
                peerIdentifier: $0.publicKey.base64Key,
                receivedBytes: $0.rxBytes ?? 0,
                sentBytes: $0.txBytes ?? 0,
                lastHandshake: $0.lastHandshakeTime
            )
        }
        let now = Date()
        let delta = accumulator.sample(peers: peers, at: now)
        downloadValue.stringValue = formatRate(delta.receivedBytesPerSecond)
        uploadValue.stringValue = formatRate(delta.sentBytesPerSecond)
        handshakeValue.stringValue = formatHandshake(delta.lastHandshake)
        stateLabel.stringValue = tr("activityRecordingShort")
        livePoints.append(
            WireRouteActivityPoint(
                date: now,
                receivedBytesPerSecond: delta.receivedBytesPerSecond,
                sentBytesPerSecond: delta.sentBytesPerSecond,
                totalReceivedBytes: delta.totalReceivedBytes,
                totalSentBytes: delta.totalSentBytes,
                lastHandshake: delta.lastHandshake
            )
        )
        livePoints = Array(livePoints.suffix(120))
        if chart.points.isEmpty {
            chart.points = livePoints
        }
    }

    @objc private func openHistory() {
        onOpenHistory?()
    }

    private func configureView(showsHistoryButton: Bool) {
        let card = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .surface
        )
        card.adaptiveBorderColor = .separatorColor
        card.adaptiveBorderAlpha = 0.65
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1

        let title = NSTextField(labelWithString: tr("activityTitle"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        let titleText = NSStackView(views: [title, stateLabel])
        titleText.orientation = .vertical
        titleText.alignment = .leading
        titleText.spacing = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let historyButton = NSButton(
            title: tr("activityHistoryButton"),
            target: self,
            action: #selector(openHistory)
        )
        historyButton.bezelStyle = .rounded
        historyButton.isHidden = !showsHistoryButton
        let header = NSStackView(views: [titleText, spacer, historyButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let metrics = NSStackView(views: [
            metric(title: tr("activityDownload"), value: downloadValue, color: WireRouteTheme.accentColor),
            metric(title: tr("activityUpload"), value: uploadValue, color: .systemTeal),
            metric(title: tr("activitySessionTotal"), value: totalValue, color: .secondaryLabelColor),
            metric(title: tr("activityLastHandshake"), value: handshakeValue, color: .secondaryLabelColor)
        ])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 12

        chart.setContentHuggingPriority(.defaultLow, for: .vertical)
        let legend = NSStackView(views: [
            legendItem(color: WireRouteTheme.accentColor, title: tr("activityDownload")),
            legendItem(color: .systemTeal, title: tr("activityUpload")),
            NSView()
        ])
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.spacing = 14

        let content = NSStackView(views: [header, metrics, chart, legend])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(14, after: header)
        card.addSubview(content)
        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            metrics.widthAnchor.constraint(equalTo: content.widthAnchor),
            chart.widthAnchor.constraint(equalTo: content.widthAnchor),
            chart.heightAnchor.constraint(equalToConstant: 90),
            legend.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func metric(title: String, value: NSTextField, color: NSColor) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = color
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        value.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func legendItem(color: NSColor, title: String) -> NSStackView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func refreshStoredHistory() {
        guard let store else { return }
        do {
            let profileIdentifier = tunnel.activityProfileIdentifier
            let points = try store.points(
                profileIdentifier: profileIdentifier,
                since: Date().addingTimeInterval(-60 * 60),
                limit: 720
            )
            if !points.isEmpty {
                chart.points = points
            }
            if let session = try store.sessions(profileIdentifier: profileIdentifier, limit: 1).first {
                let (combined, overflow) = session.receivedBytes.addingReportingOverflow(session.sentBytes)
                totalValue.stringValue = formatBytes(overflow ? .max : combined)
                handshakeValue.stringValue = formatHandshake(session.lastHandshake)
            }
        } catch {
            stateLabel.stringValue = tr("activityUnavailableShort")
        }
    }

    private func formatRate(_ value: Double) -> String {
        formatBytes(UInt64(max(0, value))) + "/s"
    }

    private func formatBytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    private func formatHandshake(_ date: Date?) -> String {
        guard let date else { return tr("activityNoHandshake") }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
final class ActivityMonitorViewController: NSViewController {
    private let tunnel: TunnelContainer
    private let store: WireRouteActivityStore?
    private let dashboard: WireRouteActivityDashboardView
    private let historyStack = NSStackView()
    private let retentionPopUp = NSPopUpButton()
    private var refreshTimer: Timer?

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        store = try? WireRouteActivityStore()
        dashboard = WireRouteActivityDashboardView(tunnel: tunnel, showsHistoryButton: false)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = AppearanceAwareMaterialView(
            material: .sidebar,
            blendingMode: .behindWindow,
            nordicSurface: .canvas
        )
        let title = NSTextField(labelWithString: tr("activityTitle"))
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: tr("activityIntro"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let close = NSButton(title: tr("activityDone"), target: self, action: #selector(closeSheet))
        close.bezelStyle = .rounded
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleStack, titleSpacer, close])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16

        let historyTitle = NSTextField(labelWithString: tr("activityRecentConnections"))
        historyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        retentionPopUp.target = self
        retentionPopUp.action = #selector(retentionChanged)
        configureRetentionPopUp()
        let clear = NSButton(title: tr("activityClearHistory"), target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        let historySpacer = NSView()
        historySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let historyHeader = NSStackView(views: [historyTitle, historySpacer, retentionPopUp, clear])
        historyHeader.orientation = .horizontal
        historyHeader.alignment = .centerY
        historyHeader.spacing = 10

        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 0
        let historyCard = AppearanceAwareMaterialView(
            material: .contentBackground,
            blendingMode: .withinWindow,
            nordicSurface: .surface
        )
        historyCard.adaptiveBorderColor = .separatorColor
        historyCard.adaptiveBorderAlpha = 0.65
        historyCard.layer?.cornerRadius = 14
        historyCard.layer?.cornerCurve = .continuous
        historyCard.layer?.borderWidth = 1
        historyCard.addSubview(historyStack)
        historyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            historyStack.leadingAnchor.constraint(equalTo: historyCard.leadingAnchor, constant: 16),
            historyStack.trailingAnchor.constraint(equalTo: historyCard.trailingAnchor, constant: -16),
            historyStack.topAnchor.constraint(equalTo: historyCard.topAnchor, constant: 8),
            historyStack.bottomAnchor.constraint(equalTo: historyCard.bottomAnchor, constant: -8)
        ])

        let content = NSStackView(views: [header, dashboard, historyHeader, historyCard])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.setCustomSpacing(20, after: header)
        content.setCustomSpacing(22, after: dashboard)
        root.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            dashboard.widthAnchor.constraint(equalTo: content.widthAnchor),
            historyHeader.widthAnchor.constraint(equalTo: content.widthAnchor),
            historyCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            historyCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 620)
        ])
        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func closeSheet() {
        dismiss(self)
    }

    @objc private func retentionChanged() {
        guard WireRouteActivityRetention.allCases.indices.contains(retentionPopUp.indexOfSelectedItem) else {
            return
        }
        let retention = WireRouteActivityRetention.allCases[retentionPopUp.indexOfSelectedItem]
        WireRouteActivityPreference.saveRetention(retention)
        try? store?.purge(before: Date().addingTimeInterval(-retention.interval))
        refreshHistory()
    }

    @objc private func clearHistory() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("activityClearHistoryTitle")
        alert.informativeText = tr("activityClearHistoryMessage")
        let clearButton = alert.addButton(withTitle: tr("activityClear"))
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: tr("activityCancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let store = self.store else { return }
            try? store.clearCompletedHistory(profileIdentifier: self.tunnel.activityProfileIdentifier)
            self.refreshHistory()
        }
    }

    private func refresh() {
        tunnel.getRuntimeTunnelConfiguration { [weak self] configuration in
            guard let self else { return }
            self.dashboard.update(configuration: configuration, isActive: self.tunnel.status == .active)
        }
        refreshHistory()
    }

    private func refreshHistory() {
        guard let sessions = try? store?.sessions(profileIdentifier: tunnel.activityProfileIdentifier) else {
            return
        }
        historyStack.arrangedSubviews.forEach {
            historyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !sessions.isEmpty else {
            let empty = NSTextField(labelWithString: tr("activityNoHistory"))
            empty.textColor = .secondaryLabelColor
            historyStack.addArrangedSubview(empty)
            return
        }
        for session in sessions.prefix(8) {
            let started = NSTextField(
                labelWithString: session.startedAt.formatted(date: .abbreviated, time: .shortened)
            )
            started.font = .systemFont(ofSize: 12, weight: .medium)
            let transfer = NSTextField(
                labelWithString: "↓ \(formatBytes(session.receivedBytes))   ↑ \(formatBytes(session.sentBytes))"
            )
            transfer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            transfer.textColor = .secondaryLabelColor
            let text = NSStackView(views: [started, transfer])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let duration = NSTextField(labelWithString: formatDuration(session))
            duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            duration.textColor = .secondaryLabelColor
            let row = NSStackView(views: [text, spacer, duration])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            historyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
        }
    }

    private func configureRetentionPopUp() {
        retentionPopUp.removeAllItems()
        for retention in WireRouteActivityRetention.allCases {
            retentionPopUp.addItem(withTitle: retentionTitle(retention))
        }
        let selected = WireRouteActivityPreference.loadRetention()
        retentionPopUp.selectItem(at: WireRouteActivityRetention.allCases.firstIndex(of: selected) ?? 0)
    }

    private func formatBytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    private func formatDuration(_ session: WireRouteActivitySession) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(
            from: max(0, (session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        ) ?? tr("activityLessThanMinute")
    }

    private func retentionTitle(_ retention: WireRouteActivityRetention) -> String {
        switch retention {
        case .oneDay:
            return tr("activityRetentionOneDay")
        case .sevenDays:
            return tr("activityRetentionSevenDays")
        case .thirtyDays:
            return tr("activityRetentionThirtyDays")
        }
    }
}
