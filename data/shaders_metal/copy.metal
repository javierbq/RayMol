// copy.metal — Full-screen texture copy / blit
#include "pymol_metal_common.h"

struct CopyVertexIn {
  float3 a_Vertex [[attribute(0)]];
};

struct CopyVertexOut {
  float4 position [[position]];
  float2 texcoordAttr;
};

vertex CopyVertexOut copy_vertex(CopyVertexIn in [[stage_in]])
{
  CopyVertexOut out;
  out.texcoordAttr = (1.0 + in.a_Vertex.xy) / 2.0;
  out.position = float4(in.a_Vertex.x, in.a_Vertex.y, 0.0, 1.0);
  return out;
}

fragment float4 copy_fragment(
    CopyVertexOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    sampler texSampler [[sampler(0)]])
{
  return colorTex.sample(texSampler, in.texcoordAttr);
}
