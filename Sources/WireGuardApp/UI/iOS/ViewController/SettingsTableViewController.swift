// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import os.log

private final class WireRouteSettingsFooterView: UIView {
    private let brandImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "WireRouteBrand"))
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 14
        return imageView
    }()

    private let productNameLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "WireRoute"
        brandImageView.accessibilityLabel = productName
        productNameLabel.text = productName

        let brandStack = UIStackView(arrangedSubviews: [brandImageView, productNameLabel])
        brandStack.axis = .horizontal
        brandStack.alignment = .center
        brandStack.spacing = 14
        addSubview(brandStack)
        brandStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            brandImageView.widthAnchor.constraint(equalToConstant: 64),
            brandImageView.heightAnchor.constraint(equalTo: brandImageView.widthAnchor),
            brandStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            brandStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            brandStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            brandStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            brandStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12)
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
        let currentFooterHeight = brandFooterView.frame.height
        let contentWithoutFooter = max(tableView.contentSize.height - currentFooterHeight, 0)
        let visibleHeight = tableView.bounds.height
            - tableView.adjustedContentInset.top
            - tableView.adjustedContentInset.bottom
        let footerHeight = max(112, visibleHeight - contentWithoutFooter)
        let footerWidth = tableView.bounds.width
        let needsReload = abs(footerHeight - currentFooterHeight) > 0.5
            || abs(footerWidth - brandFooterView.frame.width) > 0.5

        brandFooterView.frame = CGRect(x: 0, y: 0, width: footerWidth, height: footerHeight)

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
