/*
 * Python conversions of the light rig (#611). See LightRigPy.h.
 */

#include "LightRigPy.h"

#ifndef _PYMOL_NOPY

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

using pymol::Light;
using pymol::LightField;
using pymol::LightKind;
using pymol::LightRig;
using pymol::LightScope;
using pymol::LightValue;

namespace
{

const char* scopeName(LightScope scope)
{
  switch (scope) {
  case LightScope::Rig:
    return "rig";
  case LightScope::Air:
    return "air";
  case LightScope::Light:
    return "light";
  }
  return "";
}

/* ---- to Python -------------------------------------------------------- */

PyObject* pyString(const std::string& s)
{
  return PyUnicode_DecodeUTF8(s.data(), Py_ssize_t(s.size()), "replace");
}

PyObject* pyVec3(const double* v)
{
  return Py_BuildValue("[ddd]", v[0], v[1], v[2]);
}

PyObject* pyNone()
{
  Py_RETURN_NONE;
}

PyObject* pyVec3(const glm::vec3& v)
{
  return Py_BuildValue("[ddd]", double(v.x), double(v.y), double(v.z));
}

/// One field's value as a Python object (new reference, nullptr on error).
PyObject* valueToPy(const LightField& field, const LightValue& value)
{
  if (value.unset)
    Py_RETURN_NONE;
  const double v = value.num[0];
  switch (field.kind) {
  case LightKind::Bool:
    return PyBool_FromLong(v != 0.0);
  case LightKind::Int:
    return PyLong_FromLong(long(v));
  case LightKind::Float:
  case LightKind::Angle:
    return PyFloat_FromDouble(v);
  case LightKind::Vec3:
    return pyVec3(value.num);
  case LightKind::Str:
  case LightKind::Name:
    return pyString(value.str);
  case LightKind::Anchor:
  case LightKind::Aim:
    return PyUnicode_FromString(pymol::LightChoiceName(field.kind, int(v)));
  }
  Py_RETURN_NONE;
}

/// d[key] = value, stealing `value`. False (with a Python error) on failure.
bool setItem(PyObject* d, const char* key, PyObject* value)
{
  if (!value)
    return false;
  int rc = PyDict_SetItemString(d, key, value);
  Py_DECREF(value);
  return rc == 0;
}

template <typename Source>
bool putFields(PyObject* d, LightScope scope, const Source& source)
{
  for (const auto& field : pymol::LightRigFields()) {
    if (field.scope != scope)
      continue;
    if (!setItem(d, field.name, valueToPy(field, LightFieldGet(source, field))))
      return false;
  }
  return true;
}

/* ---- from Python ------------------------------------------------------ */

std::string typeName(PyObject* o)
{
  return Py_TYPE(o)->tp_name;
}

std::string reprOf(PyObject* o)
{
  unique_PyObject_ptr repr(PyObject_Repr(o));
  if (!repr) {
    PyErr_Clear();
    return typeName(o);
  }
  const char* s = PyUnicode_AsUTF8(repr.get());
  if (!s) {
    PyErr_Clear();
    return typeName(o);
  }
  return s;
}

/// A Python int or float (not a bool) as a double.
bool pyNumber(PyObject* o, double& out)
{
  if (PyBool_Check(o) || !(PyFloat_Check(o) || PyLong_Check(o)))
    return false;
  out = PyFloat_AsDouble(o);
  if (out == -1.0 && PyErr_Occurred()) {
    PyErr_Clear(); // an int too large for a double
    out = HUGE_VAL;
  }
  return true;
}

pymol::Result<double> number(
    const LightField& field, PyObject* o, const std::string& where)
{
  double v;
  if (!pyNumber(o, v)) {
    return pymol::make_error(where, "'", field.name, "' must be a number, got ",
        typeName(o));
  }
  if (!std::isfinite(v)) {
    return pymol::make_error(
        where, "'", field.name, "' must be finite, got ", reprOf(o));
  }
  return v;
}

/// One field's value from a Python object, strictly typed.
pymol::Result<LightValue> valueFromPy(
    const LightField& field, PyObject* o, const std::string& where)
{
  LightValue value;
  if (o == Py_None && field.optional) {
    value.unset = true;
    return value;
  }

  switch (field.kind) {
  case LightKind::Bool: {
    // True/False, or the ints 0/1 (the session list stores 0|1)
    long b = -1;
    if (PyBool_Check(o) || PyLong_Check(o)) {
      b = PyLong_AsLong(o);
      if (b == -1 && PyErr_Occurred())
        PyErr_Clear();
    }
    if (b != 0 && b != 1) {
      return pymol::make_error(where, "'", field.name,
          "' must be True or False, got ", reprOf(o));
    }
    value.num[0] = double(b);
    return value;
  }
  case LightKind::Int: {
    if (PyBool_Check(o) || !PyLong_Check(o)) {
      return pymol::make_error(where, "'", field.name,
          "' must be an int, got ", typeName(o));
    }
    auto v = number(field, o, where);
    p_return_if_error(v);
    value.num[0] = *v;
    return value;
  }
  case LightKind::Float:
  case LightKind::Angle: {
    auto v = number(field, o, where);
    p_return_if_error(v);
    value.num[0] = *v;
    return value;
  }
  case LightKind::Vec3: {
    // the real item count (ob_size), never a subclass's __len__: the items
    // are read straight from the list or tuple below
    const bool seq = (PyList_Check(o) || PyTuple_Check(o)) &&
                     PySequence_Fast_GET_SIZE(o) == 3;
    if (!seq) {
      return pymol::make_error(where, "'", field.name,
          "' must be a list of 3 numbers", field.optional ? " or None" : "",
          ", got ", reprOf(o));
    }
    for (int i = 0; i < 3; ++i) {
      PyObject* item = PySequence_Fast_GET_ITEM(o, i); // list or tuple
      auto v = number(field, item, where);
      p_return_if_error(v);
      value.num[i] = *v;
    }
    return value;
  }
  case LightKind::Str:
  case LightKind::Name: {
    if (!PyUnicode_Check(o)) {
      return pymol::make_error(where, "'", field.name,
          "' must be a string, got ", typeName(o));
    }
    Py_ssize_t len = 0;
    const char* s = PyUnicode_AsUTF8AndSize(o, &len);
    if (!s) {
      PyErr_Clear();
      return pymol::make_error(
          where, "'", field.name, "' is not valid text");
    }
    value.str.assign(s, size_t(len));
    return value;
  }
  case LightKind::Anchor:
  case LightKind::Aim: {
    int index = -1;
    if (PyUnicode_Check(o)) {
      const char* s = PyUnicode_AsUTF8(o);
      if (s)
        index = pymol::LightChoiceIndex(field.kind, s);
      else
        PyErr_Clear();
    }
    if (index < 0) {
      return pymol::make_error(where, "'", field.name, "' must be '",
          pymol::LightChoiceName(field.kind, 0), "' or '",
          pymol::LightChoiceName(field.kind, 1), "', got ", reprOf(o));
    }
    value.num[0] = index;
    return value;
  }
  }
  return pymol::make_error(where, "'", field.name, "': unsupported kind");
}

/// Every key of `d` is a string naming a field of `scope` or one of `extra`.
pymol::Result<> checkKeys(PyObject* d, LightScope scope,
    std::initializer_list<const char*> extra, const std::string& where)
{
  PyObject *key, *item;
  Py_ssize_t pos = 0;
  while (PyDict_Next(d, &pos, &key, &item)) {
    if (!PyUnicode_Check(key)) {
      return pymol::make_error(
          where, "keys must be strings, got ", reprOf(key));
    }
    const char* k = PyUnicode_AsUTF8(key);
    if (!k) {
      PyErr_Clear();
      return pymol::make_error(where, "keys must be valid text");
    }
    bool known = pymol::LightRigFindField(scope, k) != nullptr;
    for (const char* name : extra)
      known = known || std::string(k) == name;
    if (!known)
      return pymol::make_error(where, "unknown key '", k, "'");
  }
  return {};
}

/// Put every field of `scope` present in `d` into `target`.
template <typename Target>
pymol::Result<> takeFields(
    PyObject* d, LightScope scope, Target& target, const std::string& where)
{
  for (const auto& field : pymol::LightRigFields()) {
    if (field.scope != scope)
      continue;
    PyObject* item = PyDict_GetItemString(d, field.name); // borrowed
    if (!item)
      continue;
    auto value = valueFromPy(field, item, where);
    p_return_if_error(value);
    LightFieldPut(target, field, *value);
  }
  return {};
}

pymol::Result<Light> lightFromPy(PyObject* d, size_t index, bool& named)
{
  std::string where = "light " + std::to_string(index);
  if (!PyDict_Check(d)) {
    return pymol::make_error(where, " must be a dict, got ", typeName(d));
  }
  PyObject* name = PyDict_GetItemString(d, "name");
  if (name && PyUnicode_Check(name)) {
    if (const char* s = PyUnicode_AsUTF8(name))
      where += " ('" + std::string(s) + "')";
    else
      PyErr_Clear();
  }
  where += ": ";

  auto keys = checkKeys(d, LightScope::Light, {}, where);
  p_return_if_error(keys);

  Light light;
  auto taken = takeFields(d, LightScope::Light, light, where);
  p_return_if_error(taken);

  named = name != nullptr;
  if (light.anchor == pymol::LightAnchor::Pinned &&
      !PyDict_GetItemString(d, "position")) {
    return pymol::make_error(where, "a pinned light needs 'position'");
  }
  if (light.aim == pymol::LightAim::Point &&
      !PyDict_GetItemString(d, "aim_point")) {
    return pymol::make_error(
        where, "a light aimed at a point needs 'aim_point'");
  }
  return light;
}

/// Light names: unnamed lights take the first default names no light uses.
void nameUnnamed(LightRig& rig, const std::vector<bool>& named)
{
  std::vector<std::string> names;
  for (size_t i = 0; i < rig.lights.size(); ++i) {
    if (named[i])
      names.push_back(rig.lights[i].name);
  }
  for (size_t i = 0; i < rig.lights.size(); ++i) {
    if (!named[i]) {
      rig.lights[i].name = pymol::LightRigNextName(names);
      names.push_back(rig.lights[i].name);
    }
  }
}

/* ---- the session list ------------------------------------------------- */

bool isSequence(PyObject* o)
{
  return PyList_Check(o) || PyTuple_Check(o);
}

/// One field's value as the session list holds it: as the dict, but bools
/// and the anchor/aim choices are the ints 0|1. New reference.
PyObject* valueToList(const LightField& field, const LightValue& value)
{
  if (!value.unset) {
    switch (field.kind) {
    case LightKind::Bool:
    case LightKind::Anchor:
    case LightKind::Aim:
      return PyLong_FromLong(value.num[0] != 0.0 ? 1 : 0);
    default:
      break;
    }
  }
  return valueToPy(field, value);
}

/// list.append(item), stealing `item`. False (with a Python error) on failure.
bool appendItem(PyObject* list, PyObject* item)
{
  if (!item)
    return false;
  const int rc = PyList_Append(list, item);
  Py_DECREF(item);
  return rc == 0;
}

/// Append every field of `scope`, in table order, to `list`.
template <typename Source>
bool appendFields(PyObject* list, LightScope scope, const Source& source)
{
  for (const auto& field : pymol::LightRigFields()) {
    if (field.scope != scope)
      continue;
    if (!appendItem(list, valueToList(field, LightFieldGet(source, field))))
      return false;
  }
  return true;
}

/// One field's value from the session list: as from the dict, but bools and
/// the anchor/aim choices are the ints 0|1 (True/False are accepted too),
/// and text may be bytes: a .pse written with the legacy (Python 2) pickler,
/// for pse_export_version < 1.9, loads non-ASCII text as UTF-8 bytes.
pymol::Result<LightValue> valueFromList(
    const LightField& field, PyObject* o, const std::string& where)
{
  switch (field.kind) {
  case LightKind::Str:
  case LightKind::Name:
    if (PyBytes_Check(o)) {
      unique_PyObject_ptr text(PyUnicode_DecodeUTF8(
          PyBytes_AS_STRING(o), PyBytes_GET_SIZE(o), "replace"));
      Py_ssize_t len = 0;
      const char* s =
          text ? PyUnicode_AsUTF8AndSize(text.get(), &len) : nullptr;
      if (!s) {
        PyErr_Clear();
        return pymol::make_error(
            where, "'", field.name, "' is not valid text");
      }
      LightValue value;
      value.str.assign(s, size_t(len));
      return value;
    }
    return valueFromPy(field, o, where);
  case LightKind::Bool:
  case LightKind::Anchor:
  case LightKind::Aim: {
    long b = -1;
    if (PyLong_Check(o)) {
      b = PyLong_AsLong(o);
      if (b == -1 && PyErr_Occurred())
        PyErr_Clear();
    }
    if (b != 0 && b != 1) {
      if (field.kind == LightKind::Bool) {
        return pymol::make_error(
            where, "'", field.name, "' must be 0 or 1, got ", reprOf(o));
      }
      return pymol::make_error(where, "'", field.name, "' must be 0 (",
          pymol::LightChoiceName(field.kind, 0), ") or 1 (",
          pymol::LightChoiceName(field.kind, 1), "), got ", reprOf(o));
    }
    LightValue value;
    value.num[0] = double(b);
    return value;
  }
  default:
    return valueFromPy(field, o, where);
  }
}

/// The position of `id` among its scope's fields (its slot in that list).
Py_ssize_t fieldSlot(pymol::LightFieldId id)
{
  Py_ssize_t slot = 0;
  LightScope scope = LightScope::Rig;
  for (const auto& field : pymol::LightRigFields()) {
    if (field.id == id) {
      scope = field.scope;
      break;
    }
  }
  for (const auto& field : pymol::LightRigFields()) {
    if (field.id == id)
      return slot;
    if (field.scope == scope)
      ++slot;
  }
  return -1;
}

/// Put the fields of `scope` held by the list `seq` into `target`, in table
/// order. Fields past the end of `seq` keep their defaults; items past the
/// scope's last field are ignored (a newer version's fields).
template <typename Target>
pymol::Result<> takeListFields(
    PyObject* seq, LightScope scope, Target& target, const std::string& where)
{
  const Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
  Py_ssize_t slot = 0;
  for (const auto& field : pymol::LightRigFields()) {
    if (field.scope != scope)
      continue;
    if (slot >= n)
      break;
    auto value =
        valueFromList(field, PySequence_Fast_GET_ITEM(seq, slot), where);
    p_return_if_error(value);
    LightFieldPut(target, field, *value);
    ++slot;
  }
  return {};
}

pymol::Result<Light> lightFromList(PyObject* seq, size_t index, bool& named)
{
  std::string where = "light " + std::to_string(index);
  if (!isSequence(seq)) {
    return pymol::make_error(where, " must be a list, got ", typeName(seq));
  }
  const Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
  const Py_ssize_t nameSlot = fieldSlot(pymol::LightFieldId::Name);
  named = n > nameSlot;
  if (named) {
    PyObject* name = PySequence_Fast_GET_ITEM(seq, nameSlot);
    if (PyUnicode_Check(name)) {
      if (const char* s = PyUnicode_AsUTF8(name))
        where += " ('" + std::string(s) + "')";
      else
        PyErr_Clear();
    }
  }
  where += ": ";

  Light light;
  auto taken = takeListFields(seq, LightScope::Light, light, where);
  p_return_if_error(taken);

  if (light.anchor == pymol::LightAnchor::Pinned &&
      n <= fieldSlot(pymol::LightFieldId::Position)) {
    return pymol::make_error(where, "a pinned light needs 'position'");
  }
  if (light.aim == pymol::LightAim::Point &&
      n <= fieldSlot(pymol::LightFieldId::AimPoint)) {
    return pymol::make_error(
        where, "a light aimed at a point needs 'aim_point'");
  }
  return light;
}

/// The session list's top-level slots. Frozen since version 1: each scope
/// has its own list, so a later version adds a field at the end of its
/// scope's list (and a new top-level slot only after the lights), and this
/// reader still finds every list where it was.
enum : Py_ssize_t {
  kSlotVersion = 0,
  kSlotRig = 1,
  kSlotAir = 2,
  kSlotLights = 3,
};

/// The list at top-level `slot` of `obj`, nullptr when the list is shorter
/// (the scope takes its defaults), or an error naming `what`.
pymol::Result<PyObject*> listAt(PyObject* obj, Py_ssize_t slot, const char* what)
{
  if (PySequence_Fast_GET_SIZE(obj) <= slot)
    return static_cast<PyObject*>(nullptr);
  PyObject* item = PySequence_Fast_GET_ITEM(obj, slot);
  if (!isSequence(item)) {
    return pymol::make_error(what, " must be a list, got ", typeName(item));
  }
  return item;
}

/// "light 3 ('back')", or "light 3" for an empty name.
std::string lightLabel(const Light& light, size_t index)
{
  std::string label = "light " + std::to_string(index);
  if (!light.name.empty())
    label += " ('" + light.name + "')";
  return label;
}

pymol::Result<LightRig> rigFromList(
    PyObject* obj, std::vector<std::string>* warnings)
{
  if (!isSequence(obj)) {
    return pymol::make_error("expected a list, got ", typeName(obj));
  }
  const Py_ssize_t n = PySequence_Fast_GET_SIZE(obj);
  if (n < 1) {
    return pymol::make_error("empty list (no version)");
  }

  PyObject* version = PySequence_Fast_GET_ITEM(obj, kSlotVersion);
  if (!PyLong_Check(version) || PyBool_Check(version)) {
    return pymol::make_error(
        "'version' must be an int, got ", typeName(version));
  }
  int overflow = 0;
  const long v = PyLong_AsLongAndOverflow(version, &overflow);
  if (v == -1 && PyErr_Occurred())
    PyErr_Clear();
  if (overflow < 0 || (overflow == 0 && v < 1)) {
    return pymol::make_error("'version' ", reprOf(version),
        " is not a light rig version (1 or later)");
  }
  auto warn = [warnings](std::string text) {
    if (warnings)
      warnings->push_back(std::move(text));
  };
  if (overflow > 0 || v > pymol::kLightRigVersion) {
    warn("version " + reprOf(version) + " is newer than this build reads (" +
         std::to_string(pymol::kLightRigVersion) +
         "): loaded the fields it knows");
  }

  // [version, [rig fields...], [air fields...], [[light fields...], ...]]
  LightRig rig;
  auto rigFields = listAt(obj, kSlotRig, "the rig fields");
  p_return_if_error(rigFields);
  if (*rigFields) {
    auto taken = takeListFields(*rigFields, LightScope::Rig, rig, "");
    p_return_if_error(taken);
  }

  auto air = listAt(obj, kSlotAir, "'air'");
  p_return_if_error(air);
  if (*air) {
    auto taken = takeListFields(*air, LightScope::Air, rig, "air: ");
    p_return_if_error(taken);
  }

  auto lights = listAt(obj, kSlotLights, "'lights'");
  p_return_if_error(lights);
  if (*lights) {
    // The caps are policy, not format (#616 and #623 revisit the shadow
    // cap): a file from a build with higher caps loads with the extra lights
    // left out and the extra shadows turned off, each with a warning.
    const Py_ssize_t count = PySequence_Fast_GET_SIZE(*lights);
    const Py_ssize_t kept =
        std::min<Py_ssize_t>(count, pymol::kLightRigMaxLights);
    if (count > kept) {
      warn(std::to_string(count) + " lights: loaded the first " +
           std::to_string(kept) + " (at most " +
           std::to_string(pymol::kLightRigMaxLights) + " lights)");
    }
    std::vector<bool> named;
    for (Py_ssize_t i = 0; i < kept; ++i) {
      bool hasName = false;
      auto light = lightFromList(
          PySequence_Fast_GET_ITEM(*lights, i), size_t(i), hasName);
      p_return_if_error(light);
      rig.lights.push_back(std::move(*light));
      named.push_back(hasName);
    }
    nameUnnamed(rig, named);

    int shadowed = 0;
    for (size_t i = 0; i < rig.lights.size(); ++i) {
      auto& light = rig.lights[i];
      if (light.shadow && ++shadowed > pymol::kLightRigMaxShadowed) {
        light.shadow = false;
        warn(lightLabel(light, i) + ": shadow turned off (at most " +
             std::to_string(pymol::kLightRigMaxShadowed) +
             " lights can cast shadows)");
      }
    }
  }

  auto valid = pymol::LightRigValidate(rig);
  p_return_if_error(valid);
  return rig;
}

} // namespace

