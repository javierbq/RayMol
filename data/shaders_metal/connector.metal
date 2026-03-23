// connector.metal — Label connector rendering
//
// NOTE: The GLSL version uses a geometry shader (connector.gs) to generate
// connector line geometry on the fly. Metal has no geometry shaders.
//
// Strategy: The C++ code must pre-expand the connector geometry into triangle
// strips (as the geometry shader would have done) and submit them as regular
// triangles. This shader then just does the simple vertex transform and
// fragment coloring that the geometry shader's output feeds into connector.fs.
//
// The connector vertex buffer should contain pre-expanded vertices with:
//   - position (already in clip space or world space)
//   - color
//   - lineEdge (for antialiasing)
//   - aaCutoff
//   - fog
//   - normal
//
// This is the "non-geometry-shader" path that the GLSL code also supports
// (when use_geometry_shaders is not defined), but with triangle-strip
// expansion done on the CPU side.

#include "pymol_metal_common.h"

// ============================================================
// Non-geometry-shader path (pre-expanded connector vertices)
// ============================================================

struct ConnectorVertexIn {
  float4 a_target_pt3d      [[attribute(0)]];
  float4 a_center_pt3d      [[attribute(1)]];
  float3 a_indentFactor      [[attribute(2)]];
  float3 a_screenWorldOffset [[attribute(3)]];
  float2 a_textSize          [[attribute(4)]];
  float4 a_Color             [[attribute(5)]];
  float  a_relative_mode     [[attribute(6)]];
  float  a_draw_flags        [[attribute(7)]];
  float4 a_bkgrd_color       [[attribute(8)]];
  float  a_rel_ext_length    [[attribute(9)]];
  float  a_con_width         [[attribute(10)]];
  float  a_isCenterPt        [[attribute(11)]];
};

struct ConnectorVertexOut {
  float4 position       [[position]];
  float4 color;
  float3 normal;
  float  fog;
  float2 bgTextureLookup;
};

struct ConnectorVertexUniforms {
  float2 screenSize;
  float screenOriginVertexScale;
  float labelTextureSize;
  float front;
  float clipRange;
};

// Connector offset computation helpers (matching connector.shared)

inline float2 computeConnectorOffset_0(float2 drawVector) {
  float hmid = step(abs(drawVector.x), 0.5);
  float vmid = step(abs(drawVector.y), 0.5);
  float right = (1.0 - hmid) * step(0.0, drawVector.x) + hmid * 0.5;
  float top = (1.0 - vmid) * step(0.0, drawVector.y) + vmid * 0.5;
  return float2(2.0 * (right - 0.5), 2.0 * (top - 0.5));
}

inline float2 computeConnectorOffset_1(float2 drawVector) {
  float2 drawVectorN = normalize(drawVector);
  float absyx = step(abs(drawVectorN.y), abs(drawVectorN.x));
  float notabsyx = 1.0 - absyx;
  float hdir = 2.0 * (step(0.0, drawVectorN.x) - 0.5);
  float vdir = 2.0 * (step(0.0, drawVectorN.y) - 0.5);
  float dvxy = drawVector.x / drawVector.y;
  float dvyx = drawVector.y / drawVector.x;
  return float2(
    (absyx * hdir) + (notabsyx * vdir * dvxy),
    (notabsyx * vdir) + (absyx * hdir * dvyx));
}

inline float4 normalizeVec4Conn(float4 point, float2 screenSize) {
  float4 retPt = float4(point.xyz / point.w, 1.0);
  retPt.xy = (floor(retPt.xy * screenSize + 0.5) + 0.5) / screenSize;
  return retPt;
}

inline float convertNormalZToScreenZConn(float normalz, float front, float clipRange,
                                          float4x4 projMatrix) {
  float a_centerN = (normalz + 1.0) / 2.0;
  float ptZ = -(front + clipRange * a_centerN);
  float4 projVect = projMatrix * float4(0.0, 0.0, ptZ, 1.0);
  return projVect.z / projVect.w;
}

