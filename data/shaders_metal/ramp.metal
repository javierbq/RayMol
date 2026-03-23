// ramp.metal — Color ramp rendering
#include "pymol_metal_common.h"

struct RampVertexIn {
  float4 a_Vertex [[attribute(0)]];
  float4 a_Color  [[attribute(1)]];
  float3 a_Normal [[attribute(2)]];
};

struct RampVertexOut {
  float4 position [[position]];
  float4 color;
  float3 normal;
};

struct RampVertexUniforms {
  float3 offsetPt;
};

vertex RampVertexOut ramp_vertex(
    RampVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant RampVertexUniforms& rampU [[buffer(1)]])
{
  RampVertexOut out;
  out.color = in.a_Color;
  out.normal = in.a_Normal;
  float4 vertex = in.a_Vertex + float4(rampU.offsetPt, 0.0);
  out.position = scene.g_ProjectionMatrix * vertex;
  return out;
}

fragment float4 ramp_fragment(RampVertexOut in [[stage_in]])
{
  float NdotV = dot(in.normal, float3(0.0, 0.0, 1.0));
  return float4(NdotV * in.color.xyz, in.color.a);
}
