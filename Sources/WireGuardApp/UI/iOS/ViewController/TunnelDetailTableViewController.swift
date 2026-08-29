// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

private final class SplitRouteEntryViewController: UIViewController, UITextViewDelegate {
    var onSave: ((String, @escaping @MainActor @Sendable (WireGuardAppError?) -> Void) -> Void)?

    private let routeGlyphView: WireRouteGlyphView = {
        let view = WireRouteGlyphView()
        view.update(status: .inactive, routingMode: .split, animated: false)
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.text = tr("splitRouteEntryMessage")
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private let routesTextView: UITextView = {
        let textView = UITextView()
        textView.backgroundColor = WireRouteAppearance.card
        textView.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .numbersAndPunctuation
        textView.layer.cornerRadius = 14
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        return textView
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = tr("splitRouteEntryPlaceholder")
        label.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        label.textColor = .placeholderText
        label.numberOfLines = 0
        return label
    }()

    private let guidanceCard: UIView = {
        let card = UIView()
        card.backgroundColor = WireRouteAppearance.card
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = WireRouteAppearance.signalBlue.withAlphaComponent(0.35).cgColor

        let iconView = UIImageView(image: UIImage(systemName: "questionmark.circle.fill"))
        iconView.tintColor = WireRouteAppearance.signalBlue
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = tr("splitRouteEntryGuidanceTitle")
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true

        let messageLabel = UILabel()
        messageLabel.text = tr("splitRouteEntryGuidanceMessage")
        messageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0

        let exampleLabel = UILabel()
        exampleLabel.text = tr("splitRouteEntryGuidanceExample")
        exampleLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        exampleLabel.adjustsFontForContentSizeCategory = true
        exampleLabel.textColor = .secondaryLabel
        exampleLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, exampleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        let contentStack = UIStackView(arrangedSubviews: [iconView, textStack])
        contentStack.axis = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 10

        card.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20)
        ])
        return card
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.text = tr("splitRouteEntryHint")
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private lazy var saveButton = UIBarButtonItem(
        barButtonSystemItem: .save,
        target: self,
        action: #selector(saveTapped)
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        title = tr("splitRouteEntryTitle")
        view.backgroundColor = WireRouteAppearance.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = saveButton
        saveButton.isEnabled = false

        routesTextView.delegate = self
        routesTextView.addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: routesTextView.leadingAnchor, constant: 17),
            placeholderLabel.trailingAnchor.constraint(equalTo: routesTextView.trailingAnchor, constant: -17),
            placeholderLabel.topAnchor.constraint(equalTo: routesTextView.topAnchor, constant: 14)
        ])

        let glyphContainer = UIView()
        glyphContainer.addSubview(routeGlyphView)
        routeGlyphView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            routeGlyphView.centerXAnchor.constraint(equalTo: glyphContainer.centerXAnchor),
            routeGlyphView.centerYAnchor.constraint(equalTo: glyphContainer.centerYAnchor),
            routeGlyphView.widthAnchor.constraint(equalToConstant: 56),
            routeGlyphView.heightAnchor.constraint(equalTo: routeGlyphView.widthAnchor),
            glyphContainer.heightAnchor.constraint(equalToConstant: 56)
        ])

        let stack = UIStackView(arrangedSubviews: [
            glyphContainer,
            messageLabel,
            guidanceCard,
            routesTextView,
            hintLabel,
            errorLabel
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(20, after: messageLabel)
        stack.setCustomSpacing(16, after: guidanceCard)
        stack.setCustomSpacing(8, after: routesTextView)

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            routesTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        stack.setCustomSpacing(16, after: glyphContainer)
    }

    func textViewDidChange(_ textView: UITextView) {
        let containsText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholderLabel.isHidden = containsText
        saveButton.isEnabled = containsText
        errorLabel.isHidden = true
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        guard let onSave else { return }
        setSaving(true)
        onSave(routesTextView.text) { [weak self] error in
            guard let self else { return }
            self.setSaving(false)
            if let error {
                self.errorLabel.text = error.alertText.message
                self.errorLabel.isHidden = false
                return
            }
            self.dismiss(animated: true)
        }
    }

    private func setSaving(_ isSaving: Bool) {
        routesTextView.isEditable = !isSaving
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        saveButton.isEnabled = !isSaving
    }
}

@MainActor
private final class DNSProtectionViewController: UIViewController, UITextFieldDelegate {
    var onSave: ((DNSProtectionPolicy, @escaping @MainActor @Sendable (WireGuardAppError?) -> Void) -> Void)?
    var onEditProfileDNS: (() -> Void)?

    private let currentPolicy: DNSProtectionPolicy
    private let profileSummary: ProfileDNSRouteSummary
    private let isTunnelActive: Bool
    private var selectedPreset: DNSProtectionPreset?
    private let modeControl = UISegmentedControl(items: [
        tr("dnsProtectionProfileDNS"),
        tr("dnsProtectionEncryptedDNS")
    ])
    private let presetButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        configuration.image = UIImage(systemName: "chevron.up.chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 10
        configuration.titleAlignment = .leading
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .fill
        button.showsMenuAsPrimaryAction = true
        return button
    }()
    private let resolverURLField: UITextField = {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.placeholder = tr("dnsProtectionResolverURLPlaceholder")
        field.keyboardType = .URL
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        return field
    }()
    private let bootstrapServersField: UITextField = {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.placeholder = tr("dnsProtectionBootstrapPlaceholder")
        field.keyboardType = .numbersAndPunctuation
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        return field
    }()
    private let profileFieldsStack = UIStackView()
    private let resolverFieldsStack = UIStackView()
    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()
    private let editProfileButton = UIButton(type: .system)
    private lazy var saveButton = UIBarButtonItem(
        title: tr("dnsProtectionSave"),
        style: .done,
        target: self,
        action: #selector(saveTapped)
    )
    private var isSaving = false

