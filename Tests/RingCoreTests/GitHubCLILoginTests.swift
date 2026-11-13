import Foundation
import RingCore

final class GitHubCLILoginTests {
    func fixture(_ script: String, in folder: URL) throws -> URL {
        let executable = folder.appendingPathComponent(UUID().uuidString)
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    func testSavedGitHubLoginAndLegacySettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ring-gh-login-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let valid = try fixture("[ \"$1 $2 $3 $4\" = 'auth token --hostname github.com' ] || exit 1\n[ \"$GH_HOST\" = github.com ] || exit 1\n[ \"$GH_PROMPT_DISABLED\" = 1 ] || exit 1\nprintf 'synthetic-backup-credential\\n'\n", in: folder)
        XCTAssertEqual(try GitHubCLILogin.token(executable: valid), "synthetic-backup-credential")
        let legacy = try JSONDecoder().decode(LibraryBackupSettings.self, from: Data("{\"enabled\":true,\"remoteURL\":\"https://github.com/example/private.git\"}".utf8))
        XCTAssertEqual(legacy.authentication, nil)
        var settings = LibraryBackupSettings(); settings.authentication = .githubCLI
        XCTAssertEqual(try JSONDecoder().decode(LibraryBackupSettings.self, from: JSONEncoder().encode(settings)).authentication, .githubCLI)
    }
    func testFailedEmptyMalformedAndSlowLoginFailWithoutLeakingOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ring-gh-login-failures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for script in ["printf 'synthetic-secret'; exit 1", "exit 0", "printf 'first second'", "printf 'first\\nsecond'"] {
            let executable = try fixture(script, in: folder)
            do { _ = try GitHubCLILogin.token(executable: executable); XCTAssertTrue(false) }
            catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-secret")) }
        }
        let slow = try fixture("exec /bin/sleep 10", in: folder), started = Date()
        XCTAssertThrowsError(try GitHubCLILogin.token(executable: slow, timeout: 0.1))
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 3)
    }
}