PyObject* LightRigAsPyDict(const LightRig& rig)
{
  unique_PyObject_ptr dict(PyDict_New());
  if (!dict)
    return nullptr;
  if (!setItem(dict.get(), "version", PyLong_FromLong(pymol::kLightRigVersion)))
    return nullptr;
  if (!putFields(dict.get(), LightScope::Rig, rig))
    return nullptr;

  PyObject* air = PyDict_New();
  if (!air || !putFields(air, LightScope::Air, rig)) {
    Py_XDECREF(air);
    return nullptr;
  }
  if (!setItem(dict.get(), "air", air))
    return nullptr;

  PyObject* lights = PyList_New(Py_ssize_t(rig.lights.size()));
  if (!lights)
    return nullptr;
  for (size_t i = 0; i < rig.lights.size(); ++i) {
    PyObject* d = PyDict_New();
    if (!d || !putFields(d, LightScope::Light, rig.lights[i])) {
      Py_XDECREF(d);
      Py_DECREF(lights);
      return nullptr;
    }
    PyList_SET_ITEM(lights, Py_ssize_t(i), d); // steals d
  }
  if (!setItem(dict.get(), "lights", lights))
    return nullptr;

  return dict.release();
}

pymol::Result<LightRig> LightRigFromPyDict(PyObject* obj)
{
  if (!PyDict_Check(obj)) {
    return pymol::make_error(
        "expected a dict (or None), got ", typeName(obj));
  }

  auto keys = checkKeys(obj, LightScope::Rig, {"version", "air", "lights"}, "");
  p_return_if_error(keys);

  if (PyObject* version = PyDict_GetItemString(obj, "version")) {
    long v = -1;
    if (PyLong_Check(version) && !PyBool_Check(version)) {
      v = PyLong_AsLong(version);
      if (v == -1 && PyErr_Occurred())
        PyErr_Clear();
    } else {
      return pymol::make_error(
          "'version' must be an int, got ", typeName(version));
    }
    if (v > pymol::kLightRigVersion) {
      return pymol::make_error("'version' ", reprOf(version),
          " is newer than this build reads (", pymol::kLightRigVersion, ")");
    }
    if (v < 1) {
      return pymol::make_error("'version' ", reprOf(version),
          " is not a light rig version (1 to ", pymol::kLightRigVersion, ")");
    }
  }

  LightRig rig;
  auto taken = takeFields(obj, LightScope::Rig, rig, "");
  p_return_if_error(taken);

  if (PyObject* air = PyDict_GetItemString(obj, "air")) {
    if (!PyDict_Check(air)) {
      return pymol::make_error("'air' must be a dict, got ", typeName(air));
    }
    auto airKeys = checkKeys(air, LightScope::Air, {}, "air: ");
    p_return_if_error(airKeys);
    auto airTaken = takeFields(air, LightScope::Air, rig, "air: ");
    p_return_if_error(airTaken);
  }

  if (PyObject* lights = PyDict_GetItemString(obj, "lights")) {
    if (!PyList_Check(lights) && !PyTuple_Check(lights)) {
      return pymol::make_error(
          "'lights' must be a list, got ", typeName(lights));
    }
    const Py_ssize_t n = PySequence_Fast_GET_SIZE(lights); // not __len__
    if (n > pymol::kLightRigMaxLights) {
      return pymol::make_error("at most ", pymol::kLightRigMaxLights,
          " lights (got ", long(n), ")");
    }
    std::vector<bool> named;
    for (Py_ssize_t i = 0; i < n; ++i) {
      bool hasName = false;
      auto light = lightFromPy(
          PySequence_Fast_GET_ITEM(lights, i), size_t(i), hasName);
      p_return_if_error(light);
      rig.lights.push_back(std::move(*light));
      named.push_back(hasName);
    }
    nameUnnamed(rig, named);
  }

  return rig;
}

