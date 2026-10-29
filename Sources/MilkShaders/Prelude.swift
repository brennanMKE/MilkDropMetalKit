import Foundation

/// What MilkDrop's shader prelude provides, re-expressed for the translator: macros (`GetBlur1`, `lum`, …),
/// uniforms (`time`, `q1`, `texsize`, …) and the MSL that every translated shader starts with.
enum Prelude {
    static let standardTextures = [
        "main", "blur1", "blur2", "blur3", "noise_lq", "noise_lq_lite", "noise_mq", "noise_hq", "noisevol_lq",
        "noisevol_hq",
    ]
    static let maxUserTextures = 8

    /// MilkDrop's helper macros.
    static func preprocessor() throws -> Preprocessor {
        var p = Preprocessor()
        try p.define("GetMain(uv)", "(tex2D(sampler_main,uv).xyz)")
        try p.define("GetPixel(uv)", "(tex2D(sampler_main,uv).xyz)")
        try p.define("GetBlur1(uv)", "(tex2D(sampler_blur1,uv).xyz*scale1 + bias1)")
        try p.define("GetBlur2(uv)", "(tex2D(sampler_blur2,uv).xyz*scale2 + bias2)")
        try p.define("GetBlur3(uv)", "(tex2D(sampler_blur3,uv).xyz*scale3 + bias3)")
        try p.define("lum(x)", "(dot(x,float3(0.32,0.49,0.29)))")
        try p.define("tex2d", "tex2D")
        try p.define("tex3d", "tex3D")
        return p
    }

    private static let uniforms: [String: (String, HType)] = {
        var u: [String: (String, HType)] = [
            "time": ("u._c0.x", .float), "fps": ("u._c0.y", .float), "frame": ("u._c0.z", .float),
            "progress": ("u._c0.w", .float),
            "bass": ("u._c1.x", .float), "mid": ("u._c1.y", .float), "treb": ("u._c1.z", .float),
            "vol": ("u._c1.w", .float),
            "bass_att": ("u._c2.x", .float), "mid_att": ("u._c2.y", .float), "treb_att": ("u._c2.z", .float),
            "vol_att": ("u._c2.w", .float),
            "aspect": ("u.aspect", .float(4)), "texsize": ("u.texsize", .float(4)),
            "rand_frame": ("u.rand_frame", .float(4)), "rand_preset": ("u.rand_preset", .float(4)),
            "roam_cos": ("u.roam_cos", .float(4)), "roam_sin": ("u.roam_sin", .float(4)),
            "slow_roam_cos": ("u.slow_roam_cos", .float(4)), "slow_roam_sin": ("u.slow_roam_sin", .float(4)),
            "blur1_min": ("u.blur_min.x", .float), "blur2_min": ("u.blur_min.y", .float),
            "blur3_min": ("u.blur_min.z", .float), "decay": ("u.blur_min.w", .float),
            "blur1_max": ("u.blur_max.x", .float), "blur2_max": ("u.blur_max.y", .float),
            "blur3_max": ("u.blur_max.z", .float),
            "scale1": ("u.blur_scale.x", .float), "scale2": ("u.blur_scale.y", .float),
            "scale3": ("u.blur_scale.z", .float),
            "bias1": ("u.blur_bias.x", .float), "bias2": ("u.blur_bias.y", .float), "bias3": ("u.blur_bias.z", .float),
            "texsize_noise_lq": ("u.texsize_noise[0]", .float(4)), "texsize_noise_lq_lite": ("u.texsize_noise[1]", .float(4)),
            "texsize_noise_mq": ("u.texsize_noise[2]", .float(4)), "texsize_noise_hq": ("u.texsize_noise[3]", .float(4)),
            "texsize_noisevol_lq": ("u.texsize_noise[4]", .float(4)),
            "texsize_noisevol_hq": ("u.texsize_noise[5]", .float(4)),
            "PI": ("M_PI_F", .float), "M_PI": ("M_PI_F", .float), "M_PI_2": ("(M_PI_F * 2.0)", .float),
            "M_INV_PI_2": ("(0.5 / M_PI_F)", .float), "M_INV_PI": ("M_1_PI_F", .float),
        ]
        // Rotation matrices MilkDrop 2 provides: static, slow, fast, very fast, ultra fast, and new every frame.
        for (g, group) in rotationGroups.enumerated() {
            for k in 1...4 { u["rot_\(group)\(k)"] = ("milk_rot(u, \(g * 4 + k - 1))", .matrix(.float, 4, 3)) }
        }
        let packs = ["a", "b", "c", "d", "e", "f", "g", "h"]
        for (i, p) in packs.enumerated() {
            u["_q" + p] = ("u.q[\(i)]", .float(4))
            for (k, c) in ["x", "y", "z", "w"].enumerated() { u["q\(i * 4 + k + 1)"] = ("u.q[\(i)].\(c)", .float) }
        }
        return u
    }()

    static func uniform(_ name: String) -> (String, HType)? { uniforms[name] }

    static let rotationGroups = ["s", "d", "f", "vf", "uf", "rand"]

