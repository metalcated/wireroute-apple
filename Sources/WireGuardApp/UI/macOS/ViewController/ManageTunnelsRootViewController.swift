// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Cocoa

enum WireRouteAppearance: String, CaseIterable {
    case system
    case blueNordic

    var localizedTitle: String {
        switch self {
        case .system:
            return tr("macSettingsThemeSystem")
        case .blueNordic:
            return tr("macSettingsThemeBlueNordic")
        }
    }
}

enum WireRouteAppearancePreference {
    private static let key = "WireRoute.Appearance"

    static func load(from defaults: UserDefaults = .standard) -> WireRouteAppearance {
        guard let rawValue = defaults.string(forKey: key),
              let appearance = WireRouteAppearance(rawValue: rawValue) else {
            return .system
        }
        return appearance
    }

    static func save(_ appearance: WireRouteAppearance, to defaults: UserDefaults = .standard) {
        defaults.set(appearance.rawValue, forKey: key)
    }
}

extension Notification.Name {
    static let wireRouteAppearanceDidChange = Notification.Name("WireRouteAppearanceDidChange")
}

@MainActor
enum WireRouteTheme {
    enum Surface {
        case canvas
        case sidebar
        case inset
        case surface
        case raised
    }

    private(set) static var appearance = WireRouteAppearancePreference.load()

    static var isBlueNordic: Bool {
        return appearance == .blueNordic
    }

    static var accentColor: NSColor {
        return isBlueNordic ? blueNordicPrimary : .systemBlue
    }

    static func applyStoredPreference() {
        apply(WireRouteAppearancePreference.load(), persist: false)
    }

    static func apply(_ newAppearance: WireRouteAppearance, persist: Bool = true) {
        appearance = newAppearance
        if persist {
            WireRouteAppearancePreference.save(newAppearance)
        }
        NSApp.appearance = isBlueNordic ? NSAppearance(named: .darkAqua) : nil
        for window in NSApp.windows {
            apply(to: window)
        }
        NotificationCenter.default.post(name: .wireRouteAppearanceDidChange, object: newAppearance)
    }

    static func apply(to window: NSWindow) {
        window.backgroundColor = isBlueNordic ? color(for: .canvas) : .windowBackgroundColor
        if let contentView = window.contentView {
            refresh(contentView)
        }
    }

    static func refresh(_ view: NSView) {
        (view as? WireRouteThemeField)?.updateWireRouteTheme()
        view.needsDisplay = true
        view.needsLayout = true
        for subview in view.subviews {
            refresh(subview)
        }
    }

    static func color(for surface: Surface) -> NSColor {
        switch surface {
        case .canvas:
            return blueNordicCanvas
        case .sidebar:
            return blueNordicSidebar
        case .inset:
            return blueNordicInset
        case .surface:
            return blueNordicSurface
        case .raised:
            return blueNordicRaised
        }
    }

    static var borderColor: NSColor {
        return blueNordicBorder
    }

    private static let blueNordicCanvas = NSColor(srgbRed: 0x11 / 255, green: 0x1b / 255, blue: 0x2a / 255, alpha: 1)
    private static let blueNordicSidebar = NSColor(srgbRed: 0x10 / 255, green: 0x1a / 255, blue: 0x28 / 255, alpha: 1)
    private static let blueNordicInset = NSColor(srgbRed: 0x14 / 255, green: 0x22 / 255, blue: 0x35 / 255, alpha: 1)
    private static let blueNordicSurface = NSColor(srgbRed: 0x18 / 255, green: 0x26 / 255, blue: 0x38 / 255, alpha: 1)
    private static let blueNordicRaised = NSColor(srgbRed: 0x21 / 255, green: 0x32 / 255, blue: 0x48 / 255, alpha: 1)
    private static let blueNordicBorder = NSColor(srgbRed: 0x35 / 255, green: 0x4a / 255, blue: 0x62 / 255, alpha: 1)
    private static let blueNordicPrimary = NSColor(srgbRed: 0x4c / 255, green: 0x83 / 255, blue: 0xf3 / 255, alpha: 1)
}

