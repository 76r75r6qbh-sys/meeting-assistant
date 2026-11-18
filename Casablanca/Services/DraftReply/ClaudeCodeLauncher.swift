import AppKit
import Foundation

/// "Continue in Claude Code": opens Terminal on an interactive `claude` session
/// in `~`, in ask mode (`--permission-mode default`), seeded with a prompt.
///
/// The prompt holds to-do, meeting and draft text, so it is never written into
/// the script: it goes into a sibling file the script reads with `cat`. Inside
/// `"$(…)"` the shell neither word-splits nor re-parses that output, so a quote,
/// `;` or `$(…)` in the prompt stays text. Only the paths are in the script,
/// each single-quoted.
///
/// Once the prompt is in a shell variable the script deletes its own directory
/// (prompt file and script), so no transcript, summary or draft text stays in
/// the temporary folder after Claude Code starts.
enum ClaudeCodeLauncher {
    static let promptFileName = "prompt.txt"
    static let commandFileName = "Continue in Claude Code.command"

    static func commandFileContents(claudePath: String, promptFilePath: String, directoryPath: String) -> String {
        """
        #!/bin/zsh
        cd ~
        p="$(cat \(shellQuoted(promptFilePath)))"
        rm -rf \(shellQuoted(directoryPath))
        exec \(shellQuoted(claudePath)) --permission-mode default "$p"

        """
    }

    /// Writes the prompt (`0600`) and the `.command` script (`0700`) into
    /// `directory` and returns the script's URL. The script removes `directory`
    /// when it runs, so pass a directory that holds nothing else.
    static func writeCommandFiles(claudePath: String, prompt: String, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let promptURL = directory.appendingPathComponent(promptFileName)
        let commandURL = directory.appendingPathComponent(commandFileName)
        guard fileManager.createFile(
            atPath: promptURL.path,
            contents: Data(prompt.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: promptURL.path])
        }
        let script = commandFileContents(
            claudePath: claudePath,
            promptFilePath: promptURL.path,
            directoryPath: directory.path
        )
        guard fileManager.createFile(
            atPath: commandURL.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: commandURL.path])
        }
        return commandURL
    }

    /// Writes the files into a fresh temporary directory and opens the script,
    /// which Terminal runs; the script deletes that directory before `claude`
    /// starts.
    static func launch(claudePath: String, prompt: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinueInClaudeCode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let commandURL: URL
        do {
            commandURL = try writeCommandFiles(claudePath: claudePath, prompt: prompt, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        guard NSWorkspace.shared.open(commandURL) else {
            // The script never ran, so it can't clean up after itself.
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't open Terminal for Claude Code.",
            ])
        }
    }

    /// `it's` → `'it'\''s'`: a single-quoted word the shell takes literally.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