    static func uniformType(code: String) -> HType {
        uniforms.values.first { $0.0 == code }?.1 ?? .float
    }

    static func source(stage: ShaderStage) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;

        // Translated from a MilkDrop 2 \(stage == .warp ? "warp" : "composite") shader by MilkShaders.

        struct MilkUniforms {
            float4 _c0;            // time, fps, frame, progress
            float4 _c1;            // bass, mid, treb, vol
            float4 _c2;            // bass_att, mid_att, treb_att, vol_att
            float4 aspect;
            float4 texsize;
            float4 q[8];
            float4 rand_frame;
            float4 rand_preset;
            float4 roam_cos;
            float4 roam_sin;
            float4 slow_roam_cos;
            float4 slow_roam_sin;
            float4 blur_min;       // blur1_min, blur2_min, blur3_min, decay
            float4 blur_max;
            float4 blur_scale;
            float4 blur_bias;
            float4 texsize_noise[6];
            float4 texsize_user[\(maxUserTextures)];
            float4 hue[4];
            float4 rot[96];        // 24 float4x3 rotations (rot_s1 … rot_rand4), four float3 columns each
        };

        struct MilkVaryings { float4 position [[position]]; float2 uv; float2 uvOrig; };
        struct MilkMeshVertex { packed_float2 position; packed_float2 uv; };

        vertex MilkVaryings milk_warp_vertex(uint vid [[vertex_id]], const device MilkMeshVertex *mesh [[buffer(0)]]) {
            MilkMeshVertex v = mesh[vid];
            float2 p = float2(v.position);
            MilkVaryings out;
            out.position = float4(p, 0, 1);
            out.uv = float2(v.uv);
            out.uvOrig = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
            return out;
        }

        vertex MilkVaryings milk_quad_vertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2) * 2 - 1;
            MilkVaryings out;
            out.position = float4(p, 0, 1);
            out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
            out.uvOrig = out.uv;
            return out;
        }

        constexpr sampler milk_fw(filter::linear, address::repeat);
        constexpr sampler milk_fc(filter::linear, address::clamp_to_edge);
        constexpr sampler milk_pw(filter::nearest, address::repeat);
        constexpr sampler milk_pc(filter::nearest, address::clamp_to_edge);

        static float4x3 milk_rot(constant MilkUniforms &u, int i) {
            return float4x3(u.rot[i * 4].xyz, u.rot[i * 4 + 1].xyz, u.rot[i * 4 + 2].xyz, u.rot[i * 4 + 3].xyz);
        }

        static float3 milk_hue(constant MilkUniforms &u, float2 uv) {
            return u.hue[0].rgb * uv.x * uv.y + u.hue[1].rgb * (1 - uv.x) * uv.y
                 + u.hue[2].rgb * uv.x * (1 - uv.y) + u.hue[3].rgb * (1 - uv.x) * (1 - uv.y);
        }

        // An 8-bit target clamps; NaN and infinity from a shader's maths become black rather than garbage.
        static float4 milk_output(float3 c) {
            c = select(c, float3(0), isnan(c));
            return float4(saturate(c), 1);
        }

        // HLSL's * on matrices is componentwise; MSL's is the matrix product.
        static float2x2 milk_cmul(float2x2 a, float2x2 b) { return float2x2(a[0] * b[0], a[1] * b[1]); }
        static float3x3 milk_cmul(float3x3 a, float3x3 b) { return float3x3(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }
        static float4x4 milk_cmul(float4x4 a, float4x4 b) { return float4x4(a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3]); }
        static float2x2 milk_cdiv(float2x2 a, float2x2 b) { return float2x2(a[0] / b[0], a[1] / b[1]); }
        static float3x3 milk_cdiv(float3x3 a, float3x3 b) { return float3x3(a[0] / b[0], a[1] / b[1], a[2] / b[2]); }
        static float4x4 milk_cdiv(float4x4 a, float4x4 b) { return float4x4(a[0] / b[0], a[1] / b[1], a[2] / b[2], a[3] / b[3]); }

        // Direct3D 9 divides as a * rcp(b) and takes 0 * anything as 0: 0 / 0 is 0, not NaN. x / 0 stands in as
        // ±FLT_MAX rather than infinity, so a later 0 * (x / 0) is 0 as on Direct3D 9 instead of NaN (black). Written
        // with selects on the operands so fast math can't fold the cases away.
        template <typename T> static T milk_div(T a, T b) {
            T q = select(a / select(b, T(1), b == T(0)), copysign(T(FLT_MAX), a), b == T(0));
            return select(q, T(0), a == T(0));
        }
        template <typename T> static T milk_modf(T x, thread T &whole) { whole = trunc(x); return x - whole; }
        template <typename T> static void milk_sincos(T x, thread T &s, thread T &c) { s = sin(x); c = cos(x); }
        static void milk_clip(float x) { if (x < 0) discard_fragment(); }
        template <typename T> static void milk_clip(T x) { if (any(x < 0)) discard_fragment(); }
        """
    }
}