PyObject* LightRigAsPyList(const LightRig& rig)
{
  // [version, [rig fields...], [air fields...], [[light fields...], ...]]:
  // the slots of rigFromList(), frozen since version 1
  unique_PyObject_ptr list(PyList_New(0));
  if (!list)
    return nullptr;
  if (!appendItem(list.get(), PyLong_FromLong(pymol::kLightRigVersion)))
    return nullptr;

  unique_PyObject_ptr rigFields(PyList_New(0));
  if (!rigFields || !appendFields(rigFields.get(), LightScope::Rig, rig) ||
      PyList_Append(list.get(), rigFields.get()) != 0)
    return nullptr;

  unique_PyObject_ptr air(PyList_New(0));
  if (!air || !appendFields(air.get(), LightScope::Air, rig) ||
      PyList_Append(list.get(), air.get()) != 0)
    return nullptr;

  unique_PyObject_ptr lights(PyList_New(0));
  if (!lights)
    return nullptr;
  for (const auto& light : rig.lights) {
    unique_PyObject_ptr entry(PyList_New(0));
    if (!entry || !appendFields(entry.get(), LightScope::Light, light) ||
        PyList_Append(lights.get(), entry.get()) != 0)
      return nullptr;
  }
  if (PyList_Append(list.get(), lights.get()) != 0)
    return nullptr;

  return list.release();
}

