// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

enum WireRouteAppearance {
    static let signalBlue = UIColor(red: 0x4C / 255, green: 0x83 / 255, blue: 0xF3 / 255, alpha: 1)
    static let liveTeal = UIColor(red: 0x2A / 255, green: 0x9D / 255, blue: 0x8F / 255, alpha: 1)
    static let warningAmber = UIColor(red: 0xD6 / 255, green: 0x8B / 255, blue: 0x29 / 255, alpha: 1)

    static let background = UIColor(red: 0x11 / 255, green: 0x1B / 255, blue: 0x2A / 255, alpha: 1)
    static let sidebar = UIColor(red: 0x10 / 255, green: 0x1A / 255, blue: 0x28 / 255, alpha: 1)
    static let inset = UIColor(red: 0x14 / 255, green: 0x22 / 255, blue: 0x35 / 255, alpha: 1)
    static let card = UIColor(red: 0x18 / 255, green: 0x26 / 255, blue: 0x38 / 255, alpha: 1)
    static let raised = UIColor(red: 0x21 / 255, green: 0x32 / 255, blue: 0x48 / 255, alpha: 1)
    static let border = UIColor(red: 0x35 / 255, green: 0x4A / 255, blue: 0x62 / 255, alpha: 1)

    @MainActor
    static func applyGlobalStyle() {
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = background
        navigationAppearance.shadowColor = border.withAlphaComponent(0.45)
        navigationAppearance.titleTextAttributes = [
            .font: roundedFont(size: 17, weight: .semibold, textStyle: .headline),
            .foregroundColor: UIColor.label
        ]
        navigationAppearance.largeTitleTextAttributes = [
            .font: roundedFont(size: 34, weight: .bold, textStyle: .largeTitle),
            .foregroundColor: UIColor.label
        ]
        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = navigationAppearance
        navigationBar.scrollEdgeAppearance = navigationAppearance
        navigationBar.compactAppearance = navigationAppearance
        navigationBar.tintColor = signalBlue

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = sidebar
        tabAppearance.shadowColor = border.withAlphaComponent(0.45)
        for itemAppearance in [
            tabAppearance.stackedLayoutAppearance,
            tabAppearance.inlineLayoutAppearance,
            tabAppearance.compactInlineLayoutAppearance
        ] {
            itemAppearance.normal.iconColor = .secondaryLabel
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.secondaryLabel]
            itemAppearance.selected.iconColor = signalBlue
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: signalBlue]
        }
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tabAppearance
        tabBar.scrollEdgeAppearance = tabAppearance
        tabBar.tintColor = signalBlue

        UITableView.appearance().backgroundColor = background
        UITableView.appearance().separatorColor = border.withAlphaComponent(0.55)
        UITableViewCell.appearance().backgroundColor = card
        UISwitch.appearance().onTintColor = signalBlue
    }

    static func roundedFont(size: CGFloat, weight: UIFont.Weight, textStyle: UIFont.TextStyle) -> UIFont {
        let baseFont = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }
}

class BorderedTextButton: UIView {
    let button: UIButton = {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = WireRouteAppearance.signalBlue
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        button.configuration = configuration
        button.titleLabel?.font = WireRouteAppearance.roundedFont(size: 17, weight: .semibold, textStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }()

    override var intrinsicContentSize: CGSize {
        let buttonSize = button.intrinsicContentSize
        return CGSize(width: buttonSize.width, height: max(52, buttonSize.height))
    }

    var title: String {
        get { return button.title(for: .normal) ?? "" }
        set(value) { button.setTitle(value, for: .normal) }
    }

    var onTapped: (() -> Void)?

    init() {
        super.init(frame: CGRect.zero)

        addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func buttonTapped() {
        onTapped?()
    }

}
