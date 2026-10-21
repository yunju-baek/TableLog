import SwiftUI

/// Shared bright rose and violet palette for TableLog.
enum AppTheme {
    static let ink = Color(red: 0.24, green: 0.15, blue: 0.29)
    static let muted = Color(red: 0.45, green: 0.36, blue: 0.49)
    static let violet = Color(red: 0.48, green: 0.25, blue: 0.72)
    static let rose = Color(red: 0.73, green: 0.24, blue: 0.48)
    static let paper = Color(red: 0.995, green: 0.975, blue: 0.99)
    static let lavender = Color(red: 0.94, green: 0.89, blue: 0.98)
    static let blush = Color(red: 1.0, green: 0.90, blue: 0.94)
    static let sidebar = LinearGradient(colors: [blush, lavender], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let speakers: [Color] = [
        violet, rose,
        Color(red: 0.57, green: 0.24, blue: 0.61),
        Color(red: 0.65, green: 0.24, blue: 0.36),
        Color(red: 0.43, green: 0.27, blue: 0.57),
        Color(red: 0.65, green: 0.28, blue: 0.54),
        Color(red: 0.49, green: 0.22, blue: 0.39),
        Color(red: 0.55, green: 0.35, blue: 0.65)
    ]
}