pymol::Result<LightRig> LightRigFromPyList(
    PyObject* obj, std::vector<std::string>* warnings)
{
  auto rig = rigFromList(obj, warnings);
  if (PyErr_Occurred())
    PyErr_Clear(); // never leave an error behind for the next session block
  return rig;
}

PyObject* LightValueAsPy(const LightField& field, const LightValue& value)
{
  return valueToPy(field, value);
}

PyObject* LightRigEyeAsPyDict(
    const LightRig& rig, const pymol::LightRigEye& eye)
{
  unique_PyObject_ptr dict(PyDict_New());
  if (!dict)
    return nullptr;
  if (!setItem(dict.get(), "enabled", PyBool_FromLong(eye.enabled)))
    return nullptr;
  if (eye.hasFrame) {
    if (!setItem(dict.get(), "centre", pyVec3(eye.centre)) ||
        !setItem(dict.get(), "size", PyFloat_FromDouble(eye.size)))
      return nullptr;
  } else {
    if (!setItem(dict.get(), "centre", pyNone()) ||
        !setItem(dict.get(), "size", pyNone()))
      return nullptr;
  }

  PyObject* lights = PyList_New(0);
  if (!setItem(dict.get(), "lights", lights))
    return nullptr;
  for (size_t i = 0; i < eye.lights.size() && i < rig.lights.size(); ++i) {
    const auto& e = eye.lights[i];
    unique_PyObject_ptr d(PyDict_New());
    if (!d)
      return nullptr;
    const bool ok =
        setItem(d.get(), "name", pyString(rig.lights[i].name)) &&
        setItem(d.get(), "anchor",
            PyUnicode_FromString(pymol::LightChoiceName(
                LightKind::Anchor, static_cast<int>(e.anchor)))) &&
        setItem(d.get(), "aim",
            PyUnicode_FromString(pymol::LightChoiceName(
                LightKind::Aim, static_cast<int>(e.aim)))) &&
        setItem(d.get(), "position", pyVec3(e.position)) &&
        setItem(d.get(), "target", pyVec3(e.target)) &&
        setItem(d.get(), "direction", pyVec3(e.direction)) &&
        setItem(d.get(), "aim_distance", PyFloat_FromDouble(e.aimDistance)) &&
        setItem(d.get(), "cos_outer", PyFloat_FromDouble(e.cosOuter)) &&
        setItem(d.get(), "cos_inner", PyFloat_FromDouble(e.cosInner)) &&
        setItem(d.get(), "orbit", PyFloat_FromDouble(e.orbit)) &&
        setItem(d.get(), "pitch", PyFloat_FromDouble(e.pitch)) &&
        setItem(d.get(), "radius", PyFloat_FromDouble(e.radius)) &&
        setItem(d.get(), "shadow", PyBool_FromLong(e.shadow)) &&
        setItem(d.get(), "outline", PyBool_FromLong(e.outline));
    if (!ok || PyList_Append(lights, d.get()) != 0) // lights is borrowed
      return nullptr;
  }
  return dict.release();
}

