import Foundation

/// Compiles an `Expr` to a closure tree over `EELMemory`. Variables are resolved to slots here, once.
enum Compiler {
    typealias Node = @Sendable (EELMemory) -> Double

    /// Bounds `loop` and `while`, as ns-eel2 does, so a bad preset can't hang a frame.
    static let maxIterations = 1_048_576

    static func compile(_ expr: Expr, table: inout EELVariableTable) throws -> Node {
        switch expr {
        case .number(let v):
            return { _ in v }

        case .variable(let name, _):
            if let register = EELShared.register(name) {
                return { $0.shared.registers[register] }
            }
            let slot = table.slot(for: name)
            return { $0.values[slot] }

        case .sequence(let items):
            let nodes = try items.map { try compile($0, table: &table) }
            return { m in
                var last = 0.0
                for node in nodes { last = node(m) }
                return last
            }

        case .unary(let op, let operand):
            let a = try compile(operand, table: &table)
            switch op {
            case "-": return { -a($0) }
            default: return { EELQuirks.isTrue(a($0)) ? 0 : 1 }  // "!"
            }

        case .binary(let op, let lhs, let rhs):
            return try binary(op, try compile(lhs, table: &table), try compile(rhs, table: &table))

        case .and(let lhs, let rhs):
            let a = try compile(lhs, table: &table), b = try compile(rhs, table: &table)
            return { m in EELQuirks.isTrue(a(m)) && EELQuirks.isTrue(b(m)) ? 1 : 0 }

        case .or(let lhs, let rhs):
            let a = try compile(lhs, table: &table), b = try compile(rhs, table: &table)
            return { m in EELQuirks.isTrue(a(m)) || EELQuirks.isTrue(b(m)) ? 1 : 0 }

        case .ternary(let c, let x, let y):
            let cond = try compile(c, table: &table), a = try compile(x, table: &table), b = try compile(y, table: &table)
            return { m in EELQuirks.isTrue(cond(m)) ? a(m) : b(m) }

        case .assign(let op, let target, let value, _):
            return try assign(op, target, try compile(value, table: &table), table: &table)

        case .call(let name, let args, _):
            return try call(name, args, table: &table)
        }
    }

    private static func binary(_ op: String, _ a: @escaping Node, _ b: @escaping Node) throws -> Node {
        guard let f = operation(op) else { throw EELCompileError.syntax(message: "unknown operator \(op)", offset: 0) }
        return { m in f(a(m), b(m)) }
    }

    /// The arithmetic behind a binary operator or a compound assignment (`+=` uses `+`).
    private static func operation(_ op: String) -> (@Sendable (Double, Double) -> Double)? {
        switch op {
        case "+": { $0 + $1 }
        case "-": { $0 - $1 }
        case "*": { $0 * $1 }
        case "/": { EELQuirks.divide($0, $1) }
        case "%": { EELQuirks.modulo($0, $1) }
        case "^": { pow($0, $1) }
        case "|": { Double(EELQuirks.toInt($0) | EELQuirks.toInt($1)) }
        case "&": { Double(EELQuirks.toInt($0) & EELQuirks.toInt($1)) }
        case "==": { abs($0 - $1) < EELQuirks.closeFactor ? 1 : 0 }
        case "!=": { abs($0 - $1) < EELQuirks.closeFactor ? 0 : 1 }
        case "<": { $0 < $1 ? 1 : 0 }
        case ">": { $0 > $1 ? 1 : 0 }
        case "<=": { $0 <= $1 ? 1 : 0 }
        case ">=": { $0 >= $1 ? 1 : 0 }
        default: nil
        }
    }

    private static func assign(_ op: String, _ target: Expr, _ value: @escaping Node,
                               table: inout EELVariableTable) throws -> Node {
        let combine: (@Sendable (Double, Double) -> Double)?
        if op == "=" {
            combine = nil
        } else {
            guard let f = operation(String(op.dropLast())) else {
                throw EELCompileError.syntax(message: "unknown operator \(op)", offset: 0)
            }
            combine = f
        }
        switch target {
        case .variable(let name, _) where EELShared.register(name) != nil:
            let register = EELShared.register(name)!
            return { m in
                let v = combine.map { $0(m.shared.registers[register], value(m)) } ?? value(m)
                m.shared.registers[register] = v
                return v
            }
        case .variable(let name, _):
            let slot = table.slot(for: name)
            if let combine {
                return { m in
                    let v = combine(m.values[slot], value(m))
                    m.values[slot] = v
                    return v
                }
            }
            return { m in
                let v = value(m)
                m.values[slot] = v
                return v
            }
        case .call(let name, let args, _):
            guard args.count == 1 else {
                throw EELCompileError.wrongArgumentCount(function: name, expected: 1, got: args.count)
            }
            let index = try compile(args[0], table: &table)
            let global = name == "gmegabuf"
            return { m in
                let i = index(m)
                let old = global ? m.shared.gmegabuf.read(i) : m.megabuf.read(i)
                let v = combine.map { $0(old, value(m)) } ?? value(m)
                if global { m.shared.gmegabuf.write(i, v) } else { m.megabuf.write(i, v) }
                return v
            }
        default:
            throw EELCompileError.notAssignable(offset: 0)
        }
    }

