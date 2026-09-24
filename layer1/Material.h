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

/* The function-constant axis the Metal pipelines are specialised on. Family 0
   compiles to today's code, so a `default` draw is byte for byte unchanged. */
enum {
  cMaterialFamily_default = 0,
  cMaterialFamily_procedural,
  cMaterialFamily_reflective,
  cMaterialFamily_glass,
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
 * The opacity a glass-family material implies, or 0 when it implies none.
 *
 * Consulted at REP-BUILD time in layer2, beside the rep's own transparency
 * setting, and only when that setting is 0 -- the user's transparency slider
 * still wins. It is never written back as a setting: a `.pse` opened in an
 * older build renders an opaque surface, visible and wrong, never invisible.
 */
float MaterialImpliedAlpha(int id);

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
 * Name of a material id, or nullptr when no row has that id.
 */
const char* MaterialGetName(int id);

/**
 * True for the four PER-REPRESENTATION material settings.
 */
bool MaterialIsRepMaterialSetting(int index);

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

