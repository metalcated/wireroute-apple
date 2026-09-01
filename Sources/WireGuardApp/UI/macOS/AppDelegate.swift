// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa
import ServiceManagement
@preconcurrency import SystemExtensions

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    var tunnelsManager: TunnelsManager?
    var tunnelsTracker: TunnelsTracker?
    var statusItemController: StatusItemController?

    var manageTunnelsRootVC: ManageTunnelsRootViewController?
    var manageTunnelsWindowObject: NSWindow?
    var onAppDeactivation: (() -> Void)?
    private var aboutWindowController: NSWindowController?
    private var systemExtensionActivationCoordinator: SystemExtensionActivationCoordinator?
    private var shouldPresentSystemExtensionApprovalGuide = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        WireRouteTheme.applyStoredPreference()
        // To workaround a possible AppKit bug that causes the main menu to become unresponsive sometimes
        // (especially when launched through Xcode) if we call setActivationPolicy(.regular) in
        // in applicationDidFinishLaunching, we set it to .prohibited here.
        // Setting it to .regular would fix that problem too, but at this point, we don't know
        // whether the app was launched at login or not, so we're not sure whether we should
        // show the app icon in the dock or not.
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Logger.configureGlobal(tagged: "APP", withFilePath: FileManager.logFileURL?.path)
#if DEBUG
        let isAppStoreScreenshotMode = ProcessInfo.processInfo.arguments.contains("--app-store-screenshots")
#else
        let isAppStoreScreenshotMode = false
#endif
        if !isAppStoreScreenshotMode {
            registerLoginItem(shouldLaunchAtLogin: true)
        }

        var isLaunchedAtLogin = false
        if let appleEvent = NSAppleEventManager.shared().currentAppleEvent {
            isLaunchedAtLogin = LaunchedAtLoginDetector.isLaunchedAtLogin(openAppleEvent: appleEvent)
        }
#if DEBUG
        if isAppStoreScreenshotMode {
            isLaunchedAtLogin = false
        }
#endif

        NSApp.mainMenu = MainMenu(application: NSApp, applicationDelegate: NSApp.delegate)
        setDockIconAndMainMenuVisibility(isVisible: !isLaunchedAtLogin)

        activateSystemExtensionIfPresent { [weak self] in
            self?.finishApplicationLaunch(isLaunchedAtLogin: isLaunchedAtLogin)
        }
    }

    private func finishApplicationLaunch(isLaunchedAtLogin: Bool) {
        TunnelsManager.create { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                ErrorPresenter.showErrorAlert(error: error, from: nil)
            case .success(let tunnelsManager):
                let statusMenu = StatusMenu(tunnelsManager: tunnelsManager)
                statusMenu.windowDelegate = self

                let statusItemController = StatusItemController()
                statusItemController.statusItem.menu = statusMenu

                let tunnelsTracker = TunnelsTracker(tunnelsManager: tunnelsManager)
                tunnelsTracker.statusMenu = statusMenu
                tunnelsTracker.statusItemController = statusItemController

                self.tunnelsManager = tunnelsManager
                self.tunnelsTracker = tunnelsTracker
                self.statusItemController = statusItemController

                let shouldShowManageWindow = !isLaunchedAtLogin || self.shouldPresentSystemExtensionApprovalGuide
                if shouldShowManageWindow {
#if DEBUG
                    self.showManageTunnelsWindow { [weak self] window in
                        self?.configureAppStoreScreenshotIfNeeded(window: window, tunnelsManager: tunnelsManager)
                        self?.presentSystemExtensionApprovalGuideIfNeeded(window: window)
                    }
#else
                    self.showManageTunnelsWindow { [weak self] window in
                        self?.presentSystemExtensionApprovalGuideIfNeeded(window: window)
                    }
#endif
                }
            }
        }
    }

    private func activateSystemExtensionIfPresent(completion: @escaping @MainActor () -> Void) {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--system-extension-approval-guide") {
            shouldPresentSystemExtensionApprovalGuide = true
            completion()
            return
        }
