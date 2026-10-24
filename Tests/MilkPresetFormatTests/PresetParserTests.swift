import Foundation
import Testing
@testable import MilkPresetFormat

struct PresetParserTests {
    private func sample() throws -> PresetModel {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "milk", subdirectory: "Fixtures"))
        return try PresetModel(contentsOf: url)
    }

    @Test func readsVersionsAndSettings() throws {
        let preset = try sample()
        #expect(preset.version == 201)
        #expect(preset.warpShaderVersion == 2)
        #expect(preset.compositeShaderVersion == 3)
        #expect(preset.value("fDecay") == 0.98)
        #expect(preset.value("nwavemode") == 6)
        #expect(preset.value("wave_r") == 0.65)
        #expect(preset.value("wave_mode") == 2)
    }

    @Test func joinsEquationsInLineOrder() throws {
        let preset = try sample()
        #expect(preset.perFrameInit == "q1 = 0;")
        #expect(preset.perFrame == "zoom = zoom + 0.02*bass;\nrot = rot + 0.01*sin(time);")
        #expect(preset.perPixel == "zoom = zoom + rad*0.01;")
    }

    @Test func readsCustomWavesAndShapes() throws {
        let preset = try sample()
        #expect(preset.waves.count == 4)
        #expect(preset.waves[0].enabled)
        #expect(preset.waves[0].values["samples"] == 512)
        #expect(preset.waves[0].initCode == "t1 = 0;")
        #expect(preset.waves[0].perFrame == "r = 0.5 + 0.5*sin(time);")
        #expect(preset.waves[0].perPoint == "x = sample;\ny = 0.5 + value1;")
        #expect(!preset.waves[1].enabled)
        #expect(preset.shapes[2].enabled)
        #expect(preset.shapes[2].values["sides"] == 5)
        #expect(preset.shapes[2].perFrame == "ang = time;")
    }

    @Test func stripsShaderBackticks() throws {
        let preset = try sample()
        #expect(preset.warpShader == "shader_body\n{\n    ret = tex2D(sampler_main, uv).xyz;\n}")
        #expect(preset.compositeShader?.hasSuffix("* 1.2;\n}") == true)
    }

    @Test func numbersLinesNumericallyNotLexically() throws {
        let preset = try PresetModel(text: "per_frame_10=b=2;\nper_frame_2=a=1;\n")
        #expect(preset.perFrame == "a=1;\nb=2;")
    }

    @Test func milkDrop1FileHasNoShaders() throws {
        let preset = try PresetModel(text: "[preset00]\r\nzoom=1.0\r\nper_frame_1=rot=0.1;\r\n")
        #expect(preset.version == 100)
        #expect(preset.warpShader == nil)
        #expect(preset.warpShaderVersion == 0)
        #expect(preset.perFrame == "rot=0.1;")
    }

    @Test func readsWindows1252() throws {
        // 0xE9 is "é" in Windows-1252 and invalid UTF-8 on its own.
        var data = Data("[preset00]\nzoom=1\nauthor=Caf".utf8)
        data.append(0xE9)
        let preset = try PresetModel(data: data)
        #expect(preset.strings["author"] == "Café")
    }

    @Test func rejectsEmptyFile() {
        #expect(throws: PresetParseError.empty) { try PresetModel(text: "[preset00]\n\n") }
    }
}
