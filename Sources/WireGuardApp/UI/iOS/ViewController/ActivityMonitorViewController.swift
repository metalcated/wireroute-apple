// SPDX-License-Identifier: MIT

import UIKit

@MainActor
private final class WireRouteActivityChartView: UIView {
    var points = [WireRouteActivityPoint]() {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = tr("activityChartAccessibility")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let plotRect = rect.insetBy(dx: 10, dy: 12)
        context.setStrokeColor(UIColor.separator.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(0.5)
        for step in 0 ... 3 {
            let y = plotRect.minY + plotRect.height * CGFloat(step) / 3
            context.move(to: CGPoint(x: plotRect.minX, y: y))
            context.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        }
        context.strokePath()

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
            color: WireRouteAppearance.signalBlue,
            maximumRate: maximumRate,
            in: plotRect
        )
        drawSeries(
            points.map(\.sentBytesPerSecond),
            color: WireRouteAppearance.liveTeal,
            maximumRate: maximumRate,
            in: plotRect
        )
    }

    private func drawSeries(
        _ values: [Double],
        color: UIColor,
        maximumRate: Double,
        in rect: CGRect
    ) {
        let path = UIBezierPath()
        for (index, value) in values.enumerated() {
            let progress = values.count > 1 ? CGFloat(index) / CGFloat(values.count - 1) : 1
            let normalized = CGFloat(max(0, value) / maximumRate)
            let point = CGPoint(
                x: rect.minX + rect.width * progress,
                y: rect.maxY - rect.height * normalized
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        color.setStroke()
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()

        guard values.count > 1 else { return }
        let fillPath = path.copy() as! UIBezierPath
        fillPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fillPath.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        fillPath.close()
        color.withAlphaComponent(0.08).setFill()
        fillPath.fill()
    }

    private func drawEmptyState(in rect: CGRect) {
        let message = tr("activityWaitingForTraffic")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let size = message.size(withAttributes: attributes)
        message.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

@MainActor
private final class ActivityMetricView: UIView {
    private let valueLabel = UILabel()

    init(title: String, tintColor: UIColor) {
        super.init(frame: .zero)
        backgroundColor = WireRouteAppearance.card
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = WireRouteAppearance.roundedFont(size: 12, weight: .semibold, textStyle: .caption1)
        titleLabel.textColor = tintColor
        titleLabel.adjustsFontForContentSizeCategory = true

        valueLabel.text = "—"
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.minimumScaleFactor = 0.75
        valueLabel.adjustsFontSizeToFitWidth = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 5
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ value: String) {
        valueLabel.text = value
    }
}

@MainActor
final class ActivityMonitorViewController: UIViewController {
    private let tunnel: TunnelContainer
    private let store: WireRouteActivityStore?
    private var refreshTimer: Timer?
    private var liveAccumulator = WireRouteActivityAccumulator()
    private var livePoints = [WireRouteActivityPoint]()

    private let chartView = WireRouteActivityChartView()
    private let downloadRate = ActivityMetricView(
        title: tr("activityDownload"),
        tintColor: WireRouteAppearance.signalBlue
    )
    private let uploadRate = ActivityMetricView(
        title: tr("activityUpload"),
        tintColor: WireRouteAppearance.liveTeal
    )
    private let sessionTotal = ActivityMetricView(
        title: tr("activitySessionTotal"),
        tintColor: .secondaryLabel
    )
    private let lastHandshake = ActivityMetricView(
        title: tr("activityLastHandshake"),
        tintColor: .secondaryLabel
    )
    private let historyStack = UIStackView()
    private let statusLabel = UILabel()
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

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        store = try? WireRouteActivityStore()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("activityTitle")
        view.backgroundColor = WireRouteAppearance.background
        configureRetentionMenu()

        let subtitle = UILabel()
        subtitle.text = tr("activityIntro")
        subtitle.font = UIFont.preferredFont(forTextStyle: .body)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        chartView.heightAnchor.constraint(equalToConstant: 190).isActive = true
        let legend = makeLegend()
        let chartStack = UIStackView(arrangedSubviews: [chartView, legend])
        chartStack.axis = .vertical
        chartStack.spacing = 8
        let chartCard = makeCard(containing: chartStack)

        let rateRow = UIStackView(arrangedSubviews: [downloadRate, uploadRate])
        rateRow.axis = .horizontal
        rateRow.distribution = .fillEqually
        rateRow.spacing = 12
        let detailRow = UIStackView(arrangedSubviews: [sessionTotal, lastHandshake])
        detailRow.axis = .horizontal
        detailRow.distribution = .fillEqually
        detailRow.spacing = 12

        let historyTitle = UILabel()
        historyTitle.text = tr("activityRecentConnections")
        historyTitle.font = WireRouteAppearance.roundedFont(size: 18, weight: .semibold, textStyle: .headline)
        historyTitle.adjustsFontForContentSizeCategory = true

        historyStack.axis = .vertical
        historyStack.spacing = 0
        let historyCard = makeCard(containing: historyStack)

        let content = UIStackView(arrangedSubviews: [
            subtitle, statusLabel, chartCard, rateRow, detailRow, historyTitle, historyCard
        ])
        content.axis = .vertical
        content.spacing = 14
        content.setCustomSpacing(22, after: statusLabel)
        content.setCustomSpacing(24, after: detailRow)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(content)
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRefreshing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startRefreshing() {
        refresh()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        refreshStoredHistory()
        guard tunnel.status == .active else {
            downloadRate.setValue(formatRate(0))
            uploadRate.setValue(formatRate(0))
            statusLabel.text = tr("activityInactiveDescription")
            return
        }
        statusLabel.text = tr("activityRecordingDescription")
        tunnel.getRuntimeTunnelConfiguration { [weak self] configuration in
            guard let self, let configuration else { return }
            let peers = configuration.peers.map {
                WireRouteActivityPeerCounters(
                    peerIdentifier: $0.publicKey.base64Key,
                    receivedBytes: $0.rxBytes ?? 0,
                    sentBytes: $0.txBytes ?? 0,
                    lastHandshake: $0.lastHandshakeTime
                )
            }
            let now = Date()
            let delta = self.liveAccumulator.sample(peers: peers, at: now)
            self.downloadRate.setValue(self.formatRate(delta.receivedBytesPerSecond))
            self.uploadRate.setValue(self.formatRate(delta.sentBytesPerSecond))
            self.lastHandshake.setValue(self.formatHandshake(delta.lastHandshake))
            self.livePoints.append(
                WireRouteActivityPoint(
                    date: now,
                    receivedBytesPerSecond: delta.receivedBytesPerSecond,
                    sentBytesPerSecond: delta.sentBytesPerSecond,
                    totalReceivedBytes: delta.totalReceivedBytes,
                    totalSentBytes: delta.totalSentBytes,
                    lastHandshake: delta.lastHandshake
                )
            )
            self.livePoints = Array(self.livePoints.suffix(120))
            let storedPoints = (try? self.store?.points(
                profileIdentifier: self.tunnel.activityProfileIdentifier,
                since: now.addingTimeInterval(-60 * 60),
                limit: 720
            )) ?? []
            if storedPoints.isEmpty {
                self.chartView.points = self.livePoints
            }
        }
    }

    private func refreshStoredHistory() {
        guard let store else {
            statusLabel.text = tr("activityUnavailableDescription")
            return
        }
        let profileIdentifier = tunnel.activityProfileIdentifier
        do {
            let points = try store.points(
                profileIdentifier: profileIdentifier,
                since: Date().addingTimeInterval(-60 * 60),
                limit: 720
            )
            if !points.isEmpty {
                chartView.points = points
            }
            let sessions = try store.sessions(profileIdentifier: profileIdentifier)
            updateSessionSummary(sessions.first)
            updateHistory(sessions)
        } catch {
            statusLabel.text = error.localizedDescription
        }
    }

    private func updateSessionSummary(_ session: WireRouteActivitySession?) {
        guard let session else {
            sessionTotal.setValue("—")
            lastHandshake.setValue("—")
            return
        }
        let (combinedTotal, overflow) = session.receivedBytes.addingReportingOverflow(session.sentBytes)
        sessionTotal.setValue(formatBytes(overflow ? .max : combinedTotal))
        lastHandshake.setValue(formatHandshake(session.lastHandshake))
    }

    private func updateHistory(_ sessions: [WireRouteActivitySession]) {
        historyStack.arrangedSubviews.forEach {
            historyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !sessions.isEmpty else {
            let empty = historyLabel(tr("activityNoHistory"), color: .secondaryLabel)
            historyStack.addArrangedSubview(paddedHistoryView(empty))
            return
        }
        for (index, session) in sessions.prefix(8).enumerated() {
            if index > 0 {
                let divider = UIView()
                divider.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
                divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                historyStack.addArrangedSubview(divider)
            }
            let date = historyLabel(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            let total = historyLabel(
                "↓ \(formatBytes(session.receivedBytes))   ↑ \(formatBytes(session.sentBytes))",
                color: .secondaryLabel
            )
            total.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let duration = historyLabel(formatDuration(session), color: .secondaryLabel)
            duration.textAlignment = .right
            let text = UIStackView(arrangedSubviews: [date, total])
            text.axis = .vertical
            text.spacing = 4
            let row = UIStackView(arrangedSubviews: [text, duration])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            historyStack.addArrangedSubview(paddedHistoryView(row))
        }
    }

    private func configureRetentionMenu() {
        let selectedRetention = WireRouteActivityPreference.loadRetention()
        let retentionActions = WireRouteActivityRetention.allCases.map { retention in
            UIAction(
                title: retentionTitle(retention),
                state: retention == selectedRetention ? .on : .off
            ) { [weak self] _ in
                WireRouteActivityPreference.saveRetention(retention)
                self?.configureRetentionMenu()
            }
        }
        let clear = UIAction(
            title: tr("activityClearHistory"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmClearHistory()
        }
        let menu = UIMenu(children: [
            UIMenu(title: tr("activityKeepHistory"), options: .displayInline, children: retentionActions),
            clear
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: menu
        )
    }

    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: tr("activityClearHistoryTitle"),
            message: tr("activityClearHistoryMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: tr("activityCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: tr("activityClear"), style: .destructive) { [weak self] _ in
            guard let self, let store = self.store else { return }
            try? store.clearCompletedHistory(profileIdentifier: self.tunnel.activityProfileIdentifier)
            self.refreshStoredHistory()
        })
        present(alert, animated: true)
    }

    private func makeLegend() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [
            legendItem(color: WireRouteAppearance.signalBlue, title: tr("activityDownload")),
            legendItem(color: WireRouteAppearance.liveTeal, title: tr("activityUpload")),
            UIView()
        ])
        stack.axis = .horizontal
        stack.spacing = 16
        return stack
    }

    private func legendItem(color: UIColor, title: String) -> UIStackView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let label = historyLabel(title, color: .secondaryLabel)
        let stack = UIStackView(arrangedSubviews: [dot, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        return stack
    }

    private func makeCard(containing content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = WireRouteAppearance.card
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        card.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func paddedHistoryView(_ content: UIView) -> UIView {
        let container = UIView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private func historyLabel(_ text: String, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        formatBytes(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private func formatHandshake(_ date: Date?) -> String {
        guard let date else { return tr("activityNoHandshake") }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDuration(_ session: WireRouteActivitySession) -> String {
        let end = session.endedAt ?? Date()
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, end.timeIntervalSince(session.startedAt)))
            ?? tr("activityLessThanMinute")
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
