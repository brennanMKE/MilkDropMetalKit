import Foundation

/// A failure translating a preset shader. The renderer falls back to its fixed-function pass and reports it.
public enum ShaderError: Error, Equatable, CustomStringConvertible {
    case syntax(String, Int)
    case semantic(String, Int)
    case unsupported(String)

    public var description: String {
        switch self {
        case .syntax(let message, let line): "line \(line): \(message)"
        case .semantic(let message, let line): "line \(line): \(message)"
        case .unsupported(let message): message
        }
    }
}

/// HLSL types as MilkDrop shaders use them. `half` and `double` are read as `float`; `float1` is `float`.
indirect enum HType: Equatable, Sendable, CustomStringConvertible {
    enum Scalar: Int, Comparable, Sendable {
        case bool, int, uint, float

        static func < (a: Scalar, b: Scalar) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .bool: "bool"
            case .int: "int"
            case .uint: "uint"
            case .float: "float"
            }
        }
    }

    case void
    case scalar(Scalar)
    /// 2…4 components.
    case vector(Scalar, Int)
    /// HLSL rows × columns. Stored transposed in MSL, so `floatRxC` keeps its spelling (see `Emitter`).
    case matrix(Scalar, Int, Int)
    case sampler2D
    case sampler3D
    case array(HType, Int)

    static let float = HType.scalar(.float)
    static let int = HType.scalar(.int)
    static let bool = HType.scalar(.bool)
    static func float(_ n: Int) -> HType { n == 1 ? .float : .vector(.float, n) }

    var scalarKind: Scalar? {
        switch self {
        case .scalar(let s), .vector(let s, _), .matrix(let s, _, _): s
        default: nil
        }
    }

    /// Components of a numeric type; 0 for anything else.
    var count: Int {
        switch self {
        case .scalar: 1
        case .vector(_, let n): n
        case .matrix(_, let r, let c): r * c
        default: 0
        }
    }

    var isNumeric: Bool { scalarKind != nil }
    var isSampler: Bool { self == .sampler2D || self == .sampler3D }
    var isMatrix: Bool { if case .matrix = self { true } else { false } }

    func with(_ kind: Scalar) -> HType {
        switch self {
        case .scalar: .scalar(kind)
        case .vector(_, let n): .vector(kind, n)
        case .matrix(_, let r, let c): .matrix(kind, r, c)
        default: self
        }
    }

    /// The MSL spelling.
    var description: String {
        switch self {
        case .void: "void"
        case .scalar(let s): s.name
        case .vector(let s, let n): "\(s.name)\(n)"
        case .matrix(let s, let r, let c): "\(s == .float ? "float" : s.name)\(r)x\(c)"
        case .sampler2D: "sampler2D"
        case .sampler3D: "sampler3D"
        case .array(let t, let n): "\(t)[\(n)]"
        }
    }

    /// Parses an HLSL type name (`float3`, `half2x2`, `int`, `sampler2D`, …).
    init?(name: String) {
        switch name {
        case "void": self = .void
        case "sampler", "sampler2D", "texture", "texture2D": self = .sampler2D
        case "sampler3D", "texture3D", "samplerCUBE": self = .sampler3D
        default:
            let bases: [(String, Scalar)] = [("float", .float), ("half", .float), ("double", .float),
                                             ("min16float", .float), ("int", .int), ("uint", .uint),
                                             ("dword", .uint), ("bool", .bool)]
            guard let (base, kind) = bases.first(where: { name.hasPrefix($0.0) }) else { return nil }
            let rest = name.dropFirst(base.count)
            if rest.isEmpty { self = .scalar(kind); return }
            let digits = rest.split(separator: "x")
            if digits.count == 1, let n = Int(digits[0]), (1...4).contains(n) {
                self = n == 1 ? .scalar(kind) : .vector(kind, n)
            } else if digits.count == 2, let r = Int(digits[0]), let c = Int(digits[1]), (1...4).contains(r),
                      (1...4).contains(c) {
                self = .matrix(kind, r, c)
            } else {
                return nil
            }
        }
    }
}

/// Expressions, as parsed (untyped).
indirect enum Expr {
    case number(String, line: Int)
    case boolean(Bool, line: Int)
    case identifier(String, line: Int)
    case unary(String, Expr, line: Int)
    /// `x++` / `x--`.
    case postfix(String, Expr, line: Int)
    case binary(String, Expr, Expr, line: Int)
    case assign(String, Expr, Expr, line: Int)
    case ternary(Expr, Expr, Expr, line: Int)
    case call(String, [Expr], line: Int)
    /// `float3(…)`.
    case construct(HType, [Expr], line: Int)
    case cast(HType, Expr, line: Int)
    case member(Expr, String, line: Int)
    case index(Expr, Expr, line: Int)
    /// `{ a, b, c }`, only in initialisers.
    case list([Expr], line: Int)
    case comma(Expr, Expr, line: Int)

    var line: Int {
        switch self {
        case .number(_, let l), .boolean(_, let l), .identifier(_, let l), .unary(_, _, let l),
             .postfix(_, _, let l), .binary(_, _, _, let l), .assign(_, _, _, let l), .ternary(_, _, _, let l),
             .call(_, _, let l), .construct(_, _, let l), .cast(_, _, let l), .member(_, _, let l),
             .index(_, _, let l), .list(_, let l), .comma(_, _, let l):
            l
        }
    }
}

struct Declarator {
    var name: String
    var arraySize: Int?
    var initializer: Expr?
}

struct Declaration {
    var isStatic: Bool
    var isConst: Bool
    var type: HType
    var declarators: [Declarator]
    var line: Int
}

indirect enum Stmt {
    case block([Stmt])
    case declaration(Declaration)
    case expression(Expr)
    case ifElse(Expr, Stmt, Stmt?)
    case forLoop(Stmt?, Expr?, Expr?, Stmt)
    case whileLoop(Expr, Stmt)
    case doWhile(Stmt, Expr)
    case returnValue(Expr?, line: Int)
    case breakLoop
    case continueLoop
    case discard
    case empty
}

struct Parameter {
    enum Direction { case `in`, out, `inout` }
    var direction: Direction
    var type: HType
    var name: String
    var arraySize: Int?
}

struct Function {
    var returnType: HType
    var name: String
    var parameters: [Parameter]
    /// nil for a prototype.
    var body: [Stmt]?
    var line: Int
}

/// A parsed preset shader: global declarations and functions, then the `shader_body`.
struct ShaderProgram {
    enum Global {
        case declaration(Declaration)
        case function(Function)
    }

    var globals: [Global]
    var body: [Stmt]
}
