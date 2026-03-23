// bg.metal — Background rendering
#include "pymol_metal_common.h"

struct BgVertexIn {
  float3 a_Vertex [[attribute(0)]];
};

struct BgVertexOut {
  float4 position       [[position]];
  float2 bgTextureLookup;
};

vertex BgVertexOut bg_vertex(
    BgVertexIn in [[stage_in]])
{
  BgVertexOut out;
  out.position = float4(in.a_Vertex.xy, 0.5, 1.0);
  out.bgTextureLookup = (1.0 + in.a_Vertex.xy) / 2.0;
  return out;
}

fragment float4 bg_fragment(
    BgVertexOut in [[stage_in]],
    constant FogUniforms& fogU [[buffer(0)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
  return float4(bgColor, 1.0);
}
