/*
 * Materials (#503): the named material table.
 *
 * A material says what a representation is MADE OF, the way colour says what
 * it IS. Ids — not names — are what `cartoon_material`, `surface_material`,
 * `stick_material`, `sphere_material` and `material_default` store, so the
 * values round-trip through `.pse` and through builds that predate a given
 * material. Id 0 is `default`: today's shading, byte for byte.
 *
 * Names live here, on the C side, so `get`, the `Setting: ... set to ...`
 * feedback line, the Settings panel and `.pml` logs all show `marble` rather
 * than `7` — and `set` takes those same names back (the Python side maps them
 * through `_cmd.get_material_names`), so `get` never reports something `set`
 * would refuse. An id with no row is not renamed and resolves to `default` at
 * draw time; a NAME never falls back, it is an error at set time.
 */

#pragma once

struct PyMOLGlobals;
struct CSetting;
struct CoordSet;

/* The function-constant axis the Metal pipelines are specialised on. Family 0
   compiles to today's code, so a `default` draw is byte for byte unchanged. */
enum {
  cMaterialFamily_default = 0,
  cMaterialFamily_procedural,
  cMaterialFamily_reflective,
  cMaterialFamily_glass,
  cMaterialFamily_count
};

/* Material ids. Append only: these are written into .pse files. */
enum {
  cMaterial_default = 0,
  cMaterial_matte,
  cMaterial_plastic,
  cMaterial_metallic,
  cMaterial_glass,
  cMaterial_frosted_glass,
  cMaterial_jelly,
  cMaterial_marble,
  cMaterial_clay,
  cMaterial_rubber,
  cMaterial_count
};

/**
 * What a material resolves to for one draw. A pure function of the material id
 * and the representation: it writes no setting and never touches colour.
 *
 * `family` is the function-constant axis the pipelines are specialised on
 * (default / procedural / reflective / glass); family 0 compiles to today's
 * code. `mode` selects within a family. `p` carries the per-material knobs
 * (grain, frequency, vein sharpness, ...). `wantsPeel` asks the scene loop to
 * keep only this object's nearest transparent layer.
 *
 * Mirrored field for field by `MaterialU` on the Metal side, which appends the
 * object's inverse modelview. Floats and ints only.
 */
