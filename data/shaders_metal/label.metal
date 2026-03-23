// label.metal — Text/label rendering with texture atlas
#include "pymol_metal_common.h"

struct LabelVertexIn {
  float4 attr_targetpos       [[attribute(0)]];
  float4 attr_worldpos        [[attribute(1)]];
  float3 attr_screenoffset    [[attribute(2)]];
  float2 attr_texcoords       [[attribute(3)]];
  float3 attr_screenworldoffset [[attribute(4)]];
  float4 attr_pickcolor       [[attribute(5)]];
  float  attr_relative_mode   [[attribute(6)]];
};

struct LabelVertexOut {
  float4 position             [[position]];
  float2 textureLookup;
  float3 normalizedViewCoordinate;
  float4 pickcolor;
  float  fog;
};

struct LabelVertexUniforms {
  float2 screenSize;
  float screenOriginVertexScale;
  float scaleByVertexScale;
  float labelTextureSize;
  float front;
  float clipRange;
};

inline float4 normalizeVec4Label(float4 point) {
  return float4(point.xyz / point.w, 1.0);
}

inline float convertNormalZToScreenZ(float normalz, float front, float clipRange,
                                      constant SceneUniforms& scene) {
  float a_centerN = (normalz + 1.0) / 2.0;
  float ptInPreProjectionZ = -(front + clipRange * a_centerN);
  float4 ptInPreProjection = float4(0.0, 0.0, ptInPreProjectionZ, 1.0);
  float4 projVect = scene.g_ProjectionMatrix * ptInPreProjection;
  return projVect.z / projVect.w;
}

vertex LabelVertexOut label_vertex(
    LabelVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant LabelVertexUniforms& labelU [[buffer(1)]],
    constant FogUniforms& fogU [[buffer(2)]])
{
  LabelVertexOut out;

  float isScreenCoord = step(2.0, fmod(in.attr_relative_mode, 4.0));
  float isPixelCoord = step(4.0, fmod(in.attr_relative_mode, 8.0));
  float zTarget = step(8.0, fmod(in.attr_relative_mode, 16.0));
  float isProjected = step(isPixelCoord + isScreenCoord, 0.5);

  float3 viewVector = float3(float4(0.0, 0.0, -1.0, 0.0) * scene.g_ModelViewMatrix);
  float sovx = labelU.screenOriginVertexScale;
  float screenVertexScale = labelU.scaleByVertexScale * sovx * labelU.labelTextureSize + (1.0 - labelU.scaleByVertexScale);

  float4 transformedPosition = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.attr_worldpos;
  float4 targetPosition = normalizeVec4Label(scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.attr_targetpos);
  transformedPosition.xyz = transformedPosition.xyz / transformedPosition.w;
  transformedPosition.xy = (floor(transformedPosition.xy * labelU.screenSize + 0.5) + 0.5) / labelU.screenSize;

  float4 a_center = in.attr_worldpos + in.attr_screenworldoffset.z * float4(viewVector, 0.0);
  float4 transformedPositionZ = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * a_center;
  transformedPositionZ.xyz = transformedPositionZ.xyz / transformedPositionZ.w;
  transformedPositionZ.w = 1.0;

  float2 pixOffset = (2.0 * in.attr_worldpos.xy / labelU.screenSize) - 1.0;
  transformedPosition = isProjected * transformedPosition + isScreenCoord * in.attr_worldpos + isPixelCoord * float4(pixOffset.x, pixOffset.y, -0.5, 0.0);
  transformedPosition.xy = transformedPosition.xy + in.attr_screenworldoffset.xy / (labelU.screenSize * sovx);

  transformedPosition.z = (1.0 - zTarget) * ((isProjected * transformedPositionZ.z) +
      (1.0 - isProjected) * convertNormalZToScreenZ(in.attr_worldpos.z, labelU.front, labelU.clipRange, scene)) +
      zTarget * targetPosition.z;

  transformedPosition.xy += in.attr_screenoffset.xy * 2.0 / (labelU.screenSize * screenVertexScale);
  transformedPosition.w = 1.0;

  out.position = transformedPosition;
  out.textureLookup = in.attr_texcoords;
  out.normalizedViewCoordinate = (out.position.xyz / out.position.w) / 2.0 + 0.5;

  if (fogU.depth_cue) {
    float3 eye_pos = mix(in.attr_worldpos, scene.g_ModelViewMatrix * in.attr_worldpos, isProjected).xyz;
    out.fog = max((scene.g_Fog_end + eye_pos.z) * scene.g_Fog_scale, 0.0);
  } else {
    out.fog = 1.1;
  }

  out.pickcolor = in.attr_pickcolor;
  return out;
}

fragment float4 label_fragment(
    LabelVertexOut in [[stage_in]],
    constant FogUniforms& fogU [[buffer(0)]],
    texture2d<float> textureMap [[texture(0)]],
    texture2d<float> bgTextureMap [[texture(1)]],
    sampler texSampler [[sampler(0)]],
    sampler bgSampler [[sampler(1)]])
{
  if (fogU.isPicking) {
    return in.pickcolor;
  }

  float4 color = textureMap.sample(texSampler, in.textureLookup);
  if (color.a < 0.05)
    discard_fragment();

  color = ApplyColorEffects(color, in.position.z);
  float3 bgColor = ComputeBgColor(fogU, in.normalizedViewCoordinate.xy, bgTextureMap, bgSampler);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
