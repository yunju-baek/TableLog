import AppKit
import Foundation

enum AppHelp {
    static let repository = URL(string:"https://github.com/yunju-baek/TableLog")!
    static let guide = URL(string:"https://github.com/yunju-baek/TableLog/blob/main/docs/USER_GUIDE.md")!
    static let cliSetup = URL(string:"https://github.com/yunju-baek/TableLog/blob/main/docs/AI_CLI_SETUP.md")!
    static let showAISettings = Notification.Name("TableLog.showAISettings")
    @MainActor static func openGuide() { NSWorkspace.shared.open(guide) }
    @MainActor static func openCLISetup() { NSWorkspace.shared.open(cliSetup) }
    @MainActor static func openRepository() { NSWorkspace.shared.open(repository) }
}
