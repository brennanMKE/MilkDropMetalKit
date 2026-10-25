import Foundation

/// The C preprocessor subset MilkDrop shaders use: `#define` (object- and function-like), `#undef`, `#if`/`#ifdef`/
/// `#ifndef`/`#elif`/`#else`/`#endif`. Other directives (`#include`, `#pragma`, `#line`) are ignored. Returns the
/// expanded tokens without newlines.
struct Preprocessor {
    struct Macro {
        var parameters: [String]?
        var body: [Token]
    }

    private(set) var macros: [String: Macro] = [:]

    init(predefined: [String: Macro] = [:]) {
        macros = predefined
    }

    /// Defines a macro from source text, e.g. `define("GetMain(uv)", "(tex2D(sampler_main,uv).xyz)")`.
    mutating func define(_ head: String, _ body: String) throws {
        let tokens = try Lexer.tokenize("#define \(head) \(body)\n")
        _ = try process(tokens)
    }

    mutating func process(_ tokens: [Token]) throws -> [Token] {
        var output: [Token] = []
        var i = 0
        // Conditional stack: (active, anyBranchTaken).
        var conditions: [(active: Bool, taken: Bool)] = []
        var active: Bool { conditions.allSatisfy(\.active) }

        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .directive {
                // Collect the directive's line.
                var line: [Token] = []
                i += 1
                while i < tokens.count, tokens[i].kind != .newline, tokens[i].kind != .end {
                    line.append(tokens[i])
                    i += 1
                }
                guard let name = line.first?.text else { continue }
                let rest = Array(line.dropFirst())
                switch name {
                case "if":
                    let value = active ? try evaluate(rest) : false
                    conditions.append((value, value))
                case "ifdef", "ifndef":
                    let defined = rest.first.map { macros[$0.text] != nil } ?? false
                    let value = name == "ifdef" ? defined : !defined
                    conditions.append((value, value))
                case "elif":
                    guard var top = conditions.popLast() else { throw ShaderError.syntax("#elif without #if", token.line) }
                    let outerActive = active
                    if top.taken {
                        top.active = false
                    } else {
                        top.active = outerActive ? try evaluate(rest) : false
                        top.taken = top.active
                    }
                    conditions.append(top)
                case "else":
                    guard var top = conditions.popLast() else { throw ShaderError.syntax("#else without #if", token.line) }
                    top.active = !top.taken
                    top.taken = true
                    conditions.append(top)
                case "endif":
                    guard conditions.popLast() != nil else { throw ShaderError.syntax("#endif without #if", token.line) }
                case "define" where active:
                    try define(rest, line: token.line)
                case "undef" where active:
                    if let n = rest.first?.text { macros[n] = nil }
                default:
                    break
                }
                continue
            }
            if token.kind == .newline || !active {
                i += 1
                continue
            }
            if token.kind == .end {
                output.append(token)
                break
            }
            if token.kind == .identifier, macros[token.text] != nil {
                // Expand, reading arguments from the remaining input when the macro takes them.
                var rest = Array(tokens[i...].filter { $0.kind != .newline })
                let (expanded, consumed) = try expand(at: 0, in: &rest, hidden: [])
                output += expanded
                // Map consumed (newline-free) tokens back to positions in `tokens`.
                var remaining = consumed
                while remaining > 0, i < tokens.count {
                    if tokens[i].kind != .newline { remaining -= 1 }
                    i += 1
                }
                continue
            }
            output.append(token)
            i += 1
        }
        if output.last?.kind != .end { output.append(Token(kind: .end, text: "", line: tokens.last?.line ?? 0)) }
        return output
    }

    private mutating func define(_ rest: [Token], line: Int) throws {
        guard let nameToken = rest.first, nameToken.kind == .identifier else {
            throw ShaderError.syntax("#define needs a name", line)
        }
        var k = 1
        var parameters: [String]?
        // Function-like only when "(" follows the name directly; the lexer drops spacing, so compare lines and accept.
        if k < rest.count, rest[k].is("("), isFunctionLike(rest) {
            parameters = []
            k += 1
            while k < rest.count, !rest[k].is(")") {
                if rest[k].kind == .identifier { parameters?.append(rest[k].text) }
                k += 1
            }
            k += 1
        }
        macros[nameToken.text] = Macro(parameters: parameters, body: Array(rest.dropFirst(k)))
    }

    /// `#define F(x) …` is function-like; `#define F (x)` isn't, but the lexer has dropped the space. Treat the
    /// parenthesis as a parameter list when it holds only identifiers and commas and is followed by more tokens.
    private func isFunctionLike(_ rest: [Token]) -> Bool {
        var k = 2
        while k < rest.count, !rest[k].is(")") {
            guard rest[k].kind == .identifier || rest[k].is(",") else { return false }
            k += 1
        }
        return k < rest.count
    }

    /// Expands the macro at `tokens[index]`. Returns the expansion and how many tokens of `tokens` it used.
    private func expand(at index: Int, in tokens: inout [Token], hidden: Set<String>) throws -> ([Token], Int) {
        let name = tokens[index]
        guard let macro = macros[name.text], !hidden.contains(name.text) else { return ([name], 1) }
        var consumed = 1
        var body = macro.body
        if let parameters = macro.parameters {
            // A function-like macro name without arguments is left alone.
            guard index + 1 < tokens.count, tokens[index + 1].is("(") else { return ([name], 1) }
            var args: [[Token]] = [[]]
            var depth = 0
            var k = index + 2
            while k < tokens.count {
                let t = tokens[k]
                if t.kind == .end { throw ShaderError.syntax("unterminated macro call \(name.text)", name.line) }
                if t.is("(") { depth += 1 }
                if t.is(")") {
                    if depth == 0 { break }
                    depth -= 1
                }
                if t.is(","), depth == 0 {
                    args.append([])
                } else {
                    args[args.count - 1].append(t)
                }
                k += 1
            }
            consumed = k - index + 1
            if parameters.isEmpty, args == [[]] { args = [] }
            // Arguments are expanded before substitution.
            let expandedArgs = try args.map { try expandAll($0, hidden: hidden) }
            body = body.flatMap { t -> [Token] in
                if t.kind == .identifier, let p = parameters.firstIndex(of: t.text), p < expandedArgs.count {
                    return expandedArgs[p]
                }
                return [t]
            }
        }
        return (try expandAll(body.map { var t = $0; t.line = name.line; return t }, hidden: hidden.union([name.text])),
                consumed)
    }

    private func expandAll(_ tokens: [Token], hidden: Set<String>) throws -> [Token] {
        var tokens = tokens
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].kind == .identifier, macros[tokens[i].text] != nil, !hidden.contains(tokens[i].text) {
                let (expanded, consumed) = try expand(at: i, in: &tokens, hidden: hidden)
                out += expanded
                i += consumed
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    /// `#if` conditions: integers, `defined(X)`, macros, `!`, `&&`, `||`, comparisons and parentheses.
    private func evaluate(_ tokens: [Token]) throws -> Bool {
        var resolved: [Token] = []
        var k = 0
        while k < tokens.count {
            let t = tokens[k]
            if t.kind == .identifier, t.text == "defined" {
                var j = k + 1
                if j < tokens.count, tokens[j].is("(") { j += 1 }
                let name = j < tokens.count ? tokens[j].text : ""
                resolved.append(Token(kind: .number, text: macros[name] != nil ? "1" : "0", line: t.line))
                k = j + 1
                if k < tokens.count, tokens[k].is(")") { k += 1 }
                continue
            }
            resolved.append(t)
            k += 1
        }
        let expanded = try expandAll(resolved, hidden: []).map { t -> Token in
            // Undefined identifiers are 0, as in C.
            t.kind == .identifier ? Token(kind: .number, text: "0", line: t.line) : t
        }
        var p = ConditionParser(tokens: expanded)
        return try p.expression() != 0
    }
}

