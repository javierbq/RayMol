/*
 * Materials (#503): material ids, and which settings hold one. See Material.h.
 */

#include "Material.h"
#include "Rep.h"
#include "Setting.h"
#include "CoordSet.h"
#include "AtomInfo.h"
#include "ObjectMolecule.h"

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

    {cMaterial_plastic, "plastic", cMaterialFamily_reflective, true, 0.0f,
        {cMaterialFamily_reflective, cMaterial_plastic, 0.25f, 0.0f, 0.15f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_metallic, "metallic", cMaterialFamily_reflective, true, 0.0f,
        {cMaterialFamily_reflective, cMaterial_metallic, 0.6f, 0.35f, 0.35f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_glass, "glass", cMaterialFamily_glass, true, 0.15f,
        {cMaterialFamily_glass, cMaterial_glass, 0.0f, 0.0f, 0.0f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_frosted_glass, "frosted_glass", cMaterialFamily_glass, true,
        0.2f,
        {cMaterialFamily_glass, cMaterial_frosted_glass, 0.0f, 0.0f, 0.6f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_jelly, "jelly", cMaterialFamily_glass, false, 0.45f,
        {cMaterialFamily_glass, cMaterial_jelly, 0.0f, 0.0f, 0.1f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_marble, "marble", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_marble, 0.0f, 0.0f, 0.9f,
            {0.0f, 0.22f, 0.0f, 0.0f, 0.85f, 6.0f}, 0}},

    /* Clay's knobs are raised from the prototype's 0.04 / 8 / 0.15. Those were
       tuned against `default`, which has a specular highlight; against `matte`,
       which this epic adds and which is the same Lambert with every knob at
       zero, they were invisible -- measured at 0.000% of pixels differing by
       more than 16/255 on all four representations. A material the dropdown
       offers has to be one the user can actually tell apart. The grazing
       darkening does most of the work: it is what reads as an unglazed porous
       body rather than a flat matte one.

       Only p[0..2] reach the GPU for this family. `reflect`, `tint` and `rough`
       in every row are overwritten from the metal_rt_reflect* settings in
       CGOGL.cpp before upload, so tuning them here has no effect. */
    {cMaterial_clay, "clay", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_clay, 0.0f, 0.0f, 1.0f,
            {0.10f, 9.0f, 0.45f, 0.0f, 0.0f, 0.0f}, 0}},

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

/* Does this stick rep emit any stick_ball sphere?
 *
 * `stick_ball` is an ATOM-level setting (SettingInfo.h: REC_b(276, stick_ball,
 * atom)) and RepCylBond reads it per atom via AtomSettingGetWD. Asking only the
 * object/global value therefore answers the wrong question in both directions:
 * an atom-level `stick_ball 1` under an object-level 0 drew glass balls (the
 * near-invisible discs the rule exists to prevent, and reachable now that the
 * glass-family sphere pipelines are built), while every atom overriding an
 * object-level 1 back to 0 degraded a rep that emits no balls at all.
 *
 * Scanned only for a glass stick rep, which is rare and already expensive; the
 * default path never reaches this.
 */
static bool MaterialRepEmitsStickBalls(
    PyMOLGlobals* G, const CoordSet* cs, const CSetting* set1,
    const CSetting* set2)
{
  bool const objLevel = SettingGet_b(G, set1, set2, cSetting_stick_ball);
  if (!cs) {
    return objLevel; // no atoms to consult; the object value is all there is
  }
  /* Indexed directly rather than through CoordSetAtomIterator: that lives in
     layer3 and this is layer1. */
  for (int idx = 0; idx < cs->getNIndex(); ++idx) {
    const AtomInfoType* ai = cs->getAtomInfo(idx);
    if (!ai || !(ai->visRep & cRepCylBit)) {
      continue;
    }
    if (AtomSettingGetWD(G, ai, cSetting_stick_ball, objLevel)) {
      return true;
    }
  }
  return false;
}

MaterialParams MaterialResolveForDraw(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs)
{
  int const id = MaterialResolveSettingId(G, set1, set2, repType);
  MaterialParams params = MaterialResolve(id, repType);
  // stick_ball spheres are emitted by the STICK rep, so they arrive as cRepCyl
  // and take stick_material -- including a glass one, which the sphere impostor
  // has no path for. A glassy stick beside near-invisible ball discs looks
  // broken, so the WHOLE rep degrades to `default` rather than half of it.
  //
  // This rule depends on a setting, not on the rep alone, so MaterialResolve
  // cannot express it. It lives here rather than at the draw site because
  // implied alpha has to obey it too: a ball-and-stick that shades as `default`
  // while still building 85% transparent is not "rendering default".
  if (params.family == cMaterialFamily_glass && repType == cRepCyl &&
      MaterialRepEmitsStickBalls(G, cs, set1, set2)) {
    return MaterialParams{};
  }
  return params;
}

MaterialParams MaterialDrawParams(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs)
{
  MaterialParams params = MaterialResolveForDraw(G, set1, set2, repType, cs);
  // reflect/tint/rough: `default` reads the legacy object-scoped
  // metal_rt_reflect* triple, and a REFLECTIVE material carries its own (#494).
  //
  // Overwriting unconditionally -- as this did while no reflective material was
  // implemented -- made the reflect/tint/rough columns of the table dead data,
  // so `metallic` would have rendered with whatever the legacy sliders happened
  // to hold: 0 for an untouched object, i.e. no reflection at all.
  //
  // GLASS is exempt for the same reason, and it was not: `rough` is its frost
  // axis (the cubemap mip is sqrt(rough) * 7, and it sets the tap spread), so
  // taking `metal_rt_reflect_rough` -- default 0 -- replaced frosted_glass's
  // 0.6 with a near-mirror sample. `frosted_glass` rendered as clear `glass`,
  // and the only surviving difference between the two materials was their
  // implied alpha. It also let a legacy object slider reshape a material that
  // is meant to be a pure function of its id.
  //
  // The procedural materials (matte, marble, clay, rubber) do not read these at
  // all, so leaving them on the legacy path keeps `default` and every
  // already-shipped material byte-exact.
  if (params.family != cMaterialFamily_reflective &&
      params.family != cMaterialFamily_glass) {
    params.reflect = SettingGet_f(G, set1, set2, cSetting_metal_rt_reflect);
    params.tint = SettingGet_f(G, set1, set2, cSetting_metal_rt_reflect_tint);
    params.rough = SettingGet_f(G, set1, set2, cSetting_metal_rt_reflect_rough);
  } else if (params.family == cMaterialFamily_reflective) {
    // A reflective material starts from its TABLE row, but an EXPLICIT
    // per-object metal_rt_reflect* value still wins (#497).
    //
    // "Explicit" is the whole point: SettingGetIfDefined, not SettingGet. An
    // object that has never been touched has no value here, so it keeps the
    // table's -- which is what stopped `metallic` rendering with the sliders'
    // default 0 and no reflection at all. But a user (or a bundle) who does set
    // one gets it, which is how `chrome` can be metallic with a tighter tint
    // and a sharper roughness without needing a table row of its own.
    //
    // GLASS is deliberately NOT given this: `rough` is its frost axis, not a
    // reflection knob, and letting a legacy slider reshape it is the bug fixed
    // earlier in this ticket.
    float v = 0.0f;
    if (SettingGetIfDefined<float>(set1, cSetting_metal_rt_reflect, &v) ||
        SettingGetIfDefined<float>(set2, cSetting_metal_rt_reflect, &v))
      params.reflect = v;
    if (SettingGetIfDefined<float>(set1, cSetting_metal_rt_reflect_tint, &v) ||
        SettingGetIfDefined<float>(set2, cSetting_metal_rt_reflect_tint, &v))
      params.tint = v;
    if (SettingGetIfDefined<float>(set1, cSetting_metal_rt_reflect_rough, &v) ||
        SettingGetIfDefined<float>(set2, cSetting_metal_rt_reflect_rough, &v))
      params.rough = v;
  }
  return params;
}

float MaterialEffectiveTransparency(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, float transparency, const CoordSet* cs)
{
  // The slider wins. Only a rep the user has left fully opaque picks up the
  // material's implied opacity, so `set transparency, 0.3` on a glass surface
  // means 0.3 and not the material's own value.
  if (transparency > 0.0f) {
    return transparency;
  }
  // The table stores ALPHA -- opacity, the spec's "implied alpha 0.15" -- while
  // layer2 builds with a TRANSPARENCY. They are opposite ends of the same axis,
  // so the conversion has to happen exactly here. Returning the alpha unchanged
  // makes clear glass 85% OPAQUE instead of 85% clear, which still shades like
  // glass and so looks plausible rather than broken.
  // Through MaterialResolveForDraw, so a material that DEGRADES on this rep
  // implies nothing either -- `mode` carries the row's own id, and the neutral
  // MaterialParams{} carries 0 (= default, which implies no opacity).
  float const impliedAlpha =
      MaterialImpliedAlpha(
          MaterialResolveForDraw(G, set1, set2, repType, cs).mode);
  if (impliedAlpha <= 0.0f) {
    return transparency; // this material implies no opacity of its own
  }
  return 1.0f - impliedAlpha;
}

int MaterialEffectiveId(int id, int repType)
{
  // MaterialResolve already encodes every degradation rule; its `mode` field is
  // the row's own id, and the neutral MaterialParams{} carries 0 (= default).
  // Reusing it means this cannot drift from what the renderer receives.
  return MaterialResolve(id, repType).mode;
}

int MaterialGetFamily(int id)
{
  for (int i = 0; i < MaterialTableSize(); ++i) {
    if (kMaterialTable[i].id == id) {
      return kMaterialTable[i].family;
    }
  }
  return -1;
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

int MaterialTransparencySettingForRep(int repType)
{
  switch (repType) {
  case cRepCartoon:
    return cSetting_cartoon_transparency;
  case cRepSurface:
    return cSetting_transparency;
  case cRepCyl:
    return cSetting_stick_transparency;
  case cRepSphere:
    return cSetting_sphere_transparency;
  default:
    return 0; // this rep has no transparency setting of its own
  }
}

bool MaterialObjectWantsPeel(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2)
{
  int peel = -1;
  if (!SettingGetIfDefined_i(G, set1, cSetting_transparency_peel, &peel) &&
      !SettingGetIfDefined_i(G, set2, cSetting_transparency_peel, &peel)) {
    peel = SettingGetGlobal_i(G, cSetting_transparency_peel);
  }
  if (peel >= 0) {
    return peel != 0;   // an explicit on/off, at any level, wins outright
  }
  // Auto: on when any representation this object can draw resolves to a
  // material whose row asks for peeling. Four settings, resolved the same way
  // the draw path resolves them, so what the user sees and what gets peeled
  // cannot disagree.
  //
  // But peeling is OBJECT-scoped: the pre-pass records the nearest transparent
  // depth across ALL of the object's transparent reps, and everything behind it
  // fails the equality test. So auto must refuse when the object also has a
  // transparent rep that did NOT ask for this -- otherwise setting
  // `surface_material, glass` on an object whose cartoon is at
  // `cartoon_transparency 0.5` makes that cartoon VANISH, a look the user had
  // before and never asked to change. An explicit `transparency_peel 1` still
  // peels the whole object: that one the user did ask for.
  static const int kReps[] = {cRepCartoon, cRepSurface, cRepCyl, cRepSphere};
  bool anyWantsPeel = false;
  for (int rep : kReps) {
    int const id = MaterialResolveSettingId(G, set1, set2, rep);
    if (MaterialResolve(id, rep).wantsPeel) {
      anyWantsPeel = true;
      continue;
    }
    // A rep only stands in the way if it is actually drawn transparent. An
    // untouched rep is opaque and is unaffected by the peel either way, so the
    // common case still gets auto-peel.
    int const transpIndex = MaterialTransparencySettingForRep(rep);
    if (transpIndex != 0 &&
        SettingGet_f(G, set1, set2, transpIndex) > 0.0f) {
      return false;
    }
  }
  return anyWantsPeel;
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
