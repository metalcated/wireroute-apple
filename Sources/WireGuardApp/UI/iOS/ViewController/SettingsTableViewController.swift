// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import os.log

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

class SettingsTableViewController: UITableViewController {

    enum SettingsFields {
        case iosAppVersion
        case goBackendVersion
        case exportZipArchive
        case viewLog

        var localizedUIString: String {
            switch self {
            case .iosAppVersion: return tr("settingsVersionKeyWireGuardForIOS")
            case .goBackendVersion: return tr("settingsVersionKeyWireGuardGoBackend")
            case .exportZipArchive: return tr("settingsExportZipButtonTitle")
            case .viewLog: return tr("settingsViewLogButtonTitle")
            }
        }
    }

    let settingsFieldsBySection: [[SettingsFields]] = [
        [.iosAppVersion, .goBackendVersion],
        [.exportZipArchive],
        [.viewLog]
    ]

    let tunnelsManager: TunnelsManager?
    private let brandFooterView = WireRouteSettingsFooterView()

    init(tunnelsManager: TunnelsManager?) {
        self.tunnelsManager = tunnelsManager
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("settingsViewTitle")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false

        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)

        tableView.tableFooterView = brandFooterView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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

    @objc func doneTapped() {
        dismiss(animated: true, completion: nil)
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
            return tr("settingsSectionTitleExportConfigurations")
        case 2:
            return tr("settingsSectionTitleTunnelLog")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = settingsFieldsBySection[indexPath.section][indexPath.row]
        if field == .iosAppVersion || field == .goBackendVersion {
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.copyableGesture = false
            cell.key = field.localizedUIString
            if field == .iosAppVersion {
                var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version"
                if let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    appVersion += " (\(appBuild))"
                }
                cell.value = appVersion
            } else if field == .goBackendVersion {
                cell.value = WIREGUARD_GO_VERSION
            }
            return cell
        } else if field == .exportZipArchive {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = field.localizedUIString
            cell.onTapped = { [weak self] in
                self?.exportConfigurationsAsZipFile(sourceView: cell.button)
            }
            return cell
        } else if field == .viewLog {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = field.localizedUIString
            cell.onTapped = { [weak self] in
                self?.presentLogView()
            }
            return cell
        }
        fatalError()
    }
}
