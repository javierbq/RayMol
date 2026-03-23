// surface.metal — Molecular surface rendering with ambient occlusion
#include "pymol_metal_common.h"

struct SurfaceVertexIn {
  float4 a_Vertex       [[attribute(0)]];
  float3 a_Normal       [[attribute(1)]];
  float4 a_Color        [[attribute(2)]];
  float  a_Accessibility [[attribute(3)]];
};

struct SurfaceVertexOut {
  float4 position       [[position]];
  float3 normal;
  float4 color;
  float  fog;
  float2 bgTextureLookup;
};

struct SurfaceVertexUniforms {
  bool isPicking;
  bool lighting_enabled;
  float ambient_occlusion_scale;
  int accessibility_mode;
  float accessibility_mode_on;
};

vertex SurfaceVertexOut surface_vertex(
    SurfaceVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant SurfaceVertexUniforms& surfU [[buffer(1)]])
{
  SurfaceVertexOut out;
  out.normal = normalize(scene.g_NormalMatrix * in.a_Normal);
  float3 eye_pos = (scene.g_ModelViewMatrix * in.a_Vertex).xyz;

  if (surfU.isPicking) {
    out.color = in.a_Color;
  } else {
    float4 colorA;
    float E = 2.718281828459045;
    if (surfU.accessibility_mode == 1) {
      colorA = float4(clamp(in.a_Color.xyz * (1.0 - surfU.ambient_occlusion_scale * in.a_Accessibility), 0.0, 1.0), in.a_Color.w);
    } else if (surfU.accessibility_mode == 2) {
      float angle = 90.0 * (3.14159265 / 180.0) * clamp(surfU.ambient_occlusion_scale * in.a_Accessibility, 0.0, 1.0);
      colorA = float4(in.a_Color.xyz * cos(angle), in.a_Color.w);
    } else {
      float sig = 1.0 / (1.0 + pow(E, 0.5 * (surfU.ambient_occlusion_scale * in.a_Accessibility - 10.0)));
      colorA = float4(clamp(in.a_Color.xyz * sig, 0.0, 1.0), in.a_Color.w);
    }
    out.color = mix(in.a_Color, colorA, surfU.accessibility_mode_on);
    out.fog = (scene.g_Fog_end + eye_pos.z) * scene.g_Fog_scale;
  }

  out.position = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_Vertex;
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct SurfaceFragUniforms {
  bool lighting_enabled;
  bool two_sided_lighting_enabled;
  float4 interior_color;
  bool use_interior_color;
};

fragment float4 surface_fragment(
    SurfaceVertexOut in [[stage_in]],
    bool front_facing [[front_facing]],
    constant FogUniforms& fogU [[buffer(0)]],
    constant LightingUniforms& lighting [[buffer(1)]],
    constant SurfaceFragUniforms& fragU [[buffer(2)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);

  if (fogU.isPicking) {
    return in.color;
  }

  bool is_interior = !front_facing;
  float3 normal = normalize(in.normal);

  if (fragU.use_interior_color && is_interior) {
    return float4(fragU.interior_color.rgb, in.color.a);
  }

  if (is_interior) {
    if (fragU.two_sided_lighting_enabled) {
      normal = -normal;
    } else {
      normal = float3(0.0);
    }
  }

  float4 color = ApplyColorEffects(in.color, in.position.z);
  color = ApplyLighting(color, normal, lighting);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
