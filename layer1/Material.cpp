/*
 * Materials (#503): material ids, and which settings hold one. See Material.h.
 */

#include "Material.h"
#include "Rep.h"
#include "Setting.h"

namespace
{
/* One row of the material table. Adding a material is adding a row.
 *
 * `implemented` is what the names API filters on: a row whose shader has not
 * landed yet is a real material -- settable, round-tripping through .pse -- it
 * simply resolves to `default` until the flag flips, so no wave of this epic
 * can show the user a look that cannot draw.
 *
 * `impliedAlpha` is consulted at rep-build time in layer2 and is NOT a setting;
 * see MaterialImpliedAlpha.
 */
struct MaterialRow {
  int id;
  const char* name;
  int family;
  bool implemented;
  float impliedAlpha;
  MaterialParams params;
};

/* Knob slots in MaterialParams::p, per family. Named here so the table below
   reads as data and the shaders agree on what p[i] means. */
constexpr int kP_grain = 0;    /* procedural: grain amplitude */
constexpr int kP_freq = 1;     /* procedural: grain frequency, cycles per Angstrom */
constexpr int kP_edge = 2;     /* procedural: grazing-angle darkening */
constexpr int kP_sheen = 3;    /* procedural: velvet sheen (rubber) */
constexpr int kP_vein = 4;     /* marble: vein contrast */
constexpr int kP_sharp = 5;    /* marble: vein sharpness */

/* Index is the material id; the order must match the enum in Material.h.
 *
 * Only `default` is implemented today. The rest are declared in full so the
 * table is reviewed once, as a whole, rather than growing by guesswork: each
 * later ticket flips one `implemented` flag and the numbers below are already
 * the ones the prototype gallery was judged on.
 */
const MaterialRow kMaterialTable[] = {
    /* id, name, family, implemented, impliedAlpha, params
       params = {family, mode, reflect, tint, rough, {p0..p5}, wantsPeel} */
    {cMaterial_default, "default", cMaterialFamily_default, true, 0.0f, {}},

    {cMaterial_matte, "matte", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_matte, 0.0f, 0.0f, 1.0f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_plastic, "plastic", cMaterialFamily_reflective, false, 0.0f,
        {cMaterialFamily_reflective, cMaterial_plastic, 0.25f, 0.0f, 0.15f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_metallic, "metallic", cMaterialFamily_reflective, false, 0.0f,
        {cMaterialFamily_reflective, cMaterial_metallic, 0.6f, 0.35f, 0.35f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_glass, "glass", cMaterialFamily_glass, false, 0.15f,
        {cMaterialFamily_glass, cMaterial_glass, 0.0f, 0.0f, 0.0f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_frosted_glass, "frosted_glass", cMaterialFamily_glass, false,
        0.2f,
        {cMaterialFamily_glass, cMaterial_frosted_glass, 0.0f, 0.0f, 0.6f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_jelly, "jelly", cMaterialFamily_glass, false, 0.45f,
        {cMaterialFamily_glass, cMaterial_jelly, 0.0f, 0.0f, 0.1f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_marble, "marble", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_marble, 0.0f, 0.0f, 0.9f,
            {0.0f, 0.22f, 0.0f, 0.0f, 0.85f, 6.0f}, 0}},

    {cMaterial_clay, "clay", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_clay, 0.0f, 0.0f, 1.0f,
            {0.04f, 8.0f, 0.15f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_rubber, "rubber", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_rubber, 0.0f, 0.0f, 0.95f,
            {0.14f, 14.0f, 0.12f, 0.10f, 0.0f, 0.0f}, 0}},
};

constexpr int kMaterialTableSize =
    sizeof(kMaterialTable) / sizeof(kMaterialTable[0]);

static_assert(kMaterialTableSize == cMaterial_count,
    "material table and id enum disagree");

const MaterialRow* MaterialFindRow(int id)
{
  if (id < 0 || id >= kMaterialTableSize) {
    return nullptr;
  }
  /* The table is index-ordered by construction; assert it rather than search. */
  return kMaterialTable[id].id == id ? &kMaterialTable[id] : nullptr;
}
} // namespace

int MaterialTableSize()
{
  return kMaterialTableSize;
}

bool MaterialFamilyIsImplemented(int family)
{
  if (family == cMaterialFamily_default) {
    return true;   // `default` is the family every un-materialled rep draws with
  }
  for (int i = 0; i < kMaterialTableSize; ++i) {
    if (kMaterialTable[i].implemented && kMaterialTable[i].family == family) {
      return true;
    }
  }
  return false;
}

bool MaterialIsImplemented(int id)
{
  const MaterialRow* row = MaterialFindRow(id);
  return row && row->implemented;
}

float MaterialImpliedAlpha(int id)
{
  const MaterialRow* row = MaterialFindRow(id);
  /* An unimplemented material draws as `default`, so it must not imply an
     opacity either -- that would make a surface translucent with no visible
     change of material. */
  return (row && row->implemented) ? row->impliedAlpha : 0.0f;
}

MaterialParams MaterialResolve(int id, int repType)
{
  const MaterialRow* row = MaterialFindRow(id);
  /* An id no row claims -- an out-of-range int, or a material from a newer
     build read out of a .pse -- renders as `default`. Names never fall back;
     that is an error at set time. */
  if (!row || !row->implemented) {
    return MaterialParams{};
  }
  /* Glass and jelly have no sphere-impostor path; they would float as
     near-invisible discs. Degrade cleanly instead of glitching. */
  if (row->family == cMaterialFamily_glass && repType == cRepSphere) {
    return MaterialParams{};
  }
  return row->params;
}

const char* MaterialGetName(int id)
{
  const MaterialRow* row = MaterialFindRow(id);
  return row ? row->name : nullptr;
}

bool MaterialIsRepMaterialSetting(int index)
{
  switch (index) {
  case cSetting_cartoon_material:
  case cSetting_surface_material:
  case cSetting_stick_material:
  case cSetting_sphere_material:
    return true;
  default:
    return false;
  }
}

bool MaterialIsMaterialSetting(int index)
{
  return index == cSetting_material_default ||
         MaterialIsRepMaterialSetting(index);
}

bool MaterialIsSelectionRejectedSetting(int index)
{
  // transparency_peel is object-scoped for the same reason the materials are,
  // and a selection-scoped set of it fails the same silent way.
  return index == cSetting_transparency_peel ||
         MaterialIsRepMaterialSetting(index);
}

int MaterialSettingForRep(int repType)
{
  switch (repType) {
  case cRepCartoon:
    return cSetting_cartoon_material;
  case cRepSurface:
    return cSetting_surface_material;
  case cRepCyl:
    // The stick rep. It also emits the `stick_ball` spheres, which therefore
    // take stick_material and not sphere_material.
    return cSetting_stick_material;
  case cRepSphere:
    return cSetting_sphere_material;
  default:
    // Ribbon, mesh, dots, lines, labels, dashes, ... keep default shading in
    // v1, and material_default does NOT reach them.
    return 0;
  }
}

int MaterialResolveSettingId(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2, int repType)
{
  int const repSetting = MaterialSettingForRep(repType);
  if (!repSetting) {
    return cMaterial_default;
  }
  int id = cMaterial_default;
  // An explicitly set object-state or object value wins outright, including an
  // explicit `default`: that is how one object opts out of a global material.
  if (SettingGetIfDefined_i(G, set1, repSetting, &id)) {
    return id;
  }
  if (SettingGetIfDefined_i(G, set2, repSetting, &id)) {
    return id;
  }
  id = SettingGetGlobal_i(G, repSetting);
  if (id != cMaterial_default) {
    return id;
  }
  return SettingGetGlobal_i(G, cSetting_material_default);
}
