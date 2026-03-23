// cylinder.metal — Cylinder impostor rendering with ray-cylinder intersection
#include "pymol_metal_common.h"

struct CylinderVertexIn {
  float3 attr_vertex1   [[attribute(0)]];
  float3 attr_vertex2   [[attribute(1)]];
  float4 a_Color        [[attribute(2)]];
  float4 a_Color2       [[attribute(3)]];
  float  attr_radius    [[attribute(4)]];
  float  a_cap          [[attribute(5)]];
  float  attr_flags     [[attribute(6)]];
};

struct CylinderVertexOut {
  float4 position       [[position]];
  float3 surface_point;
  float3 axis;
  float3 base;
  float3 end_cyl;
  float3 U;
  float3 V;
  float  radius;
  float  cap;
  float  inv_sqr_height;
  float4 color1;
  float4 color2;
  float2 bgTextureLookup;
};

struct CylinderVertexUniforms {
  float uni_radius;
};

inline float get_bit_and_shift_f(thread float& bits) {
  float bit = fmod(bits, 2.0);
  bits = (bits - bit) / 2.0;
  return step(0.5, bit);
}

vertex CylinderVertexOut cylinder_vertex(
    CylinderVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant CylinderVertexUniforms& cylU [[buffer(1)]])
{
  CylinderVertexOut out;
  float uniformglscale = length(float3(scene.g_NormalMatrix[0]));

  float radius;
  if (cylU.uni_radius != 0.0)
    radius = cylU.uni_radius * in.attr_radius;
  else
    radius = in.attr_radius;

  out.color1 = in.a_Color;
  out.color2 = in.a_Color2;

  float3 attr_axis = in.attr_vertex2 - in.attr_vertex1;
  out.cap = in.a_cap;

  float inv_sqr_height = length(attr_axis) / uniformglscale;
  inv_sqr_height *= inv_sqr_height;
  out.inv_sqr_height = 1.0 / inv_sqr_height;

  float3 h = normalize(attr_axis);
  float3 ax = normalize(scene.g_NormalMatrix * h);
  out.axis = ax;

  float3 u = cross(h, float3(1.0, 0.0, 0.0));
  if (dot(u, u) < 0.001)
    u = cross(h, float3(0.0, 1.0, 0.0));
  u = normalize(u);
  float3 v = normalize(cross(u, h));

  out.U = normalize(scene.g_NormalMatrix * u);
  out.V = normalize(scene.g_NormalMatrix * v);

  float4 base4 = scene.g_ModelViewMatrix * float4(in.attr_vertex1, 1.0);
  out.base = base4.xyz;
  float4 end4 = scene.g_ModelViewMatrix * float4(in.attr_vertex2, 1.0);
  out.end_cyl = end4.xyz;

  float4 vertex = float4(in.attr_vertex1, 1.0);
  float packed_flags = in.attr_flags;
  float out_v = get_bit_and_shift_f(packed_flags);
  float up_v = get_bit_and_shift_f(packed_flags);
  float right_v = get_bit_and_shift_f(packed_flags);
  vertex.xyz += up_v * attr_axis;
  vertex.xyz += (2.0 * right_v - 1.0) * radius * u;
  vertex.xyz += (2.0 * out_v - 1.0) * radius * v;
  vertex.xyz += (2.0 * up_v - 1.0) * radius * h;

  float4 tvertex = scene.g_ModelViewMatrix * vertex;
  out.surface_point = tvertex.xyz;

  out.position = scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * vertex;

  radius /= uniformglscale;
  out.radius = radius;

  // Clamp z on front clipping plane if impostor box would be clipped
  if (out.position.z / out.position.w < -1.0) {
    float diff = abs(base4.z - end4.z) + radius * 3.5;
    float4 inset = scene.g_ModelViewMatrix * vertex;
    inset.z -= diff;
    inset = scene.g_ProjectionMatrix * inset;
    if (inset.z / inset.w > -1.0) {
      out.position.z = -out.position.w;
    }
  }

  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;
  return out;
}

struct CylinderFragUniforms {
  float inv_height;
  bool no_flat_caps;
  float half_bond;
  bool lighting_enabled;
};

struct CylinderFragOut {
  float4 color [[color(0)]];
  float depth [[depth(any)]];
};

inline bool get_bit_and_shift_b(thread float& bits) {
  float bit = fmod(bits, 2.0);
  bits = (bits - bit) / 2.0;
  return bit > 0.5;
}

