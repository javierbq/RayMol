// batch.metal — Simple shader for immediate-mode batch rendering
//
// Matches the BatchVertex layout used by RendererMetal::endBatch():
//   float x, y, z      (position)
//   float r, g, b, a   (color)
//   float nx, ny, nz   (normal — unused for now)
//
// Uniform buffer at index 1:
//   float4x4 modelview
//   float4x4 projection

#include <metal_stdlib>
using namespace metal;

struct BatchVertexIn {
  float3 position [[attribute(0)]];
  float4 color    [[attribute(1)]];
  float3 normal   [[attribute(2)]];
};

struct BatchUniforms {
  float4x4 modelview;
  float4x4 projection;
};

struct BatchVertexOut {
  float4 position [[position]];
  float4 color;
};

vertex BatchVertexOut batch_vertex(
    BatchVertexIn in [[stage_in]],
    constant BatchUniforms& uniforms [[buffer(1)]])
{
  BatchVertexOut out;
  out.position = uniforms.projection * uniforms.modelview * float4(in.position, 1.0);
  out.color = in.color;
  return out;
}

fragment float4 batch_fragment(BatchVertexOut in [[stage_in]])
{
  return in.color;
}