@MainActor
private protocol WireRouteThemeField: AnyObject {
    func updateWireRouteTheme()
}

@MainActor
private enum WireRouteFieldStyle {
    static func contentRect(from drawingRect: NSRect, naturalHeight: CGFloat) -> NSRect {
        var contentRect = drawingRect
        let horizontalPadding: CGFloat = 10
        if contentRect.width > horizontalPadding * 2 {
            contentRect.origin.x += horizontalPadding
            contentRect.size.width -= horizontalPadding * 2
        }
        if naturalHeight < contentRect.height {
            contentRect.origin.y += floor((contentRect.height - naturalHeight) / 2)
            contentRect.size.height = naturalHeight
        }
        return contentRect
    }

    static func minimumHeight(for controlSize: NSControl.ControlSize) -> CGFloat {
        switch controlSize {
        case .extraLarge:
            return 36
        case .large:
            return 32
        case .regular:
            return 26
        case .small:
            return 22
        case .mini:
            return 20
        @unknown default:
            return 26
        }
    }

    static func configureEditableCell(_ cell: NSTextFieldCell) {
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.wraps = false
        cell.lineBreakMode = .byClipping
    }

    static func apply(to field: NSTextField) {
        field.wantsLayer = true
        field.layer?.cornerRadius = WireRouteTheme.isBlueNordic ? 8 : 0
        field.layer?.cornerCurve = .continuous
        field.layer?.borderWidth = WireRouteTheme.isBlueNordic ? 1 : 0
        field.layer?.borderColor = WireRouteTheme.isBlueNordic
            ? WireRouteTheme.borderColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        field.layer?.backgroundColor = WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .inset).cgColor
            : NSColor.clear.cgColor
        field.layer?.masksToBounds = WireRouteTheme.isBlueNordic

        field.isBezeled = !WireRouteTheme.isBlueNordic
        field.isBordered = !WireRouteTheme.isBlueNordic
        field.drawsBackground = !WireRouteTheme.isBlueNordic
        field.backgroundColor = WireRouteTheme.isBlueNordic ? .clear : .controlBackgroundColor
        field.textColor = .controlTextColor
    }
}

@MainActor
private final class WireRouteTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let drawingRect = super.drawingRect(forBounds: rect)
        guard WireRouteTheme.isBlueNordic else { return drawingRect }
        return WireRouteFieldStyle.contentRect(from: drawingRect, naturalHeight: cellSize.height)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        let frame = WireRouteTheme.isBlueNordic ? drawingRect(forBounds: rect) : rect
        super.edit(withFrame: frame, in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        let frame = WireRouteTheme.isBlueNordic ? drawingRect(forBounds: rect) : rect
        super.select(
            withFrame: frame,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

@MainActor
private final class WireRouteSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let drawingRect = super.drawingRect(forBounds: rect)
        guard WireRouteTheme.isBlueNordic else { return drawingRect }
        return WireRouteFieldStyle.contentRect(from: drawingRect, naturalHeight: cellSize.height)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        let frame = WireRouteTheme.isBlueNordic ? drawingRect(forBounds: rect) : rect
        super.edit(withFrame: frame, in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        let frame = WireRouteTheme.isBlueNordic ? drawingRect(forBounds: rect) : rect
        super.select(
            withFrame: frame,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

@MainActor
final class WireRouteTextField: NSTextField, WireRouteThemeField {
    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let themedCell = WireRouteTextFieldCell(textCell: "")
        WireRouteFieldStyle.configureEditableCell(themedCell)
        cell = themedCell
        configureThemeUpdates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, WireRouteFieldStyle.minimumHeight(for: controlSize))
        return size
    }

    func updateWireRouteTheme() {
        WireRouteFieldStyle.apply(to: self)
        needsDisplay = true
    }

    @objc private func themeDidChange() {
        updateWireRouteTheme()
    }

    private func configureThemeUpdates() {
        focusRingType = .default
        isEditable = true
        isSelectable = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateWireRouteTheme()
    }
}

@MainActor
final class WireRouteSecureTextField: NSSecureTextField, WireRouteThemeField {
    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let themedCell = WireRouteSecureTextFieldCell(textCell: "")
        WireRouteFieldStyle.configureEditableCell(themedCell)
        cell = themedCell
        configureThemeUpdates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, WireRouteFieldStyle.minimumHeight(for: controlSize))
        return size
    }

    func updateWireRouteTheme() {
        WireRouteFieldStyle.apply(to: self)
        needsDisplay = true
    }

    @objc private func themeDidChange() {
        updateWireRouteTheme()
    }

    private func configureThemeUpdates() {
        focusRingType = .default
        isEditable = true
        isSelectable = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateWireRouteTheme()
    }
}

