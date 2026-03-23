// indicator.metal — Point indicator rendering
#include "pymol_metal_common.h"

struct IndicatorVertexIn {
  float4 a_Vertex [[attribute(0)]];
  float4 a_Color  [[attribute(1)]];
};

struct IndicatorVertexOut {
  float4 position   [[position]];
  float4 color;
  float  pointSize  [[point_size]];
};

struct IndicatorVertexUniforms {
  float g_pointSize;
};

vertex IndicatorVertexOut indicator_vertex(
    IndicatorVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant IndicatorVertexUniforms& indU [[buffer(1)]])
{
  IndicatorVertexOut out;
  out.color = in.a_Color;
  out.pointSize = indU.g_pointSize;
  out.position = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_Vertex;
  return out;
}

struct IndicatorFragUniforms {
  float2 textureLookup;
  float2 textureScale;
  float g_pointSize;
  float4 viewport;
};

fragment float4 indicator_fragment(
    IndicatorVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant IndicatorFragUniforms& fragU [[buffer(0)]],
    texture2d<float> textureMap [[texture(0)]],
    sampler texSampler [[sampler(0)]])
{
  return textureMap.sample(texSampler, fragU.textureLookup + pointCoord * fragU.textureScale);
}
