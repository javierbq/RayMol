/*
 * Native light rig (#611): field table, validation and placement helpers.
 * See LightRig.h. Pure functions over plain data: no PyMOLGlobals, no Python.
 */

#include "LightRig.h"

#include <algorithm>
#include <cassert>
#include <cctype>
#include <cmath>
#include <sstream>

namespace pymol
{

namespace
{
constexpr double kPi = 3.14159265358979323846;
constexpr double kDegToRad = kPi / 180.0;
constexpr double kRadToDeg = 180.0 / kPi;

LightField F(LightFieldId id, LightScope scope, const char* name,
    LightKind kind, double lo, double hi, bool optional = false)
{
  return {id, scope, name, kind, optional, true, lo, hi};
}

LightField U(LightFieldId id, LightScope scope, const char* name,
    LightKind kind, bool optional = false)
{
  return {id, scope, name, kind, optional, false, 0.0, 0.0};
}

std::string lower(std::string_view s)
{
  std::string out(s);
  for (auto& c : out)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return out;
}

bool isNumeric(LightKind kind)
{
  switch (kind) {
  case LightKind::Str:
  case LightKind::Name:
    return false;
  default:
    return true;
  }
}

int components(LightKind kind)
{
  return kind == LightKind::Vec3 ? 3 : 1;
}

/// "light 2 ('rim')" or "light 2"
std::string lightLabel(const LightRig& rig, size_t index)
{
  std::ostringstream os;
  os << "light " << index;
  const auto& name = rig.lights[index].name;
  if (!name.empty())
    os << " ('" << name << "')";
  return os.str();
}

LightValue scalar(double v)
{
  LightValue value;
  value.num[0] = v;
  return value;
}

LightValue vec(const glm::dvec3& v)
{
  LightValue value;
  value.num[0] = v.x;
  value.num[1] = v.y;
  value.num[2] = v.z;
  return value;
}

glm::dvec3 toVec(const LightValue& value)
{
  return {value.num[0], value.num[1], value.num[2]};
}

bool truthy(double v)
{
  return v >= 0.5;
}
} // namespace

const std::vector<LightField>& LightRigFields()
{
  using I = LightFieldId;
  using S = LightScope;
  using K = LightKind;
  static const std::vector<LightField> fields = {
      // rig
      U(I::Enabled, S::Rig, "enabled", K::Bool),
      U(I::Centre, S::Rig, "centre", K::Vec3, true),
      U(I::Size, S::Rig, "size", K::Float, true), // > 0, checked by validation
      F(I::Ambient, S::Rig, "ambient", K::Float, 0.0, 1.0),
      F(I::Classic, S::Rig, "classic", K::Float, 0.0, 1.0),
      // air (ranges proposed by #611; #618 may refine them)
      F(I::Haze, S::Air, "haze", K::Float, 0.0, 1.0),
      F(I::Dust, S::Air, "dust", K::Float, 0.0, 1.0),
      F(I::DustSize, S::Air, "dust_size", K::Float, 0.05, 2.0),
      F(I::DustSpeed, S::Air, "dust_speed", K::Float, 0.0, 10.0),
      F(I::Scatter, S::Air, "scatter", K::Float, -0.9, 0.9),
      F(I::Seed, S::Air, "seed", K::Int, 0.0, 1000000.0),
      // light
      U(I::Name, S::Light, "name", K::Name),
      U(I::Anchor, S::Light, "anchor", K::Anchor),
      F(I::Orbit, S::Light, "orbit", K::Angle, -180.0, 180.0),
      F(I::Pitch, S::Light, "pitch", K::Float, -90.0, 90.0),
      F(I::Radius, S::Light, "radius", K::Float, 0.5, 8.0),
      U(I::Position, S::Light, "position", K::Vec3),
      U(I::Aim, S::Light, "aim", K::Aim),
      U(I::AimPoint, S::Light, "aim_point", K::Vec3),
      U(I::AimSelection, S::Light, "aim_selection", K::Str),
      F(I::Beam, S::Light, "beam", K::Float, 1.0, 170.0),
      F(I::Softness, S::Light, "softness", K::Float, 0.0, 1.0),
      F(I::Color, S::Light, "color", K::Vec3, 0.0, 1.0),
      F(I::Warmth, S::Light, "warmth", K::Float, 1500.0, 15000.0),
      F(I::Intensity, S::Light, "intensity", K::Float, 0.0, 4.0),
      F(I::Highlight, S::Light, "highlight", K::Float, 0.0, 1.0),
      F(I::Falloff, S::Light, "falloff", K::Float, 0.0, 2.0),
      U(I::Shadow, S::Light, "shadow", K::Bool),
      U(I::Outline, S::Light, "outline", K::Bool),
  };
  return fields;
}

const LightField* LightRigFindField(LightScope scope, std::string_view name)
{
  for (const auto& field : LightRigFields()) {
    if (field.scope == scope && name == field.name)
      return &field;
  }
  return nullptr;
}

LightValue LightFieldGet(const LightRig& rig, const LightField& field)
{
  using I = LightFieldId;
  const auto& air = rig.air;
  switch (field.id) {
  case I::Enabled:
    return scalar(rig.enabled ? 1.0 : 0.0);
  case I::Centre: {
    if (!rig.centre) {
      LightValue value;
      value.unset = true;
      return value;
    }
    return vec(*rig.centre);
  }
  case I::Size: {
    if (!rig.size) {
      LightValue value;
      value.unset = true;
      return value;
    }
    return scalar(*rig.size);
  }
  case I::Ambient:
    return scalar(rig.ambient);
  case I::Classic:
    return scalar(rig.classic);
  case I::Haze:
    return scalar(air.haze);
  case I::Dust:
    return scalar(air.dust);
  case I::DustSize:
    return scalar(air.dustSize);
  case I::DustSpeed:
    return scalar(air.dustSpeed);
  case I::Scatter:
    return scalar(air.scatter);
  case I::Seed:
    return scalar(air.seed);
  default:
    assert(!"not a rig or air field");
    return {};
  }
}

LightValue LightFieldGet(const Light& light, const LightField& field)
{
  using I = LightFieldId;
  switch (field.id) {
  case I::Name: {
    LightValue value;
    value.str = light.name;
    return value;
  }
  case I::Anchor:
    return scalar(static_cast<int>(light.anchor));
  case I::Orbit:
    return scalar(light.orbit);
  case I::Pitch:
    return scalar(light.pitch);
  case I::Radius:
    return scalar(light.radius);
  case I::Position:
    return vec(light.position);
  case I::Aim:
    return scalar(static_cast<int>(light.aim));
  case I::AimPoint:
    return vec(light.aimPoint);
  case I::AimSelection: {
    LightValue value;
    value.str = light.aimSelection;
    return value;
  }
  case I::Beam:
    return scalar(light.beam);
  case I::Softness:
    return scalar(light.softness);
  case I::Color:
    return vec(light.color);
  case I::Warmth:
    return scalar(light.warmth);
  case I::Intensity:
    return scalar(light.intensity);
  case I::Highlight:
    return scalar(light.highlight);
  case I::Falloff:
    return scalar(light.falloff);
  case I::Shadow:
    return scalar(light.shadow ? 1.0 : 0.0);
  case I::Outline:
    return scalar(light.outline ? 1.0 : 0.0);
  default:
    assert(!"not a light field");
    return {};
  }
}

double LightWrapDegrees(double deg)
{
  if (deg > -180.0 && deg <= 180.0)
    return deg;
  double r = std::fmod(deg, 360.0);
  if (r <= -180.0)
    r += 360.0;
  else if (r > 180.0)
    r -= 360.0;
  return r;
}

double LightFieldClamp(const LightField& field, double v)
{
  if (!field.bounded || std::isnan(v))
    return v;
  if (field.kind == LightKind::Angle)
    return std::isfinite(v) ? LightWrapDegrees(v) : v;
  return std::min(std::max(v, field.lo), field.hi);
}

namespace
{
/// The value as stored: clamped, rounded for ints, 0/1 for bools and choices.
LightValue normalised(const LightField& field, const LightValue& in)
{
  LightValue value = in;
  if (!isNumeric(field.kind) || value.unset)
    return value;
  for (int i = 0; i < components(field.kind); ++i) {
    double& v = value.num[i];
    switch (field.kind) {
    case LightKind::Bool:
    case LightKind::Anchor:
    case LightKind::Aim:
      v = truthy(v) ? 1.0 : 0.0;
      break;
    case LightKind::Int:
      v = LightFieldClamp(field, v);
      if (std::isfinite(v))
        v = std::round(v);
      break;
    default:
      v = LightFieldClamp(field, v);
    }
  }
  return value;
}
} // namespace

void LightFieldPut(LightRig& rig, const LightField& field, const LightValue& in)
{
  using I = LightFieldId;
  const LightValue value = normalised(field, in);
  const double v = value.num[0];
  auto& air = rig.air;
  switch (field.id) {
  case I::Enabled:
    rig.enabled = v != 0.0;
    break;
  case I::Centre:
    if (value.unset)
      rig.centre.reset();
    else
      rig.centre = toVec(value);
    break;
  case I::Size:
    if (value.unset)
      rig.size.reset();
    else
      rig.size = v;
    break;
  case I::Ambient:
    rig.ambient = v;
    break;
  case I::Classic:
    rig.classic = v;
    break;
  case I::Haze:
    air.haze = v;
    break;
  case I::Dust:
    air.dust = v;
    break;
  case I::DustSize:
    air.dustSize = v;
    break;
  case I::DustSpeed:
    air.dustSpeed = v;
    break;
  case I::Scatter:
    air.scatter = v;
    break;
  case I::Seed:
    air.seed = std::isfinite(v) ? static_cast<int>(v) : 0;
    break;
  default:
    assert(!"not a rig or air field");
  }
}

void LightFieldPut(Light& light, const LightField& field, const LightValue& in)
{
  using I = LightFieldId;
  const LightValue value = normalised(field, in);
  const double v = value.num[0];
  switch (field.id) {
  case I::Name:
    light.name = value.str;
    break;
  case I::Anchor:
    light.anchor = v != 0.0 ? LightAnchor::Pinned : LightAnchor::Camera;
    break;
  case I::Orbit:
    light.orbit = v;
    break;
  case I::Pitch:
    light.pitch = v;
    break;
  case I::Radius:
    light.radius = v;
    break;
  case I::Position:
    light.position = toVec(value);
    break;
  case I::Aim:
    light.aim = v != 0.0 ? LightAim::Point : LightAim::Centre;
    break;
  case I::AimPoint:
    light.aimPoint = toVec(value);
    break;
  case I::AimSelection:
    light.aimSelection = value.str;
    break;
  case I::Beam:
    light.beam = v;
    break;
  case I::Softness:
    light.softness = v;
    break;
  case I::Color:
    light.color = toVec(value);
    break;
  case I::Warmth:
    light.warmth = v;
    break;
  case I::Intensity:
    light.intensity = v;
    break;
  case I::Highlight:
    light.highlight = v;
    break;
  case I::Falloff:
    light.falloff = v;
    break;
  case I::Shadow:
    light.shadow = v != 0.0;
    break;
  case I::Outline:
    light.outline = v != 0.0;
    break;
  default:
    assert(!"not a light field");
  }
}

const char* LightKindName(LightKind kind)
{
  switch (kind) {
  case LightKind::Bool:
    return "bool";
  case LightKind::Int:
    return "int";
  case LightKind::Float:
    return "float";
  case LightKind::Angle:
    return "angle";
  case LightKind::Vec3:
    return "vec3";
  case LightKind::Str:
    return "str";
  case LightKind::Name:
    return "name";
  case LightKind::Anchor:
    return "camera|pinned";
  case LightKind::Aim:
    return "centre|point";
  }
  return "";
}

const char* LightChoiceName(LightKind kind, int index)
{
  static const char* const anchors[] = {"camera", "pinned"};
  static const char* const aims[] = {"centre", "point"};
  if (index < 0 || index > 1)
    return nullptr;
  switch (kind) {
  case LightKind::Anchor:
    return anchors[index];
  case LightKind::Aim:
    return aims[index];
  default:
    return nullptr;
  }
}

int LightChoiceIndex(LightKind kind, std::string_view text)
{
  for (int i = 0; i < 2; ++i) {
    const char* name = LightChoiceName(kind, i);
    if (name && text == name)
      return i;
  }
  return -1;
}

bool LightNameValid(std::string_view name)
{
  if (name.empty() || name.size() > size_t(kLightNameMaxLength))
    return false;
  auto ok = [](char c, bool first) {
    unsigned char u = static_cast<unsigned char>(c);
    if (u >= 0x80)
      return false;
    return c == '_' || std::isalpha(u) || (!first && std::isdigit(u));
  };
  for (size_t i = 0; i < name.size(); ++i) {
    if (!ok(name[i], i == 0))
      return false;
  }
  return true;
}

std::string LightRigNextName(const std::vector<std::string>& taken)
{
  auto used = [&](const std::string& candidate) {
    for (const auto& name : taken) {
      if (lower(name) == candidate)
        return true;
    }
    return false;
  };
  static const char* const first[] = {"key", "fill", "rim"};
  for (const char* name : first) {
    if (!used(name))
      return name;
  }
  for (int i = 4;; ++i) {
    std::string name = "light" + std::to_string(i);
    if (!used(name))
      return name;
  }
}

pymol::Result<> LightRigValidate(const LightRig& rig)
{
  const auto& fields = LightRigFields();

  if (rig.lights.size() > size_t(kLightRigMaxLights)) {
    return pymol::make_error("at most ", kLightRigMaxLights, " lights (got ",
        rig.lights.size(), ")");
  }

  // numbers: finite and in range, for the rig, the air and every light
  auto checkNumbers = [](const LightField& field, const LightValue& value,
                          const std::string& where) -> pymol::Result<> {
    if (!isNumeric(field.kind) || value.unset)
      return {};
    for (int i = 0; i < components(field.kind); ++i) {
      const double v = value.num[i];
      if (!std::isfinite(v)) {
        return pymol::make_error(where, "'", field.name, "' must be finite");
      }
      bool inside = true;
      switch (field.kind) {
      case LightKind::Bool:
      case LightKind::Anchor:
      case LightKind::Aim:
        inside = (v == 0.0 || v == 1.0);
        break;
      case LightKind::Angle:
        inside = (v > field.lo && v <= field.hi);
        break;
      default:
        inside = !field.bounded || (v >= field.lo && v <= field.hi);
      }
      if (!inside) {
        std::ostringstream os;
        os << where << "'" << field.name << "' " << v << " is outside "
           << field.lo << " to " << field.hi;
        return pymol::make_error(os.str());
      }
    }
    return {};
  };

  for (const auto& field : fields) {
    if (field.scope == LightScope::Light)
      continue;
    const std::string where = field.scope == LightScope::Air ? "air: " : "";
    auto res = checkNumbers(field, LightFieldGet(rig, field), where);
    p_return_if_error(res);
  }

  if (rig.centre.has_value() != rig.size.has_value()) {
    return pymol::make_error("'centre' and 'size' go together: give both or "
                             "neither");
  }
  if (rig.size && !(*rig.size > 0.0)) {
    return pymol::make_error("'size' must be > 0");
  }
  if (!rig.lights.empty() && !rig.centre) {
    return pymol::make_error(
        "a rig with lights needs a frame ('centre' and 'size')");
  }

  int shadowed = 0;
  for (size_t i = 0; i < rig.lights.size(); ++i) {
    const auto& light = rig.lights[i];
    const std::string label = lightLabel(rig, i);
    if (!LightNameValid(light.name)) {
      return pymol::make_error(label, ": name '", light.name,
          "' is not valid (letters, digits and _, not starting with a "
          "digit, at most ",
          kLightNameMaxLength, " characters)");
    }
    for (size_t j = 0; j < i; ++j) {
      if (lower(rig.lights[j].name) == lower(light.name)) {
        return pymol::make_error(label, ": name '", light.name,
            "' is already used by light ", j,
            " (names are unique ignoring case)");
      }
    }
    for (const auto& field : fields) {
      if (field.scope != LightScope::Light)
        continue;
      auto res = checkNumbers(field, LightFieldGet(light, field), label + ": ");
      p_return_if_error(res);
    }
    if (light.shadow && ++shadowed > kLightRigMaxShadowed) {
      return pymol::make_error(label, ": at most ", kLightRigMaxShadowed,
          " lights can cast shadows");
    }
  }

  return {};
}

glm::dvec3 LightOrbitDirection(double orbitDeg, double pitchDeg)
{
  const double o = orbitDeg * kDegToRad;
  const double p = pitchDeg * kDegToRad;
  const double cp = std::cos(p);
  return {std::sin(o) * cp, std::sin(p), std::cos(o) * cp};
}

void LightOrbitFromOffset(const glm::dvec3& d, double size, double keepOrbit,
    double& orbit, double& pitch, double& radius)
{
  const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  if (!(len > 0.0)) {
    orbit = keepOrbit;
    pitch = 0.0;
    radius = 0.0;
    return;
  }
  const double s = std::min(1.0, std::max(-1.0, d.y / len));
  pitch = std::asin(s) * kRadToDeg;
  if (std::abs(std::cos(std::asin(s))) < 1e-9) {
    orbit = keepOrbit;
  } else {
    orbit = LightWrapDegrees(std::atan2(d.x, d.z) * kRadToDeg);
  }
  radius = size > 0.0 ? len / size : 0.0;
}

} // namespace pymol
