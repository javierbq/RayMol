// sphere.metal — Sphere impostor rendering with ray-sphere intersection
#include "pymol_metal_common.h"

struct SphereVertexIn {
  float4 a_vertex_radius  [[attribute(0)]];
  float4 a_Color          [[attribute(1)]];
  float  a_rightUpFlags   [[attribute(2)]];
};

struct SphereVertexOut {
  float4 position       [[position]];
  float4 color;
  float3 sphere_center;
  float  radius2;
  float3 point;
  float2 bgTextureLookup;
};

struct SphereVertexUniforms {
  float sphere_size_scale;
};

// Horizontial and vertical adjustment of outer tangent hitting the impostor quad
inline float2 outer_tangent_adjustment(float3 center, float radius_sq) {
  float2 xy_dist = float2(length(center.xz), length(center.yz));
  float2 cos_a = clamp(center.z / xy_dist, -1.0, 1.0);
  float2 cos_b = xy_dist / sqrt(radius_sq + (xy_dist * xy_dist));
  float2 cos_ab = cos_a * cos_b + sqrt((1.0 - cos_a * cos_a) * (1.0 - cos_b * cos_b));
  float2 cos_ab_sq = cos_ab * cos_ab;
  float2 tan_ab_sq = (1.0 - cos_ab_sq) / cos_ab_sq;
  float2 adjustment = sqrt(tan_ab_sq + 1.0);
  return min(adjustment, 10.0);
}

vertex SphereVertexOut sphere_vertex(
    SphereVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant SphereVertexUniforms& sphereU [[buffer(1)]])
{
  SphereVertexOut out;

  float radius = in.a_vertex_radius.w * sphereU.sphere_size_scale;
  radius /= length(float3(scene.g_NormalMatrix[0]));

  float right = -1.0 + 2.0 * fmod(in.a_rightUpFlags, 2.0);
  float up = -1.0 + 2.0 * floor(fmod(in.a_rightUpFlags / 2.0, 2.0));
  float4 tmppos = scene.g_ModelViewMatrix * float4(in.a_vertex_radius.xyz, 1.0);

  out.color = in.a_Color;
  out.radius2 = radius * radius;

  float2 corner_offset = float2(right, up);
  // Perspective adjustment (ortho skipped via compile-time flag if needed)
  corner_offset *= outer_tangent_adjustment(tmppos.xyz, out.radius2);

  float4 eye_space_pos = tmppos;
  eye_space_pos.xy += radius * corner_offset;

  out.sphere_center = tmppos.xyz / tmppos.w;
  out.point = eye_space_pos.xyz / eye_space_pos.w;

  out.position = scene.g_ProjectionMatrix * eye_space_pos;
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct SphereFragUniforms {
  bool lighting_enabled;
};

struct SphereFragOut {
  float4 color [[color(0)]];
  float depth [[depth(any)]];
};

fragment SphereFragOut sphere_fragment(
    SphereVertexOut in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant FogUniforms& fogU [[buffer(1)]],
    constant LightingUniforms& lighting [[buffer(2)]],
    constant SphereFragUniforms& fragU [[buffer(3)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  SphereFragOut out;

  // Perspective ray casting
  float3 ray_origin = float3(0.0);
  float3 ray_direction = normalize(in.point);
  float3 sphere_direction = in.sphere_center;

  float b = dot(sphere_direction, ray_direction);
  float position = b * b + in.radius2 - dot(sphere_direction, sphere_direction);

  if (position < 0.0)
    discard_fragment();

  float nearest = b - sqrt(position);
  float3 ipoint = nearest * ray_direction + ray_origin;
  float3 normal = normalize(ipoint - in.sphere_center);

  float2 clipZW = ipoint.z * scene.g_ProjectionMatrix[2].zw +
      scene.g_ProjectionMatrix[3].zw;
  float depth = 0.5 + 0.5 * clipZW.x / clipZW.y;

  if (depth <= 0.0 || depth >= 1.0)
    discard_fragment();

  out.depth = depth;

  if (!fogU.isPicking) {
    if (fragU.lighting_enabled) {
      float4 color = ApplyColorEffects(in.color, depth);
      color = ApplyLighting(color, normal, lighting);
      float fogv = (scene.g_Fog_end + ipoint.z) * scene.g_Fog_scale;
      float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
      out.color = ApplyFog(color, fogv, fogU.isPicking, fogU.depth_cue, bgColor);
    } else {
      out.color = in.color;
    }
  } else {
    if (in.color.a == 0.0)
      discard_fragment();
    out.color = in.color;
  }

  return out;
}
