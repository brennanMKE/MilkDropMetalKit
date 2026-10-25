import Foundation

/// A token of MilkDrop's HLSL dialect.
struct Token: Equatable, CustomStringConvertible {
    enum Kind: Equatable {
        case identifier
        case number
        case symbol
        /// `#` at the start of a line: a preprocessor directive follows.
        case directive
        case newline
        case end
    }

    var kind: Kind
    var text: String
    /// 1-based line, for error messages.
    var line: Int

    var description: String { kind == .end ? "end of shader" : "\"\(text)\"" }

    func `is`(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
}

/// Splits HLSL source into tokens. Comments are dropped; newlines are kept so the preprocessor can find the end
/// of a directive, and removed after it runs.
enum Lexer {
    private static let symbols: [String] = [
        "<<=", ">>=", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "==", "!=", "<=", ">=", "&&", "||",
        "<<", ">>", "::",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "~", "&", "|", "^", "?", ":", ".", ",", ";", "(", ")", "[", "]",
        "{", "}", "#", "\\",
    ]

    static func tokenize(_ source: String) throws -> [Token] {
        let chars = Array(source.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        var line = 1
        var lineStart = true
        func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < chars.count ? chars[i + k] : nil }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                tokens.append(Token(kind: .newline, text: "\n", line: line))
                line += 1
                i += 1
                lineStart = true
                continue
            }
            if c == " " || c == "\t" || c == "\r" || c.value == 0xA0 || c.value == 0x0B || c.value == 0x0C {
                i += 1
                continue
            }
            if c == "/" && peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && peek(1) == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && peek(1) == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            // A backslash before a newline continues the line (used in multi-line #defines).
            if c == "\\" && (peek(1) == "\n" || (peek(1) == "\r" && peek(2) == "\n")) {
                i += peek(1) == "\n" ? 2 : 3
                line += 1
                continue
            }
            if c == "#" && lineStart {
                tokens.append(Token(kind: .directive, text: "#", line: line))
                i += 1
                lineStart = false
                continue
            }
            lineStart = false
            if isIdentifierStart(c) {
                let start = i
                while i < chars.count, isIdentifierPart(chars[i]) { i += 1 }
                tokens.append(Token(kind: .identifier, text: String(String.UnicodeScalarView(chars[start..<i])),
                                    line: line))
                continue
            }
            if isDigit(c) || (c == "." && peek(1).map(isDigit) == true) {
                tokens.append(Token(kind: .number, text: number(chars, &i), line: line))
                continue
            }
            if let symbol = symbols.first(where: { matches($0, chars, i) }) {
                tokens.append(Token(kind: .symbol, text: symbol, line: line))
                i += symbol.unicodeScalars.count
                continue
            }
            // Stray characters (Windows-1252 leftovers, `@`, `$`, quotes) can't be part of valid code; skip them
            // and let the parser fail if they mattered.
            i += 1
        }
        tokens.append(Token(kind: .end, text: "", line: line))
        return tokens
    }

    private static func matches(_ symbol: String, _ chars: [Unicode.Scalar], _ i: Int) -> Bool {
        var k = i
        for s in symbol.unicodeScalars {
            guard k < chars.count, chars[k] == s else { return false }
            k += 1
        }
        return true
    }

    /// A numeric literal: decimal, float (`1.`, `.5`, `1e-3`) with an optional `f`/`h`/`l` suffix, or hex.
    private static func number(_ chars: [Unicode.Scalar], _ i: inout Int) -> String {
        let start = i
        if chars[i] == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
            i += 2
            while i < chars.count, chars[i].properties.isASCIIHexDigit { i += 1 }
            return String(String.UnicodeScalarView(chars[start..<i]))
        }
        while i < chars.count, isDigit(chars[i]) { i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, isDigit(chars[i]) { i += 1 }
        }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var k = i + 1
            if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
            if k < chars.count, isDigit(chars[k]) {
                i = k
                while i < chars.count, isDigit(chars[i]) { i += 1 }
            }
        }
        if i < chars.count, "fFhHlLuU".unicodeScalars.contains(chars[i]) { i += 1 }
        return String(String.UnicodeScalarView(chars[start..<i]))
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
    private static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }
    private static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool { isIdentifierStart(c) || isDigit(c) }
}