    init(
        policy: DNSProtectionPolicy,
        profileSummary: ProfileDNSRouteSummary,
        isTunnelActive: Bool
    ) {
        currentPolicy = policy
        self.profileSummary = profileSummary
        self.isTunnelActive = isTunnelActive
        selectedPreset = DNSProtectionPreset.matching(policy)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("dnsProtectionTitle")
        view.backgroundColor = WireRouteAppearance.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = saveButton

        let iconView = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = tr("dnsProtectionTitle")
        titleLabel.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.adjustsFontForContentSizeCategory = true

        let introLabel = UILabel()
        introLabel.text = tr("dnsProtectionIntro")
        introLabel.font = UIFont.preferredFont(forTextStyle: .body)
        introLabel.adjustsFontForContentSizeCategory = true
        introLabel.textColor = .secondaryLabel
        introLabel.numberOfLines = 0

        let titleStack = UIStackView(arrangedSubviews: [titleLabel, introLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 4
        let header = UIStackView(arrangedSubviews: [iconView, titleStack])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 14

        let modeLabel = makeFieldLabel(tr("dnsProtectionMode"))
        modeControl.selectedSegmentIndex = currentPolicy.mode == .encryptedHTTPS ? 1 : 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        configureProfileFieldsStack()
        resolverURLField.delegate = self
        bootstrapServersField.delegate = self
        resolverURLField.addTarget(self, action: #selector(resolverFieldChanged), for: .editingChanged)
        bootstrapServersField.addTarget(self, action: #selector(resolverFieldChanged), for: .editingChanged)
        configurePresetButton()
        if currentPolicy.mode == .encryptedHTTPS {
            resolverURLField.text = currentPolicy.serverURL?.absoluteString
            bootstrapServersField.text = currentPolicy.bootstrapServers.joined(separator: ", ")
        }

        let presetLabel = makeFieldLabel(tr("dnsProtectionProvider"))
        let resolverLabel = makeFieldLabel(tr("dnsProtectionResolverURL"))
        let bootstrapLabel = makeFieldLabel(tr("dnsProtectionBootstrapServers"))
        let bootstrapHelp = UILabel()
        bootstrapHelp.text = tr("dnsProtectionBootstrapHelp")
        bootstrapHelp.font = UIFont.preferredFont(forTextStyle: .footnote)
        bootstrapHelp.adjustsFontForContentSizeCategory = true
        bootstrapHelp.textColor = .secondaryLabel
        bootstrapHelp.numberOfLines = 0

        let internalDNSWarningIcon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        internalDNSWarningIcon.tintColor = .systemOrange
        internalDNSWarningIcon.contentMode = .scaleAspectFit
        internalDNSWarningIcon.setContentHuggingPriority(.required, for: .horizontal)
        internalDNSWarningIcon.isAccessibilityElement = false
        let internalDNSWarningLabel = UILabel()
        internalDNSWarningLabel.text = tr("dnsProtectionEncryptedInternalWarning")
        internalDNSWarningLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        internalDNSWarningLabel.adjustsFontForContentSizeCategory = true
        internalDNSWarningLabel.textColor = .secondaryLabel
        internalDNSWarningLabel.numberOfLines = 0
        let internalDNSWarning = UIStackView(arrangedSubviews: [internalDNSWarningIcon, internalDNSWarningLabel])
        internalDNSWarning.axis = .horizontal
        internalDNSWarning.alignment = .top
        internalDNSWarning.spacing = 8
        internalDNSWarning.accessibilityLabel = tr("dnsProtectionEncryptedInternalWarning")

        resolverFieldsStack.axis = .vertical
        resolverFieldsStack.spacing = 8
        resolverFieldsStack.addArrangedSubview(internalDNSWarning)
        resolverFieldsStack.setCustomSpacing(16, after: internalDNSWarning)
        let profileOverrideMessage: String
        if profileSummary.servers.isEmpty {
            profileOverrideMessage = tr("dnsProtectionEncryptedOverridesNone")
        } else {
            profileOverrideMessage = tr(
                format: "dnsProtectionEncryptedOverrides (%@)",
                profileSummary.servers.map(\.address).joined(separator: ", ")
            )
        }
        let profileOverridePanel = makeNoticePanel(
            message: profileOverrideMessage,
            symbolName: "arrow.triangle.swap",
            tintColor: WireRouteAppearance.signalBlue
        )
        resolverFieldsStack.addArrangedSubview(profileOverridePanel)
        resolverFieldsStack.setCustomSpacing(16, after: profileOverridePanel)
        resolverFieldsStack.addArrangedSubview(presetLabel)
        resolverFieldsStack.addArrangedSubview(presetButton)
        resolverFieldsStack.setCustomSpacing(16, after: presetButton)
        resolverFieldsStack.addArrangedSubview(resolverLabel)
        resolverFieldsStack.addArrangedSubview(resolverURLField)
        resolverFieldsStack.setCustomSpacing(16, after: resolverURLField)
        resolverFieldsStack.addArrangedSubview(bootstrapLabel)
        resolverFieldsStack.addArrangedSubview(bootstrapServersField)
        resolverFieldsStack.addArrangedSubview(bootstrapHelp)

        let stateLabel = UILabel()
        stateLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 0
        stateLabel.text = isTunnelActive ? tr("dnsProtectionAppliesNextConnection") : nil
        stateLabel.isHidden = !isTunnelActive

        let cardStack = UIStackView(arrangedSubviews: [
            header,
            modeLabel,
            modeControl,
            profileFieldsStack,
            resolverFieldsStack,
            errorLabel,
            stateLabel
        ])
        cardStack.axis = .vertical
        cardStack.spacing = 10
        cardStack.setCustomSpacing(24, after: header)
        cardStack.setCustomSpacing(18, after: modeControl)

        let card = UIView()
        card.backgroundColor = WireRouteAppearance.card
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.addSubview(cardStack)
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.addSubview(card)
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            card.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            card.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            internalDNSWarningIcon.widthAnchor.constraint(equalToConstant: 18),
            internalDNSWarningIcon.heightAnchor.constraint(equalTo: internalDNSWarningIcon.widthAnchor),
            presetButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            resolverURLField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            bootstrapServersField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        updateMode(animated: false)
    }

    @objc private func modeChanged() {
        errorLabel.isHidden = true
        updateMode(animated: true)
    }

    private func updateMode(animated: Bool) {
        let isEncrypted = modeControl.selectedSegmentIndex == 1
        let changes = {
            self.profileFieldsStack.isHidden = isEncrypted
            self.profileFieldsStack.alpha = isEncrypted ? 0 : 1
            self.resolverFieldsStack.isHidden = !isEncrypted
            self.resolverFieldsStack.alpha = isEncrypted ? 1 : 0
            self.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes)
        } else {
            changes()
        }
        updateSaveButtonState()
    }

    private func configureProfileFieldsStack() {
        profileFieldsStack.axis = .vertical
        profileFieldsStack.spacing = 8

        let pathLabel = makeFieldLabel(tr("dnsProtectionProfilePath"))
        let pathDescription = profileTextLabel(tr("dnsProtectionProfilePathDescription"))
        profileFieldsStack.addArrangedSubview(pathLabel)
        profileFieldsStack.addArrangedSubview(pathDescription)
        profileFieldsStack.setCustomSpacing(16, after: pathDescription)

        if !profileSummary.isConfigurationAvailable {
            profileFieldsStack.addArrangedSubview(
                makeNoticePanel(
                    message: tr("dnsProtectionProfileUnavailable"),
                    symbolName: "exclamationmark.triangle.fill",
                    tintColor: .systemOrange
                )
            )
        } else if profileSummary.servers.isEmpty {
            let emptyMessage = profileSummary.searchDomains.isEmpty
                ? tr("dnsProtectionProfileNoServers")
                : tr("dnsProtectionProfileNoServersWithSearchDomains")
            profileFieldsStack.addArrangedSubview(
                makeNoticePanel(
                    message: emptyMessage,
                    symbolName: "questionmark.diamond.fill",
                    tintColor: .systemOrange
                )
            )
        } else {
            profileFieldsStack.addArrangedSubview(makeFieldLabel(tr("dnsProtectionProfileServers")))
            for server in profileSummary.servers {
                profileFieldsStack.addArrangedSubview(makeProfileServerRow(server))
            }
            if profileSummary.servers.contains(where: { $0.route == .outsideTunnel }) {
                profileFieldsStack.addArrangedSubview(
                    makeNoticePanel(
                        message: tr("dnsProtectionProfileOutsideTunnelWarning"),
                        symbolName: "exclamationmark.triangle.fill",
                        tintColor: .systemOrange
                    )
                )
            }
        }

        if !profileSummary.searchDomains.isEmpty {
            if let lastView = profileFieldsStack.arrangedSubviews.last {
                profileFieldsStack.setCustomSpacing(16, after: lastView)
            }
            profileFieldsStack.addArrangedSubview(makeFieldLabel(tr("dnsProtectionProfileSearchDomains")))
            let domains = profileTextLabel(profileSummary.searchDomains.joined(separator: "  ·  "))
            domains.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            profileFieldsStack.addArrangedSubview(domains)
        }

        var editConfiguration = UIButton.Configuration.gray()
        editConfiguration.title = tr("dnsProtectionEditProfileDNS")
        editConfiguration.image = UIImage(systemName: "pencil")
        editConfiguration.imagePadding = 7
        editConfiguration.cornerStyle = .medium
        editProfileButton.configuration = editConfiguration
        editProfileButton.addTarget(self, action: #selector(editProfileDNSTapped), for: .touchUpInside)
        if let lastView = profileFieldsStack.arrangedSubviews.last {
            profileFieldsStack.setCustomSpacing(18, after: lastView)
        }
        profileFieldsStack.addArrangedSubview(editProfileButton)
        editProfileButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func makeProfileServerRow(_ server: ProfileDNSRouteSummary.Server) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "server.rack"))
        icon.tintColor = WireRouteAppearance.signalBlue
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let address = UILabel()
        address.text = server.address
        address.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        address.adjustsFontSizeToFitWidth = true
        address.minimumScaleFactor = 0.72
        address.lineBreakMode = .byTruncatingMiddle
        let throughTunnel = server.route == .throughTunnel
        let badge = makeRouteBadge(
            title: tr(throughTunnel ? "dnsProtectionProfileViaTunnel" : "dnsProtectionProfileOutsideTunnel"),
            color: throughTunnel ? .systemGreen : .systemOrange
        )
        let content = UIStackView(arrangedSubviews: [icon, address, badge])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 10

        let row = UIView()
        row.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.07)
        row.layer.cornerRadius = 11
        row.layer.cornerCurve = .continuous
        row.layer.borderWidth = 1
        row.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
        row.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])
        return row
    }

    private func makeRouteBadge(title: String, color: UIColor) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = color
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7)
        let badge = UIButton(configuration: configuration)
        badge.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        badge.isUserInteractionEnabled = false
        badge.accessibilityTraits = .staticText
        badge.setContentHuggingPriority(.required, for: .horizontal)
        return badge
    }

    private func makeNoticePanel(message: String, symbolName: String, tintColor: UIColor) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbolName))
        icon.tintColor = tintColor
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false
        let label = profileTextLabel(message)
        let content = UIStackView(arrangedSubviews: [icon, label])
        content.axis = .horizontal
        content.alignment = .top
        content.spacing = 8
        let panel = UIView()
        panel.backgroundColor = tintColor.withAlphaComponent(0.08)
        panel.layer.cornerRadius = 11
        panel.layer.cornerCurve = .continuous
        panel.layer.borderWidth = 1
        panel.layer.borderColor = tintColor.withAlphaComponent(0.22).cgColor
        panel.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -11),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])
        return panel
    }

    private func profileTextLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }

    @objc private func editProfileDNSTapped() {
        let action = onEditProfileDNS
        dismiss(animated: true) {
            action?()
        }
    }

    @objc private func resolverFieldChanged() {
        updateSaveButtonState()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    private func configurePresetButton() {
        let presetActions = DNSProtectionPreset.allCases.map { preset in
            UIAction(
                title: preset.localizedTitle,
                subtitle: preset.localizedDescription,
                state: selectedPreset == preset ? .on : .off
            ) { [weak self] _ in
                self?.applyPreset(preset)
            }
        }
        let customAction = UIAction(
            title: tr("dnsPresetCustom"),
            subtitle: tr("dnsPresetCustomDescription"),
            state: selectedPreset == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectCustomPreset()
        }
        presetButton.menu = UIMenu(children: presetActions + [customAction])

        var configuration = presetButton.configuration
        configuration?.title = selectedPreset?.localizedTitle ?? tr("dnsPresetCustom")
        configuration?.subtitle = selectedPreset?.localizedDescription ?? tr("dnsPresetCustomDescription")
        presetButton.configuration = configuration
    }

    private func applyPreset(_ preset: DNSProtectionPreset) {
        selectedPreset = preset
        resolverURLField.text = preset.serverURLString
        bootstrapServersField.text = preset.bootstrapServers.joined(separator: ", ")
        errorLabel.isHidden = true
        configurePresetButton()
        updateSaveButtonState()
    }

    private func selectCustomPreset() {
        selectedPreset = nil
        errorLabel.isHidden = true
        configurePresetButton()
        updateSaveButtonState()
    }

    @objc private func saveTapped() {
        guard hasUnsavedChanges else { return }
        let policy: DNSProtectionPolicy
        if modeControl.selectedSegmentIndex == 0 {
            policy = .profile
        } else {
            do {
                policy = try DNSProtectionPolicy.encryptedHTTPS(
                    serverURLString: resolverURLField.text ?? "",
                    bootstrapServerStrings: parsedBootstrapServers()
                )
            } catch DNSProtectionPolicyError.invalidServerURL {
                showError(tr("dnsProtectionInvalidURLMessage"))
                return
            } catch DNSProtectionPolicyError.invalidBootstrapServer(let server) {
                showError(tr(format: "dnsProtectionInvalidBootstrapMessage (%@)", server))
                return
            } catch {
                showError(tr("dnsProtectionInvalidStoredMessage"))
                return
            }
        }

        guard let onSave else { return }
        setSaving(true)
        onSave(policy) { [weak self] error in
            guard let self else { return }
            self.setSaving(false)
            if let error {
                self.showError(error.alertText.message)
            } else {
                self.dismiss(animated: true)
            }
        }
    }

    private func parsedBootstrapServers() -> [String] {
        let separators = CharacterSet(charactersIn: ",\n \t")
        return (bootstrapServersField.text ?? "")
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
    }

    private func setSaving(_ isSaving: Bool) {
        self.isSaving = isSaving
        updateSaveButtonState()
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        modeControl.isEnabled = !isSaving
        editProfileButton.isEnabled = !isSaving
        presetButton.isEnabled = !isSaving
        resolverURLField.isEnabled = !isSaving
        bootstrapServersField.isEnabled = !isSaving
    }

    private var hasUnsavedChanges: Bool {
        if modeControl.selectedSegmentIndex == 0 {
            return currentPolicy.mode != .profile
        }
        guard currentPolicy.mode == .encryptedHTTPS else { return true }
        let resolverURL = (resolverURLField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolverURL != currentPolicy.serverURL?.absoluteString
            || parsedBootstrapServers() != currentPolicy.bootstrapServers
    }

    private func updateSaveButtonState() {
        saveButton.isEnabled = !isSaving && hasUnsavedChanges
    }

    private func makeFieldLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === resolverURLField {
            bootstrapServersField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if selectedPreset != nil {
            selectedPreset = nil
            configurePresetButton()
        }
        return true
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

class TunnelDetailTableViewController: UITableViewController {

    private enum Section {
        case status
        case activity
        case routing
        case dnsProtection
        case interface
        case peer(index: Int, peer: TunnelViewModel.PeerData)
        case onDemand
        case delete
    }

    static let interfaceFields: [TunnelViewModel.InterfaceField] = [
        .name, .publicKey, .addresses,
        .listenPort, .mtu, .dns
    ]

    static let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .persistentKeepAlive,
        .rxBytes, .txBytes, .lastHandshakeTime
    ]

    static let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .onDemand, .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer
    var tunnelViewModel: TunnelViewModel
    var onDemandViewModel: ActivateOnDemandViewModel

    private var sections = [Section]()
    private var interfaceFieldIsVisible = [Bool]()
    private var peerFieldIsVisible = [[Bool]]()

    private var statusObservationToken: AnyObject?
    private var onDemandObservationToken: AnyObject?
    private var reloadRuntimeConfigurationTimer: Timer?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(style: .grouped)
        loadSections()
        loadVisibleFields()
        statusObservationToken = tunnel.observe(\.status) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.tunnel.status == .active {
                    self.startUpdatingRuntimeConfiguration()
                } else if self.tunnel.status == .inactive {
                    self.reloadRuntimeConfiguration()
                    self.stopUpdatingRuntimeConfiguration()
                }
            }
        }
        onDemandObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Handle On-Demand getting turned on/off outside of the app.
                self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: self.tunnel)
                self.updateActivateOnDemandFields()
            }
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tunnelViewModel.interfaceData[.name]
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(ChevronCell.self)

        restorationIdentifier = "TunnelDetailVC:\(tunnel.name)"
    }

    private func loadSections() {
        sections.removeAll()
        sections.append(.status)
        sections.append(.activity)
        sections.append(.routing)
        sections.append(.dnsProtection)
        sections.append(.interface)
        for (index, peer) in tunnelViewModel.peersData.enumerated() {
            sections.append(.peer(index: index, peer: peer))
        }
        sections.append(.onDemand)
        sections.append(.delete)
    }

    private func loadVisibleFields() {
        let visibleInterfaceFields = tunnelViewModel.interfaceData.filterFieldsWithValueOrControl(interfaceFields: TunnelDetailTableViewController.interfaceFields)
        interfaceFieldIsVisible = TunnelDetailTableViewController.interfaceFields.map { visibleInterfaceFields.contains($0) }
        peerFieldIsVisible = tunnelViewModel.peersData.map { peer in
            let visiblePeerFields = peer.filterFieldsWithValueOrControl(peerFields: TunnelDetailTableViewController.peerFields)
            return TunnelDetailTableViewController.peerFields.map { visiblePeerFields.contains($0) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        if tunnel.status == .active {
            self.startUpdatingRuntimeConfiguration()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        stopUpdatingRuntimeConfiguration()
    }

    @objc func editTapped() {
        PrivateDataConfirmation.confirmAccess(to: tr("iosViewPrivateData")) { [weak self] in
            guard let self = self else { return }
            let editVC = TunnelEditTableViewController(tunnelsManager: self.tunnelsManager, tunnel: self.tunnel)
            editVC.delegate = self
            let editNC = UINavigationController(rootViewController: editVC)
            editNC.modalPresentationStyle = .fullScreen
            self.present(editNC, animated: true)
        }
    }

    func startUpdatingRuntimeConfiguration() {
        reloadRuntimeConfiguration()
        reloadRuntimeConfigurationTimer?.invalidate()
        let reloadTimer = Timer(timeInterval: 1 /* second */, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadRuntimeConfiguration()
            }
        }
        reloadRuntimeConfigurationTimer = reloadTimer
        RunLoop.main.add(reloadTimer, forMode: .common)
    }

    func stopUpdatingRuntimeConfiguration() {
        reloadRuntimeConfigurationTimer?.invalidate()
        reloadRuntimeConfigurationTimer = nil
    }

    func applyTunnelConfiguration(tunnelConfiguration: TunnelConfiguration) {
        // Incorporates changes from tunnelConfiguation. Ignores any changes in peer ordering.
        guard let tableView = self.tableView else { return }
        let sections = self.sections
        let interfaceSectionIndex = sections.firstIndex {
            if case .interface = $0 {
                return true
            } else {
                return false
            }
        }!
        let firstPeerSectionIndex = interfaceSectionIndex + 1
        let interfaceFieldIsVisible = self.interfaceFieldIsVisible
        let peerFieldIsVisible = self.peerFieldIsVisible

        func handleSectionFieldsModified<T>(fields: [T], fieldIsVisible: [Bool], section: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            for (index, field) in fields.enumerated() {
                guard let change = changes[field] else { continue }
                if case .modified(let newValue) = change {
                    let row = fieldIsVisible[0 ..< index].filter { $0 }.count
                    let indexPath = IndexPath(row: row, section: section)
                    if let cell = tableView.cellForRow(at: indexPath) as? KeyValueCell {
                        cell.value = newValue
                    }
                }
            }
        }

        func handleSectionRowsInsertedOrRemoved<T>(fields: [T], fieldIsVisible fieldIsVisibleInput: [Bool], section: Int, changes: [T: TunnelViewModel.Changes.FieldChange]) {
            var fieldIsVisible = fieldIsVisibleInput

            var removedIndexPaths = [IndexPath]()
            for (index, field) in fields.enumerated().reversed() where changes[field] == .removed {
                let row = fieldIsVisible[0 ..< index].filter { $0 }.count
                removedIndexPaths.append(IndexPath(row: row, section: section))
                fieldIsVisible[index] = false
            }
            if !removedIndexPaths.isEmpty {
                tableView.deleteRows(at: removedIndexPaths, with: .automatic)
            }

            var addedIndexPaths = [IndexPath]()
            for (index, field) in fields.enumerated() where changes[field] == .added {
                let row = fieldIsVisible[0 ..< index].filter { $0 }.count
                addedIndexPaths.append(IndexPath(row: row, section: section))
                fieldIsVisible[index] = true
            }
            if !addedIndexPaths.isEmpty {
                tableView.insertRows(at: addedIndexPaths, with: .automatic)
            }
        }

        let changes = self.tunnelViewModel.applyConfiguration(other: tunnelConfiguration)

        if !changes.interfaceChanges.isEmpty {
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.interfaceFields, fieldIsVisible: interfaceFieldIsVisible,
                                        section: interfaceSectionIndex, changes: changes.interfaceChanges)
        }
        for (peerIndex, peerChanges) in changes.peerChanges {
            handleSectionFieldsModified(fields: TunnelDetailTableViewController.peerFields, fieldIsVisible: peerFieldIsVisible[peerIndex], section: firstPeerSectionIndex + peerIndex, changes: peerChanges)
        }

        let isAnyInterfaceFieldAddedOrRemoved = changes.interfaceChanges.contains { $0.value == .added || $0.value == .removed }
        let isAnyPeerFieldAddedOrRemoved = changes.peerChanges.contains { $0.changes.contains { $0.value == .added || $0.value == .removed } }
        let peersRemovedSectionIndices = changes.peersRemovedIndices.map { firstPeerSectionIndex + $0 }
        let peersInsertedSectionIndices = changes.peersInsertedIndices.map { firstPeerSectionIndex + $0 }

        if isAnyInterfaceFieldAddedOrRemoved || isAnyPeerFieldAddedOrRemoved || !peersRemovedSectionIndices.isEmpty || !peersInsertedSectionIndices.isEmpty {
            tableView.beginUpdates()
            if isAnyInterfaceFieldAddedOrRemoved {
                handleSectionRowsInsertedOrRemoved(fields: TunnelDetailTableViewController.interfaceFields, fieldIsVisible: interfaceFieldIsVisible, section: interfaceSectionIndex, changes: changes.interfaceChanges)
            }
            if isAnyPeerFieldAddedOrRemoved {
                for (peerIndex, peerChanges) in changes.peerChanges {
                    handleSectionRowsInsertedOrRemoved(fields: TunnelDetailTableViewController.peerFields, fieldIsVisible: peerFieldIsVisible[peerIndex], section: firstPeerSectionIndex + peerIndex, changes: peerChanges)
                }
            }
            if !peersRemovedSectionIndices.isEmpty {
                tableView.deleteSections(IndexSet(peersRemovedSectionIndices), with: .automatic)
            }
            if !peersInsertedSectionIndices.isEmpty {
                tableView.insertSections(IndexSet(peersInsertedSectionIndices), with: .automatic)
            }
            self.loadSections()
            self.loadVisibleFields()
            tableView.endUpdates()
        } else {
            self.loadSections()
            self.loadVisibleFields()
        }
    }

    private func reloadRuntimeConfiguration() {
        tunnel.getRuntimeTunnelConfiguration { [weak self] tunnelConfiguration in
            guard let tunnelConfiguration = tunnelConfiguration else { return }
            guard let self = self else { return }
            self.applyTunnelConfiguration(tunnelConfiguration: tunnelConfiguration)
        }
    }

    private func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(where: { if case .onDemand = $0 { return true } else { return false } }) else { return }
        let numberOfTableViewOnDemandRows = tableView.numberOfRows(inSection: onDemandSection)
        let ssidRowIndexPath = IndexPath(row: 1, section: onDemandSection)
        switch (numberOfTableViewOnDemandRows, onDemandViewModel.isWiFiInterfaceEnabled) {
        case (1, true):
            tableView.insertRows(at: [ssidRowIndexPath], with: .automatic)
        case (2, false):
            tableView.deleteRows(at: [ssidRowIndexPath], with: .automatic)
        default:
            break
        }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
    }
}

