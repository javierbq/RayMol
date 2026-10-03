/*
 * Python conversions of the light rig (#611). The only lighting code that
 * touches Python: included by layer4/Cmd.cpp and layer3/Executive.cpp
 * (sessions), never by the scene or the app bridge.
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
 * wrong types, non-finite numbers, bad choices, a pinned light without a
 * 'position' and a light aimed at a point without an 'aim_point' are errors
 * naming the key (and the light). Missing keys take the
 * defaults, a light without a name takes the next unused default name, and
 * out-of-range numbers are clamped. The frame is not captured and the rig is
 * not validated here: SceneLightsReplace() does both.
 */
pymol::Result<pymol::LightRig> LightRigFromPyDict(PyObject* obj);

/**
 * The rig as the .pse session key 'light_rig' holds it (spec §6): a
 * positional list with the dict's version and fields, one list per scope,
 * each in field-table order:
 *
 *   [version,
 *    [enabled, centre, size, ambient, classic],
 *    [haze, dust, dust_size, dust_speed, scatter, seed],
 *    [[name, anchor, orbit, pitch, radius, position, aim, aim_point,
 *      aim_selection, beam, softness, color, warmth, intensity, highlight,
 *      falloff, shadow, outline], ...]]
 *
 * Plain values only: bools and the anchor/aim choices as the ints 0|1,
 * numbers as int or float, vectors as lists of 3 floats, text as str, an
 * unset frame as None. Nothing goes through PConv's binary arrays, so
 * pse_binary_dump never turns the values into blobs, and older builds (which
 * read only the keys they know) see plain data. New reference.
 *
 * Append-only, and the four top-level slots are frozen: a later version adds
 * a field at the end of its scope's list (append it at the end of its scope
 * in LightRigFields()), and a new top-level slot only after the lights. A
 * version 1 reader then still finds every list where it was and loads each
 * list's known prefix.
 */
PyObject* LightRigAsPyList(const pymol::LightRig& rig);

/**
 * Read the 'light_rig' session list. Lenient where LightRigFromPyDict is
 * strict, so that a session loads whenever its rig makes sense:
 * - missing trailing fields and lists take the defaults (a light without a
 *   name takes the next unused default name);
 * - extra trailing fields and top-level slots are ignored; when the version
 *   is newer than this build reads, the known prefix is loaded with a
 *   warning (Q6);
 * - out-of-range numbers are clamped (Q3);
 * - the caps are policy, not format: lights after the 6th are left out and
 *   shadows after the 3rd turned off, each with a warning;
 * - text may be UTF-8 bytes, which is how a .pse saved with the legacy
 *   pickler (pse_export_version < 1.9) gives non-ASCII text back.
 * A wrong type, a non-finite number, a version below 1, a pinned light
 * without a position, a light aimed at a point without an aim point, or a
 * rig that fails LightRigValidate() is an error naming the field (and the
 * light): the caller then clears the rig. `warnings` (when given) gets one
 * line per warning. Never leaves a Python error set.
 */
pymol::Result<pymol::LightRig> LightRigFromPyList(
    PyObject* obj, std::vector<std::string>* warnings = nullptr);

/**
 * The field table, for _cmd.get_light_fields():
 *   [(scope, name, kind, default, min, max), ...]
 * scope is 'rig', 'air' or 'light'; kind is LightKindName(); min/max are None
 * for unbounded fields; the frame fields default to None and a light's name
 * to None (assigned: key, fill, rim, light4, ...). New reference.
 */
PyObject* LightFieldsAsPyList();

/// One field's value as the dict holds it (bool, int, float, [x, y, z], str,
/// 'camera'/'pinned', 'centre'/'point', or None). New reference.
PyObject* LightValueAsPy(const pymol::LightField& field,
    const pymol::LightValue& value);

/**
 * The rig resolved to eye space, for _cmd.get_lights_eye():
 *   {'enabled', 'centre': [x, y, z] | None, 'size': float | None,
 *    'lights': [{'name', 'anchor', 'aim', 'position', 'target', 'direction',
 *                'aim_distance', 'cos_outer', 'cos_inner', 'orbit', 'pitch',
 *                'radius', 'shadow', 'outline'}, ...]}
 * Positions are eye space; names come from `rig`. New reference.
 */
PyObject* LightRigEyeAsPyDict(
    const pymol::LightRig& rig, const pymol::LightRigEye& eye);

/// A world->eye matrix from 16 numbers in column-major order (as
/// glm::make_mat4 reads them).
pymol::Result<glm::dmat4> LightMatrixFromPy(PyObject* obj);

/// _cmd.light_set's value: a number (n = 1) or a sequence of 3 (n = 3).
pymol::Result<> LightSetValueFromPy(PyObject* obj, double v[3], int& n);

#endif
