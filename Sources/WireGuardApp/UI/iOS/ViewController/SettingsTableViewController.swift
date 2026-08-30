// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import os.log
import SafariServices

private final class WireRouteSettingsMarkView: UIView {
    override var intrinsicContentSize: CGSize {
        return CGSize(width: 50, height: 44)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let scaleX = rect.width / 50
        let scaleY = rect.height / 44
        context.saveGState()
        context.scaleBy(x: scaleX, y: scaleY)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let routePath = UIBezierPath()
        routePath.move(to: CGPoint(x: 6, y: 7))
        routePath.addLine(to: CGPoint(x: 25, y: 37))
        routePath.addLine(to: CGPoint(x: 44, y: 7))
        routePath.move(to: CGPoint(x: 13, y: 18))
        routePath.addCurve(
            to: CGPoint(x: 37, y: 18),
            controlPoint1: CGPoint(x: 18, y: 11),
            controlPoint2: CGPoint(x: 32, y: 11)
        )
        routePath.lineWidth = 3
        WireRouteAppearance.signalBlue.setStroke()
        routePath.stroke()

        let nodePath = UIBezierPath()
        for point in [CGPoint(x: 6, y: 7), CGPoint(x: 44, y: 7), CGPoint(x: 25, y: 37)] {
            nodePath.append(UIBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)))
        }
        WireRouteAppearance.liveTeal.setFill()
        nodePath.fill()

        let shieldPath = UIBezierPath()
        shieldPath.move(to: CGPoint(x: 25, y: 19))
        shieldPath.addLine(to: CGPoint(x: 31, y: 21.5))
        shieldPath.addLine(to: CGPoint(x: 30, y: 28))
        shieldPath.addQuadCurve(to: CGPoint(x: 25, y: 32), controlPoint: CGPoint(x: 28.5, y: 30.5))
        shieldPath.addQuadCurve(to: CGPoint(x: 20, y: 28), controlPoint: CGPoint(x: 21.5, y: 30.5))
        shieldPath.addLine(to: CGPoint(x: 19, y: 21.5))
        shieldPath.close()
        UIColor.label.setFill()
        shieldPath.fill()

        context.restoreGState()
    }
}

private final class WireRouteSettingsFooterView: UIView {
    private let markView = WireRouteSettingsMarkView()

    private let productNameLabel: UILabel = {
        let label = UILabel()
        label.font = WireRouteAppearance.roundedFont(size: 26, weight: .semibold, textStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "WireRoute"
        productNameLabel.text = productName
        isAccessibilityElement = true
        accessibilityLabel = productName

        let brandStack = UIStackView(arrangedSubviews: [markView, productNameLabel])
        brandStack.axis = .horizontal
        brandStack.alignment = .center
        brandStack.spacing = 12
        addSubview(brandStack)
        brandStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            markView.widthAnchor.constraint(equalToConstant: 50),
            markView.heightAnchor.constraint(equalToConstant: 44),
            brandStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            brandStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            brandStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            brandStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WireRouteSettingsIntroView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)

        let iconView = UIImageView(image: UIImage(systemName: "shield.checkered"))
        iconView.tintColor = WireRouteAppearance.signalBlue
        iconView.contentMode = .scaleAspectFit

        let messageLabel = UILabel()
        messageLabel.text = tr("iosSettingsSubtitle")
        messageLabel.font = UIFont.preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, messageLabel])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 12
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WireRouteSettingsItemCell: UITableViewCell {
    var onTapped: (() -> Void)?

    let actionButton = UIButton(type: .custom)
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let trailingImageView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none
        backgroundColor = WireRouteAppearance.card
        contentView.backgroundColor = WireRouteAppearance.card

        iconContainer.layer.cornerRadius = 12
        iconContainer.layer.cornerCurve = .continuous
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = WireRouteAppearance.roundedFont(size: 16, weight: .medium, textStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        detailLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2
        trailingImageView.contentMode = .scaleAspectFit
        trailingImageView.tintColor = .tertiaryLabel

        iconContainer.addSubview(iconView)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        let contentStack = UIStackView(arrangedSubviews: [iconContainer, textStack, UIView(), trailingImageView])
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 13
        contentStack.isUserInteractionEnabled = false

        actionButton.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(actionButton)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            actionButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: actionButton.layoutMarginsGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: actionButton.layoutMarginsGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: actionButton.layoutMarginsGuide.topAnchor, constant: 7),
            contentStack.bottomAnchor.constraint(equalTo: actionButton.layoutMarginsGuide.bottomAnchor, constant: -7),
            iconContainer.widthAnchor.constraint(equalToConstant: 42),
            iconContainer.heightAnchor.constraint(equalTo: iconContainer.widthAnchor),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            trailingImageView.widthAnchor.constraint(equalToConstant: 16),
            trailingImageView.heightAnchor.constraint(equalToConstant: 16)
        ])

        actionButton.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        actionButton.menu = nil
        actionButton.showsMenuAsPrimaryAction = false
        onTapped = nil
    }

    func configure(
        title: String,
        detail: String,
        symbolName: String,
        trailingSymbol: String?,
        isInteractive: Bool
    ) {
        titleLabel.text = title
        detailLabel.text = detail
        iconView.image = UIImage(systemName: symbolName)
        iconView.tintColor = WireRouteAppearance.signalBlue
        iconContainer.backgroundColor = WireRouteAppearance.signalBlue.withAlphaComponent(0.14)
        trailingImageView.image = trailingSymbol.flatMap { UIImage(systemName: $0) }
        trailingImageView.isHidden = trailingSymbol == nil
        actionButton.isUserInteractionEnabled = isInteractive
        actionButton.accessibilityLabel = title
        actionButton.accessibilityValue = detail
        actionButton.accessibilityTraits = isInteractive ? .button : .staticText
    }

    @objc private func buttonTapped() {
        onTapped?()
    }
}