@MainActor
final class WireRoutePopUpButton: NSPopUpButton, WireRouteThemeField {
    convenience init() {
        self.init(frame: .zero, pullsDown: false)
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        configureThemeUpdates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateWireRouteTheme() {
        bezelColor = WireRouteTheme.isBlueNordic ? WireRouteTheme.color(for: .raised) : nil
        contentTintColor = WireRouteTheme.isBlueNordic ? .controlTextColor : nil
        needsDisplay = true
    }

    @objc private func themeDidChange() {
        updateWireRouteTheme()
    }

    private func configureThemeUpdates() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateWireRouteTheme()
    }
}

@MainActor
final class WireRouteSegmentedControl: NSSegmentedControl, WireRouteThemeField {
    convenience init(
        labels: [String],
        trackingMode: NSSegmentedControl.SwitchTracking,
        target: AnyObject?,
        action: Selector?
    ) {
        self.init(frame: .zero)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            setLabel(label, forSegment: index)
        }
        self.trackingMode = trackingMode
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureThemeUpdates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateWireRouteTheme() {
        selectedSegmentBezelColor = WireRouteTheme.isBlueNordic ? WireRouteTheme.accentColor : nil
        needsDisplay = true
    }

    @objc private func themeDidChange() {
        updateWireRouteTheme()
    }

    private func configureThemeUpdates() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateWireRouteTheme()
    }
}

@MainActor
final class WireRouteTextEditorScrollView: NSScrollView, WireRouteThemeField {
    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureThemeUpdates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateWireRouteTheme() {
        wantsLayer = true
        layer?.cornerRadius = WireRouteTheme.isBlueNordic ? 8 : 0
        layer?.cornerCurve = .continuous
        layer?.borderWidth = WireRouteTheme.isBlueNordic ? 1 : 0
        layer?.borderColor = WireRouteTheme.isBlueNordic
            ? WireRouteTheme.borderColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        layer?.masksToBounds = WireRouteTheme.isBlueNordic

        borderType = WireRouteTheme.isBlueNordic ? .noBorder : .bezelBorder
        drawsBackground = true
        backgroundColor = WireRouteTheme.isBlueNordic
            ? WireRouteTheme.color(for: .inset)
            : .controlBackgroundColor
        contentView.drawsBackground = true
        contentView.backgroundColor = backgroundColor

        guard let textView = documentView as? NSTextView else { return }
        textView.drawsBackground = false
        textView.textColor = .controlTextColor
        textView.insertionPointColor = WireRouteTheme.accentColor
        textView.needsDisplay = true
    }

    @objc private func themeDidChange() {
        updateWireRouteTheme()
    }

    private func configureThemeUpdates() {
        scrollerStyle = .overlay
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateWireRouteTheme()
    }
}