fragment CylinderFragOut cylinder_fragment(
    CylinderVertexOut in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant FogUniforms& fogU [[buffer(1)]],
    constant LightingUniforms& lighting [[buffer(2)]],
    constant CylinderFragUniforms& cylFragU [[buffer(3)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  CylinderFragOut out;

  float3 ray_target = in.surface_point;
  float3 ray_origin = float3(0.0);
  float3 ray_direction = normalize(-ray_target);

  float3x3 basis = float3x3(in.U, in.V, in.axis);

  float2 P = ((ray_target - in.base) * basis).xy;
  float2 D = (ray_direction * basis).xy;

  float radius2 = in.radius * in.radius;

  float a0 = P.x * P.x + P.y * P.y - radius2;
  float a1 = P.x * D.x + P.y * D.y;
  float a2 = D.x * D.x + D.y * D.y;
  float d = a1 * a1 - a0 * a2;
  if (d < 0.0)
    discard_fragment();

  float dist = (-a1 + sqrt(d)) / a2;
  float3 new_point = ray_target + dist * ray_direction;

  float3 tmp_point = new_point - in.base;
  float3 normal = normalize(tmp_point - in.axis * dot(tmp_point, in.axis));

  float fcap = in.cap + 0.001;
  bool frontcap      = get_bit_and_shift_b(fcap);
  bool endcap        = get_bit_and_shift_b(fcap);
  bool frontcapround = get_bit_and_shift_b(fcap) && cylFragU.no_flat_caps;
  bool endcapround   = get_bit_and_shift_b(fcap) && cylFragU.no_flat_caps;
  bool nocolorinterp = !get_bit_and_shift_b(fcap);

  float4 color;
  float ratio = dot(new_point - in.base, in.end_cyl - in.base) * in.inv_sqr_height;

  if (fogU.isPicking || !cylFragU.lighting_enabled) {
    ratio = step(0.5, ratio);
  } else if (nocolorinterp) {
    float dp = clamp(-cylFragU.half_bond * new_point.z * cylFragU.inv_height, 0.0, 0.5);
    ratio = smoothstep(0.5 - dp, 0.5 + dp, ratio);
  } else {
    ratio = clamp(ratio, 0.0, 1.0);
  }
  color = mix(in.color1, in.color2, ratio);

  bool cap_test_base = 0.0 > dot(new_point - in.base, in.axis);
  bool cap_test_end  = 0.0 < dot(new_point - in.end_cyl, in.axis);

  if (cap_test_base || cap_test_end) {
    float3 thisaxis = -in.axis;
    float3 thisbase = in.base;

    if (cap_test_end) {
      thisaxis = in.axis;
      thisbase = in.end_cyl;
      frontcap = endcap;
      frontcapround = endcapround;
    }

    if (!frontcap)
      discard_fragment();

    if (frontcapround) {
      float3 sphere_direction = thisbase - ray_origin;
      float b = dot(sphere_direction, ray_direction);
      float pos = b * b + radius2 - dot(sphere_direction, sphere_direction);
      if (pos < 0.0)
        discard_fragment();
      float near = sqrt(pos) + b;
      new_point = near * ray_direction + ray_origin;
      normal = normalize(new_point - thisbase);
    } else {
      float dNV = dot(thisaxis, ray_direction);
      if (dNV < 0.0)
        discard_fragment();
      float near = dot(thisaxis, thisbase - ray_origin) / dNV;
      new_point = ray_direction * near + ray_origin;
      if (dot(new_point - thisbase, new_point - thisbase) > radius2)
        discard_fragment();
      normal = thisaxis;
    }
  }

  float2 clipZW = new_point.z * scene.g_ProjectionMatrix[2].zw +
      scene.g_ProjectionMatrix[3].zw;
  float depth = 0.5 + 0.5 * clipZW.x / clipZW.y;

  if (depth <= 0.0)
    discard_fragment();

  out.depth = depth;

  if (!fogU.isPicking && cylFragU.lighting_enabled) {
    color = ApplyColorEffects(color, depth);
    color = ApplyLighting(color, normal, lighting);
  }

  if (fogU.isPicking) {
    out.color = color;
  } else {
    float fog = (scene.g_Fog_end + new_point.z) * scene.g_Fog_scale;
    float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
    out.color = ApplyFog(color, fog, fogU.isPicking, fogU.depth_cue, bgColor);
  }

  return out;
}