struct MaterialParams {
  int family = 0;
  int mode = 0;
  float reflect = 0.0f;
  float tint = 0.0f;
  float rough = 0.0f;
  float p[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
  int wantsPeel = 0;
};

/**
 * The material setting a representation reads, or 0 for the representations
 * that keep default shading in v1 (ribbon, mesh, dots, lines, labels).
 *
 * `stick_ball` spheres are emitted by the STICK rep, so they arrive here as
 * cRepCyl and take `stick_material`, not `sphere_material`.
 */
int MaterialSettingForRep(int repType);

/**
 * Resolve the material id for one draw: the rep's OBJECT-level value (or
 * object-state), then the rep's global value, then `material_default`.
 *
 * An object-level value wins outright even when it is `default` — that is how
 * a user turns a global material off for one object. A global rep value only
 * loses to `material_default` when it is itself `default`, since a global has
 * no "undefined" state to distinguish.
 *
 * @param set1 coordinate-set (object-state) settings, may be null
 * @param set2 object settings, may be null
 */
int MaterialResolveSettingId(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2, int repType);

/**
 * True when at least one IMPLEMENTED material belongs to this family, so the
 * renderer knows which specialised pipelines are worth building. The default
 * family is always in use. As later waves flip `implemented` flags this grows;
 * a family nothing can draw costs no pipeline.
 */
bool MaterialFamilyIsImplemented(int family);

/**
 * Number of rows in the material table.
 */
int MaterialTableSize();

/**
 * True when a material can actually draw today. The names API hides the rest,
 * so the Inspector dropdown grows wave by wave instead of offering looks that
 * would silently render as `default`. Setting one by name still works: it is a
 * real material id, it just has no shader yet.
 */
bool MaterialIsImplemented(int id);

/**
 * The ALPHA -- opacity, where 1 is fully solid -- that a glass-family material
 * implies, or 0 when it implies none. Clear `glass` is 0.15, i.e. mostly
 * see-through. Callers that want a TRANSPARENCY must use 1 - alpha;
 * MaterialEffectiveTransparency is the one place that conversion lives.
 *
 * Consulted at REP-BUILD time in layer2, beside the rep's own transparency
 * setting, and only when that setting is 0 -- the user's transparency slider
 * still wins. It is never written back as a setting: a `.pse` opened in an
 * older build renders an opaque surface, visible and wrong, never invisible.
 */
float MaterialImpliedAlpha(int id);

/**
 * The transparency a representation should build with (#495).
 *
 * `transparency` is the rep's own setting, already resolved. When it is 0 and
 * the rep's material implies an opacity -- the glass family does -- the implied
 * value is used instead. The user's slider always wins: a non-zero setting is
 * returned untouched, so turning glass down to opaque stays possible.
 *
 * Implied alpha is a rep-BUILD input, never written back as a setting. A .pse
 * opened in a build that does not know the material then renders an opaque
 * surface -- visible and wrong -- rather than an invisible one.
 *
 * @param set1 coordinate-set settings, may be null
 * @param set2 object settings, may be null
 * @param repType the cRep_t whose material to consult
 * @param transparency the rep's own resolved transparency (0 = opaque)
 * @param cs the coordinate set, so ATOM-level overrides of `stick_ball` are
 *        seen; without it only the object-level value is consulted
 */
float MaterialEffectiveTransparency(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, float transparency,
    const CoordSet* cs = nullptr);

/**
 * The parameters a material id renders with on a given representation.
 *
 * Also where a material that cannot draw on a representation degrades to
 * `default` (glass on sphere impostors, for one) rather than glitching.
 *
 * The table behind this arrives with the material table itself (#486); today
 * every id resolves to `default`, so declaring a material changes nothing that
 * is drawn.
 */
MaterialParams MaterialResolve(int id, int repType);

/**
 * The parameters a representation actually DRAWS with: the resolved material id
 * put through MaterialResolve, plus the degradation rules that depend on a
 * SETTING rather than on the rep alone (glass on `stick_ball` sticks).
 *
 * The single definition of "what this rep is made of". Shading and implied
 * alpha both go through it, because they have to agree: a rep that shades as
 * `default` but still builds transparent is not rendering `default`.
 */
MaterialParams MaterialResolveForDraw(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs = nullptr);

/**
 * The FINAL parameters a draw uses: MaterialResolveForDraw plus the decision of
 * which families read the legacy object-scoped `metal_rt_reflect*` triple.
 *
 * The draw site is a thin caller of this, so the rules stay in one place and
 * can be asserted from Python without a Metal context.
 */
MaterialParams MaterialDrawParams(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs = nullptr);

/**
 * Name of a material id, or nullptr when no row has that id.
 */
const char* MaterialGetName(int id);

/**
 * Shading family of a material id, or -1 when no row has that id.
 *
 * Exposed so a test can ask which family a material belongs to. Without it the
 * only Python-visible facts are the id, the name and whether it is implemented
 * -- so a test that means "no implemented material is reflective yet" cannot
 * express itself and quietly asserts something else instead. That happened
 * (#493's own guard), which is why this exists.
 */
int MaterialGetFamily(int id);

/**
 * The material id a representation EFFECTIVELY draws with, after the per-rep
 * degradation in MaterialResolve (glass on sphere impostors, for one, which
 * would otherwise float as near-invisible discs).
 *
 * Distinct from MaterialResolveSettingId, which answers what the SETTING says.
 * Both matter: the setting keeps the user's intent across a .pse, while this is
 * what actually reaches the shader. Exposed so the difference is testable.
 */
int MaterialEffectiveId(int id, int repType);

/**
 * True for the four PER-REPRESENTATION material settings.
 */
bool MaterialIsRepMaterialSetting(int index);

/**
 * The transparency setting a representation reads, or 0 when it has none.
 *
 * `transparency` for a surface, `cartoon_transparency` for a cartoon, and so
 * on. Returning 0 for the rest matters: mapping every unknown rep onto
 * `transparency` would report the SURFACE's value for a mesh or a ribbon.
 */
int MaterialTransparencySettingForRep(int repType);

/**
 * Whether an object's transparent geometry should be depth-PEELED (#488):
 * a colour-less depth pre-pass, then the object's transparent draws tested for
 * equality against it, so only the nearest surface per pixel contributes.
 * Without it a translucent ball-and-stick reads as dense mottle -- the front
 * and back of every stick, and every stick behind it, all accumulate.
 *
 * `transparency_peel` decides: 1 on, 0 off, and -1 (the default) means AUTO --
 * on when any of the object's four representations resolves to a material whose
 * row asks for it (`wantsPeel`, which the glass family sets). Auto is
 * deliberately not "any transparent object": peeling a plain translucent
 * surface changes a look users already rely on, and it costs a depth blit and
 * two encoder boundaries per object per grid cell.
 *
 * @param set1 coordinate-set (object-state) settings, may be null
 * @param set2 object settings, may be null
 */
bool MaterialObjectWantsPeel(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2);

/**
 * True for every setting whose value is a material id (the four
 * per-representation ones plus `material_default`) — i.e. every setting whose
 * value `get` should render as a NAME rather than as a number.
 */
bool MaterialIsMaterialSetting(int index);

/**
 * True for the object-scoped settings a SELECTION-scoped `set` is refused for:
 * the four per-representation materials plus `transparency_peel`. They are
 * ints, so the generic selection path would write an atom-level value on every
 * matched atom that no draw path reads -- a success message and no change.
 */
bool MaterialIsSelectionRejectedSetting(int index);

