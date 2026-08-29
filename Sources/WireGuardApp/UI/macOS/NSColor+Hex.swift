// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import AppKit

extension NSColor {

    convenience init(hex: String) {
        var hexString = hex.uppercased()

        if hexString.hasPrefix("#") {
            hexString.remove(at: hexString.startIndex)
        }

        if hexString.count != 6 {
            fatalError("Invalid hex string \(hex)")
        }

        guard let rgb = UInt32(hexString, radix: 16) else {
            fatalError("Invalid hex string \(hex)")
        }

        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat((rgb >> 0) & 0xff) / 255.0, alpha: 1)
    }

}
