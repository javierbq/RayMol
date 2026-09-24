/*
 * Materials (#503): material ids, and which settings hold one.
 *
 * A material says what a representation is MADE OF, the way colour says what
 * it IS. Ids — not names — are what `cartoon_material`, `surface_material`,
 * `stick_material`, `sphere_material` and `material_default` store, so the
 * values round-trip through `.pse` and through builds that predate a given
 * material. Id 0 is `default`: today's shading, byte for byte.
 *
 * The names, and the table behind them, arrive with the material table — both
 * directions of the mapping at once, so `get` never reports a name that `set`
 * would refuse.
 */

#pragma once

struct PyMOLGlobals;
struct CSetting;

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
 * True for the four PER-REPRESENTATION material settings.
 */
bool MaterialIsRepMaterialSetting(int index);

/**
 * True for the object-scoped settings a SELECTION-scoped `set` is refused for:
 * the four per-representation materials plus `transparency_peel`. They are
 * ints, so the generic selection path would write an atom-level value on every
 * matched atom that no draw path reads -- a success message and no change.
 */
bool MaterialIsSelectionRejectedSetting(int index);

