// pymol_metal_common.h — Shared types and constants for all PyMOL Metal shaders
#ifndef PYMOL_METAL_COMMON_H
#define PYMOL_METAL_COMMON_H

#include <metal_stdlib>
using namespace metal;

// ============================================================
// Uniform buffer structures
// ============================================================

struct SceneUniforms {
  float4x4 g_ModelViewMatrix;
  float4x4 g_ProjectionMatrix;
  float3x3 g_NormalMatrix;
  float g_Fog_end;
  float g_Fog_scale;
  float g_PointSize;
};

struct LightSource {
  float4 ambient;
  float4 diffuse;
  float4 specular;
  float4 position;
};

struct LightingUniforms {
  float4 g_LightModelAmbient;
  LightSource g_LightSource[8];
  float shininess;
  float shininess_0;
  float spec_value;
  float spec_value_0;
  int lightCount;
};

struct FogUniforms {
  float3 bgSolidColor;
  float2 tileSize;
  float2 tiledSize;
  float2 viewImageSize;
  bool isPicking;
  bool depth_cue;
};

// ============================================================
// Lighting functions
// ============================================================

inline float2 ComputeLighting(float3 normal, float3 L, float diffuse_val,
                               float spec, float shine) {
  L = normalize(L);
  float NdotL = dot(normal, L);
  if (NdotL > 0.0) {
    float diff = diffuse_val * NdotL;
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float NdotH = max(dot(normal, H), 0.0);
    float s = spec * pow(NdotH, shine);
    return float2(diff, s);
  }
  return float2(0.0);
}

inline float4 ApplyLighting(float4 color, float3 normal,
                             constant LightingUniforms& lighting) {
  float2 lit = float2(lighting.g_LightModelAmbient.r, 0.0);

  // Light 0 uses shininess_0 / spec_value_0
  lit += ComputeLighting(normal,
      lighting.g_LightSource[0].position.xyz,
      lighting.g_LightSource[0].diffuse.r,
      lighting.spec_value_0, lighting.shininess_0);

  for (int i = 1; i < lighting.lightCount && i < 8; i++) {
    lit += ComputeLighting(normal,
        lighting.g_LightSource[i].position.xyz,
        lighting.g_LightSource[i].diffuse.r,
        lighting.spec_value, lighting.shininess);
  }

  color.rgb *= min(lit.x, 1.0);
  color.rgb += lit.y;
  return color;
}

// ============================================================
// Fog / background functions
// ============================================================

inline float3 ComputeBgColorSolid(constant FogUniforms& fog) {
  return fog.bgSolidColor;
}

inline float3 ComputeBgColor(constant FogUniforms& fogU,
                              float2 bgTextureLookup,
                              texture2d<float> bgTextureMap,
                              sampler bgSampler) {
  float4 bgColor = bgTextureMap.sample(bgSampler, bgTextureLookup);
  return mix(fogU.bgSolidColor, bgColor.rgb, bgColor.a);
}

inline float4 ApplyFog(float4 color, float fog, bool isPicking,
                        bool depth_cue, float3 bgColor) {
  if (!depth_cue || isPicking || fog >= 1.0)
    return color;
  return float4(mix(bgColor, color.rgb, fog), color.a);
}

// ============================================================
// Color effects
// ============================================================

inline float4 ApplyColorEffects(float4 color, float depth) {
  // Placeholder for chromadepth etc — extended via defines at compile time
  return color;
}

// ============================================================
// OIT (order-independent transparency)
// ============================================================

inline float get_oit_weight(float depth, float alpha) {
  return alpha * max(1e-2, 3e3 * pow(1.0 - depth, 3.0));
}

#endif // PYMOL_METAL_COMMON_H
