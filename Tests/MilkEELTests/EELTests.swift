import Foundation
import Testing
@testable import MilkEEL

/// Compiles `source`, runs it once on fresh memory, and returns the memory and table.
private func run(_ source: String, setup: [String: Double] = [:], seed: UInt64 = 1) throws
    -> (EELMemory, EELVariableTable) {
    var table = EELVariableTable()
    for (k, v) in setup { table[k] = v }
    let program = try EELProgram(source: source, table: &table)
    let memory = EELMemory(table: table, seed: seed)
    program.run(memory)
    return (memory, table)
}

/// The value of `name` after running `source`.
private func value(_ name: String, after source: String, setup: [String: Double] = [:]) throws -> Double {
    let (memory, table) = try run(source, setup: setup)
    return memory[try #require(table.existingSlot(for: name))]
}

/// The value of a single expression.
private func eval(_ expression: String) throws -> Double {
    try value("result", after: "result = \(expression);")
}

struct EELVariableTests {
    @Test func variablesAreCaseInsensitiveAndStartAtZero() {
        var table = EELVariableTable()
        #expect(table["Zoom"] == 0)
        let slot = table.slot(for: "zoom")
        table["ZOOM"] = 1.5
        #expect(table.values[slot] == 1.5)
        #expect(table.slot(for: "Zoom") == slot)
    }

    @Test func emptySourceCompiles() throws {
        var table = EELVariableTable()
        let program = try EELProgram(source: " \n// nothing\n;;", table: &table)
        #expect(program.isEmpty)
    }

    @Test func initialValuesReachMemory() throws {
        #expect(try value("zoom", after: "zoom = zoom * 2;", setup: ["zoom": 1.5]) == 3)
    }

    @Test func unknownVariablesAreCreatedAsZero() throws {
        #expect(try value("b", after: "b = a + 1;") == 1)
    }
}

struct EELArithmeticTests {
    @Test func precedence() throws {
        #expect(try eval("1 + 2 * 3") == 7)
        #expect(try eval("(1 + 2) * 3") == 9)
        #expect(try eval("-2 ^ 2") == -4)  // ^ binds tighter than unary minus
        #expect(try eval("2 ^ 3 ^ 2") == 512)  // right-associative
        #expect(try eval("10 - 4 - 3") == 3)
        #expect(try eval("1 + 2 < 4") == 1)
    }

    @Test func numberForms() throws {
        #expect(try eval(".5") == 0.5)
        #expect(try eval("1e3") == 1000)
        #expect(try eval("0x10") == 16)
        #expect(try eval("$pi") == Double.pi)
    }

    @Test func divisionByZeroIsZero() throws {
        #expect(EELQuirks.divide(1, 0) == 0)
        #expect(try eval("1 / 0") == 0)
        #expect(try eval("5 % 0") == 0)
    }

    @Test func moduloAndBitwiseAreIntegers() throws {
        #expect(try eval("7.9 % 3") == 1)
        #expect(try eval("5 | 2") == 7)
        #expect(try eval("6 & 3") == 2)
        #expect(try eval("(0/0) | 1") == 1)  // NaN converts to 0 instead of trapping
    }

    @Test func comparisonsUseATolerance() throws {
        #expect(try eval("1 == 1.000001") == 1)
        #expect(try eval("1 != 1.1") == 1)
        #expect(try eval("equal(0.3, 0.1 + 0.2)") == 1)
    }

    @Test func logicShortCircuits() throws {
        #expect(try value("a", after: "0 && (a = 1);") == 0)
        #expect(try value("a", after: "1 || (a = 1);") == 0)
        #expect(try eval("!0") == 1)
        #expect(try eval("1 ? 2 : 3") == 2)
    }

    @Test func compoundAssignment() throws {
        #expect(try value("a", after: "a = 2; a += 3; a *= 4; a -= 1; a /= 2;") == 9.5)
        #expect(try value("a", after: "a = b = 4;") == 4)
    }

    @Test func statementSequencesInParentheses() throws {
        #expect(try eval("(a = 2; a * 3)") == 6)
    }

    @Test func comments() throws {
        #expect(try value("a", after: "a = 1; // a = 2;\n/* a = 3; */ a += 1;") == 2)
    }
}

struct EELFunctionTests {
    @Test func math() throws {
        #expect(try eval("sqr(3)") == 9)
        #expect(try eval("sqrt(-16)") == 4)  // ns-eel2 takes the absolute value
        #expect(try eval("pow(2, 10)") == 1024)
        #expect(try eval("min(3, -1)") == -1)
        #expect(try eval("max(3, -1)") == 3)
        #expect(try eval("abs(-2.5)") == 2.5)
        #expect(try eval("sign(-3)") == -1)
        #expect(try eval("int(-2.7)") == -2)  // truncates toward zero
        #expect(try eval("floor(-2.5)") == -3)
        #expect(abs(try eval("atan2(1, 1)") - Double.pi / 4) < 1e-12)
    }

    @Test func comparisonsAndBooleans() throws {
        #expect(try eval("above(2, 1)") == 1)
        #expect(try eval("below(2, 1)") == 0)
        #expect(try eval("bnot(0)") == 1)
        #expect(try eval("band(1, 0)") == 0)
        #expect(try eval("bor(1, 0)") == 1)
        #expect(try eval("sigmoid(0, 1)") == 0.5)
    }

    @Test func oldCompatibilityNames() throws {
        #expect(try eval("_aboeq(1, 1)") == 1)
        #expect(try eval("_beleq(2, 1)") == 0)
        #expect(try eval("_noteq(2, 1)") == 1)
        #expect(try eval("_and(1, 1) + _or(0, 0) + _not(0)") == 2)
        #expect(try value("a", after: "assign(a, 3);") == 3)
    }

    @Test func ifRunsOnlyTheChosenBranch() throws {
        #expect(try value("b", after: "if(1, a = 1, b = 1);") == 0)
        #expect(try eval("if(0, 1, 2)") == 2)
    }

    @Test func randIsAnIntegerBelowN() throws {
        let (memory, table) = try run("loop(1000, (r = rand(10); bad += r < 0 || r >= 10 || r != int(r)));")
        #expect(memory[try #require(table.existingSlot(for: "bad"))] == 0)
    }

    @Test func randIsDeterministicForASeed() throws {
        let source = "a = rand(1000000); b = rand(1000000);"
        let (m1, t) = try run(source, seed: 42)
        let (m2, _) = try run(source, seed: 42)
        let (m3, _) = try run(source, seed: 43)
        let a = try #require(t.existingSlot(for: "a"))
        #expect(m1[a] == m2[a])
        #expect(m1[a] != m3[a])
    }

    @Test func loopsAndWhile() throws {
        #expect(try value("n", after: "loop(5, n += 2);") == 10)
        #expect(try value("n", after: "while(n += 1; n < 7);") == 7)
    }

    @Test func megabuf() throws {
        #expect(try value("x", after: "megabuf(10) = 3; megabuf(10) += 1; x = megabuf(10) + megabuf(11);") == 4)
        #expect(try value("x", after: "gmegabuf(5) = 2; x = gmegabuf(5);") == 2)
    }
}

struct EELErrorTests {
    @Test func unknownFunction() {
        var table = EELVariableTable()
        #expect(throws: EELCompileError.unknownFunction("nosuch")) {
            try EELProgram(source: "a = nosuch(1);", table: &table)
        }
    }

    @Test func wrongArgumentCount() {
        var table = EELVariableTable()
        #expect(throws: EELCompileError.wrongArgumentCount(function: "sin", expected: 1, got: 2)) {
            try EELProgram(source: "a = sin(1, 2);", table: &table)
        }
    }

    @Test func syntaxErrors() {
        var table = EELVariableTable()
        #expect(throws: EELCompileError.self) { try EELProgram(source: "a = (1 + ;", table: &table) }
        #expect(throws: EELCompileError.self) { try EELProgram(source: "1 = a;", table: &table) }
        #expect(throws: EELCompileError.self) { try EELProgram(source: "a = 1 @ 2;", table: &table) }
    }
}
