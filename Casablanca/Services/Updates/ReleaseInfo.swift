import Foundation

struct ReleaseInfo: Equatable {
    let version: SemanticVersion
    let tag: String
    let title: String
    let bodyMarkdown: String
    let assetURL: URL
    let assetByteCount: Int64
}
