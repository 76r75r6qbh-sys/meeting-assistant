import Foundation

/// One reproducible transcription run, driven from the command line.
///
/// Transcription tuning (fallback count, worker count, compute units) can only
/// be judged against a real recording, and a 44-minute meeting takes tens of
/// minutes to transcribe — far too slow for a test, and far too easy to measure
/// inconsistently by hand. This harness turns a run into a single command whose
/// output is a file on disk:
///
///     Casablanca.app/Contents/MacOS/Casablanca \
///       --benchmark-transcription "~/Library/Application Support/Casablanca/Benchmarks/vzvz-44min.m4a" \
///       --benchmark-variant baseline -whisperFallbackCount 2
///
/// `UserDefaults.standard` reads its argument domain first, so every hidden knob
/// in `TranscriptionOptionsBuilder` can be flipped per run without a rebuild.
/// The run writes `<timestamp>-<variant>.json` (timings plus the resolved
/// options, so a number can always be traced back to the settings that produced
/// it) and `<timestamp>-<variant>.txt` in exactly the format
/// `TranscriptionService.saveTranscriptLocally` writes, so the transcript can be
/// diffed against a reference with `scripts/transcript-agreement.py`.
///
/// The app never touches its SwiftData store in this mode: nothing is recorded,
/// no meeting is created, and the process exits when the run finishes.
enum TranscriptionBenchmark {
    /// A benchmark run requested on the command line.
    struct Request: Equatable {
        /// The audio file to transcribe.
        let fileURL: URL
        /// Names this run's output files, so a series of runs is self-describing.
        let variant: String
    }

    /// The benchmark corpus is Dutch; the locale is fixed rather than an
    /// argument so two runs can never differ by language without saying so.
    static let localeIdentifier = "nl-NL"
    /// The Whisper language code for `localeIdentifier`, used to report the
    /// options a run resolved to.
    private static let languageCode = "nl"

    static let defaultVariant = "default"
    private static let fileFlag = "--benchmark-transcription"
    private static let variantFlag = "--benchmark-variant"

    /// The requested run, or `nil` for a normal launch.
    ///
    /// Absent (or valueless) `--benchmark-transcription` means "not a benchmark
    /// run" — there is nothing to transcribe, and refusing to guess keeps a
    /// mistyped argument from launching a 40-minute run against the wrong file.
    static func requestedRun(from arguments: [String]) -> Request? {
        guard let path = value(of: fileFlag, in: arguments) else { return nil }
        let variant = value(of: variantFlag, in: arguments) ?? defaultVariant
        return Request(fileURL: URL(fileURLWithPath: path), variant: variant)
    }

    /// Base name shared by a run's `.json` and `.txt`: sortable timestamp first,
    /// variant second, so a directory listing reads as a run log.
    static func reportBaseName(
        variant: String,
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(slug(variant))"
    }

    /// Run the benchmark and return the process exit code (0 on success).
    ///
    /// Creates its own `TranscriptionService` so the run is independent of the
    /// app's shared services and of anything the UI may be doing.
    @MainActor
    static func run(_ request: Request) async -> Int32 {
        let resolved = TranscriptionOptionsBuilder.resolve(language: languageCode)
        Log.transcription.notice(
            "benchmark start variant=\(request.variant, privacy: .public) file=\(request.fileURL.lastPathComponent, privacy: .public)"
        )

        let service = TranscriptionService()
        do {
            let result = try await service.transcribe(
                fileURL: request.fileURL,
                localeIdentifier: localeIdentifier
            )

            let summaryLine = service.lastTimingReport?.summaryLine ?? "no timing report"
            print(summaryLine)

            let directory = try benchmarksDirectory()
            let baseName = reportBaseName(variant: request.variant)

            let transcriptURL = directory.appendingPathComponent("\(baseName).txt")
            let contents = TranscriptionService.transcriptFileContents(
                title: request.fileURL.deletingPathExtension().lastPathComponent,
                date: ISO8601DateFormatter().string(from: Date()),
                duration: result.duration,
                result: result
            )
            try contents.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let reportURL = directory.appendingPathComponent("\(baseName).json")
            let report = Report(
                variant: request.variant,
                inputPath: request.fileURL.path,
                options: resolved.summaryLine,
                timing: service.lastTimingReport
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)

            print(reportURL.path)
            print(transcriptURL.path)
            Log.transcription.notice(
                "benchmark finished variant=\(request.variant, privacy: .public) report=\(baseName, privacy: .public)"
            )
            return 0
        } catch {
            let message = "benchmark failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Log.transcription.error(
                "benchmark failed variant=\(request.variant, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return 1
        }
    }

    /// What a run leaves behind next to the audio it measured.
    private struct Report: Codable {
        let variant: String
        let inputPath: String
        /// `TranscriptionOptionsBuilder.Resolved.summaryLine` — the knobs this
        /// run actually decoded with.
        let options: String
        let timing: TranscriptionTimingReport?
    }

    /// `~/Library/Application Support/Casablanca/Benchmarks`, where the corpus
    /// and the reference transcripts already live.
    static func benchmarksDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Casablanca/Benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Argument parsing

    /// The argument after `flag`, or `nil` when the flag is absent, last, or
    /// followed by another flag rather than a value.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        return value
    }

    /// A variant name safe to put in a file name: a variant like `workers 8/gpu`
    /// must not create a nested path or a file that is awkward to quote.
    private static func slug(_ variant: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(
            variant.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        let collapsed = mapped
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? defaultVariant : collapsed
    }
}
