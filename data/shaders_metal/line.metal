// line.metal — Line rendering with color interpolation
#include "pymol_metal_common.h"

struct LineVertexIn {
  float4 a_Vertex       [[attribute(0)]];
  float3 a_Normal       [[attribute(1)]];
  float4 a_Color        [[attribute(2)]];
  float  a_interpolate  [[attribute(3)]];
  float  a_line_position [[attribute(4)]];
};

struct LineVertexOut {
  float4 position       [[position]];
  float3 normal;
  float4 color;
  float4 color2;
  float4 color_interp;
  float  interpolate;
  float  line_position;
  float  fog;
  float2 bgTextureLookup;
};

struct LineVertexUniforms {
  bool isPicking;
};

vertex LineVertexOut line_vertex(
    LineVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant LineVertexUniforms& lineU [[buffer(1)]])
{
  LineVertexOut out;
  float3 eye_pos = (scene.g_ModelViewMatrix * in.a_Vertex).xyz;
  out.interpolate = lineU.isPicking ? 0.0 : in.a_interpolate;
  out.line_position = in.a_line_position;
  out.position = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_Vertex;
  out.normal = normalize(scene.g_NormalMatrix * in.a_Normal);
  out.color_interp = in.a_Color;
  out.color = (1.0 - in.a_line_position) * in.a_Color;
  out.color2 = in.a_line_position * in.a_Color;
  out.fog = (scene.g_Fog_end + eye_pos.z) * scene.g_Fog_scale;
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct LineFragUniforms {
  bool lighting_enabled;
  bool two_sided_lighting_enabled;
};

fragment float4 line_fragment(
    LineVertexOut in [[stage_in]],
    bool front_facing [[front_facing]],
    constant FogUniforms& fogU [[buffer(0)]],
    constant LightingUniforms& lighting [[buffer(1)]],
    constant LineFragUniforms& fragU [[buffer(2)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  float whichColor = step(0.5, in.line_position);
  float4 color_step = whichColor * in.color2 / in.line_position +
      (1.0 - whichColor) * in.color / (1.0 - in.line_position);
  float4 icolor = in.interpolate * in.color_interp + (1.0 - in.interpolate) * color_step;
  float4 color = ApplyColorEffects(icolor, in.position.z);

  if (!fogU.isPicking && fragU.lighting_enabled) {
    float3 normal = in.normal;
    if (fragU.two_sided_lighting_enabled && !front_facing)
      normal = -normal;
    color = ApplyLighting(color, normal, lighting);
  }

  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
