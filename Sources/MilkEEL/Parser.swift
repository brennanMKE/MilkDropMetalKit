/// The EEL syntax tree.
indirect enum Expr: Equatable {
    case number(Double)
    case variable(String, offset: Int)
    case call(String, [Expr], offset: Int)
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case and(Expr, Expr)
    case or(Expr, Expr)
    case ternary(Expr, Expr, Expr)
    case assign(String, Expr, Expr, offset: Int)
    case sequence([Expr])
}

struct Token: Equatable {
    enum Kind: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(String)
        case end
    }
    var kind: Kind
    var offset: Int
}

/// Splits EEL source into tokens. Handles `//` and `/* */` comments.
struct Lexer {
    private let chars: [Character]
    private var i = 0

    init(_ source: String) {
        chars = Array(source)
    }

    // Longest first, so `+=` wins over `+`.
    private static let symbols = [
        "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&=",
        "+", "-", "*", "/", "%", "^", "|", "&", "!", "=", "<", ">", "?", ":", "(", ")", ",", ";",
    ]

    mutating func tokens() throws -> [Token] {
        var out: [Token] = []
        while true {
            skipSpaceAndComments()
            guard i < chars.count else {
                out.append(Token(kind: .end, offset: i))
                return out
            }
            let start = i
            let c = chars[i]
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                out.append(Token(kind: .number(try number()), offset: start))
            } else if c.isLetter || c == "_" || c == "$" {
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." {
                    i += 1
                }
                out.append(Token(kind: .identifier(String(chars[start..<i]).lowercased()), offset: start))
            } else if let symbol = Self.symbols.first(where: matches) {
                i += symbol.count
                out.append(Token(kind: .symbol(symbol), offset: start))
            } else {
                throw EELCompileError.syntax(message: "unexpected character \"\(c)\"", offset: start)
            }
        }
    }

    private func matches(_ symbol: String) -> Bool {
        var j = i
        for s in symbol {
            guard j < chars.count, chars[j] == s else { return false }
            j += 1
        }
        return true
    }

    private mutating func skipSpaceAndComments() {
        while i < chars.count {
            if chars[i].isWhitespace {
                i += 1
            } else if matches("//") {
                while i < chars.count, !chars[i].isNewline { i += 1 }
            } else if matches("/*") {
                i += 2
                while i < chars.count, !matches("*/") { i += 1 }
                i = min(i + 2, chars.count)
            } else {
                return
            }
        }
    }

    private mutating func number() throws -> Double {
        let start = i
        if matches("0x") || matches("0X") {
            i += 2
            while i < chars.count, chars[i].isHexDigit { i += 1 }
            guard let v = UInt64(String(chars[(start + 2)..<i]), radix: 16) else {
                throw EELCompileError.syntax(message: "bad hex number", offset: start)
            }
            return Double(v)
        }
        while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            if j < chars.count, chars[j].isNumber {
                i = j
                while i < chars.count, chars[i].isNumber { i += 1 }
            }
        }
        guard let v = Double(String(chars[start..<i])) else {
            throw EELCompileError.syntax(message: "bad number", offset: start)
        }
        return v
    }
}

/// Recursive-descent parser. Precedence, lowest first: assignment, `?:`, `||`, `&&`, comparisons, `|` `&`,
/// `+` `-`, `*` `/` `%`, unary `-` `+` `!`, `^`.
struct Parser {
    private var tokens: [Token]
    private var p = 0

    init(source: String) throws {
        var lexer = Lexer(source)
        tokens = try lexer.tokens()
    }

    /// The whole program, or nil when it has no statements.
    mutating func parseProgram() throws -> Expr? {
        let statements = try sequence()
        guard case .end = peek.kind else { throw unexpected() }
        return statements
    }

    private var peek: Token { tokens[p] }

    private func isSymbol(_ s: String) -> Bool {
        if case .symbol(s) = peek.kind { return true }
        return false
    }

    private mutating func accept(_ s: String) -> Bool {
        guard isSymbol(s) else { return false }
        p += 1
        return true
    }

    private mutating func expect(_ s: String) throws {
        guard accept(s) else { throw EELCompileError.syntax(message: "expected \"\(s)\"", offset: peek.offset) }
    }

