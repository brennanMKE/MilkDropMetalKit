/// Nullsoft EEL (ns-eel2), the expression language of MilkDrop equations.
///
/// Plan (handoff §5.1): parse once at preset load into an AST, resolve every variable to a slot in a flat
/// `[Double]` table, and compile to a closure tree or register bytecode. No string lookups per frame. Evaluation
/// is deterministic for a given seed so golden-image tests are stable.
///
/// Status: API shape only. Milestone 1 fills in the lexer, parser and evaluator.

/// Variables of one evaluation context (a preset's per-frame state, a wave's per-point state, …).
/// Names resolve to slots at compile time; programs read and write `values` by index.
public struct EELVariableTable: Sendable {
    public private(set) var names: [String] = []
    public var values: [Double] = []
    private var slots: [String: Int] = [:]

    public init() {}

    /// The slot for `name` (case-insensitive, as in ns-eel2), created as 0 on first use.
    public mutating func slot(for name: String) -> Int {
        let key = name.lowercased()
        if let slot = slots[key] { return slot }
        let slot = names.count
        names.append(key)
        values.append(0)
        slots[key] = slot
        return slot
    }

    public subscript(name: String) -> Double {
        get { slots[name.lowercased()].map { values[$0] } ?? 0 }
        set { values[slot(for: name)] = newValue }
    }
}

public enum EELCompileError: Error, Equatable {
    case notImplemented
    case syntax(message: String, offset: Int)
    case unknownFunction(String)
}

/// A compiled block of `;`-separated statements.
public struct EELProgram: Sendable {
    public let source: String

    /// Compiles `source`, adding any variables it uses to `table`.
    public init(source: String, table: inout EELVariableTable) throws {
        self.source = source
        if source.allSatisfy(\.isWhitespace) { return }
        throw EELCompileError.notImplemented
    }

    /// Runs the program against `values` (the table's storage).
    public func run(_ values: inout [Double]) {}
}

/// Arithmetic rules presets depend on. Collect new ones here, each with a test, as they are found.
public enum EELQuirks {
    /// `x / 0` is 0, not ±inf or NaN.
    @inlinable public static func divide(_ a: Double, _ b: Double) -> Double { b == 0 ? 0 : a / b }
    /// `equal`, `above` and `below` compare with this tolerance.
    public static let comparisonEpsilon = 0.00001
}
