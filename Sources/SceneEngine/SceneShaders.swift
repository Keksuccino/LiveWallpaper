import Foundation
import simd
import Metal

// Owner: SCENERENDER. Metal Shading Language sources, compiled at runtime with `MTLDevice.makeLibrary(source:options:)`.
// They are Swift string literals on purpose: SwiftPM command line builds need no .metal compile rules, no resource
// bundle and no metallib lookup, which keeps the executable bundle layout of build.sh unchanged.
// M0 needs: a textured quad (vertex: layer transform + parallax offset; fragment: sample * tint) drawn with the
// blend states for (normal, opaque, additive, multiply, screen), a copy pass and a two-source crossfade pass
// (LockVideoRenderer). The uniform block layouts are shared with Swift through `LayerUniforms`/`GlobalUniforms`.

enum SceneShaderSource {
    /// One uniform block per drawn layer (see SceneRenderer for how it is filled).
    struct LayerUniforms {
        var model: simd_float4x4        // local quad corner -> scene coordinates (origin, rotation, parents)
        var projection: simd_float4x4   // scene coordinates -> clip space (fit to the target; parallax in it)
        var tint: simd_float4           // rgb = color * brightness, a = alpha (straight alpha)
        var uvs: simd_float4            // u0, v0, du, dv: the picture inside the stored texture
    }

    struct GlobalUniforms {
        var crossfadeMix: Float         // weight of the second texture in the crossfade pass (live player: 0)
        var singleChannel: UInt32       // 1 for .r8Unorm textures (the red channel carries the picture level)
    }

    static let m0 = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4x4 model;
        float4x4 projection;
        float4 tint;
        float4 uvs;
    };
    struct GlobalUniforms {
        float crossfadeMix;
        uint singleChannel;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Six vertices, two unit triangles of one quad; corners run 0..1 over the picture.
    static inline float2 quadCorner(uint vertexID) {
        switch (vertexID) {
        case 0: return float2(0.0, 0.0);
        case 1: return float2(1.0, 0.0);
        case 2: return float2(1.0, 1.0);
        case 3: return float2(0.0, 0.0);
        case 4: return float2(1.0, 1.0);
        default: return float2(0.0, 1.0);
        }
    }

    vertex VertexOut scene_vertex(uint vertexID [[vertex_id]],
                                  constant LayerUniforms &layer [[buffer(0)]]) {
        VertexOut out;
        float2 corner = quadCorner(vertexID);
        float4 local = float4(corner * 2.0 - 1.0, 0.0, 1.0);   // local quad space: -1..1, y up
        out.position = layer.projection * (layer.model * local);
        // Texture v grows downward (row 0 is the top), the quad's y grows upward: flip v.
        float2 uv;
        uv.x = layer.uvs.x + corner.x * layer.uvs.z;
        uv.y = layer.uvs.y + (1.0 - corner.y) * layer.uvs.w;
        out.uv = uv;
        return out;
    }

    fragment float4 scene_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> texture [[texture(0)]],
                                   sampler textureSampler [[sampler(0)]],
                                   constant LayerUniforms &layer [[buffer(1)]],
                                   constant GlobalUniforms &glob [[buffer(2)]]) {
        float4 sample = texture.sample(textureSampler, in.uv);
        if (glob.singleChannel == 1u) {
            sample = float4(sample.r, sample.r, sample.r, sample.a);
        }
        return clamp(sample * layer.tint, 0.0, 1.0);
    }

    fragment float4 copy_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> texture [[texture(0)]],
                                  sampler textureSampler [[sampler(0)]]) {
        return clamp(texture.sample(textureSampler, in.uv), 0.0, 1.0);
    }

    fragment float4 crossfade_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> first [[texture(0)]],
                                       texture2d<float> second [[texture(1)]],
                                       sampler textureSampler [[sampler(0)]],
                                       constant GlobalUniforms &glob [[buffer(2)]]) {
        float4 a = first.sample(textureSampler, in.uv);
        float4 b = second.sample(textureSampler, in.uv);
        return clamp(mix(a, b, glob.crossfadeMix), 0.0, 1.0);
    }
    """
}
