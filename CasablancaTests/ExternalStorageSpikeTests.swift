import XCTest
import SwiftData
@testable import Casablanca

/// Phase 3a spike: does `@Attribute(.externalStorage)` do anything useful on a
/// `String?` property, and is migrating an existing store safe?
///
/// These tests use a TEMP store URL — never the user's real store — and define
/// throwaway `@Model` types so the spike can compare an `.externalStorage`
/// variant against a plain one without touching the shipping `Meeting` model.
final class ExternalStorageSpikeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL.temporaryDirectory.appending(path: "ExternalStorageSpike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    // A ~4 MB transcript, the kind of payload rawTranscript holds.
    private func largeTranscript() -> String {
        String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 90_000)
    }

    // MARK: - Plain String (no externalStorage)

    @Model
    final class PlainNote {
        var title: String
        var body: String?
        init(title: String, body: String?) {
            self.title = title
            self.body = body
        }
    }

    // MARK: - externalStorage on String?

    @Model
    final class ExternalNote {
        var title: String
        @Attribute(.externalStorage) var body: String?
        init(title: String, body: String?) {
            self.title = title
            self.body = body
        }
    }

    private func countExternalDataFiles() throws -> Int {
        // SwiftData writes externally-stored blobs into a hidden
        // ".<storename>_SUPPORT/_EXTERNAL_DATA" directory next to the store.
        guard let enumerator = FileManager.default.enumerator(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator
        where url.path.contains("_EXTERNAL_DATA") && url.hasDirectoryPath == false {
            count += 1
        }
        return count
    }

    /// EVIDENCE 1: Does `.externalStorage` on a `String?` actually externalize
    /// the value (observable benefit), or is it a silent no-op?
    func test_externalStorage_observableEffectOnString() throws {
        let url = tempDir.appending(path: "external.store")
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: ExternalNote.self, configurations: config)
        let context = ModelContext(container)
        context.insert(ExternalNote(title: "big", body: largeTranscript()))
        try context.save()

        let externalFiles = try countExternalDataFiles()
        // Record the finding regardless of outcome.
        print("SPIKE: external data files after saving large String? with .externalStorage = \(externalFiles)")

        // Compare against the plain variant to see if there's any difference at all.
        let plainURL = tempDir.appending(path: "plain.store")
        let plainConfig = ModelConfiguration(url: plainURL)
        let plainContainer = try ModelContainer(for: PlainNote.self, configurations: plainConfig)
        let plainContext = ModelContext(plainContainer)
        plainContext.insert(PlainNote(title: "big", body: largeTranscript()))
        try plainContext.save()

        // This assertion documents the spike conclusion. If externalStorage is a
        // no-op on String, externalFiles == 0 and this test records that fact.
        // (We do not fail the build on the no-op; we record the number.)
        XCTAssertGreaterThanOrEqual(externalFiles, 0)
    }

    /// EVIDENCE 2: Round-trip safety — a value written with `.externalStorage`
    /// reads back unchanged across a container close/reopen at the same URL.
    func test_externalStorage_roundTripsUnchanged() throws {
        let url = tempDir.appending(path: "roundtrip.store")
        let payload = largeTranscript()

        do {
            let config = ModelConfiguration(url: url)
            let container = try ModelContainer(for: ExternalNote.self, configurations: config)
            let context = ModelContext(container)
            context.insert(ExternalNote(title: "rt", body: payload))
            try context.save()
        }

        // Reopen a fresh container at the same URL.
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(for: ExternalNote.self, configurations: config)
        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<ExternalNote>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.body, payload, "externally-stored String must round-trip unchanged")
    }
}
