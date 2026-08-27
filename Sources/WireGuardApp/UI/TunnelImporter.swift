// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

private struct ImportedConfigFile: Sendable {
    let configuration: TunnelConfiguration?
    let errorText: (title: String, message: String)?
}

@MainActor
private final class TunnelImportAccumulator {
    var configurations = [TunnelConfiguration?]()
    var lastErrorText: (title: String, message: String)?
}

@MainActor
class TunnelImporter {
    static func importFromFile(
        urls: [URL],
        into tunnelsManager: TunnelsManager,
        sourceVC: AnyObject?,
        errorPresenterType: ErrorPresenterProtocol.Type,
        completionHandler: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !urls.isEmpty else {
            completionHandler?()
            return
        }
        let dispatchGroup = DispatchGroup()
        let accumulator = TunnelImportAccumulator()
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                dispatchGroup.enter()
                ZipImporter.importConfigFiles(from: url) { result in
                    switch result {
                    case .failure(let error):
                        accumulator.lastErrorText = error.alertText
                    case .success(let configsInZip):
                        accumulator.configurations.append(contentsOf: configsInZip)
                    }
                    dispatchGroup.leave()
                }
            } else { /* if it is not a zip, we assume it is a conf */
                dispatchGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let importedFile = importConfigFile(at: url)
                    Task { @MainActor in
                        accumulator.lastErrorText = importedFile.errorText ?? accumulator.lastErrorText
                        accumulator.configurations.append(importedFile.configuration)
                        dispatchGroup.leave()
                    }
                }
            }
        }
        dispatchGroup.notify(queue: .main) {
            let configs = accumulator.configurations
            tunnelsManager.addMultiple(tunnelConfigurations: configs.compactMap { $0 }) { numberSuccessful, lastAddError in
                if !configs.isEmpty && numberSuccessful == configs.count {
                    completionHandler?()
                    return
                }
                let alertText: (title: String, message: String)?
                if urls.count == 1 {
                    if urls.first!.pathExtension.lowercased() == "zip" && !configs.isEmpty {
                        alertText = (title: tr(format: "alertImportedFromZipTitle (%d)", numberSuccessful),
                                     message: tr(format: "alertImportedFromZipMessage (%1$d of %2$d)", numberSuccessful, configs.count))
                    } else {
                        alertText = accumulator.lastErrorText ?? lastAddError?.alertText
                    }
                } else {
                    alertText = (title: tr(format: "alertImportedFromMultipleFilesTitle (%d)", numberSuccessful),
                                 message: tr(format: "alertImportedFromMultipleFilesMessage (%1$d of %2$d)", numberSuccessful, configs.count))
                }
                if let alertText = alertText {
                    errorPresenterType.showErrorAlert(title: alertText.title, message: alertText.message, from: sourceVC, onPresented: completionHandler)
                } else {
                    completionHandler?()
                }
            }
        }
    }

    private nonisolated static func importConfigFile(at url: URL) -> ImportedConfigFile {
        let fileName = url.lastPathComponent
        let fileBaseName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileContents: String
        do {
            fileContents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message: String
            if let cocoaError = error as? CocoaError, cocoaError.isFileError {
                message = error.localizedDescription
            } else {
                message = tr(format: "alertCantOpenInputConfFileMessage (%@)", fileName)
            }
            return ImportedConfigFile(
                configuration: nil,
                errorText: (title: tr("alertCantOpenInputConfFileTitle"), message: message)
            )
        }

        do {
            return ImportedConfigFile(
                configuration: try TunnelConfiguration(fromWgQuickConfig: fileContents, called: fileBaseName),
                errorText: nil
            )
        } catch let error as WireGuardAppError {
            return ImportedConfigFile(configuration: nil, errorText: error.alertText)
        } catch {
            return ImportedConfigFile(
                configuration: nil,
                errorText: (
                    title: tr("alertBadConfigImportTitle"),
                    message: tr(format: "alertBadConfigImportMessage (%@)", fileName)
                )
            )
        }
    }
}