#endif
        guard let extensionIdentifier = SystemExtensionActivationCoordinator.embeddedSystemExtensionIdentifier else {
            completion()
            return
        }

        let coordinator = SystemExtensionActivationCoordinator(extensionIdentifier: extensionIdentifier)
        systemExtensionActivationCoordinator = coordinator
        let launchGate = SystemExtensionLaunchGate(completion: completion)
        coordinator.activate(
            onNeedsUserApproval: { [weak self] in
                self?.shouldPresentSystemExtensionApprovalGuide = true
                launchGate.finish()
            },
            completion: { [weak self] result in
                self?.systemExtensionActivationCoordinator = nil
                if case .failure(let error) = result {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "WireRoute system extension could not be activated"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: tr("actionOK"))
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                launchGate.finish()
            }
        )
    }

    private func presentSystemExtensionApprovalGuideIfNeeded(window: NSWindow?) {
        guard shouldPresentSystemExtensionApprovalGuide, let window else { return }
        shouldPresentSystemExtensionApprovalGuide = false

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = tr("macSystemExtensionApprovalTitle")
        alert.informativeText = tr("macSystemExtensionApprovalMessage")
        alert.addButton(withTitle: tr("macSystemExtensionApprovalOpenSettings"))
        alert.addButton(withTitle: tr("macSystemExtensionApprovalLater"))

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(self)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Self.openSystemExtensionSettings()
        }
    }

    private static func openSystemExtensionSettings() {
        if let loginItemsURL = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ), NSWorkspace.shared.open(loginItemsURL) {
            return
        }

        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
        )
    }

#if DEBUG
    private func configureAppStoreScreenshotIfNeeded(
        window: NSWindow?,
        tunnelsManager: TunnelsManager
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--app-store-screenshots"), let window else { return }

        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        window.center()

        let route = arguments
            .first(where: { $0.hasPrefix("--app-store-screen=") })?
            .replacingOccurrences(of: "--app-store-screen=", with: "")

        switch route {
        case "routeros":
            manageTunnelsRootVC?.selectRouterOSManager()
        case "settings":
            manageTunnelsRootVC?.selectSettings()
        case "activity":
            guard tunnelsManager.numberOfTunnels() > 0 else { return }
            let tunnel = tunnelsManager.tunnel(at: 0)
            manageTunnelsRootVC?.selectTunnel(tunnel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let detailViewController = self?.manageTunnelsRootVC?.tunnelDetailVC else { return }
                detailViewController.presentAsSheet(ActivityMonitorViewController(tunnel: tunnel))
            }
        default:
            guard tunnelsManager.numberOfTunnels() > 0 else { return }
            manageTunnelsRootVC?.selectTunnel(tunnelsManager.tunnel(at: 0))
        }
    }
