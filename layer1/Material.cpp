/*
 * Materials (#503): material ids, and which settings hold one. See Material.h.
 */

#include "Material.h"
#include "Setting.h"
#include "CoordSet.h"
#include "AtomInfo.h"
#include "ObjectMolecule.h"
#include "Rep.h"

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
/* Glass family. The slots are reused per family, and within it per material
   -- p[0] is grain for a procedural material, absorption for jelly and
   reflection for clear and frosted glass -- which is why they are named here
   rather than carried as one flat list. p[5] is NOT a table knob:
   setRepMaterial overwrites it for the whole glass family with the frost tap
   count the current target can afford, so nothing put here would survive. */
constexpr int kP_absorb = 0;   /* jelly: Beer-Lambert strength through the body */
constexpr int kP_scatter = 1;  /* jelly: density of the scattered inner glow */
constexpr int kP_wet = 2;      /* jelly: sharp wet-skin highlight strength */
constexpr int kP_jellyDistort = 3;  /* jelly: refraction amount (#590) */
constexpr int kP_reflect = 0;  /* clear/frosted glass: surface reflection (#590) */
constexpr int kP_distort = 1;  /* clear/frosted glass: refraction amount (#590) */

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
        {cMaterialFamily_reflective, cMaterial_metallic, 0.6f, 0.35f, 0.25f,
            {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 0}},

    /* Glass p[0] = reflection, p[1] = distortion (#590): both on. */
    {cMaterial_glass, "glass", cMaterialFamily_glass, true, 0.15f,
        {cMaterialFamily_glass, cMaterial_glass, 0.0f, 0.0f, 0.0f,
            {1.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    {cMaterial_frosted_glass, "frosted_glass", cMaterialFamily_glass, true,
        0.2f,
        {cMaterialFamily_glass, cMaterial_frosted_glass, 0.0f, 0.0f, 0.6f,
            {1.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f}, 1}},

    /* Jelly is in the glass family but is the opposite material: a dense
       scattering BODY under a smooth skin, where glass is a clear body under a
       Fresnel rim. p[0..2] are the prototype's gummy knobs (absorption 2.2,
       scatter 0.35, wet highlight 1.1).

       IMPLIED ALPHA IS 0.85, NOT THE 0.45 #496 AND #503 SPECIFY. At 0.45 this
       material cannot reach the look it is measured against, and the reason is
       arithmetic rather than taste -- but the arithmetic has two conditions,
       and both happen to hold for jelly, which is why it is stated here rather
       than in the design doc as a law.

       A single transparent layer over a NEUTRAL background reaches the screen
       as col*a + bg*(1-a). Channel spread (max - min) is unaffected by adding
       a constant to every channel, so the spread of the result is
       a * spread(col) <= a. Both conditions matter:

         - NEUTRAL background. In general spread(result) <= a * spread(col) +
           (1-a) * spread(bg); a coloured background contributes its own spread
           through the second term and the bound does not hold. The epic's
           probe uses a 0.85 grey, so it does here.
         - ONE layer. The OIT resolve composites reveal = product of (1 - a_i)
           over every transparent fragment, so n overlapping layers cover
           1 - (1-a)^n, not a. `backface_cull` is 0 by default, so a closed
           surface delivers two. Jelly's row sets wantsPeel, and the peel is an
           EQUAL depth test that keeps only the nearest layer, so n is 1 for a
           jelly object that is actually PEELED. That is not the same as "every
           jelly object": auto-peel refuses when the object has another
           transparent rep, SceneCollectPeelObjects stops at kMaxPeeledObjects
           (3) per frame, and the GL path peels nothing at all. So the bound is
           load-bearing on the peel, and the peel is not guaranteed.

       The prototype gallery's red gummy measures a mean channel spread of
       0.539, and the measured spread of jelly's own emitted colour is ~0.62,
       so reproducing the reference EXACTLY would take alpha ~0.87. 0.85 lands
       at 0.528, i.e. 98% of the reference and just under it.

       Be precise about which half of that is arithmetic. The LOW end is:
       spread(result) = a * spread(col) <= a, so any alpha at or below 0.539
       cannot reach the reference's spread no matter how the shader is
       written, and the specified 0.45 is well inside that -- it renders
       something (a pale pink that still reads as a gummy), it just cannot
       render THIS one. The HIGH end is a judgement, not a bound: the alpha is
       also how much of the scene a jelly object hides, so there is no reason
       to round past the reference and every reason not to. Arithmetic rules
       out below ~0.87 for an exact match and below 0.539 outright; the
       preference for not hiding more than the reference does rules out above.
       Between them the band is narrow, and 0.85 is in it.
       That the 0.45 version still reads as "a gummy" -- pale pink, highlights
       intact -- is exactly why the ticket's done-when is a measurement and not
       a glance.

       An unpeeled jelly object is therefore denser than the one measured
       above: two layers cover 1 - 0.15^2 = 0.978 rather than 0.85. It does not
       become OPAQUE, which is the intuition the reveal term alone suggests and
       which is wrong -- measured, a translucent cartoon inside an unpeeled
       jelly surface still contributes across 42% of the frame at mean |delta|
       0.134 (0.257 at alpha 0.45), because the weighted-blend resolve averages
       the layers' colours instead of occluding the far ones.

       0.45 is not wrong so much as it is a number from a different
       architecture. In the prototype the user's 0.55 was a SHADING knob: the
       fragment wrote coverage 1.0 ("this fragment must dominate the
       weighted-blended resolve") and did its own transmission by sampling the
       refracted opaque scene. #495 deliberately did not port that sampling --
       there is no opaque texture inside the OIT pass -- so here the implied
       alpha IS the blend coverage, and it has to carry the density the
       prototype got from the refraction.

       Measured at 0.85, against the gallery's g_jelly_red_v3 / sticks_red:
       surface mean rgb 0.810/0.323/0.282 vs 0.796/0.298/0.257, spread 0.528 vs
       0.539, silhouette coverage 0.421 vs 0.426.

       `rough` is 0.03, not the 0.1 this row was declared with in #486. It is
       the cubemap MIP axis (lod = sqrt(rough) * 7), and 0.1 selects level 2.2
       of 7 -- a 32px room, visibly soft. A gummy's skin is WET: the whole
       point of the look is that the body is frosted and the surface is not.
       0.03 lands just under level 1. The number was never rendered before
       this ticket; the table declared it in advance. */
    {cMaterial_jelly, "jelly", cMaterialFamily_glass, true, 0.85f,
        {cMaterialFamily_glass, cMaterial_jelly, 0.0f, 0.0f, 0.03f,
            {2.2f, 0.35f, 1.1f, 1.0f, 0.0f, 0.0f}, 1}},  // p[3] distortion (#590)

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
       are zeroed for it in MaterialFinalizeParams, so tuning them here has no
       effect. */
    {cMaterial_clay, "clay", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_clay, 0.0f, 0.0f, 1.0f,
            {0.10f, 9.0f, 0.45f, 0.0f, 0.0f, 0.0f}, 0}},

    {cMaterial_rubber, "rubber", cMaterialFamily_procedural, true, 0.0f,
        {cMaterialFamily_procedural, cMaterial_rubber, 0.0f, 0.0f, 0.95f,
            {0.14f, 26.5f, 0.17f, 0.37f, 0.0f, 0.0f}, 0}},
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
  /* Clear and frosted glass do not draw on sphere impostors: at an implied
     alpha of 0.15 / 0.2 a sphere reads as a near-invisible disc, and a
     ball-and-stick of them as scattered smudges. Jelly DOES (#526): at 0.85 it
     is a dense body, gummy balls are the representation a gummy most
     obviously belongs on, and the path already exists --
     buildImpostorPipelines() builds the sphere pipelines for every implemented
     family and mat_impostor_composite's kMatGlass branch dispatches jelly.
     Kept in one place so a rep cannot shade as a material while building with
     its implied alpha (MaterialEffectiveTransparency resolves through here). */
  if (row->family == cMaterialFamily_glass && repType == cRepSphere &&
      row->id != cMaterial_jelly) {
    return MaterialParams{};
  }
  return row->params;
}

MaterialRayParams MaterialRayParamsFor(int id)
{
  /* A switch rather than a column in kMaterialTable: these numbers mean
     something only to `ray`'s lighting model, and none of the Metal code reads
     them. Unlisted ids (default, the glass family, an id with no row) take the
     neutral {0, 1, 1, 0}, which is today's `ray`, byte for byte.

     The textures are `ray_texture` modes as the Rendering menu names them
     (modules/pymol/_gui.py): 1 Matte 1, 2 Swirl 1, 4 Matte 2. Swirl 1 is a
     smooth cosine field over the surface position -- the only mode that reads
     as veining. Matte 1 perturbs every sample's normal at random, a fine dry
     grain (unglazed clay); Matte 2 perturbs it through a coarser positional
     lookup, a mottled skin (rubber). These three ALSO keep default's
     highlight, so "marble under ray" and "default under ray_texture 2" are the
     same image, byte for byte. Clay and rubber are the same only
     STATISTICALLY: Matte 1 and Matte 2 draw from rand(), and RayNew refills
     its table on every render, so no two traces of either match. frosted_glass
     takes Matte 1 as well, on top of the transparency it already implies.

     A known limit of the positional textures: Swirl 1 (marble) is evaluated
     at the impact point in CAMERA space, and Matte 2 (rubber) un-rotates it
     but does not un-translate it, so those patterns slide over the surface as
     the camera moves. The viewport's procedural materials are locked to the
     object; under `ray` a movie of a marble object will show its veins swim.
     Matte 1 (clay, frosted_glass) reads no position at all -- it is fresh
     noise per sample, so there is no pattern to lock or to slide.

     The highlight knobs are best effort, and deliberately few. matte drops the
     highlight entirely, as its Lambert shader does. plastic is a brighter
     white highlight on unchanged diffuse. metallic dims the diffuse term and
     tints the highlight toward the surface's own colour, which is what makes
     a metal read as metal without an environment to reflect. */
  MaterialRayParams r;
  if (!MaterialIsImplemented(id)) {
    return r;
  }
  switch (id) {
  case cMaterial_matte:
    r.specular = 0.0f;
    break;
  case cMaterial_plastic:
    r.specular = 1.6f;
    break;
  case cMaterial_metallic:
    r.specular = 1.4f;
    r.diffuse = 0.6f;
    r.specTint = 0.8f;
    break;
  case cMaterial_marble:
    r.wobble = 2;
    break;
  case cMaterial_clay:
    r.wobble = 1;
    break;
  case cMaterial_rubber:
    r.wobble = 4;
    break;
  case cMaterial_frosted_glass:
    /* Its transparency is already glass's; without a texture it traced as
       plain glass. Matte 1's scattered normals frost the highlights, which is
       the part of the look `ray` can do. */
    r.wobble = 1;
    break;
  default:
    break;
  }
  return r;
}

int MaterialRayId(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs)
{
  if (!MaterialSettingForRep(repType)) {
    return 0; // this rep takes no material; skip the resolve entirely
  }
  return MaterialResolveForDraw(G, set1, set2, repType, cs).mode;
}

int MaterialRayWobble(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int materialId)
{
  // A value SET on the object or its state is explicit whatever it is, 0
  // included: that is how a user traces a marble surface without the swirl.
  int texture = 0;
  if (SettingGetIfDefined_i(G, set1, cSetting_ray_texture, &texture) ||
      SettingGetIfDefined_i(G, set2, cSetting_ray_texture, &texture)) {
    return texture;
  }
  // The global value cannot say whether 0 was chosen or merely inherited, so
  // only a non-zero one is explicit there.
  texture = SettingGetGlobal_i(G, cSetting_ray_texture);
  if (texture != 0) {
    return texture;
  }
  return MaterialRayParamsFor(materialId).wobble;
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
bool MaterialRepEmitsStickBalls(
    PyMOLGlobals* G, const CoordSet* cs, const CSetting* set1,
    const CSetting* set2)
{
  /* int, not bool: AtomSettingGetWD deduces V from this argument, and its
     `bool` instantiation declares an uninitialised `V out;` that the bool
     overload then reads -- UB, and a UBSan -fsanitize=bool trap. Every other
     call site in the tree passes an int, RepCylBond's included. */
  int const objLevel = SettingGet_b(G, set1, set2, cSetting_stick_ball);
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

bool MaterialLayerHasOwnMaterial(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType)
{
  // A material of its OWN, at any level, keeps the layer independent: set on
  // the state or the object, or a non-default global value for the layer.
  int const own = MaterialSettingForRep(repType);
  int id = cMaterial_default;
  return !own || SettingGetIfDefined_i(G, set1, own, &id) ||
         SettingGetIfDefined_i(G, set2, own, &id) ||
         SettingGetGlobal_i(G, own) != cMaterial_default;
}

int MaterialSourceRep(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const pymol::CObject* obj)
{
  if (repType != cRepCyl && repType != cRepSphere) {
    return repType; // only the side-chain layers follow
  }
  if (MaterialLayerHasOwnMaterial(G, set1, set2, repType)) {
    return repType;
  }
  // Cheap checks first: this runs per draw op. The cast and the visibility
  // test only happen for a stick or sphere layer with no material of its own.
  auto const* objmol = dynamic_cast<const ObjectMolecule*>(obj);
  if (!objmol || !objmol->showsPolymerCartoon()) {
    return repType;
  }
  return cRepCartoon;
}

static MaterialParams MaterialResolveForDrawCached(PyMOLGlobals* G,
    const CSetting* set1, const CSetting* set2, int repType,
    bool emitsStickBalls, const pymol::CObject* obj)
{
  // The SETTING comes from the source layer (a side chain following its
  // cartoon reads cartoon_material); the degradations below stay keyed on the
  // rep that actually draws -- glass on sphere impostors, stick_ball glass.
  int const id = MaterialResolveSettingId(
      G, set1, set2, MaterialSourceRep(G, set1, set2, repType, obj));
  MaterialParams params = MaterialResolve(id, repType);
  // stick_ball spheres are emitted by the STICK rep, so they arrive as cRepCyl
  // and take stick_material -- including clear or frosted glass, which
  // MaterialResolve keeps off sphere impostors. A glassy stick beside
  // near-invisible ball discs looks broken, so the WHOLE rep degrades to
  // `default` rather than half of it. Jelly is exempt, as it is from the
  // sphere rule (#526): its balls read as gummy balls.
  //
  // This rule depends on a setting, not on the rep alone, so MaterialResolve
  // cannot express it. It lives here rather than at the draw site because
  // implied alpha has to obey it too: a ball-and-stick that shades as `default`
  // while still building 85% transparent is not "rendering default".
  if (params.family == cMaterialFamily_glass && repType == cRepCyl &&
      params.mode != cMaterial_jelly && emitsStickBalls) {
    return MaterialParams{};
  }
  return params;
}

MaterialParams MaterialResolveForDraw(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs)
{
  int const id = MaterialResolveSettingId(G, set1, set2,
      MaterialSourceRep(G, set1, set2, repType, cs ? cs->Obj : nullptr));
  MaterialParams params = MaterialResolve(id, repType);
  /* LAZY on purpose: resolve first, and walk atoms only when the answer can
     change something. Computing it eagerly for every cRepCyl call -- as this
     briefly did -- put an O(atoms) pass back on the `default` path, which is
     the exact cost the cached variant exists to remove. */
  if (params.family == cMaterialFamily_glass && repType == cRepCyl &&
      params.mode != cMaterial_jelly &&
      MaterialRepEmitsStickBalls(G, cs, set1, set2)) {
    return MaterialParams{};
  }
  return params;
}

static MaterialParams MaterialFinalizeParams(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2, int repType,
    MaterialParams params);

/* The Custom overrides come from the same layer as the material: a side chain
   following its cartoon draws with the cartoon's tuning, not its own. */
MaterialParams MaterialDrawParams(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs)
{
  int const source =
      MaterialSourceRep(G, set1, set2, repType, cs ? cs->Obj : nullptr);
  return MaterialFinalizeParams(G, set1, set2, source,
      MaterialResolveForDraw(G, set1, set2, repType, cs));
}

MaterialParams MaterialDrawParamsCached(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, bool emitsStickBalls,
    const pymol::CObject* obj)
{
  return MaterialFinalizeParams(G, set1, set2,
      MaterialSourceRep(G, set1, set2, repType, obj),
      MaterialResolveForDrawCached(
          G, set1, set2, repType, emitsStickBalls, obj));
}

/* The Custom material's per-layer overrides (#568): for each material-bearing
   rep, the object-scoped settings that replace its material's own knobs --
   reflect, tint, rough, then knob1..knob6 for p[0..5]. Unset means the
   material's value. */
namespace {
struct CustomOverrideSet {
  int slot[kMaterialKnobSlotCount];   // indexed by MaterialKnobSlot
};
const CustomOverrideSet* MaterialCustomOverridesForRep(int repType)
{
#define RAYMOL_CUSTOM_SET(rep)                                                 \
  {{cSetting_##rep##_material_reflect, cSetting_##rep##_material_tint,         \
      cSetting_##rep##_material_rough, cSetting_##rep##_material_knob1,        \
      cSetting_##rep##_material_knob2, cSetting_##rep##_material_knob3,        \
      cSetting_##rep##_material_knob4, cSetting_##rep##_material_knob5,        \
      cSetting_##rep##_material_knob6}}
  static const CustomOverrideSet kCartoon = RAYMOL_CUSTOM_SET(cartoon);
  static const CustomOverrideSet kSurface = RAYMOL_CUSTOM_SET(surface);
  static const CustomOverrideSet kStick = RAYMOL_CUSTOM_SET(stick);
  static const CustomOverrideSet kSphere = RAYMOL_CUSTOM_SET(sphere);
#undef RAYMOL_CUSTOM_SET
  switch (MaterialSettingForRep(repType)) {
  case cSetting_cartoon_material: return &kCartoon;
  case cSetting_surface_material: return &kSurface;
  case cSetting_stick_material: return &kStick;
  case cSetting_sphere_material: return &kSphere;
  }
  return nullptr;
}

/* Which knobs each material HAS: the slots its shader actually reads, with
   the name and a sensible range. One table, because the meaning of a
   p[] slot differs per material, not per family -- marble reads p[1] as vein
   scale and never reads p[0], rubber reads p[2] as its highlight where clay
   reads it as grazing darkening, and matte reads only p[0..1]. An override
   of a slot that is not listed for the layer's material is ignored, so the
   settings cannot promise a change the shader does not make. Ranges are for
   the Inspector's sliders (a toggle writes its min or max); the core clamps
   nothing. Checked against
   RendererMetal.mm: mat_body_shade / mat_shade_procedural (matte, clay,
   rubber), mat_marble_albedo, mat_jelly_shade, mat_glass_shade and the
   frosted tap spread, mat_env_specular (reflective). */
const MaterialKnob kReflective[] = {
    {kKnob_reflect, "Reflection", 0.0f, 1.0f},
    {kKnob_tint, "Reflection tint", 0.0f, 1.0f},
    {kKnob_rough, "Roughness", 0.0f, 1.0f}};
// Clear and frosted glass: p[0] scales the surface reflection (the Fresnel
// environment rim and the glints, mat_glass_shade), p[1] the refraction
// (#588, bindRepMaterial). Both are 1 in the table and toggles in the
// Inspector (#590). `rough` is the glints' and reflection's blur.
const MaterialKnob kGlass[] = {{kKnob_p0 + kP_reflect, "Reflection", 0.0f, 1.0f, true},
    {kKnob_p0 + kP_distort, "Distortion", 0.0f, 1.0f, true},
    {kKnob_rough, "Roughness", 0.0f, 1.0f}};
const MaterialKnob kFrostedGlass[] = {{kKnob_p0 + kP_reflect, "Reflection", 0.0f, 1.0f, true},
    {kKnob_p0 + kP_distort, "Distortion", 0.0f, 1.0f, true},
    {kKnob_rough, "Frost", 0.0f, 1.0f}};
// Jelly's p[3] scales its refraction (#590); p[0..2] are its body.
const MaterialKnob kJelly[] = {{kKnob_rough, "Skin reflection blur", 0.0f, 1.0f},
    {kKnob_p0, "Absorption", 0.0f, 6.0f},
    {kKnob_p1, "Inner glow", 0.0f, 1.0f},
    {kKnob_p2, "Wet highlight", 0.0f, 3.0f},
    {kKnob_p0 + kP_jellyDistort, "Distortion", 0.0f, 1.0f, true}};
const MaterialKnob kMatte[] = {{kKnob_p0, "Grain", 0.0f, 0.5f},
    {kKnob_p1, "Grain frequency", 0.0f, 40.0f}};
const MaterialKnob kClay[] = {{kKnob_p0, "Grain", 0.0f, 0.5f},
    {kKnob_p1, "Grain frequency", 0.0f, 40.0f},
    {kKnob_p2, "Edge darkening", 0.0f, 1.0f}};
const MaterialKnob kRubber[] = {{kKnob_p0, "Grain", 0.0f, 0.5f},
    {kKnob_p1, "Grain frequency", 0.0f, 40.0f},
    {kKnob_p2, "Highlight", 0.0f, 1.0f},
    {kKnob_p3, "Sheen", 0.0f, 1.0f}};
const MaterialKnob kMarble[] = {{kKnob_p1, "Vein scale", 0.02f, 1.0f},
    {kKnob_p4, "Vein contrast", 0.0f, 1.0f},
    {kKnob_p5, "Vein sharpness", 1.0f, 20.0f}};

/* The object's (or state's) own value only: a GLOBAL override would turn one
   layer's tuning into every object's, which is not what Custom means. */
bool MaterialCustomValue(const CSetting* set1, const CSetting* set2, int index,
    float* out)
{
  return SettingGetIfDefined<float>(set1, index, out) ||
         SettingGetIfDefined<float>(set2, index, out);
}
} // namespace

int MaterialKnobs(int id, const MaterialKnob** knobs)
{
  const MaterialKnob* k = nullptr;
  int n = 0;
#define RAYMOL_KNOBS(arr) (k = arr, n = int(sizeof(arr) / sizeof(arr[0])))
  if (MaterialIsImplemented(id)) {
    switch (id) {
    case cMaterial_plastic:
    case cMaterial_metallic: RAYMOL_KNOBS(kReflective); break;
    case cMaterial_glass: RAYMOL_KNOBS(kGlass); break;
    case cMaterial_frosted_glass: RAYMOL_KNOBS(kFrostedGlass); break;
    case cMaterial_jelly: RAYMOL_KNOBS(kJelly); break;
    case cMaterial_matte: RAYMOL_KNOBS(kMatte); break;
    case cMaterial_clay: RAYMOL_KNOBS(kClay); break;
    case cMaterial_rubber: RAYMOL_KNOBS(kRubber); break;
    case cMaterial_marble: RAYMOL_KNOBS(kMarble); break;
    }
  }
#undef RAYMOL_KNOBS
  if (knobs)
    *knobs = k;
  return n;
}

static MaterialParams MaterialFinalizeParams(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2, int repType,
    MaterialParams params)
{
  // reflect/tint/rough belong to the REFLECTIVE family (its reflection) and
  // the GLASS family (`rough` is its reflection blur or frost). Every other
  // family draws with all three at 0: that is what `default` has always
  // drawn with, and the procedural rows' `rough` values (matte's 1.0,
  // clay's...) are not a knob those shaders read. Zeroing here keeps
  // `default` and the procedural materials byte-exact now that the legacy
  // object-wide metal_rt_reflect* triple they used to read -- 0 unless
  // someone set it -- is gone (#565).
  (void)G;
  if (params.family != cMaterialFamily_reflective &&
      params.family != cMaterialFamily_glass) {
    params.reflect = 0.0f;
    params.tint = 0.0f;
    params.rough = 0.0f;
  }
  // Custom (#568): the layer's own overrides of the knobs its material HAS
  // (MaterialKnobs, keyed by the material's own id -- `mode`). The shading
  // model stays the material's, so an override never switches pipelines.
  // `default` has no knobs, which also keeps the default path free of these
  // lookups; so does a degraded rep, which resolves to `default`.
  if (params.family == cMaterialFamily_default)
    return params;
  const CustomOverrideSet* ov = MaterialCustomOverridesForRep(repType);
  if (!ov)
    return params;
  const MaterialKnob* knobs = nullptr;
  int const n = MaterialKnobs(params.mode, &knobs);
  float v = 0.0f;
  for (int i = 0; i < n; ++i) {
    int const slot = knobs[i].slot;
    if (!MaterialCustomValue(set1, set2, ov->slot[slot], &v))
      continue;
    switch (slot) {
    case kKnob_reflect: params.reflect = v; break;
    case kKnob_tint: params.tint = v; break;
    case kKnob_rough: params.rough = v; break;
    default: params.p[slot - kKnob_p0] = v; break;
    }
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

/* Is this representation drawn TRANSPARENT?
 *
 * The four transparency settings are atom-level (stick_transparency is
 * bond-level, but `set ..., <selection>` writes its atoms too), and a selection
 * write leaves the object value at 0 -- so the object-level value alone misses
 * `set cartoon_transparency, 0.5, chain A` entirely.
 *
 * Rep::hasTransparency() knows the truth, but only once the rep has been built,
 * which makes it order-dependent. Reading the settings answers the same
 * question deterministically, the way each rep's own build does. */
static bool MaterialRepIsTransparent(PyMOLGlobals* G, const CoordSet* cs,
    const CSetting* set1, const CSetting* set2, int repType, int repBit)
{
  int const index = MaterialTransparencySettingForRep(repType);
  if (index == 0) {
    return false;
  }
  float const objLevel = SettingGet_f(G, set1, set2, index);
  if (objLevel > 0.0f) {
    return true;
  }
  if (cs && cs->Rep[repType] && cs->Rep[repType]->hasTransparency()) {
    return true;
  }
  if (!cs) {
    return false;
  }
  for (int idx = 0; idx < cs->getNIndex(); ++idx) {
    const AtomInfoType* ai = cs->getAtomInfo(idx);
    if (!(ai->visRep & repBit)) {
      continue;
    }
    if (AtomSettingGetWD(G, ai, index, objLevel) > 0.0f) {
      return true;
    }
  }
  return false;
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

bool MaterialObjectWantsPeel(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, const pymol::CObject* obj)
{
  int peel = -1;
  if (!SettingGetIfDefined_i(G, set1, cSetting_transparency_peel, &peel) &&
      !SettingGetIfDefined_i(G, set2, cSetting_transparency_peel, &peel)) {
    peel = SettingGetGlobal_i(G, cSetting_transparency_peel);
  }
  if (peel >= 0) {
    return peel != 0;   // an explicit on/off, at any level, wins outright
  }
  // Auto: on when a representation resolves to a material whose row asks for
  // peeling, resolved the same way the DRAW path resolves it -- so a glass
  // stick that degrades to `default` on a stick_ball object does not turn on a
  // peel that would cost a depth blit and two encoder boundaries per grid cell
  // for geometry with no transparent fragments.
  //
  // But peeling is OBJECT-scoped: the pre-pass records the nearest transparent
  // depth across ALL of the object's transparent reps, and anything behind it
  // fails the equality test. So auto must refuse when the object also has a
  // transparent rep that did not ask for this -- otherwise setting
  // `surface_material, glass` on an object whose cartoon is translucent makes
  // that cartoon VANISH, a look the user had before and never asked to change.
  // An explicit `transparency_peel 1` still peels the whole object: that one
  // the user did ask for.
  static const int kReps[] = {cRepCartoon, cRepSurface, cRepCyl, cRepSphere};
  static const int kRepBits[] = {cRepCartoonBit, cRepSurfaceBit, cRepCylBit,
      cRepSphereBit};
  auto const* objmol = dynamic_cast<const ObjectMolecule*>(obj);
  const CoordSet* cs = nullptr;
  if (objmol) {
    cs = const_cast<ObjectMolecule*>(objmol)->getCoordSet(
        const_cast<ObjectMolecule*>(objmol)->getCurrentState());
  }
  /* Two passes, cheap one first. Asking whether anything wants peeling is a
     pair of table lookups per rep; the VETO costs atom scans. An object with no
     material set -- every object in a default session -- must not pay the
     second, and this runs once per object per FRAME. */
  bool maybeWantsPeel = false;
  for (size_t i = 0; i < sizeof(kReps) / sizeof(kReps[0]); ++i) {
    if (MaterialResolve(MaterialResolveSettingId(G, set1, set2,
                            MaterialSourceRep(G, set1, set2, kReps[i], obj)),
            kReps[i])
            .wantsPeel) {
      maybeWantsPeel = true;
      break;
    }
  }
  if (!maybeWantsPeel) {
    return false;
  }
  /* MAYBE, not "does": the gate reads the material row BEFORE the per-rep
     degradations, because seeing them needs the coordinate set this pass exists
     to avoid touching. It is a sound over-approximation -- degradation can only
     ever clear wantsPeel -- so the answer still has to come from the second
     loop. Returning true here on the strength of the gate turned peel ON for a
     ball-and-stick glass object, whose sticks degrade to `default` and have no
     transparent fragments at all: a depth blit and two encoder boundaries per
     grid cell for nothing, and enough to evict a real glass object from the
     three-slot peel cap. */
  /* Indexed, not range-for: the rep and its visibility BIT have to stay in
     step, and a range-for gives a copy whose address says nothing about which
     element it came from. */
  bool wantsPeel = false;
  for (size_t i = 0; i < sizeof(kReps) / sizeof(kReps[0]); ++i) {
    int const rep = kReps[i];
    // Re-resolved through the DRAW path, so a glass stick that degrades to
    // `default` on a stick_ball object is not treated as asking for a peel it
    // will never use.
    if (MaterialResolveForDraw(G, set1, set2, rep, cs).wantsPeel) {
      // ...but only if the object actually DRAWS it. `set surface_material,
      // glass` on an object showing nothing but an opaque cartoon would
      // otherwise turn peel on for geometry that does not exist -- a depth blit
      // and two encoder boundaries per grid cell, and one of only three peel
      // slots, which can evict an object that really is glass.
      //
      // `!cs ||` is load-bearing: cs is null for every non-ObjectMolecule in
      // NonGadgetObjs, and those still resolve materials through CGOGL, so a
      // bare hasRep gate would silently stop peeling them.
      if (!cs || const_cast<CoordSet*>(cs)->hasRep(kRepBits[i])) {
        wantsPeel = true;
      }
      continue;
    }
    // A rep the object does not draw cannot be occluded by the peel, so it must
    // not veto. Without this gate a GLOBAL `set transparency, 0.5` -- which
    // SettingGet_f falls back to -- turned auto-peel off for every glass
    // cartoon in the session on account of a surface nothing was showing.
    if (!cs || !const_cast<CoordSet*>(cs)->hasRep(kRepBits[i])) {
      continue;
    }
    if (MaterialRepIsTransparent(G, cs, set1, set2, rep, kRepBits[i])) {
      return false;
    }
  }
  return wantsPeel;
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
