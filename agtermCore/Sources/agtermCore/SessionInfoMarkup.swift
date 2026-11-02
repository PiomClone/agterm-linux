import Foundation

/// SessionInfoSpan is one styled run of a session info line. Host-free, so the app maps it to fonts and colors.
public struct SessionInfoSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var dim = false
    public var color: TintColor?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, dim: Bool = false,
                color: TintColor? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.dim = dim
        self.color = color
    }

    func sameStyle(as other: SessionInfoSpan) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code && dim == other.dim && color == other.color
    }
}

/// SessionInfo is a session's caller-set sidebar info line: the source as sent, whether it is markdown, its
/// configured expiry in seconds (0 for none), and the spans the row draws.
public struct SessionInfo: Equatable, Sendable {
    /// maxSourceBytes caps the source in UTF-8 bytes; markup syntax counts toward it.
    public static let maxSourceBytes = 512

    public let source: String
    public let markdown: Bool
    public let hideAfter: Double
    public let spans: [SessionInfoSpan]

    /// make validates a set and parses its source; a failure carries the control response message.
    public static func make(source: String, markdown: Bool, hideAfter: Double) -> Result<SessionInfo, SessionInfoRejection> {
        guard source.utf8.count <= maxSourceBytes else {
            return .failure(SessionInfoRejection(message: "info text is over \(maxSourceBytes) bytes"))
        }
        guard HudSpec.isValidHideAfter(hideAfter) else {
            return .failure(SessionInfoRejection(message: "--hide-after must be 0...\(Int(HudSpec.maxHideAfter)) seconds"))
        }
        do {
            let spans = try SessionInfoMarkup.spans(source, markdown: markdown)
            return .success(SessionInfo(source: source, markdown: markdown, hideAfter: hideAfter, spans: spans))
        } catch {
            return .failure(SessionInfoRejection(message: error.message))
        }
    }
}

/// SessionInfoRejection is a refused `session.info` set, worded for the control response.
public struct SessionInfoRejection: Error, Equatable {
    public let message: String
}

/// SessionInfoMarkup turns a session info source into spans. Markdown is inline-only Foundation markdown plus
/// `^[text](color: "NAME")` and `^[text](dim: true)`; a link keeps its label and drops its target. An unknown
/// attribute key is dropped by Foundation and renders unstyled, which is accepted rather than lexed for.
enum SessionInfoMarkup {
    /// ParseError is why a source was refused.
    enum ParseError: Error, Equatable {
        case empty
        case lineBreak
        case controlCharacter
        case unknownColor(String)
        case invalidMarkdown

        var message: String {
            switch self {
            case .empty: "info text is empty"
            case .lineBreak: "info text must be one line"
            case .controlCharacter: "info text contains a control character"
            case .unknownColor(let name): "unknown info color: \(name) (\(TintColor.validNamesList))"
            case .invalidMarkdown: "invalid info markdown; quote attribute values: ^[text](color: \"green\")"
            }
        }
    }

    /// spans parses `source` as markdown when `markdown` is set, otherwise as literal text. The visible text
    /// must be non-blank and one line with no control characters, checked after entities are decoded.
    static func spans(_ source: String, markdown: Bool) throws(ParseError) -> [SessionInfoSpan] {
        let spans = markdown ? try parseMarkdown(source) : [SessionInfoSpan(text: source)]
        try validate(spans.map(\.text).joined())
        return spans
    }

    #if canImport(Darwin)
    private static func parseMarkdown(_ source: String) throws(ParseError) -> [SessionInfoSpan] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, including: \.agtermSessionInfo, options: options)
        } catch {
            throw .invalidMarkdown
        }
        var spans: [SessionInfoSpan] = []
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var color: TintColor?
            if let name = run[SessionInfoColorKey.self] {
                guard let known = TintColor(rawValue: name.lowercased()) else { throw .unknownColor(name) }
                color = known
            }
            let span = SessionInfoSpan(text: String(parsed[run.range].characters),
                                       bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
                                       code: intent.contains(.code), dim: run[SessionInfoDimKey.self] ?? false,
                                       color: color)
            if let last = spans.last, last.sameStyle(as: span) {
                spans[spans.count - 1].text += span.text
                continue
            }
            spans.append(span)
        }
        return spans
    }
    #else
    private static func parseMarkdown(_ source: String) throws(ParseError) -> [SessionInfoSpan] {
        try LinuxSessionInfoParser(source: source).parse()
    }
    #endif

    private static func validate(_ text: String) throws(ParseError) {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x2028, 0x2029, 0x85: throw .lineBreak
            default: if scalar.properties.generalCategory == .control { throw .controlCharacter }
            }
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw .empty }
    }
}

