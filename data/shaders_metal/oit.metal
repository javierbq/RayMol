// oit.metal — Order-independent transparency compositing pass
#include "pymol_metal_common.h"

struct OITVertexIn {
  float3 a_Vertex [[attribute(0)]];
};

struct OITVertexOut {
  float4 position [[position]];
  float2 texcoordAttr;
};

vertex OITVertexOut oit_vertex(OITVertexIn in [[stage_in]])
{
  OITVertexOut out;
  out.texcoordAttr = (1.0 + in.a_Vertex.xy) / 2.0;
  out.position = float4(in.a_Vertex.x, in.a_Vertex.y, 0.0, 1.0);
  return out;
}

fragment float4 oit_fragment(
    OITVertexOut in [[stage_in]],
    texture2d<float> accumTex [[texture(0)]],
    texture2d<float> revealageTex [[texture(1)]],
    sampler texSampler [[sampler(0)]])
{
  float4 accum = accumTex.sample(texSampler, in.texcoordAttr);
  float r = accum.a;
  accum.a = revealageTex.sample(texSampler, in.texcoordAttr).r;
  return float4(accum.rgb / clamp(accum.a, 1e-4, 5e4), r);
}