vertex ConnectorVertexOut connector_vertex(
    ConnectorVertexIn in [[stage_in]],
    constant SceneUniforms& scene [[buffer(0)]],
    constant ConnectorVertexUniforms& connU [[buffer(1)]],
    constant FogUniforms& fogU [[buffer(2)]])
{
  ConnectorVertexOut out;
  out.normal = float3(0.0, 0.0, 1.0);
  out.color = in.a_Color;

  float isScreenCoord = step(2.0, fmod(in.a_relative_mode, 4.0));
  float isPixelCoord = step(4.0, fmod(in.a_relative_mode, 8.0));
  float isProjected = step(isPixelCoord + isScreenCoord, 0.5);
  float zTarget = step(8.0, fmod(in.a_relative_mode, 16.0));

  float4 tCenter = normalizeVec4Conn(scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_center_pt3d, connU.screenSize);
  float4 tTarget = normalizeVec4Conn(scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * in.a_target_pt3d, connU.screenSize);

  float3 viewVector = float3(float4(0.0, 0.0, -1.0, 0.0) * scene.g_ModelViewMatrix);
  float4 a_centerp = in.a_center_pt3d + in.a_screenWorldOffset.z * float4(viewVector, 0.0);
  float4 transformedPositionZ = normalizeVec4Conn(scene.g_ProjectionMatrix * scene.g_ModelViewMatrix * a_centerp, connU.screenSize);

  float zValue = (1.0 - zTarget) * ((isProjected * transformedPositionZ.z) +
      (1.0 - isProjected) * convertNormalZToScreenZConn(in.a_center_pt3d.z, connU.front, connU.clipRange, scene.g_ProjectionMatrix)) +
      zTarget * tTarget.z;
  zValue += 1e-4;

  float2 pixOffset = (2.0 * in.a_center_pt3d.xy / connU.screenSize) - 1.0;
  tCenter = isProjected * tCenter + isScreenCoord * in.a_center_pt3d + isPixelCoord * float4(pixOffset.x, pixOffset.y, -0.5, 0.0);
  tCenter.w = 1.0;

  float2 tsScreen = in.a_textSize / connU.screenSize;
  float sovx = connU.screenOriginVertexScale;
  float2 offset = in.a_indentFactor.xy * tsScreen + in.a_screenWorldOffset.xy / (connU.screenSize * sovx);
  float2 dVector = (tTarget.xy - tCenter.xy - offset) / tsScreen;

  // Decode draw flags
  float drawFlags = in.a_draw_flags;
  float connector_mode_1 = step(8.0, fmod(drawFlags, 16.0));
  float connector_mode_0 = 1.0 - step(0.5, connector_mode_1);

  float2 conOff;
  if (connector_mode_0 > 0.0)
    conOff = computeConnectorOffset_0(dVector);
  else
    conOff = computeConnectorOffset_1(dVector);

  float2 addXY = offset + tsScreen * conOff;
  float4 endpointOnBBX = tCenter;
  endpointOnBBX.xy += addXY;
  endpointOnBBX.z = zValue;

  float3 eye_pos = (isProjected * (scene.g_ModelViewMatrix * in.a_center_pt3d) + (1.0 - isProjected) * in.a_center_pt3d).xyz;
  out.fog = (scene.g_Fog_end - abs(eye_pos.z)) * scene.g_Fog_scale;

  float withinView = step(zValue, 1.0) * step(-1.0, zValue);
  tTarget.z = withinView * tTarget.z + (1.0 - withinView) * zValue;

  // Pick between target and endpoint based on a_isCenterPt
  float isCenterPt = in.a_isCenterPt;
  out.position = mix(tTarget, endpointOnBBX, step(0.5, isCenterPt));
  out.bgTextureLookup = (out.position.xy / out.position.w) / 2.0 + 0.5;

  return out;
}

fragment float4 connector_fragment(
    ConnectorVertexOut in [[stage_in]],
    constant FogUniforms& fogU [[buffer(0)]],
    texture2d<float> bgTextureMap [[texture(0)]],
    sampler bgSampler [[sampler(0)]])
{
  float4 color = ApplyColorEffects(in.color, in.position.z);
  float3 bgColor = ComputeBgColor(fogU, in.bgTextureLookup, bgTextureMap, bgSampler);
  return ApplyFog(color, in.fog, fogU.isPicking, fogU.depth_cue, bgColor);
}
