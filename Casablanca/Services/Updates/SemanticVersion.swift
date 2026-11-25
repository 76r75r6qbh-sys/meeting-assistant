import Foundation

struct SemanticVersion: Comparable, Codable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    enum ParseError: Error, Equatable { case malformed(String) }

    init(parsing raw: String) throws {
        var input = raw
        if input.hasPrefix("v") { input.removeFirst() }

        // strip build metadata
        if let plus = input.firstIndex(of: "+") {
            input = String(input[..<plus])
        }

        var prerelease: String? = nil
        if let dash = input.firstIndex(of: "-") {
            prerelease = String(input[input.index(after: dash)...])
            input = String(input[..<dash])
        }

        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else {
            throw ParseError.malformed(raw)
        }
        if let pre = prerelease, pre.isEmpty {
            throw ParseError.malformed(raw)
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?):  return false              // release > prerelease
        case (_?, nil):  return true               // prerelease < release
        case (let l?, let r?):
            return comparePrereleaseIdentifiers(l, r) == .orderedAscending
        }
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    private static func comparePrereleaseIdentifiers(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".")
        let bParts = b.split(separator: ".")
        for i in 0..<min(aParts.count, bParts.count) {
            let l = String(aParts[i])
            let r = String(bParts[i])
            let lNum = Int(l)
            let rNum = Int(r)
            switch (lNum, rNum) {
            case (let li?, let ri?):
                if li != ri { return li < ri ? .orderedAscending : .orderedDescending }
            case (_?, nil): return .orderedAscending          // numeric < alphanumeric
            case (nil, _?): return .orderedDescending
            case (nil, nil):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            }
        }
        if aParts.count == bParts.count { return .orderedSame }
        return aParts.count < bParts.count ? .orderedAscending : .orderedDescending
    }
}