    private static let unaryFunctions: [String: @Sendable (Double) -> Double] = [
        "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
        "sqr": { $0 * $0 },
        "sqrt": { sqrt(abs($0)) },
        "invsqrt": { $0 == 0 ? 0 : 1 / sqrt(abs($0)) },
        "exp": exp, "log": log, "log10": log10,
        "abs": { abs($0) },
        "sign": { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) },
        "int": { Double(EELQuirks.toInt($0)) },
        "floor": { floor($0) },
        "ceil": { ceil($0) },
        "bnot": { EELQuirks.isTrue($0) ? 0 : 1 },
        // ns-eel1 names some old presets still call.
        "_not": { EELQuirks.isTrue($0) ? 0 : 1 },
        "_neg": { -$0 },
    ]

    private static let binaryFunctions: [String: @Sendable (Double, Double) -> Double] = [
        "atan2": atan2,
        "pow": pow,
        "min": { min($0, $1) },
        "max": { max($0, $1) },
        "above": { $0 > $1 ? 1 : 0 },
        "below": { $0 < $1 ? 1 : 0 },
        "equal": { abs($0 - $1) < EELQuirks.closeFactor ? 1 : 0 },
        "band": { EELQuirks.isTrue($0) && EELQuirks.isTrue($1) ? 1 : 0 },
        "bor": { EELQuirks.isTrue($0) || EELQuirks.isTrue($1) ? 1 : 0 },
        // ns-eel1 names some old presets still call.
        "_above": { $0 > $1 ? 1 : 0 },
        "_below": { $0 < $1 ? 1 : 0 },
        "_aboeq": { $0 >= $1 ? 1 : 0 },
        "_beleq": { $0 <= $1 ? 1 : 0 },
        "_equal": { abs($0 - $1) < EELQuirks.closeFactor ? 1 : 0 },
        "_noteq": { abs($0 - $1) < EELQuirks.closeFactor ? 0 : 1 },
        "_and": { EELQuirks.isTrue($0) && EELQuirks.isTrue($1) ? 1 : 0 },
        "_or": { EELQuirks.isTrue($0) || EELQuirks.isTrue($1) ? 1 : 0 },
        "sigmoid": { x, constraint in
            let t = 1 + exp(-x * constraint)
            return abs(t) > EELQuirks.closeFactor ? 1 / t : 0
        },
    ]

    private static func call(_ name: String, _ args: [Expr], table: inout EELVariableTable) throws -> Node {
        func arity(_ n: Int) throws {
            guard args.count == n else { throw EELCompileError.wrongArgumentCount(function: name, expected: n, got: args.count) }
        }
        let nodes = try args.map { try compile($0, table: &table) }

        if let f = unaryFunctions[name] {
            try arity(1)
            let a = nodes[0]
            return { f(a($0)) }
        }
        if let f = binaryFunctions[name] {
            try arity(2)
            let a = nodes[0], b = nodes[1]
            return { m in f(a(m), b(m)) }
        }
        switch name {
        case "assign":
            // assign(dest, value) is `dest = value`.
            try arity(2)
            return try assign("=", args[0], nodes[1], table: &table)
        case "if":
            // Lazy: only the chosen branch runs.
            try arity(3)
            let c = nodes[0], a = nodes[1], b = nodes[2]
            return { m in EELQuirks.isTrue(c(m)) ? a(m) : b(m) }
        case "rand":
            // MilkDrop's rand(n) is an integer in [0, n), with n below 1 treated as 1.
            try arity(1)
            let a = nodes[0]
            return { m in
                let n = max(1, floor(a(m)))
                return floor(m.nextRandom() * n)
            }
        case "loop":
            try arity(2)
            let count = nodes[0], body = nodes[1]
            return { m in
                let n = min(Int(EELQuirks.toInt(count(m))), maxIterations)
                var last = 0.0
                if n > 0 { for _ in 0..<n { last = body(m) } }
                return last
            }
        case "while":
            // ns-eel2's while(expr) runs expr until it returns false.
            try arity(1)
            let body = nodes[0]
            return { m in
                var n = 0
                while EELQuirks.isTrue(body(m)), n < maxIterations { n += 1 }
                return 0
            }
        case "megabuf", "gmegabuf":
            try arity(1)
            let index = nodes[0]
            let global = name == "gmegabuf"
            return { m in global ? m.shared.gmegabuf.read(index(m)) : m.megabuf.read(index(m)) }
        case "exec2", "exec3":
            try arity(name == "exec2" ? 2 : 3)
            return { m in
                var last = 0.0
                for node in nodes { last = node(m) }
                return last
            }
        case "freembuf":
            try arity(1)
            let a = nodes[0]
            return { a($0) }
        default:
            throw EELCompileError.unknownFunction(name)
        }
    }
}
