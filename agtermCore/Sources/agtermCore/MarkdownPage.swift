import Foundation

/// MarkdownPage is the page a markdown overlay shows. The app reads the file and the local pictures it
/// references, and this builds the document a bundled renderer turns into HTML. The markdown comes from a
/// clicked path in untrusted output, so its text and the picture map travel as escaped, inert data; the page
/// can load only the `data:` pictures the app embedded.
public enum MarkdownPage {
    /// maxBytes bounds the markdown file a page reads.
    public static let maxBytes = 4 << 20
    /// maxImageBytes bounds the pictures one page embeds, all of them together.
    public static let maxImageBytes = 32 << 20
    /// maxImagePixels bounds the decoded pictures one page embeds, all of them together: the budget one image
    /// page has, since several small compressed files can promise more pixels than one large one.
    public static let maxImagePixels = ImagePage.maxPixels
    /// maxImages bounds the distinct picture files one page probes, a failed probe included. `render.js`
    /// separately shows at most this many picture occurrences.
    public static let maxImages = 256

    /// Image is one picture reference and the local file it may embed.
    public struct Image: Equatable, Sendable {
        /// reference is the reference as written, percent-decoded: the form the renderer looks it up by,
        /// since the two parsers encode a reference differently.
        public let reference: String
        public let path: String
    }

    /// Embedded is the pictures a page carries: each file's data URI once in `uris`, and every reference that
    /// names it as an index into them, so a picture referenced under many spellings is still one copy.
    public struct Embedded: Encodable, Equatable, Sendable {
        public var uris: [String] = []
        public var references: [String: Int] = [:]

        public init(uris: [String] = [], references: [String: Int] = [:]) {
            self.uris = uris
            self.references = references
        }
    }

    /// imageReferences lists each picture `markdown` references that names a file inside `folder`, the
    /// markdown file's own folder, after symlinks on both sides are resolved; in document order, each
    /// reference once. A remote, a `data:` or an escaping reference is left out and renders as its alt text.
    public static func imageReferences(in markdown: String, folder: String) -> [Image] {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }
        var found: [Image] = [], seen: Set<String> = []
        for run in parsed.runs {
            guard let url = run.imageURL else { continue }
            let reference = url.relativeString.removingPercentEncoding ?? url.relativeString
            guard seen.insert(reference).inserted, let path = localPath(reference, folder: folder) else { continue }
            found.append(Image(reference: reference, path: path))
        }
        return found
        #else
        return linuxImageReferences(in: markdown, folder: folder)
        #endif
    }

    #if !canImport(Darwin)
    static func linuxImageReferences(in markdown: String, folder: String) -> [Image] {
        var defs: [String: String] = [:]
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let closeBracket = trimmed.firstIndex(of: "]") else { continue }
            let after = trimmed[trimmed.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)
            guard after.hasPrefix(":") else { continue }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket]).lowercased()
            var dest = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
            if dest.hasPrefix("<"), let end = dest.firstIndex(of: ">") {
                dest = String(dest[dest.index(after: dest.startIndex)..<end])
            } else if let space = dest.firstIndex(where: { $0.isWhitespace }) {
                dest = String(dest[..<space])
            }
            if !label.isEmpty && !dest.isEmpty {
                defs[label] = dest
            }
        }

        var found: [Image] = []
        var seen: Set<String> = []
        let chars = Array(markdown)
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "!" && chars[i + 1] == "[" {
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
                guard depth == 0 && j < chars.count else {
                    i += 1
                    continue
                }
                let alt = String(chars[(i + 2)..<(j - 1)])
                if chars[j] == "(" {
                    var end = j + 1
                    var parenDepth = 1
                    while end < chars.count && parenDepth > 0 {
                        if chars[end] == "(" {
                            parenDepth += 1
                        } else if chars[end] == ")" {
                            parenDepth -= 1
                        }
                        end += 1
                    }
                    guard parenDepth == 0 else {
                        i += 1
                        continue
                    }
                    var dest = String(chars[(j + 1)..<(end - 1)]).trimmingCharacters(in: .whitespaces)
                    if dest.hasPrefix("<"), dest.hasSuffix(">") {
                        dest = String(dest.dropFirst().dropLast())
                    }
                    let ref = dest.removingPercentEncoding ?? dest
                    if seen.insert(ref).inserted, let path = localPath(ref, folder: folder) {
                        found.append(Image(reference: ref, path: path))
                    }
                    i = end
                    continue
                } else if chars[j] == "[" {
                    guard let endBracket = chars[(j + 1)...].firstIndex(of: "]") else {
                        i += 1
                        continue
                    }
                    let refLabel = String(chars[(j + 1)..<endBracket]).trimmingCharacters(in: .whitespaces)
                    let key = (refLabel.isEmpty ? alt : refLabel).lowercased()
                    if let rawDest = defs[key] {
                        let ref = rawDest.removingPercentEncoding ?? rawDest
                        if seen.insert(ref).inserted, let path = localPath(ref, folder: folder) {
                            found.append(Image(reference: ref, path: path))
                        }
                    }
                    i = endBracket + 1
                    continue
                }
            }
            i += 1
        }
        return found
    }
    #endif

    /// localPath resolves one decoded reference against `folder`, nil unless it names a file inside it. The
    /// lexical check runs first, so a reference outside the folder is refused without touching the filesystem.
    static func localPath(_ reference: String, folder: String) -> String? {
        guard folder.hasPrefix("/"), !reference.isEmpty else { return nil }
        let candidate: String
        if reference.hasPrefix("/") {
            candidate = reference
        } else if reference.hasPrefix("~") || hasScheme(reference) {
            return nil
        } else {
            candidate = folder + "/" + reference
        }
        let root = LinkPolicy.lexicallyNormalizedAbsolutePath(folder)
        let lexical = LinkPolicy.lexicallyNormalizedAbsolutePath(candidate)
        guard lexical != root, HtmlOverlay.contains(root, lexical) else { return nil }
        let realRoot = real(root), file = real(lexical)
        return file != realRoot && HtmlOverlay.contains(realRoot, file) ? file : nil
    }

    private static func hasScheme(_ reference: String) -> Bool {
        guard let colon = reference.firstIndex(of: ":") else { return false }
        let scheme = reference[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// html is the document the renderer fills: the markdown as the text of a hidden element, the embedded
    /// pictures as a JSON attribute, and `style`, the app's own stylesheet. Everything authored is HTML-escaped,
    /// never placed inside a script element, and the policy loads nothing but `data:` pictures.
    public static func html(markdown: String, images: Embedded, style: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let map = (try? encoder.encode(images)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">\
        <style>\(style)</style></head><body>\
        <pre id="agterm-markdown" hidden data-images="\(escaped(map))">\(escaped(markdown))</pre>\
        <main id="agterm-page"></main></body></html>
        """
    }

    /// escaped walks scalars, not Characters: a quote fused with a combining mark is one Character
    /// that would match no case and pass through.
    static func escaped(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