pymol::Result<glm::dmat4> LightMatrixFromPy(PyObject* obj)
{
  const bool seq = (PyList_Check(obj) || PyTuple_Check(obj)) &&
                   PySequence_Fast_GET_SIZE(obj) == 16; // not __len__
  if (!seq) {
    return pymol::make_error(
        "matrix must be 16 numbers (column-major) or None, got ", reprOf(obj));
  }
  glm::dmat4 m(1.0);
  for (int i = 0; i < 16; ++i) {
    double v;
    PyObject* item = PySequence_Fast_GET_ITEM(obj, i); // list or tuple
    if (!pyNumber(item, v) || !std::isfinite(v)) {
      return pymol::make_error(
          "matrix item ", i, " must be a finite number, got ", reprOf(item));
    }
    m[i / 4][i % 4] = v; // column i / 4, row i % 4
  }
  return m;
}

pymol::Result<> LightSetValueFromPy(PyObject* obj, double v[3], int& n)
{
  if (PyBool_Check(obj)) {
    v[0] = obj == Py_True ? 1.0 : 0.0;
    n = 1;
    return {};
  }
  if (pyNumber(obj, v[0])) {
    n = 1;
    return {};
  }
  if ((PyList_Check(obj) || PyTuple_Check(obj)) &&
      PySequence_Fast_GET_SIZE(obj) == 3) { // not __len__
    for (int i = 0; i < 3; ++i) {
      PyObject* item = PySequence_Fast_GET_ITEM(obj, i); // list or tuple
      if (!pyNumber(item, v[i])) {
        return pymol::make_error(
            "value item ", i, " must be a number, got ", reprOf(item));
      }
    }
    n = 3;
    return {};
  }
  return pymol::make_error(
      "value must be a number or a list of 3 numbers, got ", reprOf(obj));
}

