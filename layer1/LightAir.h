/*
 * The air (haze and dust, #618, lighting epic #610): what one frame's air
 * pass reads, as pure functions over plain data.
 *
 * Like LightShading.h and LightShadows.h: no PyMOLGlobals, no Python, no file
 * statics. CI tests them from Python through _cmd (get_light_air_frame,
 * light_air_clock, light_air_time, light_air_resolution,
 * light_air_shadow_filter); the scene glue is SceneLightsAir() and
 * SceneLightsAirAnimating() (SceneLights.h).
 *
 * Every air length is in rig sizes (the captured frame's 1x radius), so the
 * air looks the same on a small protein and on a ribosome. The air spans the
 * rig centre's eye depth +- kLightAirRangeSizes sizes, from the captured
 * frame, never from the visible extent: showing, hiding or zooming never
 * moves it.
 *
 * The constants are named once here, and once in kAirSrc (the MSL); a source
 * test pins them equal.
 *
 * Nothing here runs unless the rig is on with haze or dust: with no rig, a rig
 * that is off, or air at zero, SceneLightsFrame() never calls these and the
 * frame draws no air.
 */

#pragma once

#include <optional>

#include <glm/mat4x4.hpp>
#include <glm/vec3.hpp>

#include "LightAirBlock.h"
#include "LightRig.h"

namespace pymol
{

/* ---- the model's constants (kAirSrc mirrors the shader's) -------------- */

/// The air spans the rig centre's eye depth +- this many rig sizes.
inline constexpr double kLightAirRangeSizes = 1.8;
/// The near end of the air is never closer to the eye than this (Å).
inline constexpr double kLightAirMinNear = 0.5;
/// A dust cell is this many rig sizes, and at least kLightAirMinCell Å.
inline constexpr double kLightAirCellSizes = 0.15;
inline constexpr double kLightAirMinCell = 0.5;
/// Haze density per Å at haze 1 is this over the rig size. Calibrated once
/// (#618) on 1rx1's captured size (36.4 Å, the half diagonal of its extent)
/// to the prototype's 0.02 / Å, then frozen.
inline constexpr double kLightAirHazeDensity = 0.73;
/// A mote's radius at dust_size 1, in dust cells (before its own factor).
/// Calibrated once (#618) on 1rx1's captured size, where a dust cell is
/// 0.15 x 36.4 Å, to the prototype's dust_size Å, then frozen.
inline constexpr double kLightAirMoteCells = 0.18;
/// Defocus: the mote blur per Å away from the focus depth, over the rig size.
inline constexpr double kLightAirDefocus = 0.3;
/// A dust cell holds a mote when its hash is <= this times dust.
inline constexpr double kLightAirOccupancy = 0.35;
/// The dust time wraps here (s), so float32 keeps its precision.
inline constexpr double kLightAirTimeWrap = 20000.0;
/// movie_fps 0 or less reads as this.
inline constexpr double kLightAirDefaultFps = 30.0;
/// Phase function caps (haze, dust) and the falloff cap.
inline constexpr double kLightAirHazePhaseCap = 5.0;
inline constexpr double kLightAirDustPhaseCap = 8.0;
inline constexpr double kLightAirFalloffCap = 4.0;
/// Haze steps along a view ray, and dust depth layers.
inline constexpr int kLightAirHazeSteps = 48;
inline constexpr int kLightAirDustLayers = 32;
/// The scatter (Henyey-Greenstein g) is clamped to +-this.
inline constexpr double kLightAirMaxScatter = 0.9;
/// Half resolution: the upsample's depth similarity is a Gaussian this share
/// of the air's range wide (the eye depth where each march stopped), so the
/// air does not bleed across a silhouette. Used only by the shader.
inline constexpr double kLightAirDepthSigma = 0.02;

/// metal_light_air_resolution / metal_light_air_shadow_filter values.
inline constexpr int kLightAirFull = 1;
inline constexpr int kLightAirHalf = 2;
inline constexpr int kLightAirOneTap = 1;
inline constexpr int kLightAirLookup = 2;

/* ---- the frame's air ---------------------------------------------------- */

/// The rig's air with the rig frame in eye space: what the frame needs to
/// pack the air block (SceneLightFrame::airSource).
struct LightAirSource {
  LightAir air;
  /// The rig centre in camera eye space (Å).
  glm::vec3 centreEye{0.0f};
  /// The rig size (1x radius) in eye units: size times the matrix's largest
  /// column scale (1 for a camera).
  float sizeEye = 0.0f;
};

/// The air shows something: haze > 0 or dust > 0.
bool LightAirActive(const LightAir& air);

/// The rig's air and frame resolved with `worldToEye`. Call only for a rig
/// with a frame (LightRigIsOn); a missing frame reads as the origin and 1 Å.
LightAirSource LightAirSourceOf(const LightRig& rig, const glm::dmat4& worldToEye);

/// metal_light_air_resolution: 1 full or 2 half. 0 (and anything else) is the
/// platform default: full on the desktop, half when `mobile` (provisional
/// until #623).
int LightAirResolution(int setting, bool mobile);

/// metal_light_air_shadow_filter: the haze's shadow lookup, 1 one hardware
/// compare per step or 2 #616's 3x3 lookup verbatim. 0 (and anything else) is
/// the platform default: one tap on both (provisional until L6 and #623).
int LightAirShadowFilter(int setting, bool mobile);

/// What the dust clock reads.
struct LightAirClockInputs {
  /// metal_light_air_time: >= 0 pins the clock (s); below 0 it is unpinned.
  double pinned = -1.0;
  /// The frame renders offscreen (an export, png, the RT throwaway frame).
  bool offscreen = false;
  /// A movie plays (live frames only).
  bool playing = false;
  /// SceneCountFrames and SceneGetFrame (0-based).
  int frames = 1;
  int frame = 0;
  /// movie_fps; 0 or less reads as kLightAirDefaultFps.
  double fps = kLightAirDefaultFps;
  /// The live clock (UtilGetSeconds).
  double wallSeconds = 0.0;
};

/**
 * The dust clock (s), before dust_speed. In order: a pin (pinned >= 0);
 * movie time frame / fps when there is a movie (frames > 1) and the frame is
 * offscreen or the movie plays; 0 for an offscreen still with no movie (so a
 * still is repeatable); the wall clock for the live view.
 */
double LightAirClock(const LightAirClockInputs& in);

/// The dust time: fmod(max(clock, 0) x max(speed, 0), kLightAirTimeWrap).
/// Never negative; 0 for a non-finite product.
double LightAirTime(double clock, double speed);

/// The dust pattern's offset for `seed`: fract(seed x golden ratio) x 1000,
/// computed in double. 0 for seed 0.
float LightAirSeedOffset(int seed);

/**
 * The dust moves on its own, so the live view must redraw for it: dust > 0
 * and dust_speed > 0, the clock not pinned, no movie playing (playback
 * redraws already), no grid and something to light. The rig being on is the
 * caller's check.
 */
bool LightAirAnimating(const LightAir& air, double pinned, bool playing,
    bool geometry, bool grid);

/**
 * The air block for the source, with the dust clock `clock` (s, before
 * dust_speed), `resolution` (LightAirResolution) and `shadowFilter`
 * (LightAirShadowFilter). nullopt when the air shows nothing or its range is
 * empty (the rig is behind the camera). The renderer fills view.y and proj.
 */
std::optional<LightAirBlock> LightAirPack(const LightAirSource& source,
    double clock, int resolution, int shadowFilter);

} // namespace pymol
