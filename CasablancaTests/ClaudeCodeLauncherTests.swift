import XCTest
@testable import Casablanca

/// The launcher's script. `launch` itself opens Terminal, so it is never called
/// here; everything it writes is built by `writeCommandFiles`, which is.
final class ClaudeCodeLauncherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCommandFileQuotesPromptViaFile() throws {
        let prompt = "Reply to Kim'; rm -rf ~; echo '$(whoami) \"done\""
        let commandURL = try ClaudeCodeLauncher.writeCommandFiles(
            claudePath: "/Users/me/.local/bin/claude",
            prompt: prompt,
            in: directory
        )
        let script = try String(contentsOf: commandURL, encoding: .utf8)
        let promptURL = directory.appendingPathComponent(ClaudeCodeLauncher.promptFileName)

        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"), script)
        XCTAssertTrue(script.contains("\ncd ~\n"), script)
        XCTAssertTrue(script.contains("exec '/Users/me/.local/bin/claude' --permission-mode default \"$(cat '\(promptURL.path)')\""), script)
        // The prompt never reaches the script, not even a fragment of it.
        XCTAssertFalse(script.contains("rm -rf"), script)
        XCTAssertFalse(script.contains("Reply to Kim"), script)
        XCTAssertFalse(script.contains("whoami"), script)
        // It lives only in the sibling file, byte for byte.
        XCTAssertEqual(try String(contentsOf: promptURL, encoding: .utf8), prompt)
    }

    func testCommandFileIsExecutableOnlyByTheOwnerAndPromptIsPrivate() throws {
        let commandURL = try ClaudeCodeLauncher.writeCommandFiles(claudePath: "/usr/local/bin/claude", prompt: "hi", in: directory)
        let promptURL = directory.appendingPathComponent(ClaudeCodeLauncher.promptFileName)

        XCTAssertEqual(commandURL.pathExtension, "command")
        XCTAssertEqual(commandURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        let commandMode = try FileManager.default.attributesOfItem(atPath: commandURL.path)[.posixPermissions] as? NSNumber
        let promptMode = try FileManager.default.attributesOfItem(atPath: promptURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(commandMode?.int16Value, 0o700)
        XCTAssertEqual(promptMode?.int16Value, 0o600)
    }

    func testPathsWithSingleQuotesAreEscaped() {
        let script = ClaudeCodeLauncher.commandFileContents(
            claudePath: "/Users/o'brien/bin/claude",
            promptFilePath: "/tmp/it's here/prompt.txt"
        )
        XCTAssertTrue(script.contains("exec '/Users/o'\\''brien/bin/claude' --permission-mode default \"$(cat '/tmp/it'\\''s here/prompt.txt')\""), script)
    }

    func testScriptRunsAsWrittenAndPassesThePromptAsOneArgument() throws {
        // A stand-in "claude" that prints its arguments, one per line, so the run
        // proves the flags and that the hostile prompt arrives as one argument.
        let fakeClaude = directory.appendingPathComponent("fake claude")
        try "#!/bin/zsh\nprintf '%s\\n' \"$#\" \"$@\"\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path)
        let prompt = "line one'; touch \(directory.path)/pwned; echo '\nline two $(id)"
        let commandURL = try ClaudeCodeLauncher.writeCommandFiles(claudePath: fakeClaude.path, prompt: prompt, in: directory)

        let process = Process()
        process.executableURL = commandURL
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(printed, "3\n--permission-mode\ndefault\n\(prompt)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    }
}
