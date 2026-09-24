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

