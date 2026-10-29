import Metal
import Testing
@testable import MilkShaders

struct TranslatorTests {
    private func msl(_ body: String, stage: ShaderStage = .warp) throws -> String {
        try ShaderTranslator.translate(body, stage: stage).metalSource
    }

    /// Translates and compiles with the Metal compiler.
    private func compiles(_ body: String, stage: ShaderStage = .warp) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let shader = try ShaderTranslator.translate(body, stage: stage)
        let library = try device.makeLibrary(source: shader.metalSource, options: nil)
        #expect(library.makeFunction(name: shader.fragmentFunction) != nil)
        #expect(library.makeFunction(name: shader.vertexFunction) != nil)
    }

    @Test func translatesAMinimalWarpShader() throws {
        let source = try msl("shader_body { ret = tex2D(sampler_main, uv).xyz * 0.98; }")
        #expect(source.contains("v_ret = (tex_main.sample(smp_main, v_uv).xyz * 0.98)"))
        try compiles("shader_body { ret = tex2D(sampler_main, uv).xyz * 0.98; }")
    }

    @Test func truncatesAndBroadcastsLikeHLSL() throws {
        // float4 → float3 on assignment, scalar → float3, int → float.
        let source = try msl("shader_body { ret = tex2D(sampler_main, uv); float3 a = 1; float b = a; ret += b; }")
        #expect(source.contains("v_ret = tex_main.sample(smp_main, v_uv).xyz"))
        #expect(source.contains("float3 v_a = float3(1.0)"))
        #expect(source.contains("float v_b = v_a.x"))
        try compiles("shader_body { ret = tex2D(sampler_main, uv); float3 a = 1; float b = a; ret += b; }")
    }

    @Test func mixedVectorSizesTruncateToTheSmaller() throws {
        let source = try msl("shader_body { float4 a = 1; float3 b = 2; ret = a * b; }")
        #expect(source.contains("(v_a.xyz * v_b)"))
    }

    @Test func helperMacrosAndUniforms() throws {
        let source = try msl("shader_body { ret = GetBlur2(uv) * lum(GetPixel(uv)) * q3 + time; }")
        #expect(source.contains("tex_blur2.sample(milk_fc, v_uv)"))
        #expect(source.contains("u.q[0].z"))
        #expect(source.contains("u._c0.x"))
        #expect(try ShaderTranslator.translate("shader_body { ret = GetBlur2(uv); }", stage: .warp).blurLevel == 2)
    }

    @Test func samplerPrefixesPickTheState() throws {
        let source = try msl("shader_body { ret = tex2D(sampler_pw_main, uv).xyz + tex2D(sampler_fc_noise_lq, uv).xyz; }")
        #expect(source.contains("tex_main.sample(milk_pw, v_uv)"))
        #expect(source.contains("tex_noise_lq.sample(milk_fc, v_uv)"))
    }

    @Test func unprefixedSamplerMainWrapsInTheComposite() throws {
        // The composite binds unprefixed sampler_main (and GetPixel) filtered and wrapping, whatever bTexWrap says;
        // the warp keeps the renderer's bTexWrap sampler.
        let text = "shader_body { ret = tex2D(sampler_main, uv * 3).xyz + GetPixel(uv + 1) + tex2D(sampler_fc_main, uv).xyz; }"
        let composite = try msl(text, stage: .composite)
        #expect(composite.contains("tex_main.sample(milk_fw, (v_uv * 3.0))"))
        #expect(composite.contains("tex_main.sample(milk_fw, (v_uv + 1.0))"))
        #expect(composite.contains("tex_main.sample(milk_fc, v_uv)"))
        #expect(!composite.contains("sample(smp_main"))
        let warp = try msl(text, stage: .warp)
        #expect(warp.contains("tex_main.sample(smp_main, (v_uv * 3.0))"))
        #expect(warp.contains("tex_main.sample(milk_fc, v_uv)"))
        try compiles(text, stage: .composite)
    }

    @Test func userTexturesGetSlots() throws {
        let shader = try ShaderTranslator.translate("""
            sampler sampler_clouds2;
            shader_body { ret = tex2D(sampler_clouds2, uv * texsize_clouds2.zw).xyz; }
            """, stage: .composite)
        #expect(shader.userTextures == ["clouds2"])
        #expect(shader.metalSource.contains("tex_user0.sample(milk_fw"))
        #expect(shader.metalSource.contains("u.texsize_user[0]"))
    }

    @Test func mulSwapsForTransposedMatrices() throws {
        let source = try msl("shader_body { float2x2 m = float2x2(0, 1, -1, 0); float2 p = mul(uv, m); ret = p.x; }")
        #expect(source.contains("(v_m * v_uv)"))
        try compiles("shader_body { float2x2 m = float2x2(0, 1, -1, 0); float2 p = mul(uv, m); ret = p.x; }")
    }

    @Test func floatModuloIsFmod() throws {
        #expect(try msl("shader_body { ret = uv.x % 0.25; }").contains("fmod(v_uv.x, 0.25)"))
        #expect(try msl("shader_body { int i = 7 % 3; ret = i; }").contains("(7 % 3)"))
    }

    @Test func writtenUniformsBecomeCopies() throws {
        let source = try msl("shader_body { q25 = q24; ret = q25; }")
        #expect(source.contains("float g_q25 = u.q[6].x;"))
        #expect(source.contains("g_q25 = u.q[5].w"))
        try compiles("shader_body { q25 = q24; ret = q25; }")
    }

    @Test func functionsReceiveTheResourcesTheyUse() throws {
        let text = """
            static float k = 2;
            float3 sharpen(float2 p) { k += 1; return tex2D(sampler_main, p).xyz * k + GetBlur1(p); }
            shader_body { ret = sharpen(uv); }
            """
        let source = try msl(text)
        #expect(source.contains("constant MilkUniforms &u, thread float &g_k, sampler smp_main, texture2d<float> tex_blur1, texture2d<float> tex_main"))
        #expect(source.contains("f_sharpen(v_uv, u, g_k, smp_main, tex_blur1, tex_main)"))
        try compiles(text)
    }

    @Test func preprocessorDefinesAndConditionals() throws {
        let text = """
            #define sat saturate
            #define SCALE(x) ((x) * 2)
            #if 0
            this is not code
            #else
            shader_body { ret = sat(SCALE(uv.x)); }
            #endif
            """
        #expect(try msl(text).contains("saturate((v_uv.x * 2.0))"))
        try compiles(text)
    }

    @Test func compositeShaderWithEverything() throws {
        let text = """
            sampler2D sampler_pic;
            static const float3 weights = float3(0.3, 0.5, 0.2);
            float2 rotate(float2 p, float a) { float s, c; sincos(a, s, c); return mul(p, float2x2(c, -s, s, c)); }
            shader_body {
                float2 p = rotate(uv - 0.5, time * 0.1) + 0.5;
                float3 c = tex2D(sampler_main, p).xyz;
                float4 n = tex3D(sampler_noisevol_hq, float3(uv * 4, time));
                for (int i = 0; i < 3; i++) { c += GetBlur3(uv + i * 0.01) * 0.1; }
                ret = lerp(c, n.xyz, 0.1) * dot(weights, hue_shader) + tex2D(sampler_pic, uv) * (rad < 0.3 ? 1 : 0);
                ret *= 1 + 0.1 * sin(ang * 6 + rot_d1[0].x);
            }
            """
        try compiles(text, stage: .composite)
    }

    @Test func logAndPowTakeTheAbsoluteValueLikeDirect3D9() throws {
        // Shader model 2/3's log and pow use |x|: pow(-0.25, 0.5) is 0.5, not NaN (which the 8-bit feedback stores
        // as black). sqrt and rsqrt keep IEEE semantics: taking |x| there too fixed some presets but turned two that
        // drew (Fractal/Nested Circle/… soft death) black, so it was left out.
        let text = "shader_body { float3 a = sqrt(uv.x - 0.5) + rsqrt(-uv.y) + log(-2) + log2(uv.x) + log10(uv.y); ret = pow(a - 1, 1.5); }"
        let source = try msl(text)
        #expect(source.contains("sqrt((v_uv.x - 0.5))"))
        #expect(source.contains("rsqrt((-v_uv.y))"))
        #expect(source.contains("log(abs(-2.0))"))
        #expect(source.contains("log2(abs(v_uv.x))"))
        #expect(source.contains("log10(abs(v_uv.y))"))
        #expect(source.contains("pow(abs((v_a - 1.0)), float3(1.5))"))
        // Other functions keep their operands.
        #expect(try msl("shader_body { ret = exp(-uv.x) + abs(-uv.y); }").contains("(exp((-v_uv.x)) + abs((-v_uv.y)))"))
        try compiles(text)
    }

    @Test func floatDivisionFollowsDirect3D9() throws {
        // 0 / 0 is 0 and x / 0 is finite, so a later * 0 gives 0 rather than NaN; constant ints still truncate.
        let text = "shader_body { float2 a = uv / uv.x; float b = 1 / q1; b /= 2; int i = 7 / 2; ret = a.x + b * q2 + i; }"
        let source = try msl(text)
        #expect(source.contains("float2 v_a = milk_div(v_uv, float2(v_uv.x))"))
        #expect(source.contains("float v_b = milk_div(1.0, u.q[0].x)"))
        #expect(source.contains("v_b = milk_div(v_b, 2.0)"))
        #expect(source.contains("int v_i = (7 / 2)"))
        try compiles(text)
    }

    @Test func reportsSyntaxErrors() {
        #expect(throws: ShaderError.self) { try ShaderTranslator.translate("shader_body { ret = ; }", stage: .warp) }
        #expect(throws: ShaderError.self) { try ShaderTranslator.translate("ret = 1;", stage: .warp) }
    }
}
