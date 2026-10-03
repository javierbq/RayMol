/*
 * Python conversions of the light rig (#611). The only lighting code that
 * touches Python: included by layer4/Cmd.cpp (and, from the session ticket
 * part on, layer3/Executive.cpp), never by the scene or the app bridge.
 *
 * Every conversion is driven by the field table in LightRig.h, so the dict
 * keys, the session list order and get_light_fields() cannot drift apart.
 */

#pragma once

#include "os_python.h"

#include "LightRig.h"
#include "Result.h"

#ifndef _PYMOL_NOPY

/**
 * The rig as cmd.get_lights() returns it (version 1):
 *   {'version': 1, 'enabled', 'centre': [x, y, z] | None, 'size': float | None,
 *    'ambient', 'classic', 'air': {...}, 'lights': [{...}, ...]}
 * in field-table order. New reference.
 */
PyObject* LightRigAsPyDict(const pymol::LightRig& rig);

/**
 * Parse cmd.set_lights()'s dict, strictly: unknown keys, a newer version,
 * wrong types, non-finite numbers, bad choices and a pinned light without a
 * 'position' are errors naming the key (and the light). Missing keys take the
 * defaults, a light without a name takes the next unused default name, and
 * out-of-range numbers are clamped. The frame is not captured and the rig is
 * not validated here: SceneLightsReplace() does both.
 */
pymol::Result<pymol::LightRig> LightRigFromPyDict(PyObject* obj);

/**
 * The field table, for _cmd.get_light_fields():
 *   [(scope, name, kind, default, min, max), ...]
 * scope is 'rig', 'air' or 'light'; kind is LightKindName(); min/max are None
 * for unbounded fields; the frame fields default to None and a light's name
 * to None (assigned: key, fill, rim, light4, ...). New reference.
 */
PyObject* LightFieldsAsPyList();

#endif
