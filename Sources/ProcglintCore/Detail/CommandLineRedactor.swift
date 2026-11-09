import Foundation

public enum CommandLineRedactor {
    private static let secretParts = ["token", "secret", "password", "passwd", "pwd", "apikey", "api-key", "api_key", "auth", "credential"]
    private static let passwordURL = try? NSRegularExpression(pattern: "(?i)([a-z][a-z0-9+.-]*://[^/\\s:@]+:)[^/\\s@]*@")
    private static let userURL = try? NSRegularExpression(pattern: "(?i)([a-z][a-z0-9+.-]*://)[^/\\s:@]+@")
    private static let bearer = try? NSRegularExpression(pattern: "(?i)\\b(Bearer)\\s+\\S+")

    private static func secretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if secretParts.contains(where: lower.contains) {
            return true
        }
        // Avoid common non-secret 'key' substrings, but still redact names such as signingkey or MYKEY.
        return lower.replacingOccurrences(of: "keyboard", with: "")
            .replacingOccurrences(of: "keymap", with: "")
            .replacingOccurrences(of: "monkey", with: "").contains("key")
    }

    public static func redact(_ arguments: [String]) -> [String] {
        var hideNext = false
        return arguments.map { argument in
            let endsInBearer = argument.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "=" }).last?.lowercased() == "bearer"
            let secretFlag = !argument.contains("=") && argument.hasPrefix("-") && secretName(argument)
            let hidden = hideNext
            hideNext = endsInBearer || secretFlag
            if hidden {
                return "<redacted>"
            }
            if let equals = argument.firstIndex(of: "="), secretName(String(argument[..<equals])) {
                return String(argument[...equals]) + "<redacted>"
            }
            var text = replace(passwordURL, in: argument, with: "$1<redacted>@")
            text = replace(userURL, in: text, with: "$1<redacted>@")
            return replace(bearer, in: text, with: "$1 <redacted>")
        }
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return "<redacted>" } // Fail closed if a pattern is accidentally broken.
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
