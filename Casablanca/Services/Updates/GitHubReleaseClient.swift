import Foundation
import OSLog

protocol GitHubReleaseClient {
    func fetchLatestRelease(includePrereleases: Bool) async throws -> ReleaseInfo
}

final class URLSessionGitHubReleaseClient: NSObject, GitHubReleaseClient, URLSessionTaskDelegate {
    private let owner: String
    private let repo: String
    private let baseURL: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    static let assetNamePattern = try! NSRegularExpression(
        pattern: #"^Casablanca-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)-macOS\.zip$"#
    )

    init(
        owner: String,
        repo: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.owner = owner
        self.repo = repo
        self.baseURL = baseURL
        self.session = session
    }

    func fetchLatestRelease(includePrereleases: Bool) async throws -> ReleaseInfo {
        let path = includePrereleases
            ? "/repos/\(owner)/\(repo)/releases"
            : "/repos/\(owner)/\(repo)/releases/latest"
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Casablanca-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: self)
        } catch let urlError as URLError {
            throw UpdateError.checkFailed(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.malformedResponse
        }

        if http.statusCode == 429 || http.statusCode == 403 {
            let seconds = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Int.init) ?? 60
            throw UpdateError.rateLimited(retryAfter: Date().addingTimeInterval(TimeInterval(seconds)))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.malformedResponse
        }

        if includePrereleases {
            let releases: [GHReleasePayload]
            do { releases = try JSONDecoder().decode([GHReleasePayload].self, from: data) }
            catch { throw UpdateError.malformedResponse }
            guard let first = releases.first else { throw UpdateError.assetNotFound }
            return try Self.parse(first)
        } else {
            let release: GHReleasePayload
            do { release = try JSONDecoder().decode(GHReleasePayload.self, from: data) }
            catch { throw UpdateError.malformedResponse }
            return try Self.parse(release)
        }
    }

    private static func parse(_ payload: GHReleasePayload) throws -> ReleaseInfo {
        let version = try SemanticVersion(parsing: payload.tag_name)
        guard let asset = payload.assets.first(where: { asset in
            let range = NSRange(asset.name.startIndex..., in: asset.name)
            return assetNamePattern.firstMatch(in: asset.name, range: range) != nil
        }) else {
            throw UpdateError.assetNotFound
        }
        return ReleaseInfo(
            version: version,
            tag: payload.tag_name,
            title: payload.name ?? payload.tag_name,
            bodyMarkdown: payload.body ?? "",
            assetURL: asset.browser_download_url,
            assetByteCount: Int64(asset.size)
        )
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var rewritten = request
        if let originalHost = task.originalRequest?.url?.host,
           let newHost = request.url?.host,
           originalHost != newHost {
            rewritten.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(rewritten)
    }
}

private struct GHReleasePayload: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let prerelease: Bool?
    let assets: [GHAsset]
}

private struct GHAsset: Decodable {
    let name: String
    let browser_download_url: URL
    let size: Int
}
