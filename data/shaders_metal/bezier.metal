// bezier.metal — Simple bezier curve rendering
#include "pymol_metal_common.h"

struct BezierVertexIn {
  float3 position [[attribute(0)]];
};

struct BezierVertexOut {
  float4 position [[position]];
};

vertex BezierVertexOut bezier_vertex(BezierVertexIn in [[stage_in]])
{
  BezierVertexOut out;
  out.position = float4(in.position, 1.0);
  return out;
}

fragment float4 bezier_fragment(BezierVertexOut in [[stage_in]])
{
  return float4(1.0, 1.0, 0.0, 1.0);
}
