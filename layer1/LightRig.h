/*
 * Native light rig (#611, lighting epic #610).
 *
 * The rig is plain data owned by the scene (CScene::lightRig, see
 * SceneLights.h): up to six spot lights placed around the molecules, plus the
 * rig-level ambient/classic terms and the air (haze and dust) parameters.
 *
 * This header is included by SceneDef.h, so it reaches nearly every
 * translation unit, including the app bridge. Keep it to std headers, glm and
 * layer0 utilities: no PyMOLGlobals, no Python, no file statics. The Python
 * conversions live in LightRigPy.h and the scene glue in SceneLights.h.
 *
 * One field table (LightRigFields()) holds every field's name, kind and range.
 * It drives the getter and setter, the Python dict, the session list and
 * _cmd.get_light_fields(), so key names and ranges live in exactly one place.
 * Defaults live in the struct initializers below; the table reads them back
 * from default-constructed values.
 */

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <glm/vec3.hpp>

#include "Result.h"

namespace pymol
{

inline constexpr int kLightRigVersion = 1;
inline constexpr int kLightRigMaxLights = 6;
inline constexpr int kLightRigMaxShadowed = 3;
inline constexpr int kLightNameMaxLength = 32;

enum class LightAnchor { Camera = 0, Pinned = 1 };
enum class LightAim { Centre = 0, Point = 1 };

/**
 * One spot light (spec §4.2). Angles in degrees, positions in world Å.
 */
struct Light {
  std::string name;
  LightAnchor anchor = LightAnchor::Camera;
  /// Placement around the rig centre (spec §4.3): orbit 0 = at the camera,
  /// +90 = camera-right; pitch +90 = camera-up; radius in rig sizes. These are
  /// the last placed values and are inert while the light is pinned.
  double orbit = 0.0;
  double pitch = 30.0;
  double radius = 4.0;
  /// Where a pinned light sits (world Å).
  glm::dvec3 position{0.0};
  /// Aim: the rig centre, or a stored world point. The selection text the
  /// point came from is kept for display only (decision 17).
  LightAim aim = LightAim::Centre;
  glm::dvec3 aimPoint{0.0};
  std::string aimSelection;
  /// Full cone angle in degrees; never changed by a radius edit (decision 8).
  double beam = 45.0;
  double softness = 0.4;
  glm::dvec3 color{1.0}; ///< sRGB, each 0..1
  double warmth = 6500.0;  ///< kelvin; 6500 is neutral
  double intensity = 1.0;
  double highlight = 0.5;
  double falloff = 2.0;
  bool shadow = false;
  bool outline = false;
};

/**
 * Haze and dust (spec §4.1). What these mean is #618's; #611 stores them.
 */
struct LightAir {
  double haze = 0.0;
  double dust = 0.0;
  double dustSize = 0.35;
  double dustSpeed = 1.0;
  double scatter = 0.55;
  int seed = 0;
};

/**
 * The rig (spec §4.1). `centre` and `size` are the captured frame: both or
 * neither. A rig with lights always has a frame; an empty rig has none until
 * its first light (§4.3).
 */
struct LightRig {
  bool enabled = false;
  std::vector<Light> lights;
  std::optional<glm::dvec3> centre; ///< world Å
  std::optional<double> size;       ///< Å, the 1x radius
  double ambient = 0.05;
  double classic = 0.0;
  LightAir air;
};

/* ---- field table ------------------------------------------------------ */

enum class LightScope { Rig, Air, Light };

enum class LightKind {
  Bool,
  Int,
  Float,
  Angle,  ///< float degrees, wrapped into (lo, hi] instead of clamped
  Vec3,   ///< 3 floats; lo/hi apply to each component
  Str,
  Name,   ///< [A-Za-z_][A-Za-z0-9_]{0,31}, unique in the rig ignoring case
  Anchor, ///< "camera" | "pinned"
  Aim,    ///< "centre" | "point"
};

enum class LightFieldId {
  // rig
  Enabled,
  Centre,
  Size,
  Ambient,
  Classic,
  // air
  Haze,
  Dust,
  DustSize,
  DustSpeed,
  Scatter,
  Seed,
  // light
  Name,
  Anchor,
  Orbit,
  Pitch,
  Radius,
  Position,
  Aim,
  AimPoint,
  AimSelection,
  Beam,
  Softness,
  Color,
  Warmth,
  Intensity,
  Highlight,
  Falloff,
  Shadow,
  Outline,
};

struct LightField {
  LightFieldId id;
  LightScope scope;
  const char* name; ///< the dict, JSON and command key
  LightKind kind;
  bool optional;    ///< may be unset (None): the frame fields
  bool bounded;     ///< lo/hi apply
  double lo, hi;
};

/// One field's value, whatever its scope.
struct LightValue {
  bool unset = false;    ///< an optional field with no value (None)
  double num[3]{};       ///< Bool, Int, Float, Angle, Anchor, Aim: num[0]; Vec3: all
  std::string str;       ///< Str, Name
};

/// The table in dict / session / JSON order: rig fields, then air, then light.
const std::vector<LightField>& LightRigFields();

/// The field called `name` in `scope`, or nullptr.
const LightField* LightRigFindField(LightScope scope, std::string_view name);

/// Read a rig- or air-scope field.
LightValue LightFieldGet(const LightRig& rig, const LightField& field);
/// Read a light-scope field.
LightValue LightFieldGet(const Light& light, const LightField& field);

/// Store a rig- or air-scope field. Numbers are clamped into range (angles
/// wrapped), ints rounded, bools and choices are true / 1 from 0.5 up.
/// Nothing else is checked: LightRigValidate() does that.
void LightFieldPut(LightRig& rig, const LightField& field, const LightValue& value);
/// Store a light-scope field, as above.
void LightFieldPut(Light& light, const LightField& field, const LightValue& value);

/// `v` clamped to the field's range (wrapped for an Angle). Unbounded fields
/// return `v` unchanged.
double LightFieldClamp(const LightField& field, double v);

/// Degrees wrapped into (-180, 180]. Values already inside are returned
/// exactly.
double LightWrapDegrees(double deg);

/// The kind's name as get_light_fields() reports it: "bool", "int", "float",
/// "angle", "vec3", "str", "name", "camera|pinned", "centre|point".
const char* LightKindName(LightKind kind);

/// Choice kinds (Anchor, Aim): the text for index 0/1, and the index for a
/// text (-1 when it is not one of the choices).
const char* LightChoiceName(LightKind kind, int index);
int LightChoiceIndex(LightKind kind, std::string_view text);

/// True for [A-Za-z_][A-Za-z0-9_]{0,31}.
bool LightNameValid(std::string_view name);

/// The first of key, fill, rim, light4, light5, light6 (then light7, ...) not
/// in `taken`, ignoring case.
std::string LightRigNextName(const std::vector<std::string>& taken);

/**
 * Check the rig's invariants: at most 6 lights and 3 shadowed lights; names
 * valid and unique ignoring case; centre and size both or neither, size > 0,
 * and a frame whenever there are lights; every number finite and in range.
 * The message names the light and the field.
 */
pymol::Result<> LightRigValidate(const LightRig& rig);

/* ---- placement helpers (spec §4.3) ------------------------------------- */

/// Unit offset of a camera light from the rig centre, in eye space:
/// (sin orbit·cos pitch, sin pitch, cos orbit·cos pitch). +x is camera-right,
/// +y camera-up, +z towards the viewer.
glm::dvec3 LightOrbitDirection(double orbitDeg, double pitchDeg);

/**
 * The inverse of the camera-light placement: orbit, pitch and radius (in rig
 * sizes) of an eye-space offset `d` from the rig centre. Straight above or
 * below the centre the orbit is undefined, so `keepOrbit` is returned. A zero
 * offset gives `keepOrbit`, pitch 0 and radius 0.
 */
void LightOrbitFromOffset(const glm::dvec3& d, double size, double keepOrbit,
    double& orbit, double& pitch, double& radius);

} // namespace pymol
