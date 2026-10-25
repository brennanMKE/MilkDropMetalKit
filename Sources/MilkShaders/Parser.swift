import Foundation

/// Recursive-descent parser for the HLSL subset MilkDrop 2 shaders use: global declarations (variables, samplers,
/// `static const` tables), functions, and `shader_body { … }`.
struct Parser {
    private var tokens: [Token]
    private var i = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    private var current: Token { tokens[min(i, tokens.count - 1)] }
    private func peek(_ k: Int) -> Token { tokens[min(i + k, tokens.count - 1)] }

    private mutating func advance() -> Token {
        let t = current
        if i < tokens.count - 1 { i += 1 }
        return t
    }

    private mutating func accept(_ symbol: String) -> Bool {
        guard current.is(symbol) else { return false }
        i += 1
        return true
    }

    private mutating func expect(_ symbol: String) throws {
        guard accept(symbol) else { throw ShaderError.syntax("expected \"\(symbol)\", found \(current)", current.line) }
    }

    private mutating func identifier() throws -> String {
        guard current.kind == .identifier else {
            throw ShaderError.syntax("expected a name, found \(current)", current.line)
        }
        return advance().text
    }

    /// Storage words that don't change the translation.
    private static let ignoredModifiers: Set<String> = [
        "uniform", "extern", "inline", "precise", "shared", "volatile", "row_major", "column_major", "nointerpolation",
        "linear", "centroid", "noperspective",
    ]

    private func isTypeName(_ t: Token) -> Bool {
        t.kind == .identifier && HType(name: t.text) != nil
    }

    // MARK: Program

    mutating func parseProgram() throws -> ShaderProgram {
        var globals: [ShaderProgram.Global] = []
        var body: [Stmt]?
        while current.kind != .end {
            if current.kind == .identifier, current.text == "shader_body" {
                _ = advance()
                try expect("{")
                body = try statements(until: "}")
                try expect("}")
                // Anything after shader_body is ignored, as MilkDrop does.
                break
            }
            if accept(";") { continue }
            globals += try global()
        }
        guard let body else { throw ShaderError.syntax("no shader_body", current.line) }
        return ShaderProgram(globals: globals, body: body)
    }

    private mutating func global() throws -> [ShaderProgram.Global] {
        let line = current.line
        var isStatic = false, isConst = false
        while current.kind == .identifier {
            if current.text == "static" { isStatic = true; _ = advance() }
            else if current.text == "const" { isConst = true; _ = advance() }
            else if Self.ignoredModifiers.contains(current.text) { _ = advance() }
            else { break }
        }
        let type = try parseType()
        let name = try identifier()
        if current.is("(") {
            return [.function(try function(returnType: type, name: name, line: line))]
        }
        let declaration = try declaration(type: type, firstName: name, isStatic: isStatic, isConst: isConst, line: line)
        return [.declaration(declaration)]
    }

    private mutating func parseType() throws -> HType {
        let t = current
        guard t.kind == .identifier, let type = HType(name: t.text) else {
            throw ShaderError.syntax("expected a type, found \(t)", t.line)
        }
        _ = advance()
        // `vector<float, 3>` / `matrix<float, 3, 3>` aren't used by presets; reject clearly.
        if current.is("<") { throw ShaderError.syntax("template types aren't supported", t.line) }
        return type
    }

    private mutating func function(returnType: HType, name: String, line: Int) throws -> Function {
        try expect("(")
        var parameters: [Parameter] = []
        if !current.is(")") {
            repeat {
                var direction = Parameter.Direction.in
                while current.kind == .identifier {
                    if current.text == "out" { direction = .out; _ = advance() }
                    else if current.text == "inout" { direction = .inout; _ = advance() }
                    else if current.text == "in" || current.text == "const" || Self.ignoredModifiers.contains(current.text) {
                        _ = advance()
                    } else { break }
                }
                if current.text == "void" { _ = advance(); break }
                let type = try parseType()
                let pname = try identifier()
                var size: Int?
                if accept("[") { size = Int(advance().text); try expect("]") }
                try skipSemantic()
                parameters.append(Parameter(direction: direction, type: type, name: pname, arraySize: size))
            } while accept(",")
        }
        try expect(")")
        try skipSemantic()
        if accept(";") { return Function(returnType: returnType, name: name, parameters: parameters, body: nil, line: line) }
        try expect("{")
        let body = try statements(until: "}")
        try expect("}")
        return Function(returnType: returnType, name: name, parameters: parameters, body: body, line: line)
    }

