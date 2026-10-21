import Foundation

enum AppIdentityMigration {
    /// Preserve the user's existing choices while the app adopts its TableLog identity.
    static func preparePreferences(defaults: UserDefaults = .standard,
                                   sourceDomain: String = "local.HwajaNote",
                                   targetDomain: String = "local.TableLog") {
        var current = defaults.persistentDomain(forName: targetDomain) ?? [:]
        let marker = "tablelog.identityMigration.v1"
        guard current[marker] as? Bool != true else { return }
        let previous = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        for (key, value) in previous where current[key] == nil { current[key] = value }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: targetDomain)
        defaults.synchronize()
    }
}
