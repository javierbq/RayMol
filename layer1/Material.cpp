/*
 * Materials (#503): material ids, and which settings hold one. See Material.h.
 */

#include "Material.h"
#include "Rep.h"
#include "Setting.h"

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

MaterialParams MaterialResolve(int id, int repType)
{
  (void) id;
  (void) repType;
  // The table lands with #486. Until then every id -- including one no row
  // claims -- resolves to `default`, which is exactly today's shading.
  return MaterialParams{};
}