#if canImport(Darwin)
enum SessionInfoColorKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = String
    static let name = "color"
}

enum SessionInfoDimKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = Bool
    static let name = "dim"
}

extension AttributeScopes {
    struct SessionInfoAttributes: AttributeScope {
        let color: SessionInfoColorKey
        let dim: SessionInfoDimKey
        let foundation: FoundationAttributes
    }

    var agtermSessionInfo: SessionInfoAttributes.Type { SessionInfoAttributes.self }
}
#else
private struct LinuxSessionInfoParser {
    typealias ParseError = SessionInfoMarkup.ParseError

    struct Style {
        var bold = false
        var italic = false
        var code = false
        var dim = false
        var color: TintColor?
    }

    let source: String

    func parse() throws(ParseError) -> [SessionInfoSpan] {
        var spans: [SessionInfoSpan] = []
        try parseInline(source, currentStyle: Style(), into: &spans)
        var merged: [SessionInfoSpan] = []
        for span in spans {
            if span.text.isEmpty { continue }
            if let last = merged.last, last.sameStyle(as: span) {
                merged[merged.count - 1].text += span.text
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func parseInline(
        _ text: String,
        currentStyle: Style,
        into out: inout [SessionInfoSpan]
    ) throws(ParseError) {
        let chars = Array(text)
        var i = 0
        var currentText = ""

        func flushText() {
            if !currentText.isEmpty {
                out.append(SessionInfoSpan(
                    text: currentText,
                    bold: currentStyle.bold,
                    italic: currentStyle.italic,
                    code: currentStyle.code,
                    dim: currentStyle.dim,
                    color: currentStyle.color
                ))
                currentText = ""
            }
        }

        while i < chars.count {
            if let (nextI, innerText, attrs) = try parseAnnotation(at: i, chars: chars) {
                flushText()
                var nextStyle = currentStyle
                if let c = attrs.color { nextStyle.color = c }
                if let d = attrs.dim { nextStyle.dim = d }
                try parseInline(innerText, currentStyle: nextStyle, into: &out)
                i = nextI
                continue
            }

            if let (nextI, codeText) = parseCode(at: i, chars: chars) {
                flushText()
                out.append(SessionInfoSpan(
                    text: codeText,
                    bold: currentStyle.bold,
                    italic: currentStyle.italic,
                    code: true,
                    dim: currentStyle.dim,
                    color: currentStyle.color
                ))
                i = nextI
                continue
            }

            if let (nextI, boldText) = parseBold(at: i, chars: chars) {
                flushText()
                var nextStyle = currentStyle
                nextStyle.bold = true
                try parseInline(boldText, currentStyle: nextStyle, into: &out)
                i = nextI
                continue
            }

            if let (nextI, italicText) = parseItalic(at: i, chars: chars) {
                flushText()
                var nextStyle = currentStyle
                nextStyle.italic = true
                try parseInline(italicText, currentStyle: nextStyle, into: &out)
                i = nextI
                continue
            }

            if let (nextI, linkText) = parseLink(at: i, chars: chars) {
                flushText()
                try parseInline(linkText, currentStyle: currentStyle, into: &out)
                i = nextI
                continue
            }

            if chars[i] == "&", let semi = chars[i...].firstIndex(of: ";") {
                let ent = String(chars[(i + 1)..<semi])
                if let decoded = decodeSingleEntity(ent) {
                    currentText.append(decoded)
                    i = semi + 1
                    continue
                }
            }

            currentText.append(chars[i])
            i += 1
        }
        flushText()
    }

    private func parseAnnotation(at i: Int, chars: [Character]) throws(ParseError) -> (Int, String, (color: TintColor?, dim: Bool?))? {
        guard chars[i] == "^", i + 1 < chars.count, chars[i + 1] == "[" else { return nil }
        var depth = 1
        var j = i + 2
        while j < chars.count && depth > 0 {
            if chars[j] == "[" {
                depth += 1
            } else if chars[j] == "]" {
                depth -= 1
            }
            j += 1
        }
        guard depth == 0 && j < chars.count && chars[j] == "(" else { return nil }
        var k = j + 1
        var parenDepth = 1
        while k < chars.count && parenDepth > 0 {
            if chars[k] == "(" {
                parenDepth += 1
            } else if chars[k] == ")" {
                parenDepth -= 1
            }
            k += 1
        }
        guard parenDepth == 0 else { return nil }
        let innerText = String(chars[(i + 2)..<(j - 1)])
        let attrText = String(chars[(j + 1)..<(k - 1)])
        let attrs = try parseAttributes(attrText)
        return (k, innerText, attrs)
    }

    private func parseCode(at i: Int, chars: [Character]) -> (Int, String)? {
        guard chars[i] == "`" else { return nil }
        guard let end = chars[(i + 1)...].firstIndex(of: "`") else { return nil }
        let codeText = decodeEntities(String(chars[(i + 1)..<end]))
        return (end + 1, codeText)
    }

    private func parseBold(at i: Int, chars: [Character]) -> (Int, String)? {
        guard chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" else { return nil }
        var j = i + 2
        var foundEnd: Int?
        while j + 1 < chars.count {
            if chars[j] == "*", chars[j + 1] == "*" {
                foundEnd = j
                break
            }
            j += 1
        }
        guard let end = foundEnd else { return nil }
        return (end + 2, String(chars[(i + 2)..<end]))
    }

    private func parseItalic(at i: Int, chars: [Character]) -> (Int, String)? {
        guard chars[i] == "*" else { return nil }
        guard let end = chars[(i + 1)...].firstIndex(of: "*") else { return nil }
        return (end + 1, String(chars[(i + 1)..<end]))
    }

    private func parseLink(at i: Int, chars: [Character]) -> (Int, String)? {
        guard chars[i] == "[" else { return nil }
        var depth = 1
        var j = i + 1
        while j < chars.count && depth > 0 {
            if chars[j] == "[" {
                depth += 1
            } else if chars[j] == "]" {
                depth -= 1
            }
            j += 1
        }
        guard depth == 0 && j < chars.count && chars[j] == "(" else { return nil }
        var k = j + 1
        var parenDepth = 1
        while k < chars.count && parenDepth > 0 {
            if chars[k] == "(" {
                parenDepth += 1
            } else if chars[k] == ")" {
                parenDepth -= 1
            }
            k += 1
        }
        guard parenDepth == 0 else { return nil }
        let labelText = String(chars[(i + 1)..<(j - 1)])
        return (k, labelText)
    }

    private func decodeSingleEntity(_ ent: String) -> String? {
        if ent.hasPrefix("#") {
            let hex = ent.lowercased().hasPrefix("#x")
            let numStr = hex ? String(ent.dropFirst(2)) : String(ent.dropFirst(1))
            if let code = UInt32(numStr, radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) {
                return String(scalar)
            }
        } else {
            switch ent {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            default: break
            }
        }
        return nil
    }

    private func decodeEntities(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "&", let semi = chars[i...].firstIndex(of: ";") {
                let ent = String(chars[(i + 1)..<semi])
                if let decoded = decodeSingleEntity(ent) {
                    result.append(decoded)
                    i = semi + 1
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    private func parseAttributes(_ attrText: String) throws(ParseError) -> (color: TintColor?, dim: Bool?) {
        var color: TintColor?
        var dim: Bool?
        let parts = attrText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else {
                throw .invalidMarkdown
            }
            let key = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "color" {
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    let colorName = String(val.dropFirst().dropLast())
                    guard let c = TintColor(rawValue: colorName.lowercased()) else {
                        throw .unknownColor(colorName)
                    }
                    color = c
                } else {
                    throw .invalidMarkdown
                }
            } else if key == "dim" {
                if val == "true" {
                    dim = true
                } else if val == "false" {
                    dim = false
                } else {
                    throw .invalidMarkdown
                }
            }
        }
        return (color, dim)
    }
}
#endif
