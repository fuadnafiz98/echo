#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlobeUniforms {
    float time;
    float energy;
    float processing;
};

vertex VertexOut globe_vertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid];
    return out;
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

fragment float4 globe_fragment(VertexOut in [[stage_in]],
                               constant GlobeUniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float r = length(uv);

    float glow = smoothstep(1.18, 0.78, r) * (0.22 + 0.35 * u.energy);
    if (r > 1.20) {
        return float4(0.0);
    }

    float z = sqrt(max(0.0, 1.0 - r * r));
    float3 n = normalize(float3(uv, z));

    float t = u.time * (0.28 + u.processing * 0.55);
    float2 swirl = float2(
        n.x * 2.4 + t * 0.7,
        n.y * 2.1 - t * 0.55
    );
    swirl += float2(n.z * 1.4, n.x * n.y * 1.8);

    float ribbons = fbm(swirl + fbm(swirl * 1.6 - t));
    float wave = sin(n.x * 7.0 + t * 1.6 + ribbons * 4.0)
               * cos(n.y * 5.5 - t * 1.1 + n.z * 3.0);

    float3 cyan    = float3(0.28, 0.86, 1.00);
    float3 blue    = float3(0.22, 0.48, 0.98);
    float3 magenta = float3(0.96, 0.38, 0.78);
    float3 lavender= float3(0.72, 0.58, 1.00);
    float3 peach   = float3(1.00, 0.72, 0.82);

    float mixA = saturate(0.5 + 0.5 * wave);
    float mixB = saturate(ribbons);
    float3 col = mix(cyan, magenta, mixA);
    col = mix(col, lavender, mixB * 0.65);
    col = mix(col, blue, saturate(n.y * 0.35 + 0.15));
    col = mix(col, peach, saturate(-n.y) * 0.28);

    float fresnel = pow(1.0 - saturate(n.z), 2.4);
    col += fresnel * float3(0.85, 0.90, 1.0) * 0.55;
    col += n.z * 0.12;
    col += u.energy * 0.22;
    col += u.processing * float3(0.10, 0.06, 0.16);

    float sphere = smoothstep(1.0, 0.93, r);
    float alpha = max(glow * 0.45, sphere * (0.78 + 0.18 * u.energy));
    col = mix(col, col * 0.55 + glow, 1.0 - sphere);

    return float4(col, alpha);
}
