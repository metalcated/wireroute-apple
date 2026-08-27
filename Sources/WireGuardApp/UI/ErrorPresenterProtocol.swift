// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

@MainActor
protocol ErrorPresenterProtocol {
    static func showErrorAlert(
        title: String,
        message: String,
        from sourceVC: AnyObject?,
        onPresented: (@MainActor @Sendable () -> Void)?,
        onDismissal: (@MainActor @Sendable () -> Void)?
    )
}

extension ErrorPresenterProtocol {
    static func showErrorAlert(title: String, message: String, from sourceVC: AnyObject?, onPresented: (@MainActor @Sendable () -> Void)?) {
        showErrorAlert(title: title, message: message, from: sourceVC, onPresented: onPresented, onDismissal: nil)
    }

    static func showErrorAlert(title: String, message: String, from sourceVC: AnyObject?, onDismissal: (@MainActor @Sendable () -> Void)?) {
        showErrorAlert(title: title, message: message, from: sourceVC, onPresented: nil, onDismissal: onDismissal)
    }

    static func showErrorAlert(title: String, message: String, from sourceVC: AnyObject?) {
        showErrorAlert(title: title, message: message, from: sourceVC, onPresented: nil, onDismissal: nil)
    }

    static func showErrorAlert(
        error: WireGuardAppError,
        from sourceVC: AnyObject?,
        onPresented: (@MainActor @Sendable () -> Void)? = nil,
        onDismissal: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let (title, message) = error.alertText
        showErrorAlert(title: title, message: message, from: sourceVC, onPresented: onPresented, onDismissal: onDismissal)
    }
}
