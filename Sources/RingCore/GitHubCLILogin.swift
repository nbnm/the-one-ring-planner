import Foundation

public enum BackupAuthentication: String, Codable, CaseIterable, Sendable {
    case token, githubCLI
}

/// Reuses the official GitHub CLI's existing login. The credential never enters arguments, files, or logs.
public enum GitHubCLILogin {
    public static func token(executable: URL? = nil, timeout: TimeInterval = 30) throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let binary = executable ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else {
            throw LibraryError.unavailable("Install GitHub CLI and sign in with gh auth login, or choose a saved token for backup.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = binary; process.arguments = ["auth", "token", "--hostname", "github.com"]
        var environment = ProcessInfo.processInfo.environment
        // Always use the saved github.com login, rather than an unrelated terminal override.
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST"] { environment.removeValue(forKey: key) }
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_HOST"] = "github.com"
        process.environment = environment; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw LibraryError.unavailable("GitHub login lookup timed out. Unlock Keychain or sign in again with gh auth login. Your local data is safe.") }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !token.isEmpty, token.utf8.count <= 4096, !token.contains(where: \.isWhitespace) else {
            throw LibraryError.unavailable("GitHub CLI is not signed in to github.com. Run gh auth login, then retry backup, or choose a saved token.")
        }
        return token
    }
}