#endif

    @objc func confirmAndQuit() {
        let alert = NSAlert()
        alert.messageText = tr("macConfirmAndQuitAlertMessage")
        if let currentTunnel = tunnelsTracker?.currentTunnel, currentTunnel.status == .active || currentTunnel.status == .activating {
            alert.informativeText = tr(format: "macConfirmAndQuitInfoWithActiveTunnel (%@)", currentTunnel.name)
        } else {
            alert.informativeText = tr("macConfirmAndQuitAlertInfo")
        }
        alert.addButton(withTitle: tr("macConfirmAndQuitAlertCloseWindow"))
        alert.addButton(withTitle: tr("macConfirmAndQuitAlertQuitWireGuard"))

        NSApp.activate(ignoringOtherApps: true)
        if let manageWindow = manageTunnelsWindowObject {
            manageWindow.orderFront(self)
            alert.beginSheetModal(for: manageWindow) { response in
                switch response {
                case .alertFirstButtonReturn:
                    manageWindow.close()
                case .alertSecondButtonReturn:
                    NSApp.terminate(nil)
                default:
                    break
                }
            }
        }
    }

    @objc func quit() {
        if let manageWindow = manageTunnelsWindowObject, manageWindow.attachedSheet != nil {
            NSApp.activate(ignoringOtherApps: true)
            manageWindow.orderFront(self)
            return
        }
        registerLoginItem(shouldLaunchAtLogin: false)
        guard let currentTunnel = tunnelsTracker?.currentTunnel, currentTunnel.status == .active || currentTunnel.status == .activating else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = tr("macAppExitingWithActiveTunnelMessage")
        alert.informativeText = tr("macAppExitingWithActiveTunnelInfo")
        NSApp.activate(ignoringOtherApps: true)
        if let manageWindow = manageTunnelsWindowObject {
            manageWindow.orderFront(self)
            alert.beginSheetModal(for: manageWindow) { _ in
                NSApp.terminate(nil)
            }
        } else {
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let currentTunnel = tunnelsTracker?.currentTunnel, currentTunnel.status == .active || currentTunnel.status == .activating else {
            return .terminateNow
        }
        guard let appleEvent = NSAppleEventManager.shared().currentAppleEvent else {
            return .terminateNow
        }
        guard MacAppStoreUpdateDetector.isUpdatingFromMacAppStore(quitAppleEvent: appleEvent) else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = tr("macAppStoreUpdatingAlertMessage")
        if currentTunnel.isActivateOnDemandEnabled {
            alert.informativeText = tr(format: "macAppStoreUpdatingAlertInfoWithOnDemand (%@)", currentTunnel.name)
        } else {
            alert.informativeText = tr(format: "macAppStoreUpdatingAlertInfoWithoutOnDemand (%@)", currentTunnel.name)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let manageWindow = manageTunnelsWindowObject {
            alert.beginSheetModal(for: manageWindow) { _ in }
        } else {
            alert.runModal()
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.setDockIconAndMainMenuVisibility(isVisible: false)
        }
        return false
    }

    private func setDockIconAndMainMenuVisibility(isVisible: Bool, completion: (() -> Void)? = nil) {
        let currentActivationPolicy = NSApp.activationPolicy()
        let newActivationPolicy: NSApplication.ActivationPolicy = isVisible ? .regular : .accessory
        guard currentActivationPolicy != newActivationPolicy else {
            if newActivationPolicy == .regular {
                NSApp.activate(ignoringOtherApps: true)
            }
            completion?()
            return
        }
        if newActivationPolicy == .regular && NSApp.isActive {
            // To workaround a possible AppKit bug that causes the main menu to become unresponsive,
            // we should deactivate the app first and then set the activation policy.
            // NSApp.deactivate() doesn't always deactivate the app, so we instead use
            // setActivationPolicy(.prohibited).
            onAppDeactivation = {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                completion?()
            }
            NSApp.setActivationPolicy(.prohibited)
        } else {
            NSApp.setActivationPolicy(newActivationPolicy)
            if newActivationPolicy == .regular {
                NSApp.activate(ignoringOtherApps: true)
            }
            completion?()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        onAppDeactivation?()
        onAppDeactivation = nil
    }
}

@MainActor
private final class SystemExtensionLaunchGate {

    private var didFinish = false
    private let completion: @MainActor () -> Void

    init(completion: @escaping @MainActor () -> Void) {
        self.completion = completion
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        completion()
    }
}

@MainActor
private final class SystemExtensionActivationCoordinator: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {

    private enum ActivationError: LocalizedError {
        case restartRequired

        var errorDescription: String? {
            switch self {
            case .restartRequired:
                return "macOS must be restarted before WireRoute can use its VPN system extension."
            }
        }
    }

    static var embeddedSystemExtensionIdentifier: String? {
        guard let appIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let identifier = "\(appIdentifier).network-extension"
        let systemExtensionsURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        let embeddedExtensions = try? FileManager.default.contentsOfDirectory(
            at: systemExtensionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let containsMatchingExtension = embeddedExtensions?.contains { url in
            url.pathExtension == "systemextension" && Bundle(url: url)?.bundleIdentifier == identifier
        } ?? false
        return containsMatchingExtension ? identifier : nil
    }

    private let extensionIdentifier: String
    private var needsUserApproval: (() -> Void)?
    private var completion: ((Result<Void, Error>) -> Void)?

    init(extensionIdentifier: String) {
        self.extensionIdentifier = extensionIdentifier
    }

    func activate(
        onNeedsUserApproval: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        needsUserApproval = onNeedsUserApproval
        self.completion = completion
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        wg_log(.info, message: "WireRoute's VPN system extension is waiting for user approval")
        let needsUserApproval = needsUserApproval
        self.needsUserApproval = nil
        needsUserApproval?()
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            finish(with: .success(()))
        case .willCompleteAfterReboot:
            finish(with: .failure(ActivationError.restartRequired))
        @unknown default:
            finish(with: .failure(ActivationError.restartRequired))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) {
        needsUserApproval = nil
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

extension AppDelegate {
    @objc func aboutClicked() {
        var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        if let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            appVersion += " (\(appBuild))"
        }

        if let aboutWindowController {
            NSApp.activate(ignoringOtherApps: true)
            aboutWindowController.showWindow(nil)
            aboutWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let aboutViewController = WireRouteAboutViewController(
            appVersion: appVersion,
            backendVersion: WIREGUARD_GO_VERSION
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = tr("macMenuAbout")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = aboutViewController
        panel.setContentSize(NSSize(width: 500, height: 390))
        panel.center()
        WireRouteTheme.apply(to: panel)

        let windowController = NSWindowController(window: panel)
        aboutWindowController = windowController
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func showRouterOSManager() {
        showManageTunnelsWindow { [weak self] window in
            guard window != nil else { return }
            self?.manageTunnelsRootVC?.selectRouterOSManager()
        }
    }

    @objc func showRouterOSSettings() {
        showManageTunnelsWindow { [weak self] window in
            guard window != nil else { return }
            self?.manageTunnelsRootVC?.selectSettings()
        }
    }
}

@MainActor
private final class WireRouteAboutViewController: NSViewController {
    private let appVersion: String
    private let backendVersion: String

    init(appVersion: String, backendVersion: String) {
        self.appVersion = appVersion
        self.backendVersion = backendVersion
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 500, height: 390)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = AppearanceAwareMaterialView(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            nordicSurface: .surface
        )

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: "WireRoute")
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let appVersionLabel = makeLabel(
            tr(format: "macAppVersion (%@)", appVersion),
            font: .systemFont(ofSize: 14, weight: .regular)
        )
        let backendVersionLabel = makeLabel(
            tr(format: "macGoBackendVersion (%@)", backendVersion),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        let versionStack = NSStackView(views: [appVersionLabel, backendVersionLabel])
        versionStack.orientation = .vertical
        versionStack.alignment = .centerX
        versionStack.spacing = 5

        let copyright = (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
            .replacingOccurrences(of: ". Portions", with: ".\nPortions")
        let copyrightLabel = makeLabel(
            copyright,
            font: .systemFont(ofSize: 12, weight: .regular),
            color: .secondaryLabelColor
        )
        copyrightLabel.maximumNumberOfLines = 2
        copyrightLabel.lineBreakMode = .byWordWrapping

        let contentStack = NSStackView(views: [iconView, titleLabel, versionStack, copyrightLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 14
        contentStack.setCustomSpacing(18, after: iconView)
        contentStack.setCustomSpacing(20, after: versionStack)

        rootView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        copyrightLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 5),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 44),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -44),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            copyrightLabel.widthAnchor.constraint(equalToConstant: 400)
        ])

        view = rootView
    }

    private func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .center
        return label
    }
}

extension AppDelegate: StatusMenuWindowDelegate {
    func showManageTunnelsWindow(selecting tunnel: TunnelContainer) {
        showManageTunnelsWindow { [weak self] _ in
            self?.manageTunnelsRootVC?.selectTunnel(tunnel)
        }
    }

    func showManageTunnelsWindow(completion: ((NSWindow?) -> Void)?) {
        guard let tunnelsManager = tunnelsManager else {
            completion?(nil)
            return
        }
        if manageTunnelsWindowObject == nil {
            manageTunnelsRootVC = ManageTunnelsRootViewController(tunnelsManager: tunnelsManager)
            let window = NSWindow(contentViewController: manageTunnelsRootVC!)
            window.title = tr("macWindowTitleManageTunnels")
            window.setContentSize(NSSize(width: 1040, height: 680))
            window.minSize = NSSize(width: 900, height: 580)
            window.titlebarAppearsTransparent = true
            window.setFrameAutosaveName(NSWindow.FrameAutosaveName("ManageTunnelsWindow")) // Auto-save window position and size
            WireRouteTheme.apply(to: window)
            manageTunnelsWindowObject = window
            tunnelsTracker?.manageTunnelsRootVC = manageTunnelsRootVC
        }
        setDockIconAndMainMenuVisibility(isVisible: true) { [weak manageTunnelsWindowObject] in
            manageTunnelsWindowObject?.makeKeyAndOrderFront(self)
            completion?(manageTunnelsWindowObject)
        }
    }
}

@discardableResult
func registerLoginItem(shouldLaunchAtLogin: Bool) -> Bool {
    let appId = Bundle.main.bundleIdentifier!
    let helperBundleId = "\(appId).login-item-helper"
    let service = SMAppService.loginItem(identifier: helperBundleId)
    do {
        if shouldLaunchAtLogin {
            if service.status == .notRegistered {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        return true
    } catch {
        wg_log(.error, message: "Unable to update login item registration: \(error)")
        return false
    }
}
