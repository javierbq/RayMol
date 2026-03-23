// default.metal — Basic molecular rendering (sticks, cartoon, etc.)
#include "pymol_metal_common.h"

struct DefaultVertexIn {
  float4 a_Vertex   [[attribute(0)]];
  float3 a_Normal   [[attribute(1)]];
  float4 a_Color    [[attribute(2)]];
};

struct DefaultVertexOut {
  float4 position       [[position]];
  float3 normal;
  float4 color;
  float  fog;
  float2 bgTextureLookup;
};

vertex DefaultVertexOut default_vertex(
    DefaultVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]])
{
  DefaultVertexOut out;
  float3 normal = normalize(scene.g_NormalMatrix * in.a_Normal);
  float3 eye_pos = (scene.g_ModelViewMatrix * in.a_Vertex).xyz;

  out.normal = normal;
  out.color = in.a_Color;
  out.fog = (scene.g_Fog_end + eye_pos.z) * scene.g_Fog_scale;
  out.position = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_Vertex;
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct DefaultFragUniforms {
  bool lighting_enabled;
  bool two_sided_lighting_enabled;
};

fragment float4 default_fragment(
    DefaultVertexOut in [[stage_in]],
    bool front_facing [[front_facing]],
    constant FogUniforms& fogU [[buffer(0)]],
    constant LightingUniforms& lighting [[buffer(1)]],
    constant DefaultFragUniforms& fragU [[buffer(2)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  float4 color = ApplyColorEffects(in.color, in.position.z);

  if (!fogU.isPicking && fragU.lighting_enabled) {
    float3 normal = normalize(in.normal);
    if (fragU.two_sided_lighting_enabled && !front_facing)
      normal = -normal;
    color = ApplyLighting(color, normal, lighting);
  }

  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
