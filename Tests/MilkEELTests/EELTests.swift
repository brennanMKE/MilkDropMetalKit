import Testing
@testable import MilkEEL

struct EELTests {
    @Test func variablesAreCaseInsensitiveAndStartAtZero() {
        var table = EELVariableTable()
        #expect(table["Zoom"] == 0)
        let slot = table.slot(for: "zoom")
        table["ZOOM"] = 1.5
        #expect(table.values[slot] == 1.5)
        #expect(table.slot(for: "Zoom") == slot)
    }

    @Test func divisionByZeroIsZero() {
        #expect(EELQuirks.divide(1, 0) == 0)
        #expect(EELQuirks.divide(1, 4) == 0.25)
    }

    @Test func emptySourceCompiles() throws {
        var table = EELVariableTable()
        _ = try EELProgram(source: " \n", table: &table)
    }
}