@MainActor
final class AppearanceAwareLayerView: NSView {
    var adaptiveBackgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var adaptiveBackgroundAlpha: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var adaptiveBorderColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var adaptiveBorderAlpha: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = adaptiveBackgroundColor?
                .withAlphaComponent(adaptiveBackgroundAlpha).cgColor
            layer?.borderColor = adaptiveBorderColor?
                .withAlphaComponent(adaptiveBorderAlpha).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class AppearanceAwareLayerScrollView: NSScrollView {
    var adaptiveBorderColor: NSColor? {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = adaptiveBorderColor?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class AppearanceAwareMaterialView: NSView {
    var adaptiveBorderColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var adaptiveBorderAlpha: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    private let materialView = NSVisualEffectView()
    private let nordicSurface: WireRouteTheme.Surface

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        nordicSurface: WireRouteTheme.Surface = .surface
    ) {
        self.nordicSurface = nordicSurface
        super.init(frame: .zero)
        wantsLayer = true

        materialView.material = material
        materialView.blendingMode = blendingMode
        materialView.state = .followsWindowActiveState
        addSubview(materialView)
        materialView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .wireRouteAppearanceDidChange,
            object: nil
        )
        updateTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        super.updateLayer()
        if WireRouteTheme.isBlueNordic {
            layer?.backgroundColor = WireRouteTheme.color(for: nordicSurface).cgColor
            layer?.borderColor = WireRouteTheme.borderColor
                .withAlphaComponent(adaptiveBorderAlpha).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.borderColor = adaptiveBorderColor?
                    .withAlphaComponent(adaptiveBorderAlpha).cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTheme()
    }

    @objc private func themeDidChange() {
        updateTheme()
    }

    private func updateTheme() {
        materialView.isHidden = WireRouteTheme.isBlueNordic
        needsDisplay = true
    }
}

class ManageTunnelsRootViewController: NSViewController {

    let tunnelsManager: TunnelsManager
    var tunnelsListVC: TunnelsListTableViewController?
    var tunnelDetailVC: TunnelDetailTableViewController?
    var routerOSManagerVC: RouterOSManagerViewController?
    var settingsVC: RouterOSSettingsViewController?
    let tunnelDetailContainerView = NSView()
    var tunnelDetailContentVC: NSViewController?

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectTunnel(_ tunnel: TunnelContainer) {
        loadViewIfNeeded()
        tunnelsListVC?.selectTunnel(tunnel)
    }

    func selectRouterOSManager() {
        loadViewIfNeeded()
        tunnelsListVC?.selectRouterOSManager()
    }

    func selectSettings() {
        loadViewIfNeeded()
        tunnelsListVC?.selectSettings()
    }

    override func loadView() {
        let backgroundView = AppearanceAwareMaterialView(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            nordicSurface: .canvas
        )
        view = backgroundView

        let horizontalSpacing: CGFloat = 22
        let verticalSpacing: CGFloat = 22
        let centralSpacing: CGFloat = 16

        let container = NSLayoutGuide()
        view.addLayoutGuide(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: verticalSpacing),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: verticalSpacing),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: horizontalSpacing),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: horizontalSpacing)
        ])

        tunnelsListVC = TunnelsListTableViewController(tunnelsManager: tunnelsManager)
        tunnelsListVC!.delegate = self
        let tunnelsListView = tunnelsListVC!.view

        addChild(tunnelsListVC!)
        view.addSubview(tunnelsListView)
        view.addSubview(tunnelDetailContainerView)

        tunnelsListView.translatesAutoresizingMaskIntoConstraints = false
        tunnelDetailContainerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tunnelsListView.topAnchor.constraint(equalTo: container.topAnchor),
            tunnelsListView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tunnelsListView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tunnelDetailContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            tunnelDetailContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tunnelDetailContainerView.leadingAnchor.constraint(equalTo: tunnelsListView.trailingAnchor, constant: centralSpacing),
            tunnelDetailContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }

    private func setTunnelDetailContentVC(_ contentVC: NSViewController) {
        if let currentContentVC = tunnelDetailContentVC {
            currentContentVC.view.removeFromSuperview()
            currentContentVC.removeFromParent()
        }
        addChild(contentVC)
        tunnelDetailContainerView.addSubview(contentVC.view)
        contentVC.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tunnelDetailContainerView.topAnchor.constraint(equalTo: contentVC.view.topAnchor),
            tunnelDetailContainerView.bottomAnchor.constraint(equalTo: contentVC.view.bottomAnchor),
            tunnelDetailContainerView.leadingAnchor.constraint(equalTo: contentVC.view.leadingAnchor),
            tunnelDetailContainerView.trailingAnchor.constraint(equalTo: contentVC.view.trailingAnchor)
        ])
        tunnelDetailContentVC = contentVC
        WireRouteTheme.refresh(contentVC.view)
    }
}

