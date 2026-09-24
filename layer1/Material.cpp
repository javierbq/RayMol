/*
 * Materials (#503): the named material table. See Material.h.
 */

#include "Material.h"
#include "Setting.h"

namespace
{
/* Index is the material id; the order must match the enum in Material.h. */
const char* const kMaterialNames[] = {
    "default",
    "matte",
    "plastic",
    "metallic",
    "glass",
    "frosted_glass",
    "jelly",
    "marble",
    "clay",
    "rubber",
};

static_assert(sizeof(kMaterialNames) / sizeof(kMaterialNames[0]) ==
                  cMaterial_count,
    "material name table and id enum disagree");
} // namespace

const char* MaterialGetName(int id)
{
  if (id < 0 || id >= cMaterial_count) {
    return nullptr;
  }
  return kMaterialNames[id];
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

bool MaterialIsSelectionRejectedSetting(int index)
{
  // transparency_peel is object-scoped for the same reason the materials are,
  // and a selection-scoped set of it fails the same silent way.
  return index == cSetting_transparency_peel ||
         MaterialIsRepMaterialSetting(index);
}

bool MaterialIsMaterialSetting(int index)
{
  return index == cSetting_material_default ||
         MaterialIsRepMaterialSetting(index);
}