class SettingsTableViewController: UITableViewController {

    enum SettingsFields {
        case iosAppVersion
        case goBackendVersion
        case appearance
        case activityRetention
        case exportZipArchive
        case viewLog
        case support
        case privacy
        case legal

        var localizedUIString: String {
            switch self {
            case .iosAppVersion: return tr("settingsVersionKeyWireGuardForIOS")
            case .goBackendVersion: return tr("settingsVersionKeyWireGuardGoBackend")
            case .appearance: return tr("iosSettingsAppearance")
            case .activityRetention: return tr("iosSettingsActivityRetention")
            case .exportZipArchive: return tr("settingsExportZipButtonTitle")
            case .viewLog: return tr("settingsViewLogButtonTitle")
            case .support: return tr("iosSettingsSupport")
            case .privacy: return tr("iosSettingsPrivacy")
            case .legal: return tr("iosSettingsLegal")
            }
        }
    }

    let settingsFieldsBySection: [[SettingsFields]] = [
        [.iosAppVersion, .goBackendVersion],
        [.appearance, .activityRetention],
        [.exportZipArchive, .viewLog],
        [.support, .privacy, .legal]
    ]

    private(set) var tunnelsManager: TunnelsManager?
    private let showsDoneButton: Bool
    private let introHeaderView = WireRouteSettingsIntroView()
    private let brandFooterView = WireRouteSettingsFooterView()

    init(tunnelsManager: TunnelsManager?, showsDoneButton: Bool = true) {
        self.tunnelsManager = tunnelsManager
        self.showsDoneButton = showsDoneButton
        super.init(style: .insetGrouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("settingsViewTitle")
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        if showsDoneButton {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        }

        tableView.backgroundColor = WireRouteAppearance.background
        tableView.separatorColor = WireRouteAppearance.border.withAlphaComponent(0.52)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 70, bottom: 0, right: 20)
        tableView.sectionHeaderTopPadding = 18
        tableView.estimatedRowHeight = 72
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false

        tableView.register(WireRouteSettingsItemCell.self)

        introHeaderView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 72)
        tableView.tableHeaderView = introHeaderView
        tableView.tableFooterView = brandFooterView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateIntroHeaderSize()

        let footerHeight: CGFloat = 68
        let bottomPadding = max(tableView.safeAreaInsets.bottom, 10)
        let minimumContentHeight = tableView.bounds.height
            - tableView.adjustedContentInset.top
            - bottomPadding
        let fullContentHeight = max(tableView.contentSize.height, minimumContentHeight)
        let footerWidth = tableView.bounds.width
        let footerY = max(fullContentHeight - footerHeight, 0)
        let needsReload = abs(footerHeight - brandFooterView.frame.height) > 0.5
            || abs(footerWidth - brandFooterView.frame.width) > 0.5

        brandFooterView.frame = CGRect(x: 0, y: footerY, width: footerWidth, height: footerHeight)

