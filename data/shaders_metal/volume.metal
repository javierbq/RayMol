// volume.metal — Volume rendering (3D texture slicing)
#include "pymol_metal_common.h"

struct VolumeVertexIn {
  float4 a_Vertex   [[attribute(0)]];
  float4 a_TexCoord [[attribute(1)]];
};

struct VolumeVertexOut {
  float4 position       [[position]];
  float3 texCoord;
  float  fog;
  float2 bgTextureLookup;
};

vertex VolumeVertexOut volume_vertex(
    VolumeVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]])
{
  VolumeVertexOut out;
  float4 vertex = scene.g_ModelViewMatrix * in.a_Vertex;
  out.texCoord = in.a_TexCoord.xyz;
  out.position = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_Vertex;
  out.fog = (scene.g_Fog_end + vertex.z) * scene.g_Fog_scale;
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct VolumeFragUniforms {
  float volumeScale;
  float volumeBias;
  float sliceDist;
  bool carvemaskFlag;
};

fragment float4 volume_fragment(
    VolumeVertexOut in [[stage_in]],
    constant FogUniforms& fogU [[buffer(0)]],
    constant VolumeFragUniforms& volU [[buffer(1)]],
    texture3d<float> volumeTex [[texture(0)]],
    texture1d<float> colorTex1D [[texture(1)]],
    texture3d<float> carvemask [[texture(2)]],
    texture2d<float> bgTextureMap [[texture(3)]],
    sampler volSampler [[sampler(0)]],
    sampler colorSampler [[sampler(1)]],
    sampler bgSampler [[sampler(2)]])
{
  if (volU.carvemaskFlag && carvemask.sample(volSampler, in.texCoord).r > 0.5)
    discard_fragment();

  float v = volumeTex.sample(volSampler, in.texCoord).r;
  v = v * volU.volumeScale + volU.volumeBias;
  if (v < 0.0 || v > 1.0)
    discard_fragment();

  float4 color = colorTex1D.sample(colorSampler, v);
  if (color.a == 0.0)
    discard_fragment();

  color = ApplyColorEffects(color, in.position.z);
  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
