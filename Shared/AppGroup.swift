import Foundation

/// Resolves the App Group shared by the app and the broadcast extension.
///
/// The identifier is looked up at runtime instead of being hard-coded, because
/// sideloading tools (AltStore, SideStore, Sideloadly, …) often rewrite App Group
/// identifiers when they re-sign the app. Order of preference:
///   1. the groups in the embedded provisioning profile (what we are really entitled to)
///   2. `ALTAppGroups` (written into Info.plist by AltStore / SideStore)
///   3. `FLAppGroupIdentifier` from Info.plist
///   4. `defaultIdentifier`
enum AppGroup {
    /// Keep in sync with `Config/*.entitlements` and `project.yml`.
    static let defaultIdentifier = "group.com.sosoalqawe12.floatlingo"

    static let identifier: String = resolveIdentifier()

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var isAvailable: Bool { containerURL != nil }

    static let defaults: UserDefaults = UserDefaults(suiteName: identifier) ?? .standard

    // MARK: - Resolution

    private static func resolveIdentifier() -> String {
        var candidates: [String] = []
        let fromProfile = groupsFromProvisioningProfile()
        // Prefer a group that looks like ours if the profile lists several.
        candidates += fromProfile.filter { $0.localizedCaseInsensitiveContains("floatlingo") }
        candidates += fromProfile
        if let alt = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            candidates += alt
        }
        if let custom = Bundle.main.object(forInfoDictionaryKey: "FLAppGroupIdentifier") as? String {
            candidates.append(custom)
        }
        candidates.append(defaultIdentifier)

        let valid = candidates.filter { $0.hasPrefix("group.") && !$0.contains("*") }
        // First candidate that actually gives us a container wins.
        for candidate in valid where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
            return candidate
        }
        return valid.first ?? defaultIdentifier
    }

    private static func groupsFromProvisioningProfile() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex)
        else { return [] }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }
}
