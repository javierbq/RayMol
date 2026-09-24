/*
 * Materials (#503): the named material table.
 *
 * A material says what a representation is MADE OF, the way colour says what
 * it IS. Ids — not names — are what `cartoon_material`, `surface_material`,
 * `stick_material`, `sphere_material` and `material_default` store, so the
 * values round-trip through `.pse` and through builds that predate a given
 * material. Names live here, on the C side, so `get`, the `Setting: ... set
 * to ...` feedback line, `iterate s.stick_material`, the Settings panel and
 * `.pml` logs all show `marble` rather than `7`.
 *
 * Id 0 is `default`: today's shading, byte for byte. An id with no row here is
 * not renamed and resolves to `default` at draw time; a NAME never falls back,
 * it is an error at set time.
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
 * Name of a material id, or nullptr when no row has that id.
 */
const char* MaterialGetName(int id);

/**
 * Id of a material name (exact match, case sensitive), or -1 when unknown.
 */
int MaterialGetId(const char* name);

/**
 * True for the four PER-REPRESENTATION material settings. These are the ones a
 * selection-scoped `set` has to be refused for: they are ints, and the generic
 * selection path would happily write an atom-level int that nothing reads.
 */
bool MaterialIsRepMaterialSetting(int index);

/**
 * True for every setting whose value is a material id (the four
 * per-representation ones plus `material_default`) — i.e. every setting whose
 * value should be rendered as a name rather than as a number.
 */
bool MaterialIsMaterialSetting(int index);