extension ManageTunnelsRootViewController: TunnelsListTableViewControllerDelegate {
    func editSelectedTunnel() {
        tunnelDetailVC?.handleEditTunnelAction()
    }

    func toggleSelectedTunnelStatus() {
        tunnelDetailVC?.handleToggleActiveStatusAction()
    }

    func routerOSManagerSelected() {
        let routerOSManagerVC = self.routerOSManagerVC ?? RouterOSManagerViewController(tunnelsManager: tunnelsManager)
        self.routerOSManagerVC = routerOSManagerVC
        setTunnelDetailContentVC(routerOSManagerVC)
        tunnelDetailVC = nil
    }

    func settingsSelected() {
        let settingsVC = self.settingsVC ?? RouterOSSettingsViewController()
        self.settingsVC = settingsVC
        setTunnelDetailContentVC(settingsVC)
        tunnelDetailVC = nil
    }

    func tunnelsSelected(tunnelIndices: [Int]) {
        assert(!tunnelIndices.isEmpty)
        if tunnelIndices.count == 1 {
            let tunnel = tunnelsManager.tunnel(at: tunnelIndices.first!)
            if tunnel.isTunnelAvailableToUser {
                let tunnelDetailVC = TunnelDetailTableViewController(tunnelsManager: tunnelsManager, tunnel: tunnel)
                setTunnelDetailContentVC(tunnelDetailVC)
                self.tunnelDetailVC = tunnelDetailVC
            } else {
                let unusableTunnelDetailVC = tunnelDetailContentVC as? UnusableTunnelDetailViewController ?? UnusableTunnelDetailViewController()
                unusableTunnelDetailVC.onButtonClicked = { [weak tunnelsListVC] in
                    tunnelsListVC?.handleRemoveTunnelAction()
                }
                setTunnelDetailContentVC(unusableTunnelDetailVC)
                self.tunnelDetailVC = nil
            }
        } else if tunnelIndices.count > 1 {
            let multiSelectionVC = tunnelDetailContentVC as? ButtonedDetailViewController ?? ButtonedDetailViewController()
            multiSelectionVC.setButtonTitle(tr(format: "macButtonDeleteTunnels (%d)", tunnelIndices.count))
            multiSelectionVC.onButtonClicked = { [weak tunnelsListVC] in
                tunnelsListVC?.handleRemoveTunnelAction()
            }
            setTunnelDetailContentVC(multiSelectionVC)
            self.tunnelDetailVC = nil
        }
    }

    func tunnelsListEmpty() {
        let noTunnelsVC = ButtonedDetailViewController()
        noTunnelsVC.setButtonTitle(tr("macButtonImportTunnels"))
        noTunnelsVC.onButtonClicked = { [weak self] in
            guard let self = self else { return }
            ImportPanelPresenter.presentImportPanel(tunnelsManager: self.tunnelsManager, sourceVC: self)
        }
        setTunnelDetailContentVC(noTunnelsVC)
        self.tunnelDetailVC = nil
    }
}

extension ManageTunnelsRootViewController {
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        switch action {
        case #selector(TunnelsListTableViewController.handleViewLogAction),
             #selector(TunnelsListTableViewController.handleAddEmptyTunnelAction),
             #selector(TunnelsListTableViewController.handleImportTunnelAction),
             #selector(TunnelsListTableViewController.handleExportTunnelsAction),
             #selector(TunnelsListTableViewController.handleRemoveTunnelAction):
            return tunnelsListVC
        case #selector(TunnelDetailTableViewController.handleToggleActiveStatusAction),
             #selector(TunnelDetailTableViewController.handleEditTunnelAction):
            return tunnelDetailVC
        default:
            return super.supplementalTarget(forAction: action, sender: sender)
        }
    }
}
