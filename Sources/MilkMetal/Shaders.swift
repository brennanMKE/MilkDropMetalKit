/// Metal source for the fixed-function pipeline, compiled at runtime with `makeLibrary(source:)` because SwiftPM
/// only builds `.metal` files in Xcode. MilkDrop 2 preset shaders are translated separately (`MilkShaders`).
///
/// Texture coordinates follow Metal (and MilkDrop/DirectX): v = 0 at the top.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct MeshVertex { packed_float2 position; packed_float2 uv; };
    struct OverlayVertex { packed_float2 position; packed_float4 color; packed_float2 uv; };

    struct WarpOut { float4 position [[position]]; float2 uv; float2 uvOrig; };
    struct OverlayOut { float4 position [[position]]; float4 color; float2 uv; };
    struct PointOut { float4 position [[position]]; float4 color; float size [[point_size]]; };
    struct QuadOut { float4 position [[position]]; float2 uv; };

    struct WarpUniforms { float decay; };
    // edge: half a pixel in clip units for lines and points, which are kept that far inside the screen so a line
    // drawn exactly on an edge (as presets do) still lands on the outermost pixels; zero for triangles.
    struct OverlayUniforms { float2 offset; float2 edge; float pointSize; };
    struct CompositeUniforms {
        float4 hue[4];
        float gamma;
        float echoZoom;
        float echoAlpha;
        float fShader;
        int echoOrient;
        int brighten;
        int darken;
        int solarize;
        int invert;
    };
    struct BlurUniforms {
        float4 texsize;
        float4 weights;
        float4 offsets;
        float divisor;
        float scale;
        float bias;
        float edgeDarken;
    };

    // Warp: resample the previous frame through the mesh, faded by decay.
    vertex WarpOut warp_vertex(uint vid [[vertex_id]], const device MeshVertex *vertices [[buffer(0)]]) {
        MeshVertex v = vertices[vid];
        float2 p = float2(v.position);
        WarpOut out;
        out.position = float4(p, 0, 1);
        out.uv = float2(v.uv);
        out.uvOrig = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return out;
    }

    fragment float4 warp_fragment(WarpOut in [[stage_in]], texture2d<float> previous [[texture(0)]],
                                  sampler s [[sampler(0)]], constant WarpUniforms &u [[buffer(0)]]) {
        return float4(previous.sample(s, in.uv).rgb * u.decay, 1);
    }

    // Transitions: the incoming preset's pass, rendered to a texture the size of the target, laid over the outgoing
    // one's through the mesh with each vertex's weight as alpha.
    struct BlendOut { float4 position [[position]]; float weight; };

    vertex BlendOut blend_vertex(uint vid [[vertex_id]], const device MeshVertex *vertices [[buffer(0)]],
                                 const device float *weights [[buffer(1)]]) {
        BlendOut out;
        out.position = float4(float2(vertices[vid].position), 0, 1);
        out.weight = weights[vid];
        return out;
    }

    fragment float4 blend_fragment(BlendOut in [[stage_in]], texture2d<float> incoming [[texture(0)]]) {
        return float4(incoming.read(uint2(in.position.xy)).rgb, in.weight);
    }

    // Overlays: lines and triangles (optionally textured with the previous frame), and points.
    vertex OverlayOut overlay_vertex(uint vid [[vertex_id]], const device OverlayVertex *vertices [[buffer(0)]],
                                     constant OverlayUniforms &u [[buffer(1)]]) {
        OverlayVertex v = vertices[vid];
        OverlayOut out;
        float2 p = float2(v.position);
        if (u.edge.x > 0) { p = clamp(p, -1 + u.edge, 1 - u.edge); }
        out.position = float4(p + u.offset, 0, 1);
        out.color = float4(v.color);
        out.uv = float2(v.uv);
        return out;
    }

    vertex PointOut overlay_point_vertex(uint vid [[vertex_id]], const device OverlayVertex *vertices [[buffer(0)]],
                                         constant OverlayUniforms &u [[buffer(1)]]) {
        OverlayVertex v = vertices[vid];
        PointOut out;
        out.position = float4(clamp(float2(v.position), -1 + u.edge, 1 - u.edge) + u.offset, 0, 1);
        out.color = float4(v.color);
        out.size = u.pointSize;
        return out;
    }

    fragment float4 overlay_fragment(OverlayOut in [[stage_in]]) {
        return in.color;
    }

    fragment float4 overlay_point_fragment(PointOut in [[stage_in]]) {
        return in.color;
    }

    fragment float4 overlay_textured_fragment(OverlayOut in [[stage_in]], texture2d<float> previous [[texture(0)]],
                                              sampler s [[sampler(0)]]) {
        return previous.sample(s, in.uv) * in.color;
    }

    // A full-screen triangle; uv in texture coordinates.
    vertex QuadOut quad_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2) * 2 - 1;
        QuadOut out;
        out.position = float4(p, 0, 1);
        out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return out;
    }

    // Composite: the feedback texture to the screen with echo, gamma, hue and the colour filters. Never fed back.
    fragment float4 composite_fragment(QuadOut in [[stage_in]], texture2d<float> main [[texture(0)]],
                                       sampler s [[sampler(0)]], constant CompositeUniforms &u [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 orient = float2((u.echoOrient & 1) ? -1 : 1, (u.echoOrient >= 2) ? -1 : 1);
        float2 uvEcho = (uv - 0.5) * (1.0 / u.echoZoom) * orient + 0.5;
        float3 ret = mix(main.sample(s, uv).rgb, main.sample(s, uvEcho).rgb, u.echoAlpha);
        ret *= u.gamma;
        float3 hue = u.hue[0].rgb * uv.x * uv.y + u.hue[1].rgb * (1 - uv.x) * uv.y
                   + u.hue[2].rgb * uv.x * (1 - uv.y) + u.hue[3].rgb * (1 - uv.x) * (1 - uv.y);
        if (u.fShader >= 1.0) {
            ret *= hue;
        } else if (u.fShader > 0.001) {
            ret *= (1.0 - u.fShader) + u.fShader * hue;
        }
        ret = saturate(ret);
        if (u.brighten) { ret = sqrt(ret); }
        if (u.darken) { ret = ret * ret; }
        if (u.solarize) { ret = ret * (1 - ret) * 4; }
        if (u.invert) { ret = 1 - ret; }
        return float4(ret, 1);
    }

    // Blur: MilkDrop's separable 16-tap Gaussian, horizontal then vertical, at half, quarter and eighth size.
    // Values are stored normalised to the preset's blur range; GetBlurN() scales them back.
    fragment float4 blur_horizontal_fragment(QuadOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                             sampler s [[sampler(0)]], constant BlurUniforms &u [[buffer(0)]]) {
        float2 uv = in.uv;
        float dx = u.texsize.z;
        float3 blur =
            (source.sample(s, uv + float2( u.offsets.x * dx, 0)).rgb + source.sample(s, uv + float2(-u.offsets.x * dx, 0)).rgb) * u.weights.x +
            (source.sample(s, uv + float2( u.offsets.y * dx, 0)).rgb + source.sample(s, uv + float2(-u.offsets.y * dx, 0)).rgb) * u.weights.y +
            (source.sample(s, uv + float2( u.offsets.z * dx, 0)).rgb + source.sample(s, uv + float2(-u.offsets.z * dx, 0)).rgb) * u.weights.z +
            (source.sample(s, uv + float2( u.offsets.w * dx, 0)).rgb + source.sample(s, uv + float2(-u.offsets.w * dx, 0)).rgb) * u.weights.w;
        blur *= u.divisor;
        return float4(blur * u.scale + u.bias, 1);
    }

    fragment float4 blur_vertical_fragment(QuadOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                           sampler s [[sampler(0)]], constant BlurUniforms &u [[buffer(0)]]) {
        float2 uv = in.uv;
        float dy = u.texsize.w;
        float3 blur =
            (source.sample(s, uv + float2(0,  u.offsets.x * dy)).rgb + source.sample(s, uv + float2(0, -u.offsets.x * dy)).rgb) * u.weights.x +
            (source.sample(s, uv + float2(0,  u.offsets.y * dy)).rgb + source.sample(s, uv + float2(0, -u.offsets.y * dy)).rgb) * u.weights.y;
        blur *= u.divisor;
        // Darken toward the edges, by blur1_edge_darken on the first level.
        float t = min(min(uv.x, uv.y), 1.0 - max(uv.x, uv.y));
        t = sqrt(t);
        t = (1.0 - u.edgeDarken) + u.edgeDarken * saturate(t * 5.0);
        return float4(blur * t, 1);
    }
    """
}

struct WarpUniforms {
    var decay: Float
}

struct OverlayUniforms {
    var offset: SIMD2<Float>
    var edge: SIMD2<Float>
    var pointSize: Float
}

struct CompositeUniforms {
    var hue: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var gamma: Float
    var echoZoom: Float
    var echoAlpha: Float
    var fShader: Float
    var echoOrient: Int32
    var brighten: Int32
    var darken: Int32
    var solarize: Int32
    var invert: Int32
}

struct BlurUniforms {
    var texsize: SIMD4<Float>
    var weights: SIMD4<Float>
    var offsets: SIMD4<Float>
    var divisor: Float
    var scale: Float
    var bias: Float
    var edgeDarken: Float
}
