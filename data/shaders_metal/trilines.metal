// trilines.metal — Triangle-based line rendering with antialiasing
#include "pymol_metal_common.h"

struct TrilinesVertexIn {
  float3 a_Vertex       [[attribute(0)]];
  float3 a_OtherVertex  [[attribute(1)]];
  float  a_UV           [[attribute(2)]];
  float4 a_Color        [[attribute(3)]];
  float4 a_Color2       [[attribute(4)]];
  float  a_interpolate  [[attribute(5)]];
};

struct TrilinesVertexOut {
  float4 position       [[position]];
  float4 color;
  float4 color2;
  float  interpolate;
  float  fog;
  float2 bgTextureLookup;
  float  centerdist;
  float  whichEnd;
};

struct TrilinesVertexUniforms {
  float2 inv_dimensions;
  float line_width;
  bool isPicking;
};

vertex TrilinesVertexOut trilines_vertex(
    TrilinesVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant TrilinesVertexUniforms& triU [[buffer(1)]])
{
  TrilinesVertexOut out;

  float2 UV;
  UV.y = fmod(in.a_UV, 2.0);
  UV.x = (in.a_UV - UV.y) / 2.0;
  UV.y = 2.0 * UV.y - 1.0;
  UV.x = 2.0 * UV.x - 1.0;

  float swapPoints = step(0.0, UV.x);
  float3 b_Vertex = mix(in.a_Vertex, in.a_OtherVertex, swapPoints);
  float3 b_OtherVertex = mix(in.a_OtherVertex, in.a_Vertex, swapPoints);
  out.whichEnd = swapPoints;

  out.interpolate = triU.isPicking ? 0.0 : in.a_interpolate;
  out.color = in.a_Color;
  out.color2 = in.a_Color2;

  float4 eye_pos = scene.g_ModelViewMatrix * float4(b_Vertex, 1.0);
  float4 pointA = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * float4(b_Vertex, 1.0);
  float4 pointB = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * float4(b_OtherVertex, 1.0);
  pointA.xyz = pointA.xyz / abs(pointA.w);
  pointB.xyz = pointB.xyz / abs(pointB.w);
  pointA.w = 1.0;
  pointB.w = 1.0;

  float2 perpAB = normalize((pointA.yx - pointB.yx) * triU.inv_dimensions) * float2(1.0, -1.0);
  float width = triU.line_width;

  // line_smooth variant
  out.centerdist = UV.x * UV.y * triU.line_width;
  if (!triU.isPicking)
    width += 1.0;
  else
    width = max(1.0, width);

  pointA.xy += width * perpAB * UV.y * triU.inv_dimensions;

  out.fog = (scene.g_Fog_end + eye_pos.z) * scene.g_Fog_scale;
  out.position = pointA;
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct TrilinesFragUniforms {
  float line_width;
};

fragment float4 trilines_fragment(
    TrilinesVertexOut in [[stage_in]],
    constant FogUniforms& fogU [[buffer(0)]],
    constant TrilinesFragUniforms& triFragU [[buffer(1)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  float which = mix(step(0.5, in.whichEnd), in.whichEnd, in.interpolate);
  float4 bcolor = mix(in.color, in.color2, which);
  float4 color = ApplyColorEffects(bcolor, in.position.z);

  // line_smooth antialiasing
  constexpr float margin = 1.5;
  if (!fogU.isPicking)
    color.a *= 1.0 - max(0.0, (abs(in.centerdist) - triFragU.line_width + margin) / margin);

  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
