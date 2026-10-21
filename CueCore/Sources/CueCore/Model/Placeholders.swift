import Foundation

/// `$NAME` and `${NAME}` in the port and address fields, which Cue fills in itself.
/// Commands never go through this: they read inputs from the environment.
public enum Placeholders {
    public static func substitute(_ text: String, values: [String: String]) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "$" else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let afterDollar = text.index(after: index)
            var nameStart = afterDollar
            var braced = false
            if afterDollar < text.endIndex, text[afterDollar] == "{" {
                braced = true
                nameStart = text.index(after: afterDollar)
            }
            var nameEnd = nameStart
            while nameEnd < text.endIndex, text[nameEnd].isLetter || text[nameEnd].isNumber || text[nameEnd] == "_" {
                nameEnd = text.index(after: nameEnd)
            }
            let name = String(text[nameStart..<nameEnd])
            let closed = !braced || (nameEnd < text.endIndex && text[nameEnd] == "}")
            if !name.isEmpty, closed, let value = values[name] {
                result += value
                index = braced ? text.index(after: nameEnd) : nameEnd
            } else {
                result.append("$")
                index = afterDollar
            }
        }
        return result
    }

    public struct InvalidPort: Error, Sendable, Equatable, CustomStringConvertible {
        public let text: String
        public var description: String {
            text.contains("$") ? "Port \(text) has an input with no value" : "Port \(text) isn't a number from 1 to 65535"
        }
    }

    /// Substitutes values into `text` and checks the result is a port from 1 to 65535.
    public static func port(_ text: String, values: [String: String]) throws(InvalidPort) -> Int {
        let resolved = substitute(text, values: values).trimmingCharacters(in: .whitespaces)
        guard let port = Int(resolved), (1...65535).contains(port) else { throw InvalidPort(text: resolved) }
        return port
    }
}
