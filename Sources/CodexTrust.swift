import Foundation
import Security

/// Validate on the utility queue immediately before each helper launch, never on timer ticks.
/// Team ID and identifiers are public signing identities, not credentials.
enum CodexTrust {
    static let teamID = "2DC432GLL2"

    static func validate(_ executable: URL) throws {
        let binary = executable.standardizedFileURL
        guard binary.resolvingSymlinksInPath().path == binary.path else { throw UsageError.unavailable }

        let oldApp = binary.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        if oldApp.pathExtension == "app",
           binary.path == oldApp.appendingPathComponent("Contents/Resources/codex").path {
            try check(oldApp, identifier: "com.openai.codex")
        } else {
            let cliApp = binary.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let desktopApp = cliApp.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard cliApp.lastPathComponent == "CodexCLI.app",
                  desktopApp.pathExtension == "app",
                  binary.path == desktopApp.appendingPathComponent(
                    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path
            else { throw UsageError.unavailable }
            try check(desktopApp, identifier: "com.openai.codex")
            try check(cliApp, identifier: "codex")
        }
        try check(binary, identifier: "codex")
    }

    static func check(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { throw UsageError.unavailable }
        // Pin the Apple Developer ID certificate chain, OpenAI team, and exact code identity.
        let rule = """
        anchor apple generic and identifier "\(identifier)" and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "\(teamID)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw UsageError.unavailable }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UsageError.unavailable
        }
    }
}