    /// `: TEXCOORD0`, `: register(s0)` — meaningless here.
    private mutating func skipSemantic() throws {
        guard accept(":") else { return }
        _ = try identifier()
        if accept("(") {
            while !current.is(")"), current.kind != .end { _ = advance() }
            try expect(")")
        }
    }

    private mutating func declaration(type: HType, firstName: String, isStatic: Bool, isConst: Bool,
                                      line: Int) throws -> Declaration {
        var declarators: [Declarator] = []
        var name = firstName
        while true {
            var size: Int?
            if accept("[") {
                if !current.is("]") {
                    let text = advance().text
                    guard let n = Int(text) else { throw ShaderError.syntax("array sizes must be numbers", line) }
                    size = n
                }
                try expect("]")
            }
            try skipSemantic()
            // Annotations: `<string name = "…";>`.
            if current.is("<") {
                while !current.is(">"), current.kind != .end { _ = advance() }
                _ = accept(">")
            }
            var initializer: Expr?
            if accept("=") {
                if current.kind == .identifier, current.text == "sampler_state" {
                    // `sampler_state { AddressU = WRAP; … }`: filtering comes from the sampler's name prefix instead.
                    _ = advance()
                    try expect("{")
                    var depth = 1
                    while depth > 0, current.kind != .end {
                        if current.is("{") { depth += 1 }
                        if current.is("}") { depth -= 1 }
                        _ = advance()
                    }
                } else {
                    initializer = current.is("{") ? try initializerList() : try assignment()
                }
            }
            declarators.append(Declarator(name: name, arraySize: size, initializer: initializer))
            guard accept(",") else { break }
            name = try identifier()
        }
        try expect(";")
        return Declaration(isStatic: isStatic, isConst: isConst, type: type, declarators: declarators, line: line)
    }

    private mutating func initializerList() throws -> Expr {
        let line = current.line
        try expect("{")
        var items: [Expr] = []
        while !current.is("}") {
            items.append(current.is("{") ? try initializerList() : try assignment())
            if !accept(",") { break }
        }
        try expect("}")
        return .list(items, line: line)
    }

    // MARK: Statements

    private mutating func statements(until terminator: String) throws -> [Stmt] {
        var out: [Stmt] = []
        while !current.is(terminator), current.kind != .end { out.append(try statement()) }
        return out
    }

    private mutating func startsDeclaration() -> Bool {
        var k = 0
        while peek(k).kind == .identifier, ["static", "const"].contains(peek(k).text)
                || Self.ignoredModifiers.contains(peek(k).text) {
            k += 1
        }
        // `float3 x` but not `float3(…)` (a constructor expression).
        return isTypeName(peek(k)) && peek(k + 1).kind == .identifier
    }

    private mutating func statement() throws -> Stmt {
        let line = current.line
        if accept(";") { return .empty }
        if current.is("{") {
            _ = advance()
            let body = try statements(until: "}")
            try expect("}")
            return .block(body)
        }
        if current.kind == .identifier {
            switch current.text {
            case "if":
                _ = advance()
                try expect("(")
                let condition = try expression()
                try expect(")")
                let then = try statement()
                var otherwise: Stmt?
                if current.kind == .identifier, current.text == "else" {
                    _ = advance()
                    otherwise = try statement()
                }
                return .ifElse(condition, then, otherwise)
            case "for":
                _ = advance()
                try expect("(")
                var initial: Stmt?
                if !current.is(";") {
                    initial = startsDeclaration() ? try declarationStatement() : .expression(try expression())
                    if case .declaration = initial {} else { try expect(";") }
                } else {
                    _ = advance()
                }
                let condition = current.is(";") ? nil : try expression()
                try expect(";")
                let step = current.is(")") ? nil : try expression()
                try expect(")")
                return .forLoop(initial, condition, step, try statement())
            case "while":
                _ = advance()
                try expect("(")
                let condition = try expression()
                try expect(")")
                return .whileLoop(condition, try statement())
            case "do":
                _ = advance()
                let body = try statement()
                guard current.text == "while" else { throw ShaderError.syntax("expected while", line) }
                _ = advance()
                try expect("(")
                let condition = try expression()
                try expect(")")
                _ = accept(";")
                return .doWhile(body, condition)
            case "return":
                _ = advance()
                let value = current.is(";") ? nil : try expression()
                try expect(";")
                return .returnValue(value, line: line)
            case "break":
                _ = advance(); _ = accept(";"); return .breakLoop
            case "continue":
                _ = advance(); _ = accept(";"); return .continueLoop
            case "discard":
                _ = advance(); _ = accept(";"); return .discard
            default:
                break
            }
            // `[unroll]` / `[loop]` attributes come as "[" identifier "]" before a loop.
        }
        if current.is("["), peek(1).kind == .identifier, peek(2).is("]") || peek(2).is("(") {
            while !current.is("]"), current.kind != .end { _ = advance() }
            _ = advance()
            return try statement()
        }
        if startsDeclaration() { return try declarationStatement() }
        let e = try expression()
        try expect(";")
        return .expression(e)
    }