    private func unexpected() -> EELCompileError {
        switch peek.kind {
        case .end: .syntax(message: "unexpected end", offset: peek.offset)
        case .number(let v): .syntax(message: "unexpected number \(v)", offset: peek.offset)
        case .identifier(let s), .symbol(let s): .syntax(message: "unexpected \"\(s)\"", offset: peek.offset)
        }
    }

    /// Statements separated by `;`, up to `)` `,` or the end. Empty statements are allowed.
    private mutating func sequence() throws -> Expr? {
        var items: [Expr] = []
        while true {
            while accept(";") {}
            if case .end = peek.kind { break }
            if isSymbol(")") || isSymbol(",") { break }
            items.append(try expression())
            if !accept(";") { break }
        }
        switch items.count {
        case 0: return nil
        case 1: return items[0]
        default: return .sequence(items)
        }
    }

    private mutating func expression() throws -> Expr {
        try assignment()
    }

    private static let assignOps: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&="]

    private mutating func assignment() throws -> Expr {
        let offset = peek.offset
        let lhs = try ternary()
        if case .symbol(let op) = peek.kind, Self.assignOps.contains(op) {
            p += 1
            switch lhs {
            case .variable, .call("megabuf", _, _), .call("gmegabuf", _, _):
                return .assign(op, lhs, try assignment(), offset: offset)
            default:
                throw EELCompileError.notAssignable(offset: offset)
            }
        }
        return lhs
    }

    private mutating func ternary() throws -> Expr {
        let cond = try logicalOr()
        guard accept("?") else { return cond }
        let a = try assignment()
        let b: Expr = accept(":") ? try assignment() : .number(0)
        return .ternary(cond, a, b)
    }

    private mutating func logicalOr() throws -> Expr {
        var lhs = try logicalAnd()
        while accept("||") { lhs = .or(lhs, try logicalAnd()) }
        return lhs
    }

    private mutating func logicalAnd() throws -> Expr {
        var lhs = try comparison()
        while accept("&&") { lhs = .and(lhs, try comparison()) }
        return lhs
    }

    private mutating func binaryLevel(_ ops: [String], next: (inout Parser) throws -> Expr) throws -> Expr {
        var lhs = try next(&self)
        while case .symbol(let op) = peek.kind, ops.contains(op) {
            p += 1
            lhs = .binary(op, lhs, try next(&self))
        }
        return lhs
    }

    private mutating func comparison() throws -> Expr {
        try binaryLevel(["==", "!=", "<", ">", "<=", ">="]) { try $0.bitwise() }
    }

    private mutating func bitwise() throws -> Expr {
        try binaryLevel(["|", "&"]) { try $0.additive() }
    }

    private mutating func additive() throws -> Expr {
        try binaryLevel(["+", "-"]) { try $0.multiplicative() }
    }

    private mutating func multiplicative() throws -> Expr {
        try binaryLevel(["*", "/", "%"]) { try $0.unary() }
    }

    private mutating func unary() throws -> Expr {
        if accept("-") { return .unary("-", try unary()) }
        if accept("+") { return try unary() }
        if accept("!") { return .unary("!", try unary()) }
        return try power()
    }

    private mutating func power() throws -> Expr {
        let base = try primary()
        // Right-associative; the exponent may carry its own sign.
        if accept("^") { return .binary("^", base, try unary()) }
        return base
    }

    private mutating func primary() throws -> Expr {
        let token = peek
        switch token.kind {
        case .number(let v):
            p += 1
            return .number(v)
        case .identifier(let name):
            p += 1
            switch name {
            case "$pi": return .number(Double.pi)
            case "$e": return .number(2.718_281_828_459_045)
            case "$phi": return .number(1.618_033_988_749_895)
            default: break
            }
            guard accept("(") else { return .variable(name, offset: token.offset) }
            var args: [Expr] = []
            if !accept(")") {
                repeat {
                    args.append(try sequence() ?? .number(0))
                } while accept(",")
                try expect(")")
            }
            return .call(name, args, offset: token.offset)
        case .symbol("("):
            p += 1
            let inner = try sequence() ?? .number(0)
            try expect(")")
            return inner
        default:
            throw unexpected()
        }
    }
}