extension TunnelDetailTableViewController: TunnelEditTableViewControllerDelegate {
    func tunnelSaved(tunnel: TunnelContainer) {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        loadSections()
        loadVisibleFields()
        title = tunnel.name
        restorationIdentifier = "TunnelDetailVC:\(tunnel.name)"
        tableView.reloadData()
    }
    func tunnelEditingCancelled() {
        // Nothing to do
    }
}

extension TunnelDetailTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status:
            return 1
        case .activity:
            return 1
        case .routing:
            return 1
        case .dnsProtection:
            return 1
        case .interface:
            return interfaceFieldIsVisible.filter { $0 }.count
        case .peer(let peerIndex, _):
            return peerFieldIsVisible[peerIndex].filter { $0 }.count
        case .onDemand:
            return onDemandViewModel.isWiFiInterfaceEnabled ? 2 : 1
        case .delete:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status:
            return tr("tunnelSectionTitleStatus")
        case .activity:
            return tr("activityTitle")
        case .routing:
            return tr("tunnelSectionTitleRouting")
        case .dnsProtection:
            return tr("dnsProtectionTitle")
        case .interface:
            return tr("tunnelSectionTitleInterface")
        case .peer:
            return tr("tunnelSectionTitlePeer")
        case .onDemand:
            return tr("tunnelSectionTitleOnDemand")
        case .delete:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .status:
            return statusCell(for: tableView, at: indexPath)
        case .activity:
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = tr("activityOpenMonitor")
            cell.detailMessage = tr("activityOpenMonitorDescription")
            return cell
        case .routing:
            return routingCell(for: tableView, at: indexPath)
        case .dnsProtection:
            return dnsProtectionCell(for: tableView, at: indexPath)
        case .interface:
            return interfaceCell(for: tableView, at: indexPath)
        case .peer(let index, let peer):
            return peerCell(for: tableView, at: indexPath, with: peer, peerIndex: index)
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        case .delete:
            return deleteConfigurationCell(for: tableView, at: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .routing:
            return tunnel.routingMode == .full
                ? tr("tunnelRoutingFullDescription")
                : tr("tunnelRoutingSplitDescription")
        case .dnsProtection:
            return tunnel.dnsProtectionPolicy.localizedDescription
        default:
            return nil
        }
    }

    private func statusCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)

        let update: @MainActor @Sendable (SwitchCell?, TunnelContainer) -> Void = { cell, tunnel in
            guard let cell = cell else { return }

            let status = tunnel.status
            let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

            let isSwitchOn = (status == .activating || status == .active || isOnDemandEngaged)
            cell.switchView.setOn(isSwitchOn, animated: true)

            if isOnDemandEngaged && !(status == .activating || status == .active) {
                cell.switchView.onTintColor = UIColor.systemYellow
            } else {
                cell.switchView.onTintColor = UIColor.systemGreen
            }

            var text: String
            switch status {
            case .inactive:
                text = tr("tunnelStatusInactive")
            case .activating:
                text = tr("tunnelStatusActivating")
            case .active:
                text = tr("tunnelStatusActive")
            case .deactivating:
                text = tr("tunnelStatusDeactivating")
            case .reasserting:
                text = tr("tunnelStatusReasserting")
            case .restarting:
                text = tr("tunnelStatusRestarting")
            case .waiting:
                text = tr("tunnelStatusWaiting")
            }

            if tunnel.hasOnDemandRules {
                text += isOnDemandEngaged ? tr("tunnelStatusAddendumOnDemand") : ""
                cell.switchView.isUserInteractionEnabled = true
                cell.isEnabled = true
            } else {
                cell.switchView.isUserInteractionEnabled = (status == .inactive || status == .active)
                cell.isEnabled = (status == .inactive || status == .active)
            }

            if tunnel.hasOnDemandRules && !isOnDemandEngaged && status == .inactive {
                text = tr("tunnelStatusOnDemandDisabled")
            }

            cell.textLabel?.text = text
        }

        update(cell, tunnel)
        cell.statusObservationToken = tunnel.observe(\.status) { [weak self, weak cell] _, _ in
            Task { @MainActor in
                guard let self else { return }
                update(cell, self.tunnel)
            }
        }
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self, weak cell] _, _ in
            Task { @MainActor in
                guard let self else { return }
                update(cell, self.tunnel)
            }
        }
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { [weak self, weak cell] _, _ in
            Task { @MainActor in
                guard let self else { return }
                update(cell, self.tunnel)
            }
        }

        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self else { return }

            if self.tunnel.hasOnDemandRules {
                self.tunnelsManager.setOnDemandEnabled(isOn, on: self.tunnel) { error in
                    if error == nil && !isOn {
                        self.tunnelsManager.startDeactivation(of: self.tunnel)
                    }
                }
            } else {
                if isOn {
                    self.tunnelsManager.startActivation(of: self.tunnel)
                } else {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        }
        return cell
    }

    private func routingCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = tr("tunnelRoutingFullTunnel")
        cell.isOn = tunnel.routingMode == .full
        cell.onSwitchToggled = { [weak self, weak cell] isFullTunnel in
            guard let self, let cell else { return }
            cell.isEnabled = false
            let requestedMode: TunnelRouteMode = isFullTunnel ? .full : .split
            self.tunnelsManager.setRoutingMode(requestedMode, on: self.tunnel) { error in
                cell.isEnabled = true
                guard let error else {
                    self.refreshAfterRoutingChange()
                    return
                }
                cell.isOn = self.tunnel.routingMode == .full
                if let routingError = error as? TunnelRoutingError,
                   case .missingSplitRoutes = routingError {
                    self.presentSplitRouteEntry()
                    return
                }
                ErrorPresenter.showErrorAlert(error: error, from: self)
            }
        }
        return cell
    }

    private func dnsProtectionCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = tr("dnsProtectionTitle")
        cell.detailMessage = tunnel.dnsProtectionPolicy.localizedTitle
        return cell
    }

    private func presentDNSProtection() {
        let dnsViewController = DNSProtectionViewController(
            policy: tunnel.dnsProtectionPolicy,
            profileSummary: tunnel.profileDNSRouteSummary,
            isTunnelActive: tunnel.status != .inactive
        )
        dnsViewController.onEditProfileDNS = { [weak self] in
            self?.editTapped()
        }
        dnsViewController.onSave = { [weak self] policy, completion in
            guard let self else {
                completion(TunnelDNSProtectionError.invalidStoredConfiguration)
                return
            }
            self.tunnelsManager.setDNSProtectionPolicy(policy, on: self.tunnel) { error in
                if error == nil {
                    self.tableView.reloadData()
                }
                completion(error)
            }
        }

        let navigationController = UINavigationController(rootViewController: dnsViewController)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.preferredContentSize = CGSize(width: 560, height: 560)
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func presentSplitRouteEntry() {
        let routeEntryViewController = SplitRouteEntryViewController()
        routeEntryViewController.onSave = { [weak self] routes, completion in
            guard let self else {
                completion(TunnelRoutingError.invalidStoredRoutes)
                return
            }
            self.tunnelsManager.setRoutingMode(
                .split,
                enteredSplitRoutes: routes,
                on: self.tunnel
            ) { error in
                if error == nil {
                    self.refreshAfterRoutingChange()
                }
                completion(error)
            }
        }

        let navigationController = UINavigationController(rootViewController: routeEntryViewController)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.preferredContentSize = CGSize(width: 540, height: 520)
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func refreshAfterRoutingChange() {
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        loadSections()
        loadVisibleFields()
        tableView.reloadData()
    }

    private func interfaceCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let visibleInterfaceFields = TunnelDetailTableViewController.interfaceFields.enumerated().filter { interfaceFieldIsVisible[$0.offset] }.map { $0.element }
        let field = visibleInterfaceFields[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        cell.value = tunnelViewModel.interfaceData[field]
        return cell
    }

    private func peerCell(for tableView: UITableView, at indexPath: IndexPath, with peerData: TunnelViewModel.PeerData, peerIndex: Int) -> UITableViewCell {
        let visiblePeerFields = TunnelDetailTableViewController.peerFields.enumerated().filter { peerFieldIsVisible[peerIndex][$0.offset] }.map { $0.element }
        let field = visiblePeerFields[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        if field == .persistentKeepAlive {
            cell.value = tr(format: "tunnelPeerPersistentKeepaliveValue (%@)", peerData[field])
        } else if field == .preSharedKey {
            cell.value = tr("tunnelPeerPresharedKeyEnabled")
        } else {
            cell.value = peerData[field]
        }
        return cell
    }

    private func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = TunnelDetailTableViewController.onDemandFields[indexPath.row]
        if field == .onDemand {
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.key = field.localizedUIString
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.copyableGesture = false
            return cell
        } else {
            assert(field == .ssid)
            if onDemandViewModel.ssidOption == .anySSID {
                let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
                cell.key = field.localizedUIString
                cell.value = onDemandViewModel.ssidOption.localizedUIString
                cell.copyableGesture = false
                return cell
            } else {
                let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = field.localizedUIString
                cell.detailMessage = onDemandViewModel.localizedSSIDDescription
                return cell
            }
        }
    }

    private func deleteConfigurationCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = tr("deleteTunnelButtonTitle")
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            ConfirmationAlertPresenter.showConfirmationAlert(message: tr("deleteTunnelConfirmationAlertMessage"),
                                       buttonTitle: tr("deleteTunnelConfirmationAlertButtonTitle"),
                                       from: cell, presentingVC: self) { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.remove(tunnel: self.tunnel) { error in
                    if error != nil {
                        print("Error removing tunnel: \(String(describing: error))")
                        return
                    }
                }
            }
        }
        return cell
    }

}

extension TunnelDetailTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .dnsProtection = sections[indexPath.section] {
            return indexPath
        }
        if case .activity = sections[indexPath.section] {
            return indexPath
        }
        if case .onDemand = sections[indexPath.section],
            case .ssid = TunnelDetailTableViewController.onDemandFields[indexPath.row] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .dnsProtection = sections[indexPath.section] {
            presentDNSProtection()
        } else if case .activity = sections[indexPath.section] {
            navigationController?.pushViewController(
                ActivityMonitorViewController(tunnel: tunnel),
                animated: true
            )
        } else if case .onDemand = sections[indexPath.section],
            case .ssid = TunnelDetailTableViewController.onDemandFields[indexPath.row] {
            let ssidDetailVC = SSIDOptionDetailTableViewController(title: onDemandViewModel.ssidOption.localizedUIString, ssids: onDemandViewModel.selectedSSIDs)
            navigationController?.pushViewController(ssidDetailVC, animated: true)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