    private mutating func declarationStatement() throws -> Stmt {
        let line = current.line
        var isStatic = false, isConst = false
        while current.kind == .identifier {
            if current.text == "static" { isStatic = true; _ = advance() }
            else if current.text == "const" { isConst = true; _ = advance() }
            else if Self.ignoredModifiers.contains(current.text) { _ = advance() }
            else { break }
        }
        let type = try parseType()
        let name = try identifier()
        return .declaration(try declaration(type: type, firstName: name, isStatic: isStatic, isConst: isConst, line: line))
    }

    // MARK: Expressions

    mutating func expression() throws -> Expr {
        var e = try assignment()
        while current.is(",") {
            let line = advance().line
            e = .comma(e, try assignment(), line: line)
        }
        return e
    }

    private static let assignmentOperators: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
                                                           "<<=", ">>="]

    private mutating func assignment() throws -> Expr {
        let target = try ternary()
        if current.kind == .symbol, Self.assignmentOperators.contains(current.text) {
            let op = advance()
            let value = current.is("{") ? try initializerList() : try assignment()
            return .assign(op.text, target, value, line: op.line)
        }
        return target
    }

    private mutating func ternary() throws -> Expr {
        let condition = try binary(0)
        guard current.is("?") else { return condition }
        let line = advance().line
        let a = try assignment()
        try expect(":")
        let b = try assignment()
        return .ternary(condition, a, b, line: line)
    }

    private static let precedence: [[String]] = [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"],
        ["*", "/", "%"],
    ]

    private mutating func binary(_ level: Int) throws -> Expr {
        guard level < Self.precedence.count else { return try unary() }
        var left = try binary(level + 1)
        while current.kind == .symbol, Self.precedence[level].contains(current.text) {
            let op = advance()
            let right = try binary(level + 1)
            left = .binary(op.text, left, right, line: op.line)
        }
        return left
    }

    private mutating func unary() throws -> Expr {
        let t = current
        if t.kind == .symbol, ["-", "+", "!", "~", "++", "--"].contains(t.text) {
            _ = advance()
            return .unary(t.text, try unary(), line: t.line)
        }
        // Cast: `(float3) x`.
        if t.is("("), isTypeName(peek(1)), peek(2).is(")") {
            _ = advance()
            let type = try parseType()
            try expect(")")
            return .cast(type, try unary(), line: t.line)
        }
        return try postfix(try primary())
    }

    private mutating func postfix(_ base: Expr) throws -> Expr {
        var e = base
        while true {
            let t = current
            if accept(".") {
                e = .member(e, try identifier(), line: t.line)
            } else if accept("[") {
                let index = try expression()
                try expect("]")
                e = .index(e, index, line: t.line)
            } else if t.is("++") || t.is("--") {
                _ = advance()
                e = .postfix(t.text, e, line: t.line)
            } else {
                return e
            }
        }
    }

    private mutating func primary() throws -> Expr {
        let t = advance()
        switch t.kind {
        case .number:
            return .number(t.text, line: t.line)
        case .identifier:
            if t.text == "true" || t.text == "false" { return .boolean(t.text == "true", line: t.line) }
            if current.is("(") {
                _ = advance()
                var args: [Expr] = []
                if !current.is(")") {
                    repeat { args.append(try assignment()) } while accept(",")
                }
                try expect(")")
                if let type = HType(name: t.text), type.isNumeric { return .construct(type, args, line: t.line) }
                return .call(t.text, args, line: t.line)
            }
            return .identifier(t.text, line: t.line)
        case .symbol where t.text == "(":
            let e = try expression()
            try expect(")")
            return e
        default:
            throw ShaderError.syntax("unexpected \(t)", t.line)
        }
    }
}