/// Integer expression evaluator for `#if`.
private struct ConditionParser {
    var tokens: [Token]
    var i = 0

    mutating func expression() throws -> Int { try or() }

    private mutating func or() throws -> Int {
        var v = try and()
        while accept("||") { let r = try and(); v = (v != 0 || r != 0) ? 1 : 0 }
        return v
    }

    private mutating func and() throws -> Int {
        var v = try comparison()
        while accept("&&") { let r = try comparison(); v = (v != 0 && r != 0) ? 1 : 0 }
        return v
    }

    private mutating func comparison() throws -> Int {
        var v = try additive()
        while true {
            if accept("==") { v = v == (try additive()) ? 1 : 0 }
            else if accept("!=") { v = v != (try additive()) ? 1 : 0 }
            else if accept("<=") { v = v <= (try additive()) ? 1 : 0 }
            else if accept(">=") { v = v >= (try additive()) ? 1 : 0 }
            else if accept("<") { v = v < (try additive()) ? 1 : 0 }
            else if accept(">") { v = v > (try additive()) ? 1 : 0 }
            else { return v }
        }
    }

    private mutating func additive() throws -> Int {
        var v = try unary()
        while true {
            if accept("+") { v += try unary() } else if accept("-") { v -= try unary() } else { return v }
        }
    }

    private mutating func unary() throws -> Int {
        if accept("!") { return try unary() == 0 ? 1 : 0 }
        if accept("-") { return -(try unary()) }
        if accept("(") {
            let v = try expression()
            _ = accept(")")
            return v
        }
        guard i < tokens.count, tokens[i].kind == .number else { return 0 }
        let text = tokens[i].text.trimmingCharacters(in: CharacterSet(charactersIn: "fFhHlLuU"))
        i += 1
        return Int(text) ?? Int(Double(text) ?? 0)
    }

    private mutating func accept(_ symbol: String) -> Bool {
        guard i < tokens.count, tokens[i].is(symbol) else { return false }
        i += 1
        return true
    }
}
