import XCTest
@testable import Casablanca

/// The launcher's script. `launch` itself opens Terminal, so it is never called
/// here; everything it writes is built by `writeCommandFiles`, which is.
final class ClaudeCodeLauncherTests: XCTestCase {
    /// Owned by the test; holds the launch directory, the fake `claude` and the
    /// file a hostile prompt would try to create.
    private var root: URL!
    /// What `launch` would pass to `writeCommandFiles`: a directory the script
    /// removes when it runs.
    private var directory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeLauncherTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("launch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

        XCTAssertEqual(script, """
        #!/bin/zsh
        cd ~
        p="$(cat '\(promptURL.path)')"
        rm -rf '\(directory.path)'
        exec '/Users/me/.local/bin/claude' --permission-mode default "$p"

        """)
        // The prompt never reaches the script, not even a fragment of it.
        XCTAssertFalse(script.contains("Reply to Kim"), script)
        XCTAssertFalse(script.contains("whoami"), script)
        XCTAssertFalse(script.contains("rm -rf ~"), script)
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
            promptFilePath: "/tmp/it's here/prompt.txt",
            directoryPath: "/tmp/it's here"
        )
        XCTAssertTrue(script.contains("p=\"$(cat '/tmp/it'\\''s here/prompt.txt')\"\n"), script)
        XCTAssertTrue(script.contains("rm -rf '/tmp/it'\\''s here'\n"), script)
        XCTAssertTrue(script.contains("exec '/Users/o'\\''brien/bin/claude' --permission-mode default \"$p\""), script)
    }

    func testScriptRunsAsWrittenPassesThePromptAsOneArgumentAndRemovesItsDirectory() throws {
        // A stand-in "claude" outside the launch directory that prints its
        // arguments, one per line, so the run proves the flags and that the
        // hostile prompt arrives as one argument. It also reports whether the
        // launch directory still exists by the time "claude" starts.
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeClaude = bin.appendingPathComponent("fake claude")
        try """
        #!/bin/zsh
        printf '%s\\n' "$#" "$@"
        if [[ -e '\(directory.path)' ]]; then print dir-present; else print dir-gone; fi

        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeClaude.path)
        let pwned = root.appendingPathComponent("pwned")
        let prompt = "line one'; touch \(pwned.path); echo '\nline two $(id)"
        let commandURL = try ClaudeCodeLauncher.writeCommandFiles(claudePath: fakeClaude.path, prompt: prompt, in: directory)

        let process = Process()
        process.executableURL = commandURL
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(printed, "3\n--permission-mode\ndefault\n\(prompt)\ndir-gone\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pwned.path))
        // The prompt file and the script are gone once the script has run.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
