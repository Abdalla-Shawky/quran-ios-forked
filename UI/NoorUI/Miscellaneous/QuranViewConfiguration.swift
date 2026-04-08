//
//  QuranViewConfiguration.swift
//
//
//  Created by Abdalla Ahmed Shawky Abdo on 08.04.26.
//

import Foundation

public struct QuranViewConfiguration {
    public static var shared = QuranViewConfiguration()

    /// Padding between a side separator and the page content.
    public var separatorContentPadding: CGFloat = 0

    /// Multiplier for readable insets spacing (0.0 = no padding, 1.0 = default).
    public var readableInsetsScale: CGFloat = 1.0

    /// Scale factor applied to page content to zoom past decorative image borders (1.0 = no zoom).
    public var pageContentScale: CGFloat = 1.0
}
