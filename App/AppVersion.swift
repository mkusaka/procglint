import Foundation

enum AppVersion {
    static func description(info: [String: Any]?) -> String {
        let parts = ["CFBundleShortVersionString", "ProcglintGitCommit"].map { key in
            let value = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty || value.hasPrefix("$(") ? "unknown" : value
        }
        return "\(parts[0]) (\(parts[1]))"
    }
}
