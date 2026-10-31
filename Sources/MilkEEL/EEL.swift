/// Nullsoft EEL (ns-eel2), the expression language of MilkDrop equations.
///
/// Source is parsed once into an AST (`Parser`), every variable is resolved to a slot in a flat table, and the AST
/// is compiled to a closure tree (`Compiler`) that reads and writes an `EELMemory`. No string lookups at run time.
/// Evaluation is deterministic for a given seed so golden-image tests are stable.

/// The variables of one evaluation context (a preset's equations, a wave's per-point code, …). Names resolve to
/// slots at compile time. `values` holds each slot's initial value; `EELMemory` is the run-time storage.
package struct EELVariableTable: Sendable {
    package private(set) var names: [String] = []
    package var values: [Double] = []
    private var slots: [String: Int] = [:]

    package init() {}

    package var count: Int { names.count }

    /// The slot for `name` (case-insensitive, as in ns-eel2), created as 0 on first use.
    package mutating func slot(for name: String) -> Int {
        let key = name.lowercased()
        if let slot = slots[key] { return slot }
        let slot = names.count
        names.append(key)
        values.append(0)
        slots[key] = slot
        return slot
    }

    /// The slot for `name` if anything has used it.
    package func existingSlot(for name: String) -> Int? {
        slots[name.lowercased()]
    }

    package subscript(name: String) -> Double {
        get { slots[name.lowercased()].map { values[$0] } ?? 0 }
        set { values[slot(for: name)] = newValue }
    }
}

/// State every context of one preset shares: `gmegabuf` and the global registers `reg00`–`reg99`.
/// Not thread-safe, like `EELMemory`.
package final class EELShared: @unchecked Sendable {
    package static let registerCount = 100
    var gmegabuf = EELBuffer()
    package let registers: UnsafeMutablePointer<Double>

    package init() {
        registers = .allocate(capacity: Self.registerCount)
        registers.initialize(repeating: 0, count: Self.registerCount)
    }

    deinit {
        registers.deallocate()
        gmegabuf.free()
    }

    /// `reg07` → 7. Any other name → nil.
    static func register(_ name: String) -> Int? {
        let lower = name.lowercased()
        guard lower.count == 5, lower.hasPrefix("reg"), let n = Int(lower.dropFirst(3)), n >= 0 else { return nil }
        return n
    }
}

/// Run-time storage for the slots of one `EELVariableTable`, plus the `rand` state and `megabuf`.
/// Not thread-safe: one memory is used by one thread at a time.
package final class EELMemory: @unchecked Sendable {
    package let count: Int
    package let values: UnsafeMutablePointer<Double>
    /// SplitMix64 state for `rand`.
    package var randomState: UInt64
    /// `megabuf`, allocated in blocks on first write.
    var megabuf = EELBuffer()
    /// `gmegabuf` and the registers, shared with the preset's other contexts.
    package let shared: EELShared

    package init(table: EELVariableTable, seed: UInt64 = 1, shared: EELShared = EELShared()) {
        count = table.count
        values = .allocate(capacity: max(count, 1))
        values.initialize(repeating: 0, count: max(count, 1))
        for (i, v) in table.values.enumerated() { values[i] = v }
        randomState = seed
        self.shared = shared
    }

    deinit {
        values.deallocate()
        megabuf.free()
    }

    package subscript(slot: Int) -> Double {
        get { values[slot] }
        set { values[slot] = newValue }
    }

    /// Copies every slot from `other`, which must come from the same table.
    package func copyValues(from other: EELMemory) {
        precondition(other.count == count)
        values.update(from: other.values, count: count)
    }

    func nextRandom() -> Double {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var z = randomState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// ns-eel2's 1M-entry buffers, allocated 64k entries at a time. The owning `EELMemory` frees the blocks.
struct EELBuffer {
    static let size = 1 << 20
    static let blockSize = 1 << 16
    private var blocks: [Int: UnsafeMutablePointer<Double>] = [:]

    func read(_ index: Double) -> Double {
        guard let i = Self.index(index), let block = blocks[i / Self.blockSize] else { return 0 }
        return block[i % Self.blockSize]
    }

    mutating func write(_ index: Double, _ value: Double) {
        guard let i = Self.index(index) else { return }
        let b = i / Self.blockSize
        let block: UnsafeMutablePointer<Double>
        if let existing = blocks[b] {
            block = existing
        } else {
            block = .allocate(capacity: Self.blockSize)
            block.initialize(repeating: 0, count: Self.blockSize)
            blocks[b] = block
        }
        block[i % Self.blockSize] = value
    }

    func free() {
        for block in blocks.values { block.deallocate() }
    }

    private static func index(_ x: Double) -> Int? {
        // ns-eel2 rounds the index (adds a small epsilon and truncates).
        guard x.isFinite else { return nil }
        let i = Int((x + 0.0001).rounded(.down))
        return (0..<size).contains(i) ? i : nil
    }
}

package enum EELCompileError: Error, Equatable, CustomStringConvertible {
    case syntax(message: String, offset: Int)
    case unknownFunction(String)
    case wrongArgumentCount(function: String, expected: Int, got: Int)
    case notAssignable(offset: Int)

    package var description: String {
        switch self {
        case .syntax(let message, let offset): "syntax error at \(offset): \(message)"
        case .unknownFunction(let name): "unknown function \(name)"
        case .wrongArgumentCount(let f, let expected, let got): "\(f) takes \(expected) argument(s), got \(got)"
        case .notAssignable(let offset): "assignment to something that is not a variable at \(offset)"
        }
    }
}

/// A compiled block of `;`-separated statements.
package struct EELProgram: Sendable {
    package let source: String
    let node: Compiler.Node?

    /// Compiles `source`, adding any variables it uses to `table`.
    package init(source: String, table: inout EELVariableTable) throws {
        self.source = source
        var parser = try Parser(source: source)
        guard let ast = try parser.parseProgram() else {
            node = nil
            return
        }
        node = try Compiler.compile(ast, table: &table)
    }

    package var isEmpty: Bool { node == nil }

    /// Runs the program against `memory`, which must have been made from the table it was compiled with (or a
    /// table that grew from it), and returns the value of the last statement.
    @discardableResult
    package func run(_ memory: EELMemory) -> Double {
        node?(memory) ?? 0
    }
}

/// Arithmetic rules presets depend on. Collect new ones here, each with a test, as they are found.
package enum EELQuirks {
    /// `equal`, `==`, `bnot` and truth tests use this tolerance.
    package static let closeFactor = 0.00001

    /// `x / 0` is 0, not ±inf or NaN.
    @inlinable package static func divide(_ a: Double, _ b: Double) -> Double { b == 0 ? 0 : a / b }

    @inlinable package static func isTrue(_ x: Double) -> Bool { abs(x) >= closeFactor }

    /// Truncates toward zero; non-finite values become 0 rather than trapping.
    @inlinable package static func toInt(_ x: Double) -> Int64 {
        guard x.isFinite else { return 0 }
        return Int64(max(min(x, 9.0e18), -9.0e18))
    }

    /// Integer modulo; `x % 0` is 0.
    @inlinable package static func modulo(_ a: Double, _ b: Double) -> Double {
        let bi = toInt(b)
        return bi == 0 ? 0 : Double(toInt(a) % bi)
    }
}