PyObject* LightFieldsAsPyList()
{
  const LightRig rig;
  const Light light;
  const auto& fields = pymol::LightRigFields();
  PyObject* list = PyList_New(Py_ssize_t(fields.size()));
  if (!list)
    return nullptr;
  for (size_t i = 0; i < fields.size(); ++i) {
    const auto& field = fields[i];
    PyObject* def = nullptr;
    if (field.kind == LightKind::Name) {
      def = Py_None; // assigned: key, fill, rim, light4, ...
      Py_INCREF(def);
    } else if (field.scope == LightScope::Light) {
      def = valueToPy(field, LightFieldGet(light, field));
    } else {
      def = valueToPy(field, LightFieldGet(rig, field));
    }
    PyObject *lo, *hi;
    if (!field.bounded) {
      lo = Py_None;
      hi = Py_None;
      Py_INCREF(lo);
      Py_INCREF(hi);
    } else if (field.kind == LightKind::Int) {
      lo = PyLong_FromLong(long(field.lo));
      hi = PyLong_FromLong(long(field.hi));
    } else {
      lo = PyFloat_FromDouble(field.lo);
      hi = PyFloat_FromDouble(field.hi);
    }
    PyObject* entry = (def && lo && hi)
                          ? Py_BuildValue("(sssOOO)", scopeName(field.scope),
                                field.name, pymol::LightKindName(field.kind),
                                def, lo, hi)
                          : nullptr;
    Py_XDECREF(def);
    Py_XDECREF(lo);
    Py_XDECREF(hi);
    if (!entry) {
      Py_DECREF(list);
      return nullptr;
    }
    PyList_SET_ITEM(list, Py_ssize_t(i), entry);
  }
  return list;
}

#endif
