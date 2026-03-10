import SwiftUI

// MARK: - Spacing (4pt base grid)

enum CasaSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

// MARK: - Corner Radius

enum CasaRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

// MARK: - Animation Durations

enum CasaDuration {
    static let micro: Double = 0.1
    static let fast: Double = 0.15
    static let standard: Double = 0.2
    static let emphasis: Double = 0.3
    static let slow: Double = 0.4
}

// MARK: - Layout Constants

enum CasaLayout {
    static let sidebarWidth: CGFloat = 220
    static let sidebarCollapsedWidth: CGFloat = 60
    static let sidebarItemHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 52
    static let contentMaxWidth: CGFloat = 720
    static let inspectorWidth: CGFloat = 280
    static let windowDefaultWidth: CGFloat = 1080
    static let windowDefaultHeight: CGFloat = 720
}
