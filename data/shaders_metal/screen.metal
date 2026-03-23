// screen.metal — Screen-space text rendering (e.g. info overlay)
#include "pymol_metal_common.h"

struct ScreenVertexIn {
  float3 attr_screenoffset      [[attribute(0)]];
  float2 attr_texcoords         [[attribute(1)]];
  float4 attr_backgroundcolor   [[attribute(2)]];
};

struct ScreenVertexOut {
  float4 position       [[position]];
  float2 textureLookup;
  float4 backgroundColor;
};

struct ScreenVertexUniforms {
  float2 t2PixelSize;
};

vertex ScreenVertexOut screen_vertex(
    ScreenVertexIn in [[stage_in]],
    constant ScreenVertexUniforms& screenU [[buffer(0)]])
{
  ScreenVertexOut out;
  out.position = float4(
      in.attr_screenoffset.x * screenU.t2PixelSize.x - 1.0,
      in.attr_screenoffset.y * screenU.t2PixelSize.y - 1.0,
      0.9, 1.0);
  out.backgroundColor = in.attr_backgroundcolor;
  out.textureLookup = in.attr_texcoords;
  return out;
}

fragment float4 screen_fragment(
    ScreenVertexOut in [[stage_in]],
    texture2d<float> textureMap [[texture(0)]],
    sampler texSampler [[sampler(0)]])
{
  float4 fColor = textureMap.sample(texSampler, in.textureLookup);
  float4 bColor = in.backgroundColor * (1.0 - fColor.a);
  return float4(bColor.rgb + fColor.rgb * fColor.a, bColor.a + fColor.a);
}