        if needsReload {
            tableView.tableFooterView = brandFooterView
        }
    }

    private func updateIntroHeaderSize() {
        let targetWidth = tableView.bounds.width
        guard targetWidth > 0 else { return }

        introHeaderView.frame.size.width = targetWidth
        let targetSize = introHeaderView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard abs(introHeaderView.frame.height - targetSize.height) > 0.5 else { return }

        introHeaderView.frame.size.height = targetSize.height
        tableView.tableHeaderView = introHeaderView
    }

    @objc func doneTapped() {
        dismiss(animated: true, completion: nil)
    }

    func setTunnelsManager(_ tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        tableView.reloadData()
    }

    func exportConfigurationsAsZipFile(sourceView: UIView) {
        PrivateDataConfirmation.confirmAccess(to: tr("iosExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let tunnelsManager = self.tunnelsManager else { return }
            guard let destinationDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            let destinationURL = destinationDir.appendingPathComponent("wireguard-export.zip")
            _ = FileManager.deleteFile(at: destinationURL)

            let count = tunnelsManager.numberOfTunnels()
            let tunnelConfigurations = (0 ..< count).compactMap { tunnelsManager.tunnel(at: $0).tunnelConfiguration }
            ZipExporter.exportConfigFiles(tunnelConfigurations: tunnelConfigurations, to: destinationURL) { [weak self] error in
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }

                let fileExportVC = UIDocumentPickerViewController(forExporting: [destinationURL], asCopy: true)
                self?.present(fileExportVC, animated: true, completion: nil)
            }
        }
    }

    func presentLogView() {
        let logVC = LogViewController()
        navigationController?.pushViewController(logVC, animated: true)

    }

    private func presentProjectDocument(path: String) {
        guard let url = URL(string: "https://github.com/metalcated/wireroute-apple/blob/master/\(path)") else { return }
        let browser = SFSafariViewController(url: url)
        browser.preferredControlTintColor = WireRouteAppearance.signalBlue
        present(browser, animated: true)
    }

    private func activityRetentionTitle(_ retention: WireRouteActivityRetention) -> String {
        switch retention {
        case .oneDay: return tr("activityRetentionOneDay")
        case .sevenDays: return tr("activityRetentionSevenDays")
        case .thirtyDays: return tr("activityRetentionThirtyDays")
        }
    }

    private func configureActivityRetentionButton(_ cell: WireRouteSettingsItemCell) {
        let selectedRetention = WireRouteActivityPreference.loadRetention()
        cell.configure(
            title: tr("iosSettingsActivityRetention"),
            detail: activityRetentionTitle(selectedRetention),
            symbolName: "clock.arrow.circlepath",
            trailingSymbol: "chevron.up.chevron.down",
            isInteractive: true
        )
        cell.actionButton.menu = UIMenu(children: WireRouteActivityRetention.allCases.map { retention in
            UIAction(
                title: activityRetentionTitle(retention),
                state: retention == selectedRetention ? .on : .off
            ) { [weak self] _ in
                WireRouteActivityPreference.saveRetention(retention)
                self?.tableView.reloadData()
            }
        })
        cell.actionButton.showsMenuAsPrimaryAction = true
    }
}

extension SettingsTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return settingsFieldsBySection.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return settingsFieldsBySection[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return tr("settingsSectionTitleAbout")
        case 1:
            return tr("iosSettingsSectionPreferences")
        case 2:
            return tr("iosSettingsSectionData")
        case 3:
            return tr("iosSettingsSectionHelp")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = settingsFieldsBySection[indexPath.section][indexPath.row]
        let cell: WireRouteSettingsItemCell = tableView.dequeueReusableCell(for: indexPath)

        switch field {
        case .iosAppVersion:
            var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version"
            if let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                appVersion += " (\(appBuild))"
            }
            cell.configure(
                title: field.localizedUIString,
                detail: appVersion,
                symbolName: "app.badge",
                trailingSymbol: nil,
                isInteractive: false
            )
        case .goBackendVersion:
            cell.configure(
                title: field.localizedUIString,
                detail: WIREGUARD_GO_VERSION,
                symbolName: "bolt.horizontal.circle",
                trailingSymbol: nil,
                isInteractive: false
            )
        case .appearance:
            cell.configure(
                title: field.localizedUIString,
                detail: tr("iosSettingsAppearanceNordicBlue"),
                symbolName: "paintpalette",
                trailingSymbol: nil,
                isInteractive: false
            )
        case .activityRetention:
            configureActivityRetentionButton(cell)
        case .exportZipArchive:
            cell.configure(
                title: field.localizedUIString,
                detail: tr("iosSettingsExportDescription"),
                symbolName: "square.and.arrow.up",
                trailingSymbol: "chevron.right",
                isInteractive: true
            )
            cell.onTapped = { [weak self] in
                self?.exportConfigurationsAsZipFile(sourceView: cell.actionButton)
            }
        case .viewLog:
            cell.configure(
                title: field.localizedUIString,
                detail: tr("iosSettingsLogDescription"),
                symbolName: "doc.text.magnifyingglass",
                trailingSymbol: "chevron.right",
                isInteractive: true
            )
            cell.onTapped = { [weak self] in
                self?.presentLogView()
            }
        case .support:
            cell.configure(
                title: field.localizedUIString,
                detail: tr("iosSettingsSupportDescription"),
                symbolName: "lifepreserver",
                trailingSymbol: "chevron.right",
                isInteractive: true
            )
            cell.onTapped = { [weak self] in
                self?.presentProjectDocument(path: "SUPPORT.md")
            }
        case .privacy:
            cell.configure(
                title: field.localizedUIString,
                detail: tr("iosSettingsPrivacyDescription"),
                symbolName: "hand.raised",
                trailingSymbol: "chevron.right",
                isInteractive: true
            )
            cell.onTapped = { [weak self] in
                self?.presentProjectDocument(path: "PRIVACY.md")
            }
        case .legal:
            cell.configure(
                title: field.localizedUIString,
                detail: tr("iosSettingsLegalDescription"),
                symbolName: "doc.text",
                trailingSymbol: "chevron.right",
                isInteractive: true
            )
            cell.onTapped = { [weak self] in
                self?.presentProjectDocument(path: "LEGAL.md")
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = WireRouteAppearance.roundedFont(size: 14, weight: .medium, textStyle: .subheadline)
        header.textLabel?.textColor = .secondaryLabel
    }
}
