// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

enum WireRouteAppearance {
    static let signalBlue = UIColor(red: 0x35 / 255, green: 0x6F / 255, blue: 0xAE / 255, alpha: 1)
    static let liveTeal = UIColor(red: 0x2A / 255, green: 0x9D / 255, blue: 0x8F / 255, alpha: 1)
    static let warningAmber = UIColor(red: 0xD6 / 255, green: 0x8B / 255, blue: 0x29 / 255, alpha: 1)

    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x0B / 255, green: 0x12 / 255, blue: 0x19 / 255, alpha: 1)
            : UIColor(red: 0xF4 / 255, green: 0xF7 / 255, blue: 0xF8 / 255, alpha: 1)
    }

    static let card = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x15 / 255, green: 0x20 / 255, blue: 0x2B / 255, alpha: 1)
            : .white
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
