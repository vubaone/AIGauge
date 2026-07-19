import Foundation

/// Single source of truth for release version values.
///
/// After changing either constant, run the repository-local `make_version.sh`
/// helper to synchronize Xcode and XcodeGen build settings.
enum AppVersion {
    static let clientVersionInt = 260701
    static let clientVersionString = "26.07.01"

    /// Runtime UI reads the built bundle first so it reflects the metadata that
    /// will actually ship. Swift constants are a fallback for `swift run`.
    static var displayString: String {
        let bundle = Bundle.main
        let marketingVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? clientVersionString
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? String(clientVersionInt)
        return "v\(marketingVersion) (\(buildNumber))"
    }
}
